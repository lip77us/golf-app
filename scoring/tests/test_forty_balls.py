"""
scoring/tests/test_forty_balls.py
---------------------------------
40 Balls — the Irish Rumble family's one game where the GROUP decides.

The subject is the BUDGET. The scoring arithmetic is small (best n nets against
n × par) and most of what can go wrong is in what the group is allowed to pick:
the bounds have to make the budget come out exactly, and when they close the app
has to fill the rest in and say it did.
"""
from django.test import TestCase

from games.models import FortyBallsConfig, FortyBallsHoleCount
from services.forty_balls import (
    FortyBallsLocked, THREESOME_FACTOR, bounds, budget, group_card,
    hole_state, set_count,
)
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}


class _Base(TestCase):
    size = 4

    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.round = make_round(course=course, active_games=['forty_balls'])
        names = [('Ann', 0), ('Bea', 0), ('Cal', 0), ('Dee', 0)][:self.size]
        self.fs = make_foursome(self.round, names, tee=self.tee)
        self.cfg = FortyBallsConfig.objects.create(
            round=self.round, entry_fee=10,
            payouts=[{'place': 1, 'amount': 150}])
        self.pids = [m.player_id for m in self.fs.memberships.order_by('id')]

    def score(self, hole, *values):
        submit_hole(self.fs, hole, list(zip(self.pids, values)))

    def par_hole(self, hole, *deltas):
        self.score(hole, *[PAR[hole] + d for d in deltas])


class BudgetTests(_Base):
    def test_a_foursome_gets_forty_and_a_threesome_thirty(self):
        self.assertEqual(budget(self.fs), 40)

    def test_the_budget_is_derived_from_the_roster_not_stored(self):
        # A group that loses a player must not keep spending his ten balls.
        m = self.fs.memberships.order_by('id').last()
        m.delete()
        self.assertEqual(budget(self.fs), 30)


class BoundsTests(TestCase):
    """The arithmetic on its own — no database, because it is arithmetic."""

    def test_the_opening_hole_of_a_foursome_allows_everything(self):
        # 40 left, 17 holes after this one: even 0 leaves 40 reachable.
        self.assertEqual(bounds(4, 40, 17), (0, 4))

    def test_the_floor_rises_when_the_holes_run_out(self):
        # 10 left with 2 holes after: 4 + 4 = 8, so this hole must take 2.
        self.assertEqual(bounds(4, 10, 2), (2, 4))

    def test_no_slack_left_pins_every_remaining_hole(self):
        # 12 left, 2 after: 4 on each of three. No choice.
        self.assertEqual(bounds(4, 12, 2), (4, 4))

    def test_a_spent_budget_pins_them_at_zero(self):
        self.assertEqual(bounds(4, 0, 5), (0, 0))

    def test_the_ceiling_is_the_group_size_not_the_balls_left(self):
        self.assertEqual(bounds(3, 30, 17), (0, 3))
        # …and the balls left when THEY are the smaller number.
        self.assertEqual(bounds(4, 2, 9), (0, 2))


class PickingTests(_Base):
    def test_the_picker_waits_for_the_LAST_score_on_the_hole(self):
        # The group chooses between nets it has seen; three of four is not
        # enough to choose on.
        submit_hole(self.fs, 1, list(zip(self.pids[:3], [4, 4, 4])))
        state = hole_state(self.fs, 1)
        self.assertFalse(state['scores_in'])
        self.assertFalse(state['can_pick'])
        with self.assertRaises(FortyBallsLocked):
            set_count(self.fs, 1, 2)

    def test_a_pick_is_recorded_and_is_the_groups_own(self):
        self.par_hole(1, 0, 0, 0, 0)
        row = set_count(self.fs, 1, 2)
        self.assertEqual(row.count, 2)
        self.assertFalse(row.app_set)

    def test_a_count_outside_the_bounds_is_refused(self):
        self.par_hole(1, 0, 0, 0, 0)
        with self.assertRaises(FortyBallsLocked):
            set_count(self.fs, 1, 5)          # more than the group has golfers

    def test_only_the_most_recent_scored_hole_can_be_changed(self):
        # The choice was made with THAT hole's information; re-making it with
        # the next hole's is a different game.
        self.par_hole(1, 0, 0, 0, 0)
        set_count(self.fs, 1, 2)
        self.par_hole(2, 0, 0, 0, 0)
        self.assertFalse(hole_state(self.fs, 1)['can_pick'])
        self.assertTrue(hole_state(self.fs, 2)['can_pick'])
        with self.assertRaises(FortyBallsLocked):
            set_count(self.fs, 1, 3)

    def test_the_most_recent_hole_CAN_be_changed_before_the_next_is_scored(self):
        self.par_hole(1, 0, 0, 0, 0)
        set_count(self.fs, 1, 2)
        set_count(self.fs, 1, 3)
        self.assertEqual(hole_state(self.fs, 1)['count'], 3)


class ScoringTests(_Base):
    def test_two_threes_on_a_par_four_for_two_balls_is_minus_two(self):
        # The packet's own worked example.
        h = next(n for n in range(1, 19) if PAR[n] == 4)
        self.score(h, 3, 3, 6, 6)
        set_count(self.fs, h, 2)
        row = next(r for r in group_card(self.fs)['holes'] if r['hole'] == h)
        self.assertEqual(row['result'], -2)

    def test_the_BEST_nets_are_the_ones_that_count(self):
        h = next(n for n in range(1, 19) if PAR[n] == 4)
        self.score(h, 6, 3, 6, 4)
        set_count(self.fs, h, 2)
        row = next(r for r in group_card(self.fs)['holes'] if r['hole'] == h)
        self.assertEqual(row['result'], 3 + 4 - 2 * 4)      # −1
        self.assertEqual(set(row['counted_ids']),
                         {self.pids[1], self.pids[3]})

    def test_zero_balls_is_level_and_counts_nobody(self):
        h = next(n for n in range(1, 19) if PAR[n] == 4)
        self.score(h, 8, 8, 8, 8)
        set_count(self.fs, h, 0)
        row = next(r for r in group_card(self.fs)['holes'] if r['hole'] == h)
        self.assertEqual(row['result'], 0)
        self.assertEqual(row['counted_ids'], [])

    def test_an_unpicked_hole_contributes_nothing_yet(self):
        self.par_hole(1, -1, -1, -1, -1)
        card = group_card(self.fs)
        self.assertIsNone(card['holes'][0]['result'])
        self.assertEqual(card['total'], 0)

    def test_the_double_bogey_cap_applies_BEFORE_the_pick(self):
        # The group picks between the numbers it is shown, so a 9 on a par 4 is
        # a 6 on the card and a 6 in the sum.
        h = next(n for n in range(1, 19) if PAR[n] == 4)
        self.score(h, 9, 9, 9, 9)
        set_count(self.fs, h, 1)
        row = next(r for r in group_card(self.fs)['holes'] if r['hole'] == h)
        self.assertEqual(row['result'], 2)        # par + 2 − par

    def test_the_cap_can_be_turned_off(self):
        self.cfg.net_max_double_bogey = False
        self.cfg.save(update_fields=['net_max_double_bogey'])
        h = next(n for n in range(1, 19) if PAR[n] == 4)
        self.score(h, 9, 9, 9, 9)
        set_count(self.fs, h, 1)
        row = next(r for r in group_card(self.fs)['holes'] if r['hole'] == h)
        self.assertEqual(row['result'], 5)


class ForcedTests(_Base):
    def _play(self, upto, delta=0):
        for h in range(1, upto + 1):
            self.par_hole(h, delta, delta, delta, delta)

    def test_spending_nothing_forces_four_a_hole_at_the_end(self):
        # 0 on the first eight leaves 40 over ten holes: every one is a 4.
        for h in range(1, 9):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, 0)
        state = hole_state(self.fs, 9)
        self.assertEqual((state['lo'], state['hi']), (4, 4))
        self.assertEqual(state['slack'], 0)

        # And the app has written the whole tail rather than asking eighteen
        # times for the only answer.
        forced = FortyBallsHoleCount.objects.filter(
            foursome=self.fs, app_set=True).order_by('hole_number')
        self.assertEqual([f.hole_number for f in forced], list(range(9, 19)))
        self.assertTrue(all(f.count == 4 for f in forced))

    def test_spending_everything_forces_zero_and_says_so(self):
        for h in range(1, 11):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, 4)
        state = hole_state(self.fs, 11)
        self.assertEqual((state['lo'], state['hi']), (0, 0))
        self.assertEqual(state['left'], 0)
        forced = FortyBallsHoleCount.objects.filter(
            foursome=self.fs, app_set=True)
        self.assertEqual(forced.count(), 8)
        self.assertTrue(all(f.count == 0 for f in forced))

    def test_scores_still_count_for_the_championship_when_the_budget_is_spent(self):
        # `0 balls` is a 40 Balls fact. The round is still being played.
        for h in range(1, 11):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, 4)
        self.par_hole(11, -1, -1, -1, -1)
        from scoring.models import HoleScore
        self.assertEqual(
            HoleScore.objects.filter(foursome=self.fs, hole_number=11).count(),
            4)

    def test_changing_the_last_pick_releases_the_tail(self):
        # Undoing the choice that forced everything has to un-force it, or the
        # app's arithmetic outlives the decision it came from.
        for h in range(1, 9):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, 0)
        self.assertTrue(FortyBallsHoleCount.objects
                        .filter(foursome=self.fs, app_set=True).exists())
        set_count(self.fs, 8, 4)
        self.assertFalse(FortyBallsHoleCount.objects
                         .filter(foursome=self.fs, app_set=True).exists())


class ThreesomeTests(_Base):
    size = 3

    def test_the_budget_is_thirty_and_the_ceiling_three(self):
        self.assertEqual(budget(self.fs), 30)
        self.par_hole(1, 0, 0, 0)
        self.assertEqual(hole_state(self.fs, 1)['hi'], 3)

    def test_the_factor_is_applied_to_the_TOTAL_not_per_hole(self):
        # −4 on 30 balls ranks as −5.333…, and the per-hole figures stay raw.
        h4 = [n for n in range(1, 19) if PAR[n] == 4][:4]
        for n in h4:
            self.score(n, PAR[n] - 1, PAR[n], PAR[n])
            set_count(self.fs, n, 1)
        card = group_card(self.fs)
        self.assertEqual(card['total'], -4)
        self.assertEqual(card['holes'][0]['result'], -1)   # raw
        self.assertAlmostEqual(card['ranking_total'], -4 * 4 / 3, places=6)
        self.assertEqual(card['factor'], '4/3')


class FoursomeFactorTests(_Base):
    def test_a_foursome_ranks_on_its_raw_total(self):
        h = next(n for n in range(1, 19) if PAR[n] == 4)
        self.score(h, 3, 3, 6, 6)
        set_count(self.fs, h, 2)
        card = group_card(self.fs)
        self.assertIsNone(card['factor'])
        self.assertEqual(card['ranking_total'], -2.0)

    def test_the_factor_is_exact_so_a_tie_is_a_real_tie(self):
        # A float 4/3 decides some ties on the seventeenth decimal place.
        from fractions import Fraction
        self.assertEqual(THREESOME_FACTOR, Fraction(4, 3))
        self.assertEqual(THREESOME_FACTOR * 3, 4)
