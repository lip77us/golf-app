"""
scoring/tests/test_hot_spot.py
------------------------------
Hot Spot — one anchor per hole whose score always counts, plus the best net
of the other three.

The tests that matter are the ones about the difference from Irish Rumble,
which Hot Spot shares an engine with: the anchor cannot be dropped however
bad it is, the rotation follows the group's own play order, the last two
holes obey the organiser, the borrowed 4th can count but never anchors, and
the order locks when the first score lands.

Spec: `~/Downloads/handoff-hot-spot/HANDOFF.md`.
"""
from __future__ import annotations

import random

from django.test import TestCase

from core.models import HandicapMode
from services.hot_spot import (HotSpotLocked, anchor_order, calculate_hot_spot,
                               hole_plan_for, hot_spot_summary,
                               order_fully_locked, set_anchor_order,
                               spent_positions,
                               setup_hot_spot)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    """Two full groups, so a total is ranked against a real field."""

    def setUp(self):
        random.seed(20261009)
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['hot_spot'])
        self.groups = []
        for n, names in enumerate((('A', 'B', 'C', 'D'),
                                   ('E', 'F', 'G', 'H')), start=1):
            self.groups.append(
                make_foursome(self.round, [(x, 0) for x in names],
                              tee=self.tee, group_number=n))
        self.fs, self.other = self.groups

    def _pids(self, fs):
        return [m.player_id for m in
                fs.memberships.select_related('player').order_by('player__name')
                if not m.player.is_phantom]

    def _play(self, fs, hole, scores):
        submit_hole(fs, hole, list(zip(self._pids(fs), scores)))

    def _row(self, fs, summary=None):
        summary = summary or hot_spot_summary(self.round)
        return next(r for r in summary['overall']
                    if r['foursome_id'] == fs.pk)

    def _gross(self, **kw):
        kw.setdefault('handicap_mode', HandicapMode.GROSS)
        return setup_hot_spot(self.round, **kw)


class TheAnchorIsTheGameTests(_Base):

    def test_the_anchor_counts_however_bad_it_is(self):
        """Rumble would drop a 9 and take the two 4s. Hot Spot cannot: the
        anchor's ball is the one that has to be carried."""
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)          # A anchors hole 1
        self._play(self.fs, 1, [9, 4, 4, 4])     # A has the 9
        row = self._row(self.fs)
        # 9 (the anchor, capped) + 4 (best of the others), not 4 + 4.
        self.assertEqual(row['total_score'], 6 + 4)

    def test_the_cap_is_a_rule_so_the_anchors_blow_up_is_bounded(self):
        """Par 4 capped at 6 under gross. Without the cap the 9 would stand
        and one hole would decide the field."""
        self.round.net_max_double_bogey = False
        self.round.save(update_fields=['net_max_double_bogey'])
        self._gross()
        set_anchor_order(self.fs, self._pids(self.fs))
        self._play(self.fs, 1, [9, 4, 4, 4])
        # The round's opt-in cap is OFF and the 9 is still a 6.
        self.assertEqual(self._row(self.fs)['total_score'], 10)

    def test_exactly_two_scores_count_on_an_ordinary_hole(self):
        self._gross()
        set_anchor_order(self.fs, self._pids(self.fs))
        self._play(self.fs, 1, [5, 4, 4, 4])
        summary = hot_spot_summary(self.round)
        hole = next(g for g in summary['groups']
                    if g['foursome_id'] == self.fs.pk)['holes'][0]
        self.assertEqual(hole['count'], 2)
        self.assertEqual(len(hole['counted_ids']), 2)
        self.assertEqual(hole['counted_total'], 9)

    def test_the_hole_does_not_score_until_the_anchor_posts(self):
        """The anchor's score IS the hole, so three of four is not enough."""
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        submit_hole(self.fs, 1, list(zip(pids[1:], [4, 4, 4])))
        self.assertIsNone(self._row(self.fs)['net_to_par'])


class TheRotationTests(_Base):

    def test_the_order_repeats_every_four_holes(self):
        config = self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        plan = hole_plan_for(self.round, self.fs, config)
        for hole in range(1, 19):
            self.assertEqual(plan[hole]['anchor'], pids[(hole - 1) % 4])

    def test_the_first_two_anchor_five_holes_and_the_others_four(self):
        """The handoff's own arithmetic, which is what 18 over 4 gives."""
        config = self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        plan = hole_plan_for(self.round, self.fs, config)
        counts = [sum(1 for h in plan.values() if h['anchor'] == pid)
                  for pid in pids]
        self.assertEqual(counts, [5, 5, 4, 4])

    def test_the_rotation_follows_play_order_not_hole_number(self):
        """A shotgun group starting on the 7th anchors from ITS first tee.
        Hole number and play position are the same integer only on a round
        that starts at the 1st."""
        self.fs.starting_hole = 7
        self.fs.save(update_fields=['starting_hole'])
        config = self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        plan = hole_plan_for(self.round, self.fs, config)
        self.assertEqual(plan[7]['anchor'], pids[0],
                         'the group\'s FIRST hole is anchored by the first '
                         'golfer in the order')
        self.assertEqual(plan[8]['anchor'], pids[1])
        self.assertEqual(plan[1]['anchor'], pids[(12) % 4],
                         'hole 1 is the 13th hole this group plays')


class TheLastTwoHolesTests(_Base):

    def test_keep_rotating_leaves_an_anchor_on_every_hole(self):
        config = self._gross(finish_rule='keep_rotating')
        set_anchor_order(self.fs, self._pids(self.fs))
        plan = hole_plan_for(self.round, self.fs, config)
        self.assertIsNotNone(plan[17]['anchor'])
        self.assertIsNotNone(plan[18]['anchor'])

    def test_best_2_drops_the_anchor_on_the_last_two(self):
        config = self._gross(finish_rule='best_2')
        set_anchor_order(self.fs, self._pids(self.fs))
        plan = hole_plan_for(self.round, self.fs, config)
        self.assertIsNone(plan[17]['anchor'])
        self.assertIsNone(plan[18]['anchor'])
        self.assertEqual((plan[17]['count'], plan[18]['count']), (2, 2))

    def test_three_then_four(self):
        config = self._gross(finish_rule='three_then_four')
        set_anchor_order(self.fs, self._pids(self.fs))
        plan = hole_plan_for(self.round, self.fs, config)
        self.assertEqual((plan[17]['count'], plan[18]['count']), (3, 4))
        self.assertIsNone(plan[18]['anchor'])

    def test_best_2_really_takes_the_two_best_not_the_anchors(self):
        self._gross(finish_rule='best_2')
        set_anchor_order(self.fs, self._pids(self.fs))
        for h in range(1, 17):
            self._play(self.fs, h, [4, 4, 4, 4])
        self._play(self.fs, 17, [8, 8, 3, 3])     # the two low count
        summary = hot_spot_summary(self.round)
        hole = next(g for g in summary['groups']
                    if g['foursome_id'] == self.fs.pk)['holes'][16]
        self.assertEqual(hole['counted_total'], 6)


class TheBorrowedFourthTests(_Base):
    """A threesome borrows a ball from the field, as in Irish Rumble."""

    def setUp(self):
        super().setUp()
        self.three = make_foursome(self.round, [('X', 0), ('Y', 0), ('Z', 0)],
                                   tee=self.tee, group_number=3)

    def test_the_order_holds_only_the_real_golfers(self):
        self._gross()
        self.assertEqual(len(anchor_order(self.three)), 3)

    def test_a_threesome_rotates_three(self):
        config = self._gross()
        pids = self._pids(self.three)
        set_anchor_order(self.three, pids)
        plan = hole_plan_for(self.round, self.three, config)
        for hole in range(1, 19):
            self.assertEqual(plan[hole]['anchor'], pids[(hole - 1) % 3])

    def test_the_borrowed_ball_never_anchors(self):
        config = self._gross()
        plan = hole_plan_for(self.round, self.three, config)
        real = set(self._pids(self.three))
        anchors = {h['anchor'] for h in plan.values() if h['anchor']}
        self.assertTrue(anchors <= real)


class TheOrderLocksTests(_Base):

    def test_the_order_can_be_set_before_any_score(self):
        self._gross()
        pids = self._pids(self.fs)
        self.assertEqual(set_anchor_order(self.fs, list(reversed(pids))),
                         list(reversed(pids)))

    def test_the_first_score_locks_the_position_it_spent(self):
        """Hole 1 fixes position 1 — and reversing the order moves it."""
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        self._play(self.fs, 1, [4, 4, 4, 4])
        with self.assertRaises(HotSpotLocked):
            set_anchor_order(self.fs, list(reversed(pids)))

    def test_an_order_naming_the_wrong_golfers_is_refused(self):
        self._gross()
        pids = self._pids(self.fs)
        with self.assertRaises(HotSpotLocked):
            set_anchor_order(self.fs, pids[:3])

    def test_an_unset_order_falls_back_to_card_order(self):
        """An unset order must not make the round unscoreable."""
        self._gross()
        self.assertEqual(len(anchor_order(self.fs)), 4)
        self._play(self.fs, 1, [4, 4, 4, 4])
        self.assertEqual(self._row(self.fs)['total_score'], 8)


class StablefordIsTheSameRankingTests(_Base):
    """The forced cap keeps the points mapping linear, so points are
    `2 * balls - net_to_par` and the order never differs. See the module
    docstring in services/hot_spot.py."""

    def _full_round(self):
        for fs, base in ((self.fs, 4), (self.other, 5)):
            set_anchor_order(fs, self._pids(fs))
            for h in range(1, 19):
                self._play(fs, h, [base, base, base + 1, base + 1])

    def test_points_are_two_per_counting_ball_minus_net_to_par(self):
        self._gross(scoring='stableford')
        self._full_round()
        for row in hot_spot_summary(self.round)['overall']:
            self.assertEqual(row['points'],
                             2 * row['counting_balls'] - row['net_to_par'])

    def test_the_ranking_is_identical_either_way(self):
        self._gross(scoring='stableford')
        self._full_round()
        rows = hot_spot_summary(self.round)['overall']
        by_points = [r['foursome_id'] for r in
                     sorted(rows, key=lambda r: -r['points'])]
        by_to_par = [r['foursome_id'] for r in
                     sorted(rows, key=lambda r: r['net_to_par'])]
        self.assertEqual(by_points, by_to_par)


class TheFieldAndTheMoneyTests(_Base):

    def test_the_lower_total_wins_the_field(self):
        self._gross(entry_fee=20, payouts=[{'place': 1, 'amount': 40.0}])
        for fs, base in ((self.fs, 4), (self.other, 5)):
            set_anchor_order(fs, self._pids(fs))
            for h in range(1, 19):
                self._play(fs, h, [base] * 4)
        self.assertEqual(self._row(self.fs)['rank'], 1)
        self.assertEqual(self._row(self.other)['rank'], 2)
        self.assertEqual(self._row(self.fs)['payout'], 40.0)
        self.assertEqual(self._row(self.other)['payout'], 0.0)

    def test_calculate_writes_one_row_per_group_and_is_repeatable(self):
        self._gross()
        set_anchor_order(self.fs, self._pids(self.fs))
        self._play(self.fs, 1, [4, 4, 4, 4])
        self.assertEqual(len(calculate_hot_spot(self.round)), 2)
        self.assertEqual(len(calculate_hot_spot(self.round)), 2)

    def test_strokes_off_is_refused(self):
        with self.assertRaises(ValueError):
            setup_hot_spot(self.round,
                           handicap_mode=HandicapMode.STROKES_OFF)


class TheCardKnowsWhatWasCappedTests(_Base):
    """A capped score reads `par + 2` exactly like a genuine net double bogey,
    so the card cannot tell them apart after the fact — the index has to say
    so while it is clamping."""

    def test_a_clamped_score_is_named(self):
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        self._play(self.fs, 1, [9, 4, 4, 4])     # A's 9 is clamped to 6
        hole = next(g for g in hot_spot_summary(self.round)['groups']
                    if g['foursome_id'] == self.fs.pk)['holes'][0]
        self.assertEqual(hole['capped_ids'], [pids[0]])

    def test_a_real_double_bogey_is_not_named(self):
        """Par 4, a 6 is a double bogey on its own merits — nothing clamped."""
        self._gross()
        set_anchor_order(self.fs, self._pids(self.fs))
        self._play(self.fs, 1, [6, 4, 4, 4])
        hole = next(g for g in hot_spot_summary(self.round)['groups']
                    if g['foursome_id'] == self.fs.pk)['holes'][0]
        self.assertEqual(hole['capped_ids'], [])


class PositionsLockOneAtATimeTests(_Base):
    """Red Ball's rule, which Hot Spot did not have.

    A scored hole fixes the ONE position that anchored it. The old rule
    refused the whole order at the first score — not wrong about hole 1, but
    wrong about holes 2, 3 and 4, which had decided nothing and could no
    longer be arranged. A group that teed off and then noticed it had the
    back three the wrong way round had no way to fix it.
    """

    def test_nothing_is_spent_before_a_score(self):
        self._gross()
        self.assertEqual(spent_positions(self.fs), set())
        self.assertFalse(order_fully_locked(self.fs))

    def test_one_hole_spends_one_position(self):
        self._gross()
        set_anchor_order(self.fs, self._pids(self.fs))
        self._play(self.fs, 1, [4, 4, 4, 4])
        self.assertEqual(spent_positions(self.fs), {0})

    def test_the_unspent_positions_can_still_be_arranged(self):
        """The whole point. Hole 1 is played; 2, 3 and 4 are not."""
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        self._play(self.fs, 1, [4, 4, 4, 4])
        # Keep position 1, reverse the rest.
        wanted = [pids[0], pids[3], pids[2], pids[1]]
        self.assertEqual(set_anchor_order(self.fs, wanted), wanted)

    def test_moving_a_spent_position_is_refused_and_names_it(self):
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        self._play(self.fs, 1, [4, 4, 4, 4])
        self._play(self.fs, 2, [4, 4, 4, 4])
        with self.assertRaises(HotSpotLocked) as caught:
            set_anchor_order(self.fs, [pids[1], pids[0], pids[2], pids[3]])
        # 1-based in the message, because the sheet numbers the rows 1..4.
        self.assertIn('1', str(caught.exception))
        self.assertIn('2', str(caught.exception))

    def test_re_posting_the_same_order_is_not_a_change(self):
        """A client that saves what it was given is not moving anything.

        Refusing it would make the sheet's own Save button fail on a round
        already under way, which is how a lock becomes a dead end.
        """
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        self._play(self.fs, 1, [4, 4, 4, 4])
        self.assertEqual(set_anchor_order(self.fs, pids), pids)

    def test_four_holes_spend_everything(self):
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        for h in (1, 2, 3, 4):
            self._play(self.fs, h, [4, 4, 4, 4])
        self.assertEqual(spent_positions(self.fs), {0, 1, 2, 3})
        self.assertTrue(order_fully_locked(self.fs))
        with self.assertRaises(HotSpotLocked) as caught:
            set_anchor_order(self.fs, list(reversed(pids)))
        self.assertIn('nothing left to change', str(caught.exception))

    def test_holes_entered_OUT_of_order_spend_the_right_position(self):
        """Why this is a SET and not a leading count.

        A group that posts the 3rd first has spent position 3 and nothing
        else. A count of leading positions cannot say that: 0 would let the
        3rd be moved, and 3 would freeze two positions that decided nothing.
        """
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        self._play(self.fs, 3, [4, 4, 4, 4])
        self.assertEqual(spent_positions(self.fs), {2})
        # 1, 2 and 4 are still free.
        wanted = [pids[3], pids[1], pids[2], pids[0]]
        self.assertEqual(set_anchor_order(self.fs, wanted), wanted)
        # 3 is not.
        with self.assertRaises(HotSpotLocked):
            set_anchor_order(self.fs, [pids[0], pids[2], pids[1], pids[3]])

    def test_a_shotgun_group_spends_by_PLAY_ORDER(self):
        """Off the 7th, the group's first hole is the 7th.

        Hole number and play-order position are the same integer only on a
        round starting at the 1st — the rotation already follows play order,
        so the lock has to as well, or a shotgun group would be told it had
        spent a position it has not reached.
        """
        self.fs.starting_hole = 7
        self.fs.save(update_fields=['starting_hole'])
        self._gross()
        pids = self._pids(self.fs)
        set_anchor_order(self.fs, pids)
        self._play(self.fs, 7, [4, 4, 4, 4])
        self.assertEqual(spent_positions(self.fs), {0})
        # Hole 1 is this group's TWELFTH, and nobody has played it.
        wanted = [pids[0], pids[3], pids[2], pids[1]]
        self.assertEqual(set_anchor_order(self.fs, wanted), wanted)

    def test_an_unset_order_freezes_the_fallback_on_the_holes_it_decided(self):
        """Card order became binding on the holes it was used for.

        That is already what happened on those holes, and it is strictly more
        than the old rule allowed — which was nothing at all.
        """
        self._gross()
        pids_card = anchor_order(self.fs)
        self._play(self.fs, 1, [4, 4, 4, 4])
        self.assertEqual(spent_positions(self.fs), {0})
        wanted = [pids_card[0], pids_card[2], pids_card[1], pids_card[3]]
        self.assertEqual(set_anchor_order(self.fs, wanted), wanted)

    def test_a_threesome_spends_its_three(self):
        # The rotation is as long as the roster, so three holes is everything.
        three = make_foursome(self.round, [('X', 0), ('Y', 0), ('Z', 0)],
                              tee=self.tee, group_number=3)
        self._gross()
        pids = self._pids(three)
        set_anchor_order(three, pids)
        for h in (1, 2, 3):
            self._play(three, h, [4, 4, 4])
        self.assertTrue(order_fully_locked(three))

    def test_the_summary_reports_the_locked_positions(self):
        self._gross()
        set_anchor_order(self.fs, self._pids(self.fs))
        self._play(self.fs, 1, [4, 4, 4, 4])
        g = next(x for x in hot_spot_summary(self.round)['groups']
                 if x['foursome_id'] == self.fs.pk)
        self.assertEqual(g['order_positions_locked'], [0])
        self.assertFalse(g['order_fully_locked'])
        # Unchanged for the shipped client, which hides Change at any score.
        self.assertTrue(g['order_locked'])
