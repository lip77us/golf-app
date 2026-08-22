"""
scoring/tests/test_team_play_models.py
--------------------------------------
Team Play — the tournament-type switch and the config model's derived state
(docs/design-review/handoff-team-play/SPEC.md §2).

The switch is the first thing built because it is a live defect: before this,
`Tournament.is_individual_play` was `'team_cup' not in active_games`, so a Team
Play tournament satisfied it and would silently inherit the individual-play
rules — the always-on net double-bogey cap, a field-wide allowance and best-N
counting — none of which this shape has. A shape must be excluded by being
NAMED, not by failing to be a cup.
"""
from django.utils import timezone

from django.test import TestCase

from tournament.models import TeamPlayConfig
from ._helpers import make_tournament


class TournamentTypeSwitchTests(TestCase):
    """Each of the three shapes answers for itself, and only for itself."""

    def test_individual_play_is_neither_cup_nor_team(self):
        t = make_tournament(active_games=['low_net'])
        self.assertTrue(t.is_individual_play)
        self.assertFalse(t.is_team_play)

    def test_cup_is_not_individual_play(self):
        t = make_tournament(active_games=['team_cup', 'low_net'])
        self.assertFalse(t.is_individual_play)
        self.assertFalse(t.is_team_play)

    def test_team_play_is_not_individual_play(self):
        """The defect this switch fixes — a team event must not pick up the
        individual-play rules just by not being a cup."""
        t = make_tournament(active_games=['team_play'])
        self.assertTrue(t.is_team_play)
        self.assertFalse(t.is_individual_play)

    def test_empty_active_games_does_not_crash(self):
        t = make_tournament(active_games=[])
        self.assertTrue(t.is_individual_play)
        self.assertFalse(t.is_team_play)


class TeamPlayConfigTests(TestCase):

    def setUp(self):
        self.tournament = make_tournament(
            name='Saturday Scramble', total_rounds=1, active_games=['team_play'],
        )

    def test_defaults_are_a_one_tap_scramble(self):
        """A TD accepting every default gets the round the packet says he
        should: a scramble, best 2 of 4 if he switches to shamble, no drive
        requirement, warn-only, net, three places at 50/30/20."""
        c = TeamPlayConfig.objects.create(
            tournament=self.tournament, split_pcts=[50, 30, 20],
        )
        self.assertTrue(c.is_scramble)
        self.assertFalse(c.is_shamble)
        self.assertEqual(c.ball_count_fixed, 2)
        self.assertEqual(c.drive_rule, TeamPlayConfig.DRIVE_NONE)
        self.assertEqual(c.drive_penalty, TeamPlayConfig.PENALTY_WARN)
        self.assertEqual(c.handicap_mode, 'net')
        self.assertIsNone(c.allowance_override_pct)
        self.assertEqual(c.places_paid, 3)

    def test_falling_short_costs_nothing_by_default(self):
        """The penalty is opt-in. Silently disqualifying a team over a drive
        count would be the worst outcome the app could produce."""
        c = TeamPlayConfig.objects.create(tournament=self.tournament)
        self.assertEqual(c.drive_penalty, TeamPlayConfig.PENALTY_WARN)

    def test_quota_rules_are_quotas_and_the_schedule_is_not(self):
        """Three quotas and one schedule — not four settings of one thing. A
        quota needs its slack shown; a schedule has none to show."""
        c = TeamPlayConfig.objects.create(tournament=self.tournament)
        for rule, is_quota in (
            (TeamPlayConfig.DRIVE_NONE,        False),
            (TeamPlayConfig.DRIVE_PER_NINE,    True),
            (TeamPlayConfig.DRIVE_PER_18,      True),
            (TeamPlayConfig.DRIVE_ALTERNATING, False),
        ):
            c.drive_rule = rule
            self.assertEqual(c.drive_rule_is_quota, is_quota, rule)

    def test_format_locks_at_the_first_score(self):
        c = TeamPlayConfig.objects.create(tournament=self.tournament)
        self.assertFalse(c.is_locked)
        c.format_locked_at = timezone.now()
        self.assertTrue(c.is_locked)

    def test_one_config_per_tournament(self):
        from django.db import IntegrityError, transaction
        TeamPlayConfig.objects.create(tournament=self.tournament)
        with self.assertRaises(IntegrityError), transaction.atomic():
            TeamPlayConfig.objects.create(tournament=self.tournament)
