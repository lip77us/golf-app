"""services/skin_rules.py — the two skins validation rules.

Pure units.  The semantics are the whole risk here: these rules decide who
gets paid, and every combination has a house-rule reading that somebody plays.
"""

from django.test import SimpleTestCase

from services.skin_rules import (
    MIN_GROSS_PAR, MIN_NET_PAR, MIN_NONE,
    decide, is_natural_birdie, meets_minimum, normalise_minimum, rules_line,
)

PAR4 = {1: 4, 2: 4, 3: 4, 4: 4}


class PlainSkinsIsUnchangedTests(SimpleTestCase):
    """Both rules off must be exactly the plain min() the engines already did."""

    def test_outright_low_wins(self):
        self.assertEqual(decide({1: 3, 2: 4, 3: 5}, {1: 3, 2: 4, 3: 5}, PAR4),
                         [1])

    def test_a_tie_returns_both(self):
        self.assertEqual(sorted(decide({1: 4, 2: 4, 3: 5},
                                       {1: 4, 2: 4, 3: 5}, PAR4)), [1, 2])

    def test_an_empty_hole_returns_empty(self):
        self.assertEqual(decide({}, {}, PAR4), [])

    def test_a_net_bogey_still_wins_with_no_minimum(self):
        self.assertEqual(decide({1: 5, 2: 6}, {1: 6, 2: 7}, PAR4), [1])


class NetParMinimumTests(SimpleTestCase):
    def test_a_net_bogey_cannot_win(self):
        """Everybody over par — the skin is not won, so it carries or dies."""
        self.assertEqual(
            decide({1: 5, 2: 6}, {1: 6, 2: 7}, PAR4, minimum=MIN_NET_PAR), [])

    def test_a_net_par_off_a_stroke_does_win(self):
        """The difference from GROSS_PAR: gross 5, stroke, net 4 — passes."""
        self.assertEqual(
            decide({1: 4, 2: 5}, {1: 5, 2: 5}, PAR4, minimum=MIN_NET_PAR), [1])

    def test_the_best_VALID_score_wins_when_the_low_fails(self):
        """A minimum is a validation on the WINNER, so the next valid claim
        takes the skin rather than the hole going unwon."""
        # 1 has the low net (5) but is over par; 2 is net par.
        self.assertEqual(
            decide({1: 5, 2: 4, 3: 6}, {1: 5, 2: 4, 3: 6}, PAR4,
                   minimum=MIN_NET_PAR), [2])


class GrossParMinimumTests(SimpleTestCase):
    def test_a_net_par_made_off_a_stroke_fails(self):
        """The rule the user actually described: gross 5 is a bogey."""
        self.assertEqual(
            decide({1: 4}, {1: 5}, PAR4, minimum=MIN_GROSS_PAR), [])

    def test_a_gross_par_passes(self):
        self.assertEqual(
            decide({1: 4}, {1: 4}, PAR4, minimum=MIN_GROSS_PAR), [1])

    def test_it_is_stricter_than_net_par_on_the_same_hole(self):
        scores, gross = {1: 4, 2: 5}, {1: 5, 2: 5}
        self.assertEqual(decide(scores, gross, PAR4, minimum=MIN_NET_PAR), [1])
        self.assertEqual(decide(scores, gross, PAR4, minimum=MIN_GROSS_PAR), [])


class BirdieStealTests(SimpleTestCase):
    def test_a_natural_birdie_beats_a_lower_net(self):
        """1 has the better net (2 off a stroke); 2 made a real birdie."""
        self.assertEqual(
            decide({1: 2, 2: 3}, {1: 4, 2: 3}, PAR4, birdie_steal=True), [2])

    def test_without_the_rule_the_low_net_keeps_it(self):
        self.assertEqual(
            decide({1: 2, 2: 3}, {1: 4, 2: 3}, PAR4, birdie_steal=False), [1])

    def test_naturals_are_separated_by_NET_not_regraded_on_gross(self):
        """Two real birdies: the game is still a net game.  1 has a stroke."""
        self.assertEqual(
            decide({1: 2, 2: 3}, {1: 3, 2: 3}, PAR4, birdie_steal=True), [1])

    def test_an_eagle_steals_too(self):
        self.assertEqual(
            decide({1: 3, 2: 2}, {1: 3, 2: 2}, PAR4, birdie_steal=True), [2])

    def test_with_no_natural_the_rule_changes_nothing(self):
        self.assertEqual(
            decide({1: 4, 2: 5}, {1: 5, 2: 5}, PAR4, birdie_steal=True), [1])

    def test_two_naturals_on_the_same_net_tie(self):
        self.assertEqual(
            sorted(decide({1: 3, 2: 3}, {1: 3, 2: 3}, PAR4,
                          birdie_steal=True)), [1, 2])


class TheTwoRulesTogetherTests(SimpleTestCase):
    def test_a_natural_always_clears_either_minimum(self):
        """The steal class can never be emptied by the minimum — a birdie is
        better than par by definition."""
        for minimum in (MIN_NET_PAR, MIN_GROSS_PAR):
            self.assertEqual(
                decide({1: 3, 2: 4}, {1: 3, 2: 4}, PAR4,
                       minimum=minimum, birdie_steal=True), [1], minimum)

    def test_both_on_with_nobody_qualifying(self):
        self.assertEqual(
            decide({1: 5, 2: 5}, {1: 6, 2: 6}, PAR4,
                   minimum=MIN_GROSS_PAR, birdie_steal=True), [])

    def test_the_steal_outranks_the_minimum_for_a_golfer_who_fails_it(self):
        """Nobody made a natural, so the minimum decides alone."""
        self.assertEqual(
            decide({1: 4, 2: 5}, {1: 5, 2: 5}, PAR4,
                   minimum=MIN_GROSS_PAR, birdie_steal=True), [])


class MixedParTests(SimpleTestCase):
    def test_each_golfer_is_measured_against_HIS_OWN_par(self):
        """A mixed-tee card can have different pars on one hole — the question
        is whether HE made par, so his own card decides."""
        # Hole is par 4 for player 1 and par 5 for player 2.
        pars = {1: 4, 2: 5}
        # Both shot 5: player 1 bogeyed, player 2 made par.
        self.assertEqual(
            decide({1: 5, 2: 5}, {1: 5, 2: 5}, pars,
                   minimum=MIN_GROSS_PAR), [2])

    def test_a_birdie_is_relative_to_his_own_par_too(self):
        pars = {1: 4, 2: 5}
        # Player 2's 4 is a birdie on his par 5; player 1's 4 is a par.
        self.assertEqual(
            decide({1: 4, 2: 4}, {1: 4, 2: 4}, pars, birdie_steal=True), [2])


class FailingOpenTests(SimpleTestCase):
    """Never invent a verdict — a missing figure must not void a skin."""

    def test_a_missing_par_passes_the_minimum(self):
        self.assertEqual(
            decide({1: 6}, {1: 6}, {}, minimum=MIN_GROSS_PAR), [1])

    def test_a_missing_par_is_not_a_birdie(self):
        self.assertFalse(is_natural_birdie(3, None))
        self.assertFalse(is_natural_birdie(None, 4))

    def test_an_unknown_minimum_means_no_minimum(self):
        self.assertEqual(normalise_minimum('eagle_or_better'), MIN_NONE)
        self.assertEqual(normalise_minimum(None), MIN_NONE)
        self.assertEqual(normalise_minimum(''), MIN_NONE)
        self.assertEqual(decide({1: 7}, {1: 7}, PAR4, minimum='nonsense'), [1])

    def test_meets_minimum_handles_missing_scores(self):
        self.assertTrue(meets_minimum(None, None, 4, MIN_NONE))
        self.assertFalse(meets_minimum(None, None, 4, MIN_NET_PAR))
        self.assertFalse(meets_minimum(None, None, 4, MIN_GROSS_PAR))


class RulesLineTests(SimpleTestCase):
    def test_nothing_on_is_an_empty_string(self):
        self.assertEqual(rules_line(MIN_NONE, False), '')

    def test_each_rule_names_itself(self):
        self.assertIn('net par', rules_line(MIN_NET_PAR, False))
        self.assertIn('gross par', rules_line(MIN_GROSS_PAR, False))
        self.assertIn('steal', rules_line(MIN_NONE, True))

    def test_both_are_joined(self):
        line = rules_line(MIN_GROSS_PAR, True)
        self.assertIn('gross par', line)
        self.assertIn('steal', line)
