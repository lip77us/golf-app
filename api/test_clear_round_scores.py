"""`clear_round_scores` — wipe the play, keep the draw.

For the night before a tournament: post scores, check the board, then hand
the group a clean card in the morning without rebuilding the draw.

The test that matters is the second one. Deleting scores is easy; the risk is
taking the SETUP with them, which would cost an evening of grouping work at
the worst possible moment.
"""
from datetime import date

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase

from core.models import Player, PlayerSex
from games.models import TripleCupHoleResult
from scoring.models import HoleScore
from scoring.tests._helpers import make_tee, make_round, submit_hole, _test_account
from services.triple_cup import setup_triple_cup, calculate_triple_cup
from tournament.models import (
    Foursome, FoursomeMembership, Round, RoundStatus, Tournament,
)


class ClearRoundScoresTests(TestCase):

    def setUp(self):
        self.acct = _test_account()
        self.tee  = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        t = Tournament.objects.create(account=self.acct, name='Thursday Cup',
                                      start_date=date(2026, 10, 8))
        self.round.tournament = t
        self.round.save(update_fields=['tournament'])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pids = []
        for i in range(4):
            p = Player.objects.create(
                account=self.acct, name=f'P{i}', short_name=f'P{i}',
                handicap_index=10 + i, sex=PlayerSex.MALE)
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=10 + i, playing_handicap=10 + i)
            self.pids.append(p.pk)
        setup_triple_cup(self.fs, team1_ids=self.pids[:2],
                         team2_ids=self.pids[2:], handicap_mode='gross')
        for h in (1, 2, 3):
            submit_hole(self.fs, h, [(pid, 4 + i)
                                     for i, pid in enumerate(self.pids)])
        calculate_triple_cup(self.fs)

    def _counts(self):
        return (
            HoleScore.objects.filter(foursome=self.fs).count(),
            TripleCupHoleResult.objects.filter(
                match__game__foursome=self.fs).count(),
        )

    def test_a_dry_run_changes_nothing(self):
        before = self._counts()
        call_command('clear_round_scores', round_id=self.round.id)
        self.assertEqual(self._counts(), before,
                         'the default must be a dry run — this command is '
                         'run under time pressure')

    def test_the_setup_survives(self):
        """The whole point. An evening of grouping work must not go with the
        scores."""
        groups   = self.round.foursomes.count()
        members  = self.fs.memberships.count()
        matches  = self.fs.triple_cup_game.matches.count()
        tees     = [m.tee_id for m in self.fs.memberships.all()]
        hcaps    = [m.playing_handicap for m in self.fs.memberships.all()]

        call_command('clear_round_scores', round_id=self.round.id, apply=True)

        self.fs.refresh_from_db()
        self.assertEqual(self.round.foursomes.count(), groups)
        self.assertEqual(self.fs.memberships.count(), members)
        self.assertEqual(self.fs.triple_cup_game.matches.count(), matches)
        self.assertEqual([m.tee_id for m in self.fs.memberships.all()], tees)
        self.assertEqual([m.playing_handicap
                          for m in self.fs.memberships.all()], hcaps)

    def test_scores_and_derived_results_both_go(self):
        self.assertNotEqual(self._counts(), (0, 0), 'setup: expected play')
        call_command('clear_round_scores', round_id=self.round.id, apply=True)
        self.assertEqual(self._counts(), (0, 0),
                         'a derived result left behind would show a finished '
                         'match on an unplayed card')

    def test_a_withdrawal_is_undone(self):
        m = self.fs.memberships.first()
        m.withdrew_after_hole = 2
        m.withdrew_killed_next_hole = True
        m.save(update_fields=['withdrew_after_hole',
                              'withdrew_killed_next_hole'])
        call_command('clear_round_scores', round_id=self.round.id, apply=True)
        m.refresh_from_db()
        self.assertIsNone(m.withdrew_after_hole)
        self.assertFalse(m.withdrew_killed_next_hole)

    def test_a_completed_round_reopens(self):
        self.round.status = RoundStatus.COMPLETE
        self.round.save(update_fields=['status'])
        call_command('clear_round_scores', round_id=self.round.id, apply=True)
        self.round.refresh_from_db()
        self.assertEqual(self.round.status, RoundStatus.IN_PROGRESS)

    def test_it_refuses_without_a_target(self):
        with self.assertRaises(CommandError):
            call_command('clear_round_scores')

    def test_it_can_take_a_tournament_name(self):
        call_command('clear_round_scores', tournament='Thursday',
                     apply=True)
        self.assertEqual(self._counts(), (0, 0))
