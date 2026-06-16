"""
scoring/tests/test_wager.py
---------------------------
Unit tests for services/wager.py — the pure, DB-free settlement core.

Uses SimpleTestCase (no database) so the whole file runs in milliseconds,
unlike the model/service tests that hit Postgres.  Covers each settlement
formula, the cap clip + pro-rata rescale (incl. the worked examples from
docs/wager-wizard.md), and the zero-sum invariant.
"""
from decimal import Decimal

from django.test import SimpleTestCase

from services.wager import (
    PAY_ABOVE,
    PAY_WINNER,
    PER_POINT,
    POOL,
    PROPORTIONAL,
    VS_AVERAGE,
    WagerConfig,
    settle,
)


def D(x):
    return Decimal(str(x))


def assert_zero_sum(test, payouts):
    test.assertEqual(sum(payouts.values()), Decimal("0.00"))


class VsAverageTests(SimpleTestCase):
    """Standard per-point settlement = Points 5-3-1 economics, generalized."""

    def test_symmetric_about_the_mean(self):
        cfg = WagerConfig(funding=PER_POINT, settlement=VS_AVERAGE, rate=D(1))
        # mean = 54; deviations +6 / 0 / -6
        out = settle({"A": 60, "B": 54, "C": 48}, cfg)
        self.assertEqual(out["A"], D("6.00"))
        self.assertEqual(out["B"], D("0.00"))
        self.assertEqual(out["C"], D("-6.00"))
        assert_zero_sum(self, out)

    def test_matches_531_constant_baseline(self):
        # 5-3-1 over 18 holes: baseline = 3 pts/hole × 18 = 54. settle() must
        # produce the same (pts − 54) × rate that points_531_summary computes.
        cfg = WagerConfig(funding=PER_POINT, settlement=VS_AVERAGE, rate=D(2))
        out = settle({"A": 70, "B": 54, "C": 38}, cfg)  # total 162, mean 54
        self.assertEqual(out["A"], D("32.00"))   # (70-54)*2
        self.assertEqual(out["B"], D("0.00"))
        self.assertEqual(out["C"], D("-32.00"))  # (38-54)*2
        assert_zero_sum(self, out)

    def test_fractional_baseline_still_balances(self):
        cfg = WagerConfig(funding=PER_POINT, settlement=VS_AVERAGE, rate=D(1))
        # total 10 / 3 = 3.333... mean — penny residue must reconcile to 0.
        out = settle({"A": 5, "B": 3, "C": 2}, cfg)
        assert_zero_sum(self, out)


class PayAboveTests(SimpleTestCase):
    """'Pay everyone above you' == n × vs_average (same ranking, n× magnitude)."""

    def test_is_n_times_vs_average(self):
        pts = {"A": 60, "B": 54, "C": 48}
        avg = settle(pts, WagerConfig(PER_POINT, VS_AVERAGE, rate=D(1)))
        above = settle(pts, WagerConfig(PER_POINT, PAY_ABOVE, rate=D(1)))
        for s in pts:
            self.assertEqual(above[s], avg[s] * 3)  # n = 3
        assert_zero_sum(self, above)


class PayWinnerTests(SimpleTestCase):
    """Only the leader(s) are paid; losers pay the leader the difference."""

    def test_single_winner(self):
        cfg = WagerConfig(PER_POINT, PAY_WINNER, rate=D(1))
        out = settle({"A": 10, "B": 6, "C": 2}, cfg)
        self.assertEqual(out["A"], D("12.00"))   # (10-6)+(10-2)
        self.assertEqual(out["B"], D("-4.00"))
        self.assertEqual(out["C"], D("-8.00"))
        assert_zero_sum(self, out)

    def test_tied_winners_split_the_pot(self):
        cfg = WagerConfig(PER_POINT, PAY_WINNER, rate=D(1))
        out = settle({"A": 10, "B": 10, "C": 4}, cfg)  # C owes 6, split A/B
        self.assertEqual(out["A"], D("3.00"))
        self.assertEqual(out["B"], D("3.00"))
        self.assertEqual(out["C"], D("-6.00"))
        assert_zero_sum(self, out)

    def test_three_tied_winners_one_loser_split_in_thirds(self):
        # 3 leaders tied at 10, one loser at 4: loser pays the 6-point
        # difference ONCE; the three winners split it in thirds (2 each).
        cfg = WagerConfig(PER_POINT, PAY_WINNER, rate=D(1))
        out = settle({"A": 10, "B": 10, "C": 10, "D": 4}, cfg)
        self.assertEqual(out["A"], D("2.00"))
        self.assertEqual(out["B"], D("2.00"))
        self.assertEqual(out["C"], D("2.00"))
        self.assertEqual(out["D"], D("-6.00"))
        assert_zero_sum(self, out)

    def test_tie_pot_with_penny_residue_still_balances(self):
        # Loser owes 10 split three ways = 3.333... → pennies must reconcile.
        cfg = WagerConfig(PER_POINT, PAY_WINNER, rate=D(1))
        out = settle({"A": 12, "B": 12, "C": 12, "D": 2}, cfg)
        self.assertEqual(out["D"], D("-10.00"))
        assert_zero_sum(self, out)


class ProportionalPoolTests(SimpleTestCase):
    def test_split_by_points_share(self):
        cfg = WagerConfig(POOL, PROPORTIONAL, entry=D(10))
        # pool = 30; shares 15/9/6; net +5/-1/-4
        out = settle({"A": 5, "B": 3, "C": 2}, cfg)
        self.assertEqual(out["A"], D("5.00"))
        self.assertEqual(out["B"], D("-1.00"))
        self.assertEqual(out["C"], D("-4.00"))
        assert_zero_sum(self, out)

    def test_zero_points_loses_exactly_the_entry(self):
        cfg = WagerConfig(POOL, PROPORTIONAL, entry=D(10))
        out = settle({"A": 8, "B": 2, "C": 0}, cfg)
        self.assertEqual(out["C"], D("-10.00"))   # max loss == entry
        assert_zero_sum(self, out)

    def test_no_points_anywhere_refunds_everyone(self):
        cfg = WagerConfig(POOL, PROPORTIONAL, entry=D(10))
        out = settle({"A": 0, "B": 0, "C": 0}, cfg)
        self.assertEqual(out, {"A": D("0.00"), "B": D("0.00"), "C": D("0.00")})


class CapTests(SimpleTestCase):
    def test_pay_above_clip_and_prorata_rescale(self):
        # pay_above, rate 1: A+20 B+4 C-4 D-20 (mean 5). Cap 12 clips D to 12;
        # collected 16, owed 24, factor 2/3 → A 13.33, B 2.67.
        cfg = WagerConfig(PER_POINT, PAY_ABOVE, rate=D(1), cap=D(12))
        out = settle({"A": 10, "B": 6, "C": 4, "D": 0}, cfg)
        self.assertEqual(out["A"], D("13.33"))
        self.assertEqual(out["B"], D("2.67"))
        self.assertEqual(out["C"], D("-4.00"))   # under the cap, untouched
        self.assertEqual(out["D"], D("-12.00"))  # clipped
        assert_zero_sum(self, out)

    def test_single_winner_absorbs_the_shortfall(self):
        # A+20, B-10, C-10. Cap 6 → losers pay 6 each, collected 12, owed 20,
        # factor 0.6 → A collects 12.
        cfg = WagerConfig(PER_POINT, PAY_WINNER, rate=D(1), cap=D(6))
        out = settle({"A": 10, "B": 0, "C": 0}, cfg)
        self.assertEqual(out["A"], D("12.00"))
        self.assertEqual(out["B"], D("-6.00"))
        self.assertEqual(out["C"], D("-6.00"))
        assert_zero_sum(self, out)

    def test_loose_cap_changes_nothing(self):
        cfg = WagerConfig(PER_POINT, VS_AVERAGE, rate=D(1), cap=D(1000))
        out = settle({"A": 60, "B": 54, "C": 48}, cfg)
        self.assertEqual(out["A"], D("6.00"))
        self.assertEqual(out["C"], D("-6.00"))
        assert_zero_sum(self, out)


class TeamSideTests(SimpleTestCase):
    """settle() is side-keyed — a 'side' can be a team; nothing changes."""

    def test_team_keys_are_just_sides(self):
        cfg = WagerConfig(PER_POINT, VS_AVERAGE, rate=D(2))
        out = settle({"Red": 30, "Blue": 20}, cfg)  # mean 25
        self.assertEqual(out["Red"], D("10.00"))    # (30-25)*2
        self.assertEqual(out["Blue"], D("-10.00"))
        assert_zero_sum(self, out)


class ConfigValidationTests(SimpleTestCase):
    def test_pool_requires_entry(self):
        with self.assertRaises(ValueError):
            WagerConfig(POOL, PROPORTIONAL)

    def test_per_point_requires_rate(self):
        with self.assertRaises(ValueError):
            WagerConfig(PER_POINT, VS_AVERAGE)

    def test_pool_rejects_per_point_settlement(self):
        with self.assertRaises(ValueError):
            WagerConfig(POOL, VS_AVERAGE, entry=D(10))

    def test_negative_cap_rejected(self):
        with self.assertRaises(ValueError):
            WagerConfig(PER_POINT, VS_AVERAGE, rate=D(1), cap=D(-5))
