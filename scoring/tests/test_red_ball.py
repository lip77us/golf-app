"""
scoring/tests/test_red_ball.py
------------------------------
The ball game engine — which it has never had a test file for, which is how it
came to carry the hole-number-for-position mistake in six places at once. Same
finding as the shotgun sweep: *the two places it mattered most were the two with
no test file at all.*

The rotation follows POSITION IN THE ROUND (ruled 25 Sep 2026): the first golfer
in ``pink_ball_order`` carries the ball on the group's FIRST TEE, whichever hole
that is. Half of what follows therefore plays off the 13th, because on a round
starting on the 1st position and hole number are the same integer and every
assertion passes either way.
"""
from django.test import TestCase

from games.models import PinkBallConfig, PinkBallHoleResult
from services.red_ball import (
    calculate_red_ball, carrier_at, carrier_on_hole, record_hole,
    red_ball_summary,
)
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}


class _Base(TestCase):
    """A round with two three-man groups carrying a ball each."""

    start = 1

    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.round = make_round(course=course, active_games=['pink_ball'])
        if self.start != 1:
            self.round.starting_hole = self.start
            self.round.save(update_fields=['starting_hole'])
        PinkBallConfig.objects.create(
            round=self.round, game_name='Devil Ball', entry_fee=10,
            payouts=[{'place': 1, 'amount': 30}])

        self.g1 = make_foursome(
            self.round, [('Ann', 0), ('Bea', 0), ('Cal', 0)],
            tee=self.tee, group_number=1)
        self.g2 = make_foursome(
            self.round, [('Dee', 0), ('Eve', 0), ('Fay', 0)],
            tee=self.tee, group_number=2)
        for fs in (self.g1, self.g2):
            fs.pink_ball_order = [
                m.player_id for m in fs.memberships.order_by('id')]
            fs.save(update_fields=['pink_ball_order'])

    # -- helpers ------------------------------------------------------------
    def order(self, fs):
        return fs.pink_ball_order

    def holes(self):
        """This round's play order."""
        return [((self.start - 1 + i) % 18) + 1 for i in range(18)]

    def play(self, fs, n, *, gross=None):
        """Score the group's first `n` holes, everybody level par unless told."""
        for h in self.holes()[:n]:
            submit_hole(fs, h, [(m.player_id, gross or PAR[h])
                                for m in fs.memberships.all()])

    def row(self, group_number):
        # The summary reads PinkBallResult rows, so it is empty until the
        # calculator has run — recalculating here keeps every assertion about
        # the summary honest about what produced it.
        calculate_red_ball(self.round)
        rows = red_ball_summary(self.round)['results']
        return next(r for r in rows if r['group_number'] == group_number)


class RotationRuleTests(_Base):
    """The rule itself, on its own."""

    def test_position_zero_is_the_first_golfer(self):
        o = self.order(self.g1)
        self.assertEqual(carrier_at(o, 0), o[0])
        self.assertEqual(carrier_at(o, 1), o[1])
        self.assertEqual(carrier_at(o, 3), o[0])   # wraps every three

    def test_an_empty_order_answers_none_rather_than_raising(self):
        self.assertIsNone(carrier_at([], 0))

    def test_a_hole_outside_the_round_has_no_carrier(self):
        # The old arithmetic answered for any integer, so a hole the group never
        # plays got a confident (and meaningless) carrier.
        self.assertIsNone(carrier_on_hole([1, 2, 3], [10, 11, 12], 4))


class StandardRoundTests(_Base):
    """A round off the 1st — where position and hole number agree. Pins the
    shipped behaviour so the position rewrite cannot change it."""

    def test_the_first_golfer_carries_the_first_hole(self):
        r = record_hole(self.round, self.g1, 1, net_score=4)
        self.assertEqual(r.pink_ball_player_id, self.order(self.g1)[0])

    def test_the_ball_rotates_every_third_hole(self):
        o = self.order(self.g1)
        for hole, expect in [(1, o[0]), (2, o[1]), (3, o[2]), (4, o[0])]:
            self.assertEqual(
                record_hole(self.round, self.g1, hole, net_score=4)
                .pink_ball_player_id, expect)

    def test_a_survivor_beats_a_lost_ball(self):
        self.play(self.g1, 18)
        self.play(self.g2, 18)
        record_hole(self.round, self.g2, 7, net_score=None, ball_lost=True)
        results = calculate_red_ball(self.round)
        self.assertEqual(results[0].foursome_id, self.g1.id)
        self.assertIsNone(results[0].eliminated_on_hole)

    def test_the_later_death_wins(self):
        self.play(self.g1, 18)
        self.play(self.g2, 18)
        record_hole(self.round, self.g1, 5, net_score=None, ball_lost=True)
        record_hole(self.round, self.g2, 14, net_score=None, ball_lost=True)
        results = calculate_red_ball(self.round)
        self.assertEqual(results[0].foursome_id, self.g2.id)

    def test_thru_counts_the_holes_played(self):
        self.play(self.g1, 6)
        self.assertEqual(self.row(1)['display_thru'], 6)
        self.assertEqual(self.row(1)['current_hole'], 6)


class ShotgunRoundTests(_Base):
    """Off the 13th — where every one of these questions used to be answered
    with a hole number."""

    start = 13

    def test_the_first_golfer_carries_the_groups_first_tee(self):
        # **The bug, at its source.** The group's first tee is the 13th, so the
        # first name in the order plays the ball there. The old arithmetic gave
        # hole 13 to `order[12 % 3] = order[0]` by luck; hole 14 went to
        # `order[1]` when it is the group's SECOND hole and belongs to the same
        # golfer's successor either way — so the test that catches it is hole 15.
        o = self.order(self.g1)
        self.assertEqual(
            record_hole(self.round, self.g1, 13, net_score=4)
            .pink_ball_player_id, o[0])
        self.assertEqual(
            record_hole(self.round, self.g1, 15, net_score=4)
            .pink_ball_player_id, o[2])
        # Hole 1 is the group's SEVENTH, so the rotation is back to the first man.
        self.assertEqual(
            record_hole(self.round, self.g1, 1, net_score=4)
            .pink_ball_player_id, o[0])

    def test_the_whole_rotation_follows_the_play_order(self):
        # **This class cannot catch the carrier bug, and that is the point of
        # the next one.** With three golfers off the 13th, `(start - 1) % 3` is
        # 0, so `(hole - 1) % 3` and `position % 3` agree on all eighteen holes —
        # the old formula and the new one are the same function here. Asserting
        # the sequence is still worth it (it pins the rule) but a mutation test
        # proves it bites nothing, so `RotationDivergenceTests` below picks a
        # start where the two genuinely differ.
        o = self.order(self.g1)
        expected = [o[i % 3] for i in range(18)]
        got = [record_hole(self.round, self.g1, h, net_score=4)
               .pink_ball_player_id for h in self.holes()]
        self.assertEqual(got, expected)

    def test_thru_is_a_count_not_the_highest_hole_number(self):
        # Six holes off the 13th reaches hole 18. The column used to read 18.
        self.play(self.g1, 6)
        row = self.row(1)
        self.assertEqual(row['display_thru'], 6)
        self.assertEqual(row['current_hole'], 18)   # the hole itself, correctly

    def test_the_carrier_is_the_next_hole_in_the_groups_own_order(self):
        self.play(self.g1, 6)     # 13..18 done; next is hole 1
        row = self.row(1)
        self.assertEqual(row['carrier_hole'], 1)
        # Seventh hole → position 6 → index 0.
        first = self.g1.memberships.order_by('id').first().player
        self.assertEqual(row['carrier'], first.name)

    def test_the_later_death_is_later_in_the_round_not_a_bigger_number(self):
        # **The ranking bug.** g1 lost it on the 15th, which off the 13th is its
        # THIRD hole. g2 lost it on the 3rd, which is its NINTH. g2 carried the
        # ball three times as far and the old key ranked g1 first, because it
        # compared 15 > 3.
        self.play(self.g1, 18)
        self.play(self.g2, 18)
        record_hole(self.round, self.g1, 15, net_score=None, ball_lost=True)
        record_hole(self.round, self.g2, 3, net_score=None, ball_lost=True)
        results = calculate_red_ball(self.round)
        self.assertEqual(results[0].foursome_id, self.g2.id)
        self.assertEqual(self.row(2)['display_thru'], 9)
        self.assertEqual(self.row(1)['display_thru'], 3)

    def test_the_ball_stops_at_the_position_it_died(self):
        # g1's ball dies on its 3rd hole (the 15th). Only three holes count —
        # not "every hole numbered 15 or below", which off the 13th would have
        # swept in holes 1..12 the group had also played.
        self.play(self.g1, 18)
        record_hole(self.round, self.g1, 15, net_score=None, ball_lost=True)
        results = calculate_red_ball(self.round)

        # **Both the calculator and the summary**, because they each walk the
        # ball themselves and the summary PREFERS its own figure (there is a
        # comment in the service saying so). Asserting only the summary let a
        # mutation of the calculator's loop pass unnoticed.
        stored = next(r for r in results if r.foursome_id == self.g1.id)
        expected = PAR[13] + PAR[14] + PAR[15]   # its first three holes
        self.assertEqual(stored.total_net_score, expected)

        row = self.row(1)
        self.assertEqual(row['total_net_score'], expected)
        self.assertEqual(row['net_to_par'], 0)

    def test_the_survivors_last_hole_is_marked_not_hole_18(self):
        # Off the 13th the round ends on the 12th. `hole_number=18` marked a hole
        # played six in.
        self.play(self.g1, 18)
        self.play(self.g2, 18)
        record_hole(self.round, self.g2, 14, net_score=None, ball_lost=True)
        for h in self.holes():
            record_hole(self.round, self.g1, h, net_score=PAR[h])
        calculate_red_ball(self.round)
        winner = PinkBallHoleResult.objects.get(
            round=self.round, foursome=self.g1, is_winner=True)
        self.assertEqual(winner.hole_number, 12)

    def test_ball_net_ranks_two_survivors_on_what_the_ball_shot(self):
        # Both alive; g2's carriers played the ball one better.
        self.play(self.g1, 18)
        self.play(self.g2, 18)
        o = self.order(self.g2)
        submit_hole(self.g2, 13, [(o[0], PAR[13] - 1)] +
                    [(m.player_id, PAR[13]) for m in self.g2.memberships.all()
                     if m.player_id != o[0]])
        results = calculate_red_ball(self.round)
        self.assertEqual(results[0].foursome_id, self.g2.id)
        self.assertEqual(self.row(2)['ball_net_to_par'], -1)
        self.assertEqual(self.row(1)['ball_net_to_par'], 0)


class RotationDivergenceTests(_Base):
    """A start where the two formulas actually differ — off the 8th.

    **Found by mutation, not by reading.** Putting the old
    ``order[(hole - 1) % len(order)]`` back into ``record_hole`` broke NOT ONE
    test, because `ShotgunRoundTests` starts on the 13th and `(13 - 1) % 3 == 0`
    makes the two formulas identical. A shotgun test that happens to land on a
    congruent start is a test that proves nothing.

    TWO conditions have to hold for the two formulas to agree, and the obvious
    one is only the first:

      1. ``(start - 1) % len(order) == 0`` — the offset cancels at the start;
      2. ``18 % len(order) == 0`` — it still cancels after the round WRAPS.

    Three golfers satisfy (2); four do not. Off the 13th a four-ball matches on
    holes 13-18 and is WRONG on 1-12, where the wrap shifts the rotation by two.
    So "three golfers off the 13th" is the one shotgun configuration where the
    bug is invisible, and it is the one the class above happens to use.

    This class picks a start where nothing cancels: 8, where
    ``(8 - 1) % 3 == 1`` and every single hole diverges.
    """

    start = 8

    def test_the_carrier_is_wrong_on_every_hole_under_the_old_rule(self):
        o = self.order(self.g1)
        holes = self.holes()
        for pos, h in enumerate(holes):
            got = record_hole(self.round, self.g1, h,
                              net_score=4).pink_ball_player_id
            self.assertEqual(got, o[pos % 3],
                             msg=f'hole {h} is the group\'s #{pos + 1}')
            # And it is NOT what the old arithmetic said, on every hole.
            self.assertNotEqual(got, o[(h - 1) % 3],
                                msg=f'hole {h}: the old rule agreed, so this '
                                    f'hole proves nothing')

    def test_the_first_tee_belongs_to_the_first_name(self):
        # The plainest statement of the ruling: whoever is first in the order
        # plays the ball off the group's first tee, whichever hole that is.
        o = self.order(self.g1)
        self.assertEqual(
            record_hole(self.round, self.g1, 8, net_score=4)
            .pink_ball_player_id, o[0])

    def test_the_ball_covers_the_holes_the_group_actually_played(self):
        # Dies on its 4th hole (the 11th). Three holes counted before it, and the
        # holes numbered below 11 that the group has NOT reached must not appear.
        self.play(self.g1, 18)
        self.play(self.g2, 18)
        record_hole(self.round, self.g1, 11, net_score=None, ball_lost=True)
        calculate_red_ball(self.round)
        row = self.row(1)
        self.assertEqual(row['display_thru'], 4)
        self.assertEqual(row['total_net_score'],
                         PAR[8] + PAR[9] + PAR[10] + PAR[11])
