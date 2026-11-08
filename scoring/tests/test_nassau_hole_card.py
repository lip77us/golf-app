"""
scoring/tests/test_nassau_hole_card.py
---------------------------------------
`services.nassau.nassau_hole_card` — the Nassau score-entry card
(`~/Downloads/handoff-nassau-score-entry`), Claremont included.

The press rules are the sharpest thing in the app — a press starts at 2
down on the LATEST bet in a nine, runs to the end of that nine, and closes
out against its own holes left — so every one of these plays them through
`calculate_nassau` rather than asserting a chip against a number typed here.
"""
import re
from decimal import Decimal

from django.test import TestCase

from services.nassau import (
    add_manual_press, calculate_nassau, nassau_hole_card, setup_nassau,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _CardBase(TestCase):
    """Paul + Dave against Sam + Mike, gross, $10 a bet."""

    SINGLES = False

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross',
                                net_max_double_bogey=False)
        self.round.bet_unit = Decimal('10')
        self.round.save(update_fields=['bet_unit'])
        names = ([('Paul Lipkin', 0), ('Sam Reid', 0)] if self.SINGLES
                 else [('Paul Lipkin', 0), ('Dave Kim', 0),
                       ('Sam Reid', 0), ('Mike Nash', 0)])
        self.fs = make_foursome(self.round, names, tee=self.tee)
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self, **kw):
        t1 = ([self.pid['Paul']] if self.SINGLES
              else [self.pid['Paul'], self.pid['Dave']])
        t2 = ([self.pid['Sam']] if self.SINGLES
              else [self.pid['Sam'], self.pid['Mike']])
        kw.setdefault('handicap_mode', 'gross')
        self.game = setup_nassau(self.fs, t1, t2, **kw)
        return self.game

    def _play(self, hole, *gross):
        order = (['Paul', 'Sam'] if self.SINGLES
                 else ['Paul', 'Dave', 'Sam', 'Mike'])
        submit_hole(self.fs, hole,
                    [(self.pid[n], g) for n, g in zip(order, gross)])
        calculate_nassau(self.fs)

    def _card(self, hole):
        return nassau_hole_card(self.fs, hole)

    def _chips(self, card, key, where='lines'):
        line = next(l for l in card[where] if l['key'] == key)
        return [c['text'] for c in line['chips']]


class TheHoleItselfTests(_CardBase):

    def test_the_lower_best_net_wins_it(self):
        self._setup()
        self._play(1, 4, 4, 5, 5)
        card = self._card(1)
        self.assertEqual([s['best'] for s in card['sides']], [4, 5])
        self.assertEqual(card['winner'], 'team1')
        self.assertEqual(card['reason'], 'net 4 v 5')
        self.assertEqual([s['result'] for s in card['sides']],
                         ['won', 'lost'])

    def test_the_second_ball_breaks_a_tie_and_says_so(self):
        # The handoff's phone 2: pine 4 · 4 against clay 4 · 5.
        self._setup(variant='tiebreak_2nd')
        self._play(1, 4, 4, 4, 5)
        card = self._card(1)
        self.assertEqual(card['winner'], 'team1')
        self.assertEqual(card['reason'], '2nd ball 4 v 5')

    def test_without_the_option_the_same_hole_is_halved(self):
        self._setup(variant='none')
        self._play(1, 4, 4, 4, 5)
        card = self._card(1)
        self.assertEqual(card['winner'], 'halved')
        self.assertEqual(card['reason'], 'net 4 v 4')

    def test_the_counting_ball_is_named(self):
        self._setup()
        self._play(1, 4, 6, 5, 7)
        card = self._card(1)
        self.assertEqual(card['sides'][0]['sub'], 'counts: Paul')
        self.assertEqual(card['sides'][1]['sub'], 'counts: Sam')

    def test_a_fresh_hole_has_a_card_and_no_result(self):
        self._setup()
        card = self._card(1)
        self.assertTrue(card)
        self.assertEqual(card['scored'], 0)
        self.assertFalse(card['hole_complete'])
        self.assertIsNone(card['winner'])
        self.assertEqual(card['reason'], '')

    def test_no_game_means_no_card(self):
        self.assertEqual(nassau_hole_card(self.fs, 1), {})


class TheBetLinesTests(_CardBase):

    def test_the_back_nine_says_when_it_starts(self):
        self._setup()
        self._play(1, 4, 4, 5, 5)
        card = self._card(1)
        self.assertEqual(self._chips(card, 'front'), ['Front 1 UP'])
        self.assertEqual(self._chips(card, 'back'), ['Back starts 10'])
        self.assertEqual(self._chips(card, 'overall'), ['Overall 1 UP'])

    def test_level_reads_AS(self):
        self._setup()
        self._play(1, 4, 4, 4, 4)
        self.assertEqual(self._chips(self._card(1), 'front'), ['Front AS'])

    def test_an_auto_press_starts_the_NEXT_hole(self):
        # Two down on the front is the trigger; the press runs from 3.
        self._setup(press_mode='auto')
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)
        card = self._card(2)
        chips = self._chips(card, 'front')
        self.assertEqual(chips[0], 'Front 2 UP')
        self.assertEqual(chips[1], 'P1 starts 3',
                         'a press called on 2 is a promise until 3 is played')

    def test_and_goes_live_once_its_first_hole_is_played(self):
        self._setup(press_mode='auto')
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)
        self._play(3, 5, 5, 4, 4)
        chips = self._chips(self._card(3), 'front')
        self.assertEqual(chips[0], 'Front 1 UP')
        self.assertEqual(chips[1], 'P1 1 UP')

    def test_a_manual_press_is_labelled_as_one(self):
        self._setup(press_mode='manual')
        self._play(1, 5, 5, 4, 4)        # pine 1 down
        card = self._card(1)
        self.assertTrue(card['can_press'])
        self.assertEqual(card['press_nine'], 'front')
        add_manual_press(self.fs, start_hole=2)
        self._play(2, 4, 4, 5, 5)
        chips = self._chips(self._card(2), 'front')
        self.assertIn('P1 manual 1 UP', chips)

    def test_the_press_button_is_the_ENGINE_s_answer(self):
        """**And the engine and the handoff disagree**, which is recorded
        rather than resolved here.

        The handoff offers a manual press when the trailing side is *1 down
        or level*. `nassau_summary.can_press` offers it on ANY non-zero
        margin and never at level — so a level match shows no button, and a
        side five down still sees one. That is the shipped rule and it is
        money, so the card reports it.
        """
        self._setup(press_mode='manual')
        self._play(1, 4, 4, 4, 4)        # all square
        self.assertFalse(self._card(1)['can_press'],
                         'the engine does not offer a press at level')
        self._play(2, 4, 4, 6, 6)
        card = self._card(2)
        self.assertTrue(card['can_press'])
        self.assertEqual(card['press_nine'], 'front')

    def test_and_never_on_the_last_hole_of_a_nine(self):
        # A press cannot start after the last hole of its nine, which both
        # the engine and the handoff agree on.
        self._setup(press_mode='manual')
        for h in range(1, 10):
            self._play(h, 4, 4, 5, 5)
        self.assertFalse(self._card(9)['can_press'])

    def test_a_closed_out_nine_reads_its_notation(self):
        self._setup()
        for h in (1, 2, 3, 4, 5):
            self._play(h, 4, 4, 5, 5)    # 5 up with 4 to play
        card = self._card(5)
        self.assertEqual(self._chips(card, 'front'), ['5&4'])

    def test_a_level_nine_at_its_end_is_a_push(self):
        self._setup()
        for h in range(1, 10):
            self._play(h, 4, 4, 4, 4)
        self.assertEqual(self._chips(self._card(9), 'front'), ['Push'])

    def test_there_are_never_presses_on_the_overall(self):
        self._setup(press_mode='auto')
        for h in (1, 2, 3):
            self._play(h, 4, 4, 5, 5)
        self.assertEqual(len(self._chips(self._card(3), 'overall')), 1)


class TheMoneyTests(_CardBase):

    def test_it_is_the_board_s_own_live_total(self):
        from services.nassau import nassau_summary
        self._setup()
        for h in (1, 2, 3):
            self._play(h, 4, 4, 5, 5)
        card = self._card(3)
        live = nassau_summary(self.fs)['payouts']['live_total']
        self.assertEqual(card['money'][0]['amount'], live)
        self.assertEqual(round(sum(m['amount'] for m in card['money']), 2), 0)

    def test_the_leading_side_is_first(self):
        self._setup()
        self._play(1, 5, 5, 4, 4)
        card = self._card(1)
        self.assertEqual(card['money'][0]['side'], 2)

    def test_no_stake_means_no_money_rows(self):
        self.round.bet_unit = Decimal('0')
        self.round.save(update_fields=['bet_unit'])
        self._setup()
        self._play(1, 4, 4, 5, 5)
        self.assertEqual(self._card(1)['money'], [])


class ClaremontTests(_CardBase):

    def _setup(self, **kw):
        kw.setdefault('variant', 'claremont')
        return super()._setup(**kw)

    def _reach(self, hole):
        """The match-play walk stops at the first unscored hole in play
        order, so a test about hole 7 has to play the six before it. These
        halve, so they move neither game."""
        for h in range(1, hole):
            self._play(h, 4, 5, 4, 5)

    def test_the_balls_grid_names_both_of_them(self):
        # The handoff's phone 8: low 4 v 4 halved, high 4 v 5 to pine.
        self._setup()
        self._reach(7)
        self._play(7, 4, 4, 4, 5)
        card = self._card(7)
        self.assertTrue(card['claremont'])
        balls = card['bottom']['balls']
        self.assertEqual([b['low'] for b in balls], [4, 4])
        self.assertEqual([b['high'] for b in balls], [4, 5])
        self.assertFalse(balls[0]['low_won'])
        self.assertTrue(balls[0]['high_won'])
        self.assertFalse(balls[1]['high_won'])

    def test_the_hole_pays_its_points(self):
        self._setup()
        self._reach(7)
        self._play(7, 4, 4, 4, 5)
        self.assertEqual(self._card(7)['bottom']['points'], 1)

    def test_both_balls_to_one_side_is_two_points(self):
        self._setup()
        self._reach(7)
        self._play(7, 4, 4, 5, 6)
        self.assertEqual(self._card(7)['bottom']['points'], 2)

    def test_the_bottom_lines_read_in_POINTS(self):
        self._setup()
        self._play(1, 4, 4, 5, 6)
        chips = self._chips(self._card(1)['bottom'], 'front', where='lines')
        self.assertEqual(chips, ['Front +2'])

    def test_a_level_bottom_bet_reads_E(self):
        self._setup()
        self._play(1, 4, 5, 5, 4)
        self.assertEqual(
            self._chips(self._card(1)['bottom'], 'front', where='lines'),
            ['Front E'])

    def test_the_money_note_splits_the_total(self):
        self._setup()
        for h in (1, 2, 3):
            self._play(h, 4, 4, 5, 6)
        card = self._card(3)
        self.assertIn('top ', card['money_note'])
        self.assertIn('bottom ', card['money_note'])
        self.assertIn('Paul + Dave', card['money_note'])

    def test_and_the_two_halves_SUM_to_the_figure_above_it(self):
        """A split that does not add up is not a split.

        `top_total` / `bottom_total` are the money already BANKED, which
        mid-round is zero — so the note read `top +$0 · bottom +$0` under a
        headline of +$40.
        """
        self._setup()
        for h in (1, 2, 3):
            self._play(h, 4, 4, 5, 6)
        card = self._card(3)
        lead = card['money'][0]
        self.assertGreater(lead['amount'], 0)
        figures = [float(x) for x in
                   re.findall(r'[+\u2212]\$([\d.]+)', card['money_note'])]
        signs = [1 if c == '+' else -1
                 for c in re.findall(r'([+\u2212])\$', card['money_note'])]
        self.assertEqual(len(figures), 2)
        self.assertAlmostEqual(sum(f * g for f, g in zip(figures, signs)),
                               lead['amount'], places=2)

    def test_the_bottom_game_shows_its_OWN_presses(self):
        """The bottom game presses at 4 down, the top at 2.

        So a top press is routine while the bottom is still level-ish, and
        reading one press list for both drew the top game's press under the
        bottom game's line — a bet the group never made.
        """
        self._setup(press_mode='auto')
        # Pine take the low ball both holes and the high balls halve:
        # top +2 (auto press), bottom +2 (needs 4, so no press).
        self._play(1, 4, 5, 5, 5)
        self._play(2, 4, 5, 5, 5)
        card = self._card(2)
        self.assertEqual(self._chips(card, 'front'),
                         ['Front 2 UP', 'P1 starts 3'])
        self.assertEqual(self._chips(card['bottom'], 'front'), ['Front +2'])

    def test_a_plain_nassau_has_no_bottom_game(self):
        self.fs.memberships.all().delete()
        self.setUp()
        super()._setup(variant='none')
        self._play(1, 4, 4, 5, 5)
        card = self._card(1)
        self.assertFalse(card['claremont'])
        self.assertIsNone(card['bottom'])
        self.assertEqual(card['money_note'], '')


class SinglesNassauTests(_CardBase):
    SINGLES = True

    def test_one_golfer_a_side(self):
        self._setup()
        self._play(1, 4, 5)
        card = self._card(1)
        self.assertTrue(card['singles'])
        self.assertEqual([s['label'] for s in card['sides']], ['Paul', 'Sam'])
        self.assertEqual(card['sides'][0]['sub'], 'CH 0 · no stroke')
        self.assertEqual(card['reason'], 'net 4 v 5')


class ItFollowsPlayOrderTests(_CardBase):

    def setUp(self):
        super().setUp()
        self.round.starting_hole = 10
        self.round.save(update_fields=['starting_hole'])

    def test_the_nine_being_played_is_the_groups_own(self):
        # Off the 10th the FIRST nine played is 10..18, which the engine
        # already treats as the front bet.
        self._setup()
        self._play(10, 4, 4, 5, 5)
        card = self._card(10)
        self.assertEqual(card['thru'], 1)
        self.assertEqual(card['nine'], 'front nine')
        self.assertEqual(self._chips(card, 'front'), ['Front 1 UP'])
        self.assertEqual(self._chips(card, 'back'), ['Back starts 1'])

    def test_and_the_second_nine_is_holes_1_to_9(self):
        self._setup()
        card = self._card(1)
        self.assertEqual(card['thru'], 10)
        self.assertEqual(card['nine'], 'back nine')


class NassauFixtureRegenTests(_CardBase):
    """Writes the JSON `mobile/test/nassau_entry_test.dart` draws, from the
    REAL engine.

    `REGEN_NASSAU_FIXTURES=1 manage.py test scoring.tests.test_nassau_hole_card`
    rewrites them. A tray tested against hand-written JSON is tested against
    what somebody THOUGHT the server sends — and the press chips are the
    thing most worth not guessing at.
    """

    def _write(self, name, card):
        import json, os, pathlib
        if os.environ.get('REGEN_NASSAU_FIXTURES') != '1':
            return
        path = (pathlib.Path(__file__).resolve().parents[2]
                / 'mobile' / 'test' / 'fixtures' / name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(card, indent=2, default=str) + '\n')

    def test_regenerate_the_second_ball_and_an_auto_press(self):
        """The handoff's phone 2: the best balls tie, the 2nd ball wins it,
        and the loser's press starts next hole."""
        self._setup(press_mode='auto', variant='tiebreak_2nd')
        # Both holes: best balls tie on 4 and pine's second ball is lower.
        self._play(1, 4, 4, 4, 5)
        self._play(2, 4, 4, 4, 5)          # pine 2 UP → press starts 3
        card = self._card(2)
        self.assertEqual(card['winner'], 'team1')
        self.assertEqual(card['reason'], '2nd ball 4 v 5',
                         'the hole turned on the second ball, not the best')
        self.assertIn('P1 starts 3', self._chips(card, 'front'))
        self._write('nassau_hole2_press.json', card)

    def test_regenerate_a_manual_press_in_play(self):
        """Phone 4: pine pressed on 5 and won the 7th."""
        # Presses at the same stake as the bets, which is what the handoff
        # draws — the default is $0, and a press worth nothing makes the
        # money card say nothing about the one bet that moved.
        self._setup(press_mode='manual', press_unit=10)
        self._play(1, 5, 5, 4, 4)          # pine 1 down
        for h in (2, 3, 4):
            self._play(h, 4, 4, 4, 4)      # halved
        add_manual_press(self.fs, start_hole=5)
        self._play(5, 4, 4, 4, 4)
        self._play(6, 4, 4, 4, 4)
        self._play(7, 4, 4, 5, 5)          # pine win → front AS, press 1 UP
        card = self._card(7)
        self.assertEqual(self._chips(card, 'front'),
                         ['Front AS', 'P1 manual 1 UP'])
        self._write('nassau_hole7_manual.json', card)

    def test_regenerate_nothing_entered(self):
        """The hole before anybody has typed anything."""
        self._setup()
        card = self._card(1)
        self.assertTrue(all(p['gross'] is None for p in card['players']))
        self.assertIsNone(card['winner'])
        self._write('nassau_hole1_empty.json', card)


class ClaremontFixtureRegenTests(_CardBase):
    """The Claremont fixture — the balls grid and the bottom game's own
    lines, which a plain Nassau card has no reason to carry.

    **`_CardBase`, not `ClaremontTests`** — a subclass re-runs its parent's
    tests, which is how `api/test_day_bet.py` ended up running four of its
    own against a fixture they were not written for.
    """

    def _setup(self, **kw):
        kw.setdefault('variant', 'claremont')
        return super()._setup(**kw)

    def _reach(self, hole):
        for h in range(1, hole):
            self._play(h, 4, 5, 4, 5)

    def _write(self, name, card):
        import json, os, pathlib
        if os.environ.get('REGEN_NASSAU_FIXTURES') != '1':
            return
        path = (pathlib.Path(__file__).resolve().parents[2]
                / 'mobile' / 'test' / 'fixtures' / name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(card, indent=2, default=str) + '\n')

    def test_regenerate_claremont(self):
        self._setup(press_mode='auto')
        self._reach(7)
        self._play(7, 4, 4, 4, 5)          # low halved, high to pine
        card = self._card(7)
        self.assertTrue(card['claremont'])
        self.assertEqual(card['bottom']['points'], 1)
        self._write('nassau_hole7_claremont.json', card)
