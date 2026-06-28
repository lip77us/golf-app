"""Regression test for Triple Cup cup-mode standings.

services/ryder_cup.py used to have NO triple_cup branch, so a Triple Cup
foursome wrote zero RyderCupMatchPoints rows and the tournament standings
collapsed to a single halved match (0.5-0.5).  This pins that a TC group now
contributes one cup-points row per match (4 matches × point_value).
"""
from datetime import date

from django.test import TestCase

from core.models import GameType
from tournament.models import (
    Tournament, TeamTournament, TournamentTeam,
    RyderCupRoundConfig, RyderCupFoursomeConfig,
)
from services.ryder_cup import calculate_ryder_cup_points
from services.triple_cup import setup_triple_cup, calculate_triple_cup

from ._helpers import (
    make_tee, make_round, make_foursome, submit_hole, _test_account,
)


class CupTripleCupPointsTests(TestCase):

    def _build_cup_tc_foursome(self, point_value):
        """A single-foursome 2v2 cup round running Triple Cup."""
        tee = make_tee()
        round_ = make_round(tee.course, handicap_mode='gross')
        acct = _test_account()

        tourn = Tournament.objects.create(
            account=acct, name='Cup', start_date=date(2026, 1, 1),
        )
        tt = TeamTournament.objects.create(
            tournament=tourn, cup_name='Test Cup', players_per_team=2,
        )
        team1 = TournamentTeam.objects.create(
            tournament=tt, name='Orange', team_number=1, colour='orange',
        )
        team2 = TournamentTeam.objects.create(
            tournament=tt, name='Blue', team_number=2, colour='blue',
        )

        fs = make_foursome(
            round_, [('A', 0), ('B', 0), ('C', 0), ('D', 0)], tee=tee,
        )
        m = {x.player.name: x
             for x in fs.memberships.select_related('player')}
        team1.players.set([m['A'].player, m['B'].player])
        team2.players.set([m['C'].player, m['D'].player])

        rc = RyderCupRoundConfig.objects.create(
            round=round_, tournament=tt,
            nassau_point_value=1, point_multiplier=1,
        )
        RyderCupFoursomeConfig.objects.create(
            foursome=fs, round_config=rc, game_type=GameType.TRIPLE_CUP,
            team1=team1, team2=team2, point_value=point_value,
        )
        setup_triple_cup(
            fs,
            team1_ids=[m['A'].player_id, m['B'].player_id],
            team2_ids=[m['C'].player_id, m['D'].player_id],
            handicap_mode='gross',
        )
        return tee, round_, fs, m

    def test_triple_cup_foursome_writes_four_match_rows(self):
        pv = 4
        tee, round_, fs, m = self._build_cup_tc_foursome(point_value=pv)

        # Team 1 (A,B) par every hole; team 2 (C,D) bogey — team 1 wins all
        # four matches (fourball, foursomes, both singles).
        for h in range(1, 19):
            par = tee.hole(h)['par']
            submit_hole(fs, h, [
                (m['A'].player_id, par),     (m['B'].player_id, par),
                (m['C'].player_id, par + 1), (m['D'].player_id, par + 1),
            ])
        calculate_triple_cup(fs)

        rows = calculate_ryder_cup_points(round_)
        tc_rows = [r for r in rows
                   if r.foursome_id == fs.id
                   and r.game_type == GameType.TRIPLE_CUP]

        # One row per TC match — was ZERO before the fix.
        self.assertEqual(len(tc_rows), 4, tc_rows)
        # Team 1 swept all 4 → 4 matches × pv(4) × mul(1) = 16; team 2 = 0.
        self.assertEqual(sum(r.team1_points for r in tc_rows), 16)
        self.assertEqual(sum(r.team2_points for r in tc_rows), 0)
        # Total distributed = 4 matches × pv (no collapse to one halved match).
        self.assertEqual(
            sum(r.team1_points + r.team2_points for r in tc_rows), 16)
