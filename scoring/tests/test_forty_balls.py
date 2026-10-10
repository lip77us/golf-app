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
    """The arithmetic on its own — no database, because it is arithmetic.

    `bounds(here, left, capacity_after)`: how many golfers can hit a ball on
    THIS hole, how many balls are still owed, and how many the later holes can
    absorb between them. With nobody withdrawn `capacity_after` is just
    `k × holes_after`, which is how these read.
    """

    def test_the_opening_hole_of_a_foursome_allows_everything(self):
        # 40 left, 17 holes after this one (68 balls of room): even 0 leaves
        # 40 reachable.
        self.assertEqual(bounds(4, 40, 4 * 17), (0, 4))

    def test_the_floor_rises_when_the_holes_run_out(self):
        # 10 left with 2 holes after: 4 + 4 = 8, so this hole must take 2.
        self.assertEqual(bounds(4, 10, 4 * 2), (2, 4))

    def test_no_slack_left_pins_every_remaining_hole(self):
        # 12 left, 2 after: 4 on each of three. No choice.
        self.assertEqual(bounds(4, 12, 4 * 2), (4, 4))

    def test_a_spent_budget_pins_them_at_zero(self):
        self.assertEqual(bounds(4, 0, 4 * 5), (0, 0))

    def test_the_ceiling_is_the_group_size_not_the_balls_left(self):
        self.assertEqual(bounds(3, 30, 3 * 17), (0, 3))
        # …and the balls left when THEY are the smaller number.
        self.assertEqual(bounds(4, 2, 4 * 9), (0, 2))

    def test_lo_above_hi_is_the_DQ_and_is_returned_UNCLAMPED(self):
        # **Left visible on purpose.** 20 balls owed with two holes of room for
        # three golfers is 6 — the budget cannot come out, and clamping the
        # pair would hide that behind a legal-looking range.
        lo, hi = bounds(3, 20, 3)
        self.assertGreater(lo, hi)


class PickingTests(_Base):
    def test_the_bounds_are_offered_BEFORE_the_hole_is_posted(self):
        # **The client shows the buttons while the group is still entering**,
        # and the count rides along in the same save. Gating them on the
        # server having the scores meant posting the hole, picking, and only
        # then moving on — and the scorer saw the buttons flash up after a
        # post and then go.
        state = hole_state(self.fs, 1)
        self.assertTrue(state['can_pick'])
        self.assertEqual((state['lo'], state['hi']), (0, 4))
        self.assertFalse(state['scores_in'])

    def test_the_SERVER_still_refuses_a_count_it_has_no_scores_for(self):
        # That is where the integrity lives: the client sends the scores first.
        submit_hole(self.fs, 1, list(zip(self.pids[:3], [4, 4, 4])))
        self.assertFalse(hole_state(self.fs, 1)['scores_in'])
        with self.assertRaises(FortyBallsLocked) as ctx:
            set_count(self.fs, 1, 2)
        self.assertIn('no scores on the server', str(ctx.exception))

    def test_a_WITHDRAWN_golfer_does_not_hold_the_hole_open(self):
        # **He cannot post a score, so waiting for one waits for ever.** The
        # first version measured against `group_size` — the budget's basis,
        # which counts every member — and the picker read `Waiting on the last
        # score` on a hole the three remaining golfers had finished.
        m = self.fs.memberships.order_by('id').last()
        m.withdrew_after_hole = 0
        m.save(update_fields=['withdrew_after_hole'])
        submit_hole(self.fs, 1, list(zip(self.pids[:3], [4, 4, 4])))
        state = hole_state(self.fs, 1)
        self.assertTrue(state['scores_in'])
        self.assertTrue(state['can_pick'])
        self.assertEqual(state['hi'], 3)     # and only three balls to spend

    def test_a_golfer_with_no_tee_does_not_hold_it_open_either(self):
        # He has nothing to score against, so he contributes no net — and
        # cannot be waited on.
        m = self.fs.memberships.order_by('id').last()
        m.tee = None
        m.save(update_fields=['tee'])
        submit_hole(self.fs, 1, list(zip(self.pids[:3], [4, 4, 4])))
        self.assertTrue(hole_state(self.fs, 1)['scores_in'])

    def test_a_pick_is_recorded_and_is_the_groups_own(self):
        self.par_hole(1, 0, 0, 0, 0)
        row = set_count(self.fs, 1, 2)
        self.assertEqual(row.count, 2)
        self.assertFalse(row.app_set)

    def test_a_count_outside_the_bounds_is_refused(self):
        self.par_hole(1, 0, 0, 0, 0)
        with self.assertRaises(FortyBallsLocked):
            set_count(self.fs, 1, 5)          # more than the group has golfers

    def test_a_hole_locks_once_the_group_has_MOVED_ON(self):
        # The choice was made with THAT hole's information; re-making it with
        # the next hole's is a different game. Stated as "a later hole has
        # scores", so it is answerable before this hole is scored too.
        self.par_hole(1, 0, 0, 0, 0)
        set_count(self.fs, 1, 2)
        self.par_hole(2, 0, 0, 0, 0)
        self.assertTrue(hole_state(self.fs, 1)['locked'])
        self.assertFalse(hole_state(self.fs, 1)['can_pick'])
        self.assertTrue(hole_state(self.fs, 2)['can_pick'])
        with self.assertRaises(FortyBallsLocked):
            set_count(self.fs, 1, 3)

    def test_even_a_PART_entered_later_hole_locks_the_one_before(self):
        # The group has moved on; that the next hole is half-entered does not
        # put the choice back.
        self.par_hole(1, 0, 0, 0, 0)
        set_count(self.fs, 1, 2)
        submit_hole(self.fs, 2, list(zip(self.pids[:2], [4, 4])))
        self.assertTrue(hole_state(self.fs, 1)['locked'])

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


class ForcedTailOnTheBoardTests(_Base):
    """A forced tail is a COMMITMENT, not a round that has been played.

    Reported from the course: a group eleven holes in read `40 of 40` with a
    total of **−97**. Spending little early forces every remaining hole to
    count all four, and the app writes those rows — correctly. The board then
    read them as played: it summed `sum([]) − 4 × par` on holes nobody had
    teed off, and counted their balls as spent.
    """

    def _force_the_tail(self):
        # 0 on the first eight leaves 40 over ten holes: every one is a 4.
        for h in range(1, 9):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, 0)

    def test_an_unplayed_hole_has_no_result(self):
        self._force_the_tail()
        card = group_card(self.fs)
        rows = {r['hole']: r for r in card['holes']}
        # Forced to 4 and nobody has hit a shot: a count it cannot fill.
        self.assertEqual(rows[12]['count'], 4)
        self.assertIsNone(rows[12]['result'])
        self.assertEqual(card['total'], 0)

    def test_the_budget_line_counts_what_was_PLAYED(self):
        self._force_the_tail()
        card = group_card(self.fs)
        self.assertEqual(card['spent'], 0)        # eight holes, no balls
        self.assertEqual(card['left'], 40)
        self.assertEqual(card['holes_left'], 10)
        # Ten holes at four apiece is exactly what is owed — no slack, and
        # emphatically not out.
        self.assertEqual(card['capacity'], 40)
        self.assertEqual(card['slack'], 0)
        self.assertFalse(card['dq'])

    def test_playing_a_forced_hole_spends_it(self):
        self._force_the_tail()
        self.par_hole(9, 0, 0, 0, 0)
        card = group_card(self.fs)
        self.assertEqual(card['spent'], 4)
        self.assertEqual(card['left'], 36)
        self.assertEqual(card['holes_left'], 9)
        self.assertEqual(card['slack'], 0)
        rows = {r['hole']: r for r in card['holes']}
        self.assertEqual(rows[9]['result'], 0)    # four pars on a par 4

    def test_a_spent_budget_forces_zeros_that_absorb_nothing(self):
        for h in range(1, 11):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, 4)
        card = group_card(self.fs)
        self.assertEqual(card['spent'], 40)
        self.assertEqual(card['left'], 0)
        # A hole forced to zero can take no ball, so there is no slack to
        # report and the group is not out.
        self.assertEqual(card['capacity'], 0)
        self.assertEqual(card['slack'], 0)
        self.assertFalse(card['dq'])

    def test_a_part_scored_hole_is_not_settled_either(self):
        # Forced to four with three of the four scores in: the group cannot
        # have counted four balls yet, so the hole is still to come.
        self._force_the_tail()
        submit_hole(self.fs, 9, list(zip(self.pids[:3], [4, 4, 4])))
        card = group_card(self.fs)
        rows = {r['hole']: r for r in card['holes']}
        self.assertEqual(rows[9]['count'], 4)
        self.assertIsNone(rows[9]['result'])
        self.assertEqual(card['spent'], 0)
        self.assertEqual(card['holes_left'], 10)


class DropoutTests(_Base):
    """**The budget stands; a dropout costs CAPACITY, not debt.**

    Ruled 26 Sep 2026. Two men left out of a threesome still owe 30 between
    them; four out of a foursome still owe 40. And when the holes left cannot
    absorb what is still owed, the group is out of 40 Balls — its scores still
    standing for the championship, because the DQ is this game's and not the
    round's.
    """

    def withdraw(self, index, after_hole):
        m = self.fs.memberships.order_by('id')[index]
        m.withdrew_after_hole = after_hole
        m.save(update_fields=['withdrew_after_hole'])
        return m

    def test_the_budget_does_not_shrink_when_a_man_drops_out(self):
        self.withdraw(3, 5)
        self.assertEqual(budget(self.fs), 40)

    def test_the_hole_ceiling_falls_to_who_is_still_playing(self):
        # You cannot count a ball nobody hit.
        self.withdraw(3, 5)
        self.par_hole(6, 0, 0, 0)
        state = hole_state(self.fs, 6)
        self.assertEqual(state['active_here'], 3)
        self.assertEqual(state['hi'], 3)
        self.assertEqual(state['group_size'], 4)   # the budget's basis

    def test_capacity_is_summed_per_hole_not_k_times_holes(self):
        # After a withdrawal the holes are not all worth the same number of
        # balls, so `k × after` would overstate the room.
        self.withdraw(3, 9)
        state = hole_state(self.fs, 1)
        # Holes 1-9 hold four, holes 10-18 hold three.
        self.assertEqual(state['capacity'], 9 * 4 + 9 * 3)

    def _spend(self, upto, n):
        """Play and pick `n` on each of the first `upto` holes.

        **A DQ cannot be set up by underspending**, which is worth knowing: the
        bounds forbid it. Spend nothing early enough and `lo` rises to pin the
        rest at 4. So the only way a group falls short is a WITHDRAWAL taking
        the room away after the fact, which is exactly the case the ruling is
        about.
        """
        for h in range(1, upto + 1):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, n)

    def test_a_group_that_cannot_reach_the_budget_is_DQd(self):
        # Ten holes at 2 is 20 spent, 20 owed, eight holes left. With four
        # golfers that is 32 of room — comfortable. Then two of them walk in.
        self._spend(10, 2)
        self.assertFalse(hole_state(self.fs, 11)['dq'])

        self.withdraw(2, 10)
        self.withdraw(3, 10)
        state = hole_state(self.fs, 11)
        self.assertTrue(state['dq'])
        self.assertEqual(state['left'], 20)
        self.assertEqual(state['capacity'], 8 * 2)   # 8 holes × 2 golfers
        self.assertFalse(state['can_pick'])

    def test_the_DQ_refusal_names_the_arithmetic_not_the_count(self):
        self._spend(10, 2)
        self.withdraw(2, 10)
        self.withdraw(3, 10)
        self.par_hole(11, 0, 0)
        with self.assertRaises(FortyBallsLocked) as ctx:
            set_count(self.fs, 11, 2)
        msg = str(ctx.exception)
        self.assertIn('20 balls', msg)
        self.assertIn('16', msg)
        self.assertIn('championship', msg)

    def test_a_DQd_group_gets_no_app_set_counts(self):
        # An app-set count on a DQ'd group is a number pretending the budget
        # still comes out.
        self._spend(10, 2)
        self.withdraw(2, 10)
        self.withdraw(3, 10)
        from services.forty_balls import _fill_forced
        _fill_forced(self.fs)
        self.assertFalse(FortyBallsHoleCount.objects
                         .filter(foursome=self.fs, app_set=True).exists())

    def test_the_card_reports_the_DQ_and_offers_no_ranking_figure(self):
        # A total built from a budget that cannot come out is not a result, and
        # sorting on it would place the group.
        self._spend(10, 2)
        self.withdraw(2, 10)
        self.withdraw(3, 10)
        card = group_card(self.fs)
        self.assertTrue(card['dq'])
        self.assertIsNone(card['ranking_total'])
        # The holes it did play are still on the card.
        self.assertEqual(len([r for r in card['holes'] if r['result'] is not None]),
                         10)

    def test_a_dropout_the_group_can_still_absorb_is_NOT_a_DQ(self):
        # Twelve holes at 3 is 36 spent, 4 owed. One man out still leaves three
        # golfers over six holes — eighteen balls of room for four.
        self._spend(12, 3)
        self.withdraw(3, 12)
        state = hole_state(self.fs, 13)
        self.assertFalse(state['dq'])
        self.assertEqual(state['left'], 4)
        self.assertEqual(state['capacity'], 6 * 3)

    def test_two_left_in_a_threesome_still_owe_thirty(self):
        # The ruling's own example.
        fs = make_foursome(self.round, [('Eve', 0), ('Fay', 0), ('Gus', 0)],
                           tee=self.tee, group_number=2)
        m = fs.memberships.order_by('id').last()
        m.withdrew_after_hole = 4
        m.save(update_fields=['withdrew_after_hole'])
        self.assertEqual(budget(fs), 30)
        state = hole_state(fs, 5)
        self.assertEqual(state['left'], 30)
        self.assertEqual(state['active_here'], 2)
        self.assertEqual(state['capacity'], 14 * 2)   # holes 5-18, two golfers
        self.assertTrue(state['dq'])


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


class ThruTests(_Base):
    """`thru` is holes PLAYED, which is not what the budget calls pending.

    The board shows it beside the group's name so one row can be compared
    against another — a group at −5 thru 9 and one at −5 thru 17 are not in
    the same position. It has to answer a different question from
    `holes_left`, and it has to answer it along the group's own play order.
    """

    def test_nothing_before_the_group_starts(self):
        # None, not 0 — the slot stays empty rather than claiming a hole.
        self.assertIsNone(group_card(self.fs)['thru'])

    def test_it_counts_the_holes_played(self):
        self.par_hole(1, 0, 0, 0, 0)
        self.par_hole(2, 0, 0, 0, 0)
        self.assertEqual(group_card(self.fs)['thru'], 2)

    def test_a_scored_hole_with_no_count_is_still_played(self):
        """The reason this is not `18 - holes_left`.

        A hole is `pending` to the budget until its balls are committed, so a
        fully scored hole with no count picked sits in both — but the group
        has played it, and a reader asking how far round they are does not
        care whether they have decided yet.
        """
        self.par_hole(1, 0, 0, 0, 0)
        card = group_card(self.fs)
        self.assertEqual(card['thru'], 1)
        # The budget still has every hole to come, including this one.
        self.assertEqual(card['holes_left'], 18)
        self.assertNotEqual(card['thru'], 18 - card['holes_left'])

    def test_a_forced_tail_does_not_advance_it(self):
        """The counterpart: a committed hole with no scores is not played.

        Once the budget forces the tail the app writes a count on every hole
        to the finish. Those holes have no balls yet, and a group reading
        "Thru 18" on the 12th tee is the bug the budget line already had.
        """
        for h in range(1, 11):
            self.par_hole(h, 0, 0, 0, 0)
            set_count(self.fs, h, 4)
        card = group_card(self.fs)
        self.assertEqual(card['thru'], 10)

    def test_a_shotgun_group_counts_along_its_own_order(self):
        """Off the 7th, two holes played is `2` — never `8`.

        The `Max('hole_number')` shape read 8 after two holes and then hit 18
        on the group's TWELFTH, where the client draws `F`. This is the one
        place that number is computed, so the whole sweep's lesson holds here.
        """
        self.fs.starting_hole = 7
        self.fs.save(update_fields=['starting_hole'])
        self.par_hole(7, 0, 0, 0, 0)
        self.par_hole(8, 0, 0, 0, 0)
        self.assertEqual(group_card(self.fs)['thru'], 2)

    def test_the_board_reports_it(self):
        from services.forty_balls import forty_balls_summary
        self.par_hole(1, 0, 0, 0, 0)
        board = forty_balls_summary(self.round)
        row = next(r for r in board['results']
                   if r['foursome_id'] == self.fs.pk)
        self.assertEqual(row['thru'], 1)

    def test_the_board_asks_for_the_played_holes_once_for_every_group(self):
        """The map is batched — `group_card` must not fetch its own.

        `forty_balls_summary` calls `group_card` per group, so computing it
        inside would be one extra round-wide query per group on a board that
        already costs a summary per game. A single-group caller may still pay
        for its own, which is why the argument is optional rather than
        required.
        """
        from unittest.mock import patch

        from services import forty_balls as fb
        make_foursome(self.round, [('Eve', 0), ('Fay', 0), ('Gus', 0),
                                   ('Hal', 0)], tee=self.tee, group_number=2)
        self.par_hole(1, 0, 0, 0, 0)
        with patch.object(fb, 'scored_holes_by_foursome',
                          wraps=fb.scored_holes_by_foursome) as spy:
            fb.forty_balls_summary(self.round)
        self.assertEqual(spy.call_count, 1)
