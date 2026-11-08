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
        """A manual press is offered at exactly 1 down on the top game.

        The rule (Paul, 8 Nov 2026) is that a manual press exists to let you
        press BEFORE the auto press fires — so the window is "down, but not
        yet down far enough to be auto-pressed". The top game is 1 point a
        hole and autos at 2, so the window is the single value 1.
        """
        self._setup(press_mode='manual')
        self._play(1, 4, 4, 4, 4)        # all square
        self.assertFalse(self._card(1)['can_press'],
                         'never while the bet itself is even')
        self._play(2, 4, 4, 6, 6)
        card = self._card(2)
        self.assertTrue(card['can_press'])
        self.assertEqual(card['press_nine'], 'front')

    def test_and_NOT_at_two_down_where_the_auto_press_takes_over(self):
        self._setup(press_mode='manual')
        self._play(1, 4, 4, 6, 6)
        self._play(2, 4, 4, 6, 6)        # 2 up: the auto press's band
        self.assertFalse(self._card(2)['can_press'])
        self.assertIsNone(self._card(2)['press_nine'])

    def test_and_never_on_the_last_hole_of_a_nine(self):
        # A press cannot start after the last hole of its nine, which both
        # the engine and the handoff agree on. The margin is kept at 1 so
        # this fails for the reason it is named for.
        self._setup(press_mode='manual')
        self._play(1, 4, 4, 5, 5)
        for h in range(2, 10):
            self._play(h, 4, 4, 4, 4)
        self.assertEqual(self._card(9)['can_press'], False)

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


class ASideReadsInCardOrderTests(_CardBase):
    """`team.players` is a many-to-many with NO ordering.

    So the database returned a side's two golfers in whatever order it
    liked — `Sam + Mike` on one request and `Mike + Sam` on the next, from
    the same rows, which is how this was found: a fixture regenerated
    against unchanged code and came back with the pair the other way round.

    That is the name of a SIDE, reordering under the reader on the board,
    the tray, the side headers and the money rows. Same shape as the Sixes
    anchor, which took its anchor from set iteration.

    **The fixture forces membership order and pk order apart**, because a
    test whose inputs agree with each other cannot pin which one is read —
    that is the lesson the Sixes anchor test was rewritten for.
    """

    def setUp(self):
        super().setUp()
        # Sam's membership is recreated, so it now has the HIGHEST id while
        # Sam's player pk is still below Mike's. Card order is therefore
        # Paul, Dave, Mike, Sam — the opposite of pk order on that side.
        from tournament.models import FoursomeMembership
        sam = self.fs.memberships.get(player_id=self.pid['Sam'])
        tee, ch, ph = sam.tee, sam.course_handicap, sam.playing_handicap
        sam.delete()
        FoursomeMembership.objects.create(
            foursome=self.fs, player_id=self.pid['Sam'],
            tee=tee, course_handicap=ch, playing_handicap=ph)
        self.assertLess(self.pid['Sam'], self.pid['Mike'],
                        'the fixture only means something while the pks '
                        'run the other way')

    def _card_order(self):
        self._setup()
        self._play(1, 4, 5, 5, 6)
        return self._card(1)

    def test_the_side_label_follows_the_card(self):
        self.assertEqual([s['label'] for s in self._card_order()['sides']],
                         ['Paul + Dave', 'Mike + Sam'])

    def test_and_so_do_the_rows(self):
        card = self._card_order()
        self.assertEqual([p['first'] for p in card['players']],
                         ['Paul', 'Dave', 'Mike', 'Sam'])

    def test_and_the_money_rows(self):
        card = self._card_order()
        self.assertEqual({m['label'] for m in card['money']},
                         {'Paul + Dave', 'Mike + Sam'})

    def test_it_is_the_same_on_every_read(self):
        """The bug was not a wrong order — it was an unstable one."""
        self._setup()
        self._play(1, 4, 5, 5, 6)
        first = [s['label'] for s in self._card(1)['sides']]
        for _ in range(4):
            self.assertEqual([s['label'] for s in self._card(1)['sides']],
                             first)


class TheManualPressWindowTests(_CardBase):
    """`can_press` — the rule Paul settled on 8 Nov 2026.

    **A manual press is offered while you are down but not yet down far
    enough for that bet's AUTO press.** One rule, two numbers, because the
    numbers follow from what each bet is worth a hole:

        top    — 1 point a hole, auto at 2 down  → offered at exactly 1 down
        bottom — 2 points a hole, auto at 4      → offered at 1, 2 or 3 down

    And never while anything is level: not the bet itself, and not a press
    already running on it.
    """

    def _setup(self, **kw):
        kw.setdefault('variant', 'claremont')
        kw.setdefault('press_mode', 'manual')
        return super()._setup(**kw)

    def _bottom(self, hole, pts):
        """Play a hole worth `pts` to the BOTTOM game, from pine's side.

        +2 / -2 is both balls, +1 / -1 is one of them, 0 is level. The TOP
        game moves with it and is not what these assert.
        """
        self._play(hole, *{
            2: (4, 5, 5, 6),
            1: (4, 6, 4, 5),
            0: (4, 5, 4, 5),
            -1: (5, 6, 4, 6),
            -2: (5, 6, 4, 5),
        }[pts])

    # ── the bottom game's own window ─────────────────────────────────────
    def test_one_point_down_can_press(self):
        self._setup()
        self._bottom(1, -1)
        card = self._card(1)
        self.assertTrue(card['can_press_bottom'])
        self.assertEqual(card['press_nine_bottom'], 'front')

    def test_and_so_can_two_and_three(self):
        self._setup()
        for pts, hole in ((-2, 1), (-1, 2)):
            self._bottom(hole, pts)
            self.assertTrue(self._card(hole)['can_press_bottom'],
                            f'{abs(pts)} down should still offer one')

    def test_but_not_FOUR_where_the_bottom_auto_fires(self):
        self._setup()
        self._bottom(1, -2)
        self._bottom(2, -2)              # 4 points down
        self.assertFalse(self._card(2)['can_press_bottom'])
        self.assertIsNone(self._card(2)['press_nine_bottom'])

    def test_nor_while_the_bottom_bet_is_even(self):
        self._setup()
        self._bottom(1, 0)
        self.assertFalse(self._card(1)['can_press_bottom'])

    # ── never while a press is even ──────────────────────────────────────
    def test_a_press_just_called_blocks_a_second(self):
        """It has no holes yet, so it is even by definition — which is what
        stops one being stacked on another."""
        self._setup()
        self._bottom(1, -1)
        self.assertTrue(self._card(1)['can_press_bottom'])
        add_manual_press(self.fs, start_hole=2, side='bottom')
        self.assertFalse(self._card(1)['can_press_bottom'])

    def test_and_a_press_that_has_MOVED_does_not(self):
        self._setup()
        self._bottom(1, -1)
        add_manual_press(self.fs, start_hole=2, side='bottom')
        self._bottom(2, -1)              # bottom -2, press -1
        self.assertTrue(self._card(2)['can_press_bottom'],
                        'the press is no longer level, and 2 down is in the '
                        'bottom window')

    # ── the two games press separately ───────────────────────────────────
    def test_a_bottom_press_lands_on_the_BOTTOM_lines(self):
        self._setup()
        self._bottom(1, -1)
        add_manual_press(self.fs, start_hole=2, side='bottom')
        card = self._card(1)
        self.assertEqual(self._chips(card['bottom'], 'front'),
                         ['Front \u22121', 'P1 manual starts 2'])
        self.assertNotIn('P1 manual starts 2', self._chips(card, 'front'))

    def test_and_the_same_hole_can_start_one_of_each(self):
        self._setup()
        self._bottom(1, -1)              # top -1 too: one ball lost
        add_manual_press(self.fs, start_hole=2, side='top')
        add_manual_press(self.fs, start_hole=2, side='bottom')
        card = self._card(1)
        self.assertIn('P1 manual starts 2', self._chips(card, 'front'))
        self.assertIn('P1 manual starts 2',
                      self._chips(card['bottom'], 'front'))

    def test_a_plain_nassau_has_no_bottom_bet_to_press(self):
        self.fs.memberships.all().delete()
        self.setUp()
        super()._setup(variant='none', press_mode='manual')
        self._play(1, 5, 5, 4, 4)
        self.assertTrue(self._card(1)['can_press'])
        self.assertFalse(self._card(1)['can_press_bottom'])
        with self.assertRaises(ValueError):
            add_manual_press(self.fs, start_hole=2, side='bottom')

    # ── the nine is by POSITION ──────────────────────────────────────────
    def test_the_nine_offered_is_the_groups_own(self):
        """Off a shotgun from the 10th the first hole played is 10, and the
        old check read `last_hole < 9` — so it named the BACK nine on the
        group's very first hole. The shotgun shape, in the one place that
        decides which bet a press joins."""
        self.round.starting_hole = 10
        self.round.save(update_fields=['starting_hole'])
        self._setup()
        self._bottom(10, -1)
        card = self._card(10)
        self.assertEqual(card['press_nine_bottom'], 'front')
        self.assertEqual(card['press_nine'], 'front')


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
