"""
api/test_cup_no_show.py
-----------------------
Tee-box "no-show" handling on a Triple-Cup-format Cup round.

The TD pulls a no-show from a cup foursome before play starts; the group drops
to a 2v1 with a phantom standing in on the no-show's cup team, and the cup-level
standings (RyderCupMatchPoints) recompute so the scoreboard is correct in the
window between the roster edit and the first score.  See the plan
`Cup No-Show at the Tee Box` and services/triple_cup.py.

Layout used throughout: two 2v2 foursomes, teams spanning BOTH groups so a 2v1
solo always has cross-foursome donors on its team.  fs1 tees first (group 1),
fs2 second (group 2).

    Team 1 (Orange):  A B  (fs1)   E F  (fs2)
    Team 2 (Blue):    C D  (fs1)   G H  (fs2)
"""
from datetime import date

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from core.models import GameType
from scoring.models import HoleScore
from services.ryder_cup import calculate_ryder_cup_points
from services.triple_cup import setup_triple_cup
from tournament.models import (
    Tournament, TeamTournament, TournamentTeam, Foursome,
    RyderCupRoundConfig, RyderCupFoursomeConfig, RyderCupMatchPoints,
)

from scoring.tests._helpers import (
    make_tee, make_round, make_foursome, submit_hole, _test_account,
)


User = get_user_model()


class CupNoShowTests(TestCase):

    def setUp(self):
        self.acct = _test_account()
        self.td = User.objects.create_user(username='td', account=self.acct)
        self.td.is_account_admin = True
        self.td.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.td)

    # ------------------------------------------------------------------ #
    # Shared fixture
    # ------------------------------------------------------------------ #
    def _build_cup_round(self, *, locked=False):
        tee = make_tee()
        round_ = make_round(tee.course, handicap_mode='gross')

        tourn = Tournament.objects.create(
            account=self.acct, name='Cup', start_date=date(2026, 9, 1),
        )
        tt = TeamTournament.objects.create(
            tournament=tourn, cup_name='September Cup', players_per_team=4,
            draft_complete=locked,
        )
        team1 = TournamentTeam.objects.create(
            tournament=tt, name='Orange', team_number=1, colour='orange',
        )
        team2 = TournamentTeam.objects.create(
            tournament=tt, name='Blue', team_number=2, colour='blue',
        )

        fs1 = make_foursome(
            round_, [('A', 0), ('B', 0), ('C', 0), ('D', 0)],
            tee=tee, group_number=1,
        )
        fs2 = make_foursome(
            round_, [('E', 0), ('F', 0), ('G', 0), ('H', 0)],
            tee=tee, group_number=2,
        )
        m1 = {x.player.name: x for x in fs1.memberships.select_related('player')}
        m2 = {x.player.name: x for x in fs2.memberships.select_related('player')}

        team1.players.set([
            m1['A'].player, m1['B'].player, m2['E'].player, m2['F'].player,
        ])
        team2.players.set([
            m1['C'].player, m1['D'].player, m2['G'].player, m2['H'].player,
        ])

        rc = RyderCupRoundConfig.objects.create(
            round=round_, tournament=tt,
            nassau_point_value=1, point_multiplier=1,
        )
        for fs, mm, t1, t2 in (
            (fs1, m1, ['A', 'B'], ['C', 'D']),
            (fs2, m2, ['E', 'F'], ['G', 'H']),
        ):
            RyderCupFoursomeConfig.objects.create(
                foursome=fs, round_config=rc, game_type=GameType.TRIPLE_CUP,
                team1=team1, team2=team2, point_value=4,
            )
            setup_triple_cup(
                fs,
                team1_ids=[mm[t1[0]].player_id, mm[t1[1]].player_id],
                team2_ids=[mm[t2[0]].player_id, mm[t2[1]].player_id],
                handicap_mode='gross',
            )

        return {
            'tee': tee, 'round': round_, 'tt': tt,
            'team1': team1, 'team2': team2,
            'fs1': fs1, 'fs2': fs2, 'm1': m1, 'm2': m2,
        }

    def _remove(self, fs, player):
        return self.client.post(
            reverse('api-foursome-remove-player', args=[fs.id]),
            {'player_id': player.id}, format='json',
        )

    # ------------------------------------------------------------------ #
    # Core: removal recomputes cup standings
    # ------------------------------------------------------------------ #
    def test_remove_from_triple_cup_recomputes_points(self):
        ctx = self._build_cup_round()
        fs2, m2, round_ = ctx['fs2'], ctx['m2'], ctx['round']
        noshow = m2['F'].player   # a Team-1 player in the later group

        # Baseline cup-points rows for the original 2v2 (4 TC matches).
        calculate_ryder_cup_points(round_)
        before_ids = set(RyderCupMatchPoints.objects
                         .filter(foursome=fs2).values_list('pk', flat=True))
        self.assertEqual(len(before_ids), 4, 'expected 4 TC rows for the 2v2')

        resp = self._remove(fs2, noshow)
        self.assertEqual(resp.status_code, 200, resp.content)

        fs2 = Foursome.objects.get(pk=fs2.id)   # fresh — the TC game was rebuilt
        self.assertTrue(fs2.has_phantom)
        self.assertEqual(fs2.triple_cup_game.matches.count(), 4)  # 2v1 → still 4

        after_ids = set(RyderCupMatchPoints.objects
                        .filter(foursome=fs2).values_list('pk', flat=True))
        self.assertEqual(len(after_ids), 4)
        # calculate_ryder_cup_points wipes + rebuilds every row, so a removal
        # that recomputed leaves an entirely fresh row set — proof the stale
        # 2v2 rows were not left in place.
        self.assertTrue(
            before_ids.isdisjoint(after_ids),
            'cup points were not rebuilt after the removal',
        )

    def test_remove_3_to_2_rebuilds_to_1v1(self):
        """Two no-shows → 1v1: the TC game drops to 3 matches, the phantom is
        stripped, and no stale 4th cup-points row lingers."""
        ctx = self._build_cup_round()
        fs2, m2, round_ = ctx['fs2'], ctx['m2'], ctx['round']

        calculate_ryder_cup_points(round_)
        self.assertEqual(
            RyderCupMatchPoints.objects.filter(foursome=fs2).count(), 4)

        self.assertEqual(self._remove(fs2, m2['F'].player).status_code, 200)  # 2v1
        self.assertEqual(self._remove(fs2, m2['G'].player).status_code, 200)  # 1v1

        fs2 = Foursome.objects.get(pk=fs2.id)
        self.assertFalse(fs2.has_phantom)                          # phantom gone
        self.assertEqual(fs2.triple_cup_game.matches.count(), 3)   # 1v1 → 3
        # The stale 4th row from the original 2v2 must be gone.
        self.assertEqual(
            RyderCupMatchPoints.objects.filter(foursome=fs2).count(), 3)

    def test_phantom_attributed_to_no_show_team(self):
        ctx = self._build_cup_round()
        fs2, m2 = ctx['fs2'], ctx['m2']
        noshow = m2['F'].player   # Team 1

        resp = self._remove(fs2, noshow)
        self.assertEqual(resp.status_code, 200, resp.content)

        fs2 = Foursome.objects.get(pk=fs2.id)   # fresh — the TC game was rebuilt
        phantom_m = fs2.memberships.filter(player__is_phantom=True).first()
        self.assertIsNotNone(phantom_m, 'a phantom should fill the 2v1 foursome')

        # In the fourball match the phantom partners the solo on the no-show's
        # (Team 1) side, so the depleted team can still contest all 4 points.
        fourball = fs2.triple_cup_game.matches.order_by('match_number').first()
        phantom_team = fourball.teams.filter(players=phantom_m.player).first()
        self.assertIsNotNone(phantom_team, 'phantom must sit on a fourball team')
        self.assertEqual(
            phantom_team.team_number, 1,
            'phantom must stand in on the no-show team (Team 1)',
        )

    # ------------------------------------------------------------------ #
    # Draft lock is a non-issue for removal (touches membership, not team M2M)
    # ------------------------------------------------------------------ #
    def test_remove_works_while_draft_locked(self):
        ctx = self._build_cup_round(locked=True)
        fs2, m2, team1 = ctx['fs2'], ctx['m2'], ctx['team1']
        noshow = m2['F'].player

        self.assertTrue(ctx['tt'].draft_complete)
        resp = self._remove(fs2, noshow)
        self.assertEqual(resp.status_code, 200, resp.content)

        # The no-show stays on their drafted roster (absent, not cut)…
        self.assertIn(noshow, list(team1.players.all()))
        # …but is off the foursome.
        self.assertFalse(fs2.memberships.filter(player=noshow).exists())

    def test_remove_refused_after_score(self):
        ctx = self._build_cup_round()
        fs2, m2 = ctx['fs2'], ctx['m2']
        submit_hole(fs2, 1, [
            (m2['E'].player_id, 4), (m2['F'].player_id, 4),
            (m2['G'].player_id, 4), (m2['H'].player_id, 4),
        ])
        resp = self._remove(fs2, m2['F'].player)
        self.assertEqual(resp.status_code, 409, resp.content)
        self.assertTrue(
            HoleScore.objects.filter(foursome=fs2).exists(),
            'scores must be untouched by a refused removal',
        )

    # ------------------------------------------------------------------ #
    # Early group with no full prior → rejected; tee swap recovers it
    # ------------------------------------------------------------------ #
    def test_tee_swap_recovers_early_no_show(self):
        ctx = self._build_cup_round()
        fs1, fs2, m1 = ctx['fs1'], ctx['fs2'], ctx['m1']
        noshow = m1['B'].player   # Team 1 in the EARLIEST group

        # fs1 tees first, so a 2v1 there would have no full group ahead of it
        # to donate phantom scores → rejected, and rolled back.
        resp = self._remove(fs1, noshow)
        self.assertEqual(resp.status_code, 400, resp.content)
        self.assertIn('errors', resp.data)
        self.assertTrue(
            fs1.memberships.filter(player=noshow).exists(),
            'a rejected removal must roll back the membership delete',
        )

        # Recovery: swap fs1 to the later position (behind the full fs2).
        swap = self.client.post(
            reverse('api-foursome-swap-position', args=[fs1.id]),
            {'target_group_number': fs2.group_number}, format='json',
        )
        self.assertEqual(swap.status_code, 200, swap.content)

        # Now a full group (fs2) tees before fs1 → the removal succeeds.
        resp2 = self._remove(fs1, noshow)
        self.assertEqual(resp2.status_code, 200, resp2.content)
        fs1.refresh_from_db()
        self.assertTrue(fs1.has_phantom)
