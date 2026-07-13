"""
api/test_nassau_multi_match.py
------------------------------
The "Larry case": one foursome runs a team Nassau AND a Singles Match at once,
with different teams.  Both are NassauGame rows discriminated by game_type, so
configuring one must not delete the other, and each summary resolves
independently.
"""

from django.test import TestCase

from games.models import NassauGame
from services.nassau import (
    setup_nassau, nassau_summary, calculate_all_nassau,
    resolve_nassau_game_type, nassau_game_types_for,
)
from scoring.tests._helpers import make_tee, make_round, make_foursome


class NassauMultiMatchTests(TestCase):
    def setUp(self):
        tee = make_tee()
        self.rnd = make_round(tee.course, active_games=['nassau', 'match_18'])
        self.fs = make_foursome(
            self.rnd, [('A', 8), ('B', 12), ('C', 16), ('D', 20)], tee=tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup_team_nassau(self):
        return setup_nassau(
            self.fs, [self.pid['A'], self.pid['B']],
            [self.pid['C'], self.pid['D']], game_type='nassau')

    def _setup_singles(self):
        # A 1-v-1 Overall-only Singles Match with a DIFFERENT pairing.
        return setup_nassau(
            self.fs, [self.pid['A']], [self.pid['C']],
            play_front=False, play_back=False, play_overall=True,
            game_type='match_18')

    def test_both_matches_coexist(self):
        self._setup_team_nassau()
        self._setup_singles()
        gts = set(nassau_game_types_for(self.fs))
        self.assertEqual(gts, {'nassau', 'match_18'})
        self.assertEqual(NassauGame.objects.filter(foursome=self.fs).count(), 2)

    def test_setup_one_does_not_delete_the_other(self):
        self._setup_team_nassau()
        self._setup_singles()
        # Re-configure the team Nassau — the Singles Match must survive.
        self._setup_team_nassau()
        self.assertEqual(
            NassauGame.objects.filter(foursome=self.fs, game_type='match_18')
            .count(), 1)
        self.assertEqual(
            NassauGame.objects.filter(foursome=self.fs, game_type='nassau')
            .count(), 1)

    def test_summaries_resolve_independently_with_distinct_teams(self):
        self._setup_team_nassau()
        self._setup_singles()
        calculate_all_nassau(self.fs)

        team = nassau_summary(self.fs, 'nassau')
        singles = nassau_summary(self.fs, 'match_18')
        self.assertEqual(team['game_type'], 'nassau')
        self.assertEqual(singles['game_type'], 'match_18')

        # Team Nassau: 2-v-2.  Singles: 1-v-1.
        self.assertEqual(len(team['teams']['team1']), 2)
        self.assertEqual(len(singles['teams']['team1']), 1)
        # Singles is Overall-only.
        self.assertTrue(singles['play_overall'])
        self.assertFalse(singles['play_front'])
        self.assertFalse(singles['play_back'])

    def test_bare_read_resolves_to_primary_team_nassau(self):
        self._setup_team_nassau()
        self._setup_singles()
        self.assertEqual(resolve_nassau_game_type(self.fs), 'nassau')
        # nassau_summary with no game_type returns the team Nassau (2-v-2).
        self.assertEqual(len(nassau_summary(self.fs)['teams']['team1']), 2)

    def test_nassau_nine_only_round_still_resolves_bare(self):
        # A Nassau-Nine-only foursome (no 'nassau' row): the bare read must
        # still find it (legacy-client compatibility).
        setup_nassau(self.fs, [self.pid['A'], self.pid['B']],
                     [self.pid['C'], self.pid['D']], single_match=True)
        self.assertEqual(nassau_game_types_for(self.fs), ['nassau_nine'])
        self.assertEqual(resolve_nassau_game_type(self.fs), 'nassau_nine')
        self.assertIsNotNone(nassau_summary(self.fs))
