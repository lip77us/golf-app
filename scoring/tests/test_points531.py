"""
scoring/tests/test_points531.py
-------------------------------
Integration tests for the Points 5-3-1 settlement now that money flows
through services.wager.settle() with an optional per-side loss cap.

The pure cap/rescale math is covered in test_wager.py; here we prove the
*game* wires into it correctly: uncapped money is unchanged from the old
(points − 3 × holes) × bet_unit, and a low cap clips losers + rescales
winners pro-rata, end to end through the summary the mobile UI consumes.
"""
from decimal import Decimal

from django.test import TestCase

from services.points_531 import (
    calculate_points_531,
    points_531_summary,
    setup_points_531,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class Points531SettlementTests(TestCase):
    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = Decimal("1.00")   # $1 / point
        self.round.save()
        # Three scratch players so net == gross and ranks are obvious.
        self.fs = make_foursome(
            self.round,
            [("Ann", 0), ("Bob", 0), ("Cy", 0)],
            tee=self.tee,
        )
        self.ann, self.bob, self.cy = (
            m.player for m in self.fs.memberships.order_by("id")
        )

    def _score_three_holes(self):
        """Ann beats Bob beats Cy on each of 3 holes → 5/3/1 every hole.

        Totals: Ann 15, Bob 9, Cy 3 (mean 9). At $1/pt the raw vs-average
        money is Ann +6, Bob 0, Cy −6.

        Holes 1/2/5 are all par 4, so gross 6 = par+2 stays under the
        double-bogey cap and the 4 < 5 < 6 order avoids any tie.
        """
        for hole in (1, 2, 5):
            submit_hole(self.fs, hole, [(self.ann, 4), (self.bob, 5), (self.cy, 6)])
        calculate_points_531(self.fs)

    def _money(self, summary):
        return {p["name"]: p["money"] for p in summary["players"]}

    def test_uncapped_matches_legacy_formula(self):
        setup_points_531(self.fs)            # loss_cap defaults to None
        self._score_three_holes()
        summary = points_531_summary(self.fs)

        money = self._money(summary)
        self.assertEqual(money["Ann"], 6.0)
        self.assertEqual(money["Bob"], 0.0)
        self.assertEqual(money["Cy"], -6.0)
        self.assertAlmostEqual(sum(money.values()), 0.0)
        self.assertIsNone(summary["money"]["loss_cap"])

    def test_high_cap_does_not_bind(self):
        setup_points_531(self.fs, loss_cap=Decimal("100"))
        self._score_three_holes()
        money = self._money(points_531_summary(self.fs))
        self.assertEqual(money["Ann"], 6.0)
        self.assertEqual(money["Cy"], -6.0)

    def test_low_cap_clips_loser_and_rescales_winner(self):
        # Cy's raw loss is 6; cap at 4 → Cy pays 4, Ann (owed 6) rescaled
        # by 4/6 → 4.00, Bob unchanged at 0. Still zero-sum.
        setup_points_531(self.fs, loss_cap=Decimal("4"))
        self._score_three_holes()
        summary = points_531_summary(self.fs)

        money = self._money(summary)
        self.assertEqual(money["Cy"], -4.0)
        self.assertEqual(money["Ann"], 4.0)
        self.assertEqual(money["Bob"], 0.0)
        self.assertAlmostEqual(sum(money.values()), 0.0)
        self.assertEqual(summary["money"]["loss_cap"], 4.0)

    def test_negative_cap_is_treated_as_uncapped(self):
        game = setup_points_531(self.fs, loss_cap=Decimal("-10"))
        self.assertIsNone(game.loss_cap)
