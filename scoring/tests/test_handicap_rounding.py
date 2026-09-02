"""
scoring/tests/test_handicap_rounding.py
---------------------------------------
WHS Rule 6.1 rounding ("0.5 or above is rounded upward") and the Net %
scaling of a strokes-off differential.

Both used to go through Python's builtin round(), which is banker's rounding:
round(4.5) == 4 and round(22.5) == 22, each a stroke short of the Rule. Exact
.5 is rare for a course handicap but routine once a Net % lands on it — 90% of
a 5-stroke strokes-off differential is exactly 4.5 — so every handicap site now
goes through core.handicap_math.round_half_up, whose Dart counterpart is
roundHalfUp() in mobile/lib/utils/handicap_rounding.dart.
"""
from django.test import SimpleTestCase

from core.handicap_math import round_half_up
from scoring.handicap import _effective_hcp, par_adjusted_playing_handicap


class RoundHalfUpTests(SimpleTestCase):
    def test_half_rounds_up_not_to_even(self):
        # The four cases builtin round() gets wrong.
        self.assertEqual(round_half_up(4.5), 5)
        self.assertEqual(round_half_up(22.5), 23)
        self.assertEqual(round_half_up(28.5), 29)
        self.assertEqual(round_half_up(40.5), 41)

    def test_agrees_with_builtin_away_from_the_tie(self):
        for v in (0.4, 0.6, 17.1, 23.83, 29.78, -2.3):
            self.assertEqual(round_half_up(v), round(v), v)

    def test_plus_handicaps_round_upward_toward_zero(self):
        # "Upward" is numeric, so -3.5 rounds to -3, not away from zero to -4.
        self.assertEqual(round_half_up(-0.5), 0)
        self.assertEqual(round_half_up(-3.5), -3)


class EffectiveHandicapTests(SimpleTestCase):
    def test_full_allowance_is_a_passthrough(self):
        self.assertEqual(_effective_hcp(19, 100), 19)

    def test_ninety_percent_rounds_half_up(self):
        self.assertEqual(_effective_hcp(19, 90), 17)   # 17.1 → 17
        self.assertEqual(_effective_hcp(25, 90), 23)   # 22.5 → 23, was 22
        self.assertEqual(_effective_hcp(45, 90), 41)   # 40.5 → 41, was 40


class ParAdjustedPlayingHandicapTests(SimpleTestCase):
    def test_single_par_group_gets_no_adjustment(self):
        self.assertEqual(par_adjusted_playing_handicap(24, 70, 70, 1.0), 24)

    def test_higher_par_tee_adds_the_par_difference(self):
        # A woman on a par-71 tee against men on par-70 gets +1.
        self.assertEqual(par_adjusted_playing_handicap(29, 71, 70, 1.0), 30)

    def test_allowance_applies_before_the_par_adjustment(self):
        # 90% of 29 = 26.1 → 26, then +1 for the par difference.
        self.assertEqual(par_adjusted_playing_handicap(29, 71, 70, 0.9), 27)


class StrokesOffScalingTests(SimpleTestCase):
    """The differential every game scales by net_percent."""

    @staticmethod
    def _so(playing_handicap, low, net_percent):
        return round_half_up(max(0, playing_handicap - low) * net_percent / 100)

    def test_low_player_plays_to_zero(self):
        self.assertEqual(self._so(24, 24, 90), 0)

    def test_ninety_percent_of_the_differential(self):
        # Playing handicaps 31/30/29/24 off a low of 24, at Net % 90.
        self.assertEqual(self._so(31, 24, 90), 6)   # 6.3 → 6
        self.assertEqual(self._so(30, 24, 90), 5)   # 5.4 → 5
        self.assertEqual(self._so(29, 24, 90), 5)   # 4.5 → 5, was 4 under banker's

    def test_full_allowance_leaves_the_differential_alone(self):
        self.assertEqual(self._so(31, 24, 100), 7)
