"""
scoring/tests/test_live_activity_survivor.py
--------------------------------------------
The Survivor lock screen, plain and Zombie
(docs/design-review/handoff-survivor-zombie/README.md, screen 3).

Weighted towards the three things this card does that no other card in the set
does: **the headline is a word**, the **track is two-dimensional**, and the
**two locked corners** carry the reader's own hole and his own round.
"""
from django.test import TestCase

from core.models import RoundStatus
from services.live_activity_survivor import survivor_activity_state
from services.survivor import calculate_survivor, setup_survivor
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class SurvivorCardTests(TestCase):
    """Three golfers, gross, $5 a Survivor. Ann is the reader unless said."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['survivor'])
        self.round.bet_unit     = 5
        self.round.primary_game = 'survivor'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_survivor(self.fs, handicap_mode='gross', zombie_option=False)

    def _play(self, hole, a, b, c):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a),
                                    (self.pid['Ben'], b),
                                    (self.pid['Cal'], c)])
        calculate_survivor(self.fs)

    def _state(self, who='Ann', thru=None):
        return survivor_activity_state(self.fs, player_id=self.pid[who],
                                       thru=thru)

    # ── the headline is a word ───────────────────────────────────────────────

    def test_the_headline_is_a_word_not_a_number(self):
        """Every other game is measured in something. Survivor is measured in
        whether you are still in it."""
        self._play(1, 4, 4, 4)
        num = self._state()['number']
        self.assertEqual(num['text'], 'ALIVE')
        self.assertEqual(num['colour'], 'mint')
        self.assertFalse(any(c.isdigit() for c in num['text']))

    def test_a_knocked_out_reader_reads_out_in_a_plain_round(self):
        self._play(1, 6, 4, 4)          # Ann worst — out
        num = self._state(who='Ann')['number']
        self.assertEqual(num['text'], 'OUT')
        self.assertEqual(num['colour'], 'orange')

    def test_the_headline_is_the_readers_own_state(self):
        """Two phones in one group show different headlines."""
        self._play(1, 6, 4, 4)
        self.assertEqual(self._state(who='Ann')['number']['text'], 'OUT')
        self.assertEqual(self._state(who='Ben')['number']['text'], 'ALIVE')

    def test_the_count_is_a_group_fact_and_lives_in_the_state_slot(self):
        self._play(1, 6, 4, 4)
        ben = self._state(who='Ben')
        self.assertNotIn('2', ben['number']['text'])
        self.assertIn('2', ben['state']['word'])

    def test_an_eliminated_reader_is_no_longer_one_of_them(self):
        """`2 PLAYING`, not `2 IN` — the count changes person."""
        self._play(1, 6, 4, 4)
        self.assertEqual(self._state(who='Ann')['state']['word'], '2 PLAYING')

    # ── the locked corners ──────────────────────────────────────────────────

    def test_the_upper_corner_is_the_hole_the_reader_is_standing_on(self):
        self._play(1, 4, 4, 4)
        seg = self._state()['header']['segment']
        self.assertTrue(seg.startswith('HOLE 2 · PAR '), seg)

    def test_the_lower_corner_is_the_round_behind_him(self):
        """Thru is the last hole FINISHED, so it trails the hole in play."""
        self._play(1, 5, 4, 4)          # Ann +1 on a par 4
        st = self._state()
        self.assertTrue(st['header']['segment'].startswith('HOLE 2'))
        self.assertEqual(st['thru'], 'THRU 1 · +1')

    def test_level_par_reads_E(self):
        self._play(1, 4, 4, 4)
        self.assertEqual(self._state()['thru'], 'THRU 1 · E')

    def test_a_finished_round_has_no_hole_in_play(self):
        """Inventing one produced `HOLE 19` with no par and no yardage — a
        locked corner reading as a failed fetch."""
        for h in range(1, 19):
            self._play(h, 4, 4, 5)
        self.round.status = RoundStatus.COMPLETE
        self.round.save(update_fields=['status'])
        st = self._state()
        self.assertEqual(st['header']['segment'], 'ROUND COMPLETE')
        self.assertNotIn('19', str(st['ruler']))

    # ── the track ───────────────────────────────────────────────────────────

    def test_the_track_has_a_row_per_golfer(self):
        self._play(1, 4, 4, 4)
        self._play(2, 4, 4, 4)
        track = self._state()['track']
        self.assertEqual(len(track), 3)
        self.assertEqual(sum(1 for r in track if r['is_reader']), 1)

    def test_it_never_draws_more_than_five_holes(self):
        """Five cells is the practical ceiling at lock-screen width."""
        for h in range(1, 9):
            self._play(h, 4, 4, 4)      # all halved — one long Survivor
        st = self._state()
        self.assertLessEqual(len(st['ruler']), 5)
        for row in st['track']:
            self.assertLessEqual(len(row['cells']), 5)

    def test_an_eliminated_golfer_gets_no_hole_in_play(self):
        """He is not standing on the next hole in this Survivor's sense."""
        self._play(1, 6, 4, 4)          # Ann out on 1
        st = self._state(who='Ben')
        ann = next(r for r in st['track'] if r['label'].startswith('A'))
        self.assertEqual(ann['cells'][0], 'out')
        self.assertNotIn('now', ann['cells'][1:])

    def test_the_reader_is_marked_by_the_row_not_by_a_colour(self):
        """The accent belongs to the headline."""
        self._play(1, 4, 4, 4)
        st = self._state()
        reader = [r for r in st['track'] if r['is_reader']]
        self.assertEqual(len(reader), 1)
        # No CELL value encodes "this is you" — the flag is on the row, and the
        # Swift renders it as a brighter name rather than a colour.
        cells = {c for r in st['track'] for c in r['cells']}
        self.assertTrue(
            cells <= {'played', 'now', 'fut', 'out', 'gone', 'zom', 'zplay',
                      'back'},
            f'unexpected cell value: {cells}')

    # ── money ───────────────────────────────────────────────────────────────

    def test_the_money_slot_is_empty_until_a_survivor_closes(self):
        """Never a `$0`. Each Survivor is its own pot."""
        self._play(1, 4, 4, 4)
        self.assertEqual(self._state()['footer']['money'], '')

    def test_a_round_with_no_stake_says_so_rather_than_printing_zero(self):
        self.round.bet_unit = 0
        self.round.save(update_fields=['bet_unit'])
        setup_survivor(self.fs, handicap_mode='gross', zombie_option=False)
        self._play(1, 4, 4, 4)
        f = self._state()['footer']
        self.assertEqual(f['context'], 'Playing for nothing')
        self.assertEqual(f['money'], '')

    # ── the gold band ───────────────────────────────────────────────────────

    def test_a_gross_round_never_pops(self):
        self._play(1, 4, 4, 4)
        self.assertEqual(self._state()['ribbon'], '')


class SurvivorZombieCardTests(TestCase):
    """The seat holds exactly one occupant, and he is still hitting shots."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['survivor'])
        self.round.bet_unit     = 5
        self.round.primary_game = 'survivor'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_survivor(self.fs, handicap_mode='gross', zombie_option=True)

    def _play(self, hole, a, b, c):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a),
                                    (self.pid['Ben'], b),
                                    (self.pid['Cal'], c)])
        calculate_survivor(self.fs)

    def _state(self, who='Ann'):
        return survivor_activity_state(self.fs, player_id=self.pid[who])

    def test_the_game_names_itself_zombie(self):
        self._play(1, 4, 4, 4)
        self.assertEqual(self._state()['header']['game'], 'SURVIVOR · ZOMBIE')

    def test_nobody_is_out_while_the_survivor_runs(self):
        """In a Zombie round `OUT` is never used — they are in the seat."""
        self._play(1, 6, 4, 4)
        st = self._state(who='Ann')
        self.assertEqual(st['number']['text'], 'ZOMBIE')
        self.assertEqual(st['number']['colour'], 'plum')

    def test_the_seat_carries_the_offer_not_a_count(self):
        """The only actionable line on any card in the set, and it states the
        rule rather than a probability."""
        self._play(1, 6, 4, 4)
        st = self._state(who='Ann')
        self.assertEqual(st['state']['word'], 'LOW GETS')
        self.assertEqual(st['state']['to_play'], 'YOU BACK IN')

    def test_everyone_else_is_told_who_the_zombie_is(self):
        self._play(1, 6, 4, 4)
        st = self._state(who='Ben')
        self.assertIn('ZOMBIE', st['state']['to_play'])

    def test_a_zombies_row_keeps_showing_him_swinging(self):
        """Plain Survivor empties the row. Here it cannot — he is still hitting
        shots, which is the entire mechanic."""
        self._play(1, 6, 4, 4)          # Ann to the seat
        self._play(2, 5, 4, 4)          # she plays on from it
        st = self._state(who='Ben')
        ann = next(r for r in st['track'] if r['label'].startswith('A'))
        self.assertEqual(ann['cells'][0], 'zom')
        self.assertIn('zplay', ann['cells'][1:])
        self.assertNotIn('out', ann['cells'])

    def test_plum_replaces_orange_entirely_in_a_zombie_round(self):
        self._play(1, 6, 4, 4)
        st = self._state(who='Ben')
        self.assertNotIn('out', str(st['track']))
        self.assertNotEqual(st['number']['colour'], 'orange')


class TrackWindowTests(TestCase):
    """The track ends at the hole in play, never ahead of it.

    `survivor_summary` emits a row for every hole a Survivor covers, played or
    not. Taking the last five of that list drew holes 14-18 while the group
    stood on the 8th — reported from the course.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['survivor'])
        self.round.bet_unit     = 5
        self.round.primary_game = 'survivor'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_survivor(self.fs, handicap_mode='gross', zombie_option=True)

    def _play(self, hole, a, b, c):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a),
                                    (self.pid['Ben'], b),
                                    (self.pid['Cal'], c)])
        calculate_survivor(self.fs)

    def test_the_ruler_never_runs_past_the_hole_in_play(self):
        for h in range(1, 8):           # through 7, standing on the 8th
            self._play(h, 4, 4, 4)
        st = survivor_activity_state(self.fs, player_id=self.pid['Ann'])
        self.assertTrue(st['ruler'], 'a running Survivor draws a track')
        self.assertLessEqual(max(st['ruler']), 8,
                             f'track ran ahead of the group: {st["ruler"]}')
        self.assertEqual(max(st['ruler']), 8, 'the hole in play is the last cell')

    def test_the_window_holds_at_five_and_ends_on_the_hole_in_play(self):
        for h in range(1, 8):
            self._play(h, 4, 4, 4)
        st = survivor_activity_state(self.fs, player_id=self.pid['Ann'])
        self.assertEqual(st['ruler'], [4, 5, 6, 7, 8])

    def test_every_row_is_as_wide_as_the_ruler(self):
        for h in range(1, 8):
            self._play(h, 4, 4, 4)
        st = survivor_activity_state(self.fs, player_id=self.pid['Ann'])
        for row in st['track']:
            self.assertEqual(len(row['cells']), len(st['ruler']))


class FreshSurvivorTrackTests(TestCase):
    """A Survivor that has not reached its first hole yet.

    The commonest state on the tee after one closes, and it was drawing the
    last five holes of the ROUND — three different Survivors' worth of story on
    a card that is supposed to show one.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['survivor'])
        self.round.bet_unit     = 5
        self.round.primary_game = 'survivor'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_survivor(self.fs, handicap_mode='gross', zombie_option=False)

    def _play(self, hole, a, b, c):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a),
                                    (self.pid['Ben'], b),
                                    (self.pid['Cal'], c)])
        calculate_survivor(self.fs)

    def test_a_survivor_that_starts_on_the_next_hole_draws_one_cell(self):
        # Ann out on 1, Ben takes the decider on 2 — Survivor 1 closes and
        # Survivor 2 starts on the 3rd, which nobody has played.
        self._play(1, 6, 4, 4)
        self._play(2, 5, 4, 5)
        st = survivor_activity_state(self.fs, player_id=self.pid['Ann'])
        self.assertEqual(st['ruler'], [3], st['ruler'])
        for row in st['track']:
            self.assertEqual(row['cells'], ['now'])

    def test_it_does_not_borrow_the_previous_survivors_holes(self):
        self._play(1, 6, 4, 4)
        self._play(2, 5, 4, 5)
        st = survivor_activity_state(self.fs, player_id=self.pid['Ann'])
        self.assertNotIn(1, st['ruler'])
        self.assertNotIn(2, st['ruler'])
