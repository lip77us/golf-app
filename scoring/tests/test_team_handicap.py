"""
scoring/tests/test_team_handicap.py
-----------------------------------
Team Play allowance maths (docs/design-review/handoff-team-play/SPEC.md §6, §7;
services/team_handicap.py).

The four teams below are the packet's own worked examples, drawn on the
handicap screen and again on the build-teams screen. They are the numbers a TD
checks, so they are the numbers the tests assert.
"""
from decimal import Decimal

from django.test import TestCase

from services.team_handicap import (
    phantom_course_handicap, player_shamble_handicap, scramble_allowance,
    shamble_allowance, shamble_allowance_pct,
)


class ScrambleAllowanceTests(TestCase):
    """25 / 20 / 15 / 10 of course handicap, lowest first, summed."""

    def test_pine(self):
        a = scramble_allowance([4, 8, 11, 19])
        self.assertEqual([str(c.strokes) for c in a.contributions],
                         ['1.00', '1.60', '1.65', '1.90'])
        self.assertEqual(a.raw, Decimal('6.15'))
        self.assertEqual(a.strokes, 6)

    def test_clay_rounds_a_half_up(self):
        """7.50 becomes 8. Python's built-in round() is half-to-even and would
        agree here but not on 6.50, so the module uses ROUND_HALF_UP."""
        a = scramble_allowance([6, 9, 14, 21])
        self.assertEqual(a.raw, Decimal('7.50'))
        self.assertEqual(a.strokes, 8)

    def test_slate(self):
        a = scramble_allowance([5, 12, 16, 24])
        self.assertEqual(a.raw, Decimal('8.45'))
        self.assertEqual(a.strokes, 8)

    def test_rounding_happens_once_on_the_total(self):
        """Rounding each contribution first turns 1.00 + 1.60 + 1.65 + 1.90
        into 1 + 2 + 2 + 2 = 7. Rounding the sum gives 6 — a full stroke of
        difference from where the rounding goes."""
        a = scramble_allowance([4, 8, 11, 19])
        per_contribution = sum(round(c.strokes) for c in a.contributions)
        self.assertEqual(per_contribution, 7)
        self.assertEqual(a.strokes, 6)

    def test_the_order_is_the_rule(self):
        """25% attaches to the lowest handicap, not to the captain or the first
        name on the list — so an unsorted input gives the same answer."""
        self.assertEqual(scramble_allowance([19, 4, 11, 8]).raw,
                         scramble_allowance([4, 8, 11, 19]).raw)
        self.assertEqual([c.pct for c in scramble_allowance([19, 4, 11, 8]).contributions],
                         [25, 20, 15, 10])

    def test_override_applies_one_flat_percentage(self):
        """A group's tradition beats the table, and the worked result is still
        shown so the TD sees what he did."""
        a = scramble_allowance([4, 8, 11, 19], override_pct=20)
        self.assertEqual([c.pct for c in a.contributions], [20] * 4)
        self.assertEqual(a.raw, Decimal('8.40'))
        self.assertEqual(a.strokes, 8)


class PhantomTests(TestCase):
    """Dune — three men and a phantom 4th."""

    def test_the_phantom_is_the_average_of_the_three(self):
        self.assertEqual(phantom_course_handicap([9, 15, 23]), 16)

    def test_dune_plays_off_ten(self):
        ph = phantom_course_handicap([9, 15, 23])
        a = scramble_allowance([9, 15, 23, ph], phantom_index=3)

        self.assertEqual([(c.course_handicap, c.pct, str(c.strokes))
                          for c in a.contributions],
                         [(9, 25, '2.25'), (15, 20, '3.00'),
                          (16, 15, '2.40'), (23, 10, '2.30')])
        self.assertEqual(a.raw, Decimal('9.95'))
        self.assertEqual(a.strokes, 10)

    def test_the_phantom_sorts_into_the_order_like_anyone_else(self):
        """It lands third on handicap and takes 15% — italic on screen, but not
        a special case in the maths."""
        ph = phantom_course_handicap([9, 15, 23])
        a = scramble_allowance([9, 15, 23, ph], phantom_index=3)
        phantom_rows = [i for i, c in enumerate(a.contributions) if c.is_phantom]
        self.assertEqual(phantom_rows, [2])
        self.assertEqual(a.contributions[2].pct, 15)

    def test_fewer_balls_must_never_mean_fewer_strokes(self):
        """The two rejected alternatives, asserted so nobody reintroduces one:
        dropping the table's bottom row gives 9, and a 30/20/10 table gives 8.
        Both take a stroke away from a team already short a ball."""
        with_phantom = scramble_allowance(
            [9, 15, 23, phantom_course_handicap([9, 15, 23])]).strokes
        three_man_table = scramble_allowance([9, 15, 23]).strokes   # 25/20/15
        self.assertEqual(with_phantom, 10)
        self.assertEqual(three_man_table, 9)
        self.assertGreater(with_phantom, three_man_table)

    def test_play_short_carries_the_same_figure(self):
        """The allowance follows the ROSTER, not the number of balls hit. The
        only thing 'play short' changes is whether anybody hits the phantom's
        ball."""
        ph = phantom_course_handicap([9, 15, 23])
        self.assertEqual(scramble_allowance([9, 15, 23, ph]).strokes, 10)


class ShambleAllowanceTests(TestCase):

    def test_the_percentage_tracks_the_ball_count(self):
        self.assertEqual(shamble_allowance_pct(1), 75)
        self.assertEqual(shamble_allowance_pct(2), 85)
        self.assertEqual(shamble_allowance_pct(3), 95)

    def test_an_average_of_2_3_gets_95_not_85(self):
        """A ceiling, not a round-to-nearest: a grid that ever asks for three
        balls is a three-ball round for allowance purposes."""
        self.assertEqual(shamble_allowance_pct(Decimal('2.3')), 95)
        self.assertEqual(shamble_allowance_pct(Decimal('1.5')), 85)

    def test_escalating_averages_two_and_takes_85(self):
        """36 counted over 18 holes is 2.0 a hole."""
        self.assertEqual(shamble_allowance_pct(Decimal('2.0')), 85)

    def test_each_golfer_keeps_his_own_strokes(self):
        a = shamble_allowance([6, 9, 14, 21], avg_ball_count=2)
        self.assertEqual([c.pct for c in a.contributions], [85] * 4)

    def test_a_golfers_own_figure_is_whole(self):
        """Rounded per golfer here, unlike the scramble — this is the number he
        plays with on his own ball."""
        self.assertEqual(player_shamble_handicap(14, 85), 12)   # 11.9
        self.assertEqual(player_shamble_handicap(10, 85), 9)    # 8.5, half up
