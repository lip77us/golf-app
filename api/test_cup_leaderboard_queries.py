"""The cup leaderboard's query count, pinned.

Reported as "bringing up the triple leaderboard is slow". Profiling a 3-group
round found 191 queries for one `cup_round_live_summary` — which extrapolates
to ~760 on a 12-group cup, and on Railway every one of those is a network
round trip rather than the sub-millisecond local hop that hides it in dev.

Two causes, both N+1:

* `hole_plan.course_hole_count` re-queried the course's tees on every call,
  and `play_order` calls it from 59 sites. 46 of the 191.
* Eleven sites read `team.players.values_list('id', flat=True)`. The matches
  queryset ALREADY prefetched `teams__players` — but `values_list` does not
  consult the prefetch cache, so each one issued a fresh query anyway. That
  is the trap this test exists to catch: the prefetch looks present and buys
  nothing.

A ceiling rather than an exact count, so ordinary changes do not fail it and
a reintroduced N+1 does.
"""
from datetime import date

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext

from core.models import Player, PlayerSex
from scoring.tests._helpers import make_tee, make_round, _test_account
from services.hole_plan import course_hole_count, play_order
from services.triple_cup import setup_triple_cup, triple_cup_summary
from tournament.models import (
    Foursome, FoursomeMembership, RyderCupRoundConfig, TeamTournament,
    Tournament, TournamentTeam,
)


class HoleCountMemoTests(TestCase):

    def test_the_hole_count_is_asked_for_once_per_round_instance(self):
        tee = make_tee()
        rnd = make_round(tee.course)
        with CaptureQueriesContext(connection) as first:
            course_hole_count(rnd)
        self.assertGreater(len(first), 0, 'setup: the first call must query')
        with CaptureQueriesContext(connection) as rest:
            for _ in range(20):
                course_hole_count(rnd)
                play_order(rnd)
        self.assertEqual(len(rest), 0,
                         'twenty more calls must not touch the database')

    def test_a_fresh_instance_recomputes(self):
        """The cache dies with the instance — it is not a process-wide cache
        that could serve a stale hole count after a tee change."""
        tee = make_tee()
        rnd = make_round(tee.course)
        course_hole_count(rnd)
        from tournament.models import Round
        again = Round.objects.get(pk=rnd.pk)
        with CaptureQueriesContext(connection) as ctx:
            course_hole_count(again)
        self.assertGreater(len(ctx), 0)


class TripleCupSummaryQueryTests(TestCase):

    def setUp(self):
        self.acct = _test_account()
        self.tee  = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        t = Tournament.objects.create(account=self.acct, name='Cup',
                                      start_date=date(2026, 10, 8))
        self.round.tournament = t
        self.round.save(update_fields=['tournament'])
        tt = TeamTournament.objects.create(tournament=t, cup_name='Cup',
                                           players_per_team=2)
        RyderCupRoundConfig.objects.create(round=self.round, tournament=tt)
        teams = [TournamentTeam.objects.create(tournament=tt, name=n,
                                               team_number=i + 1, colour=c)
                 for i, (n, c) in enumerate([('Red', 'red'), ('Blue', 'blue')])]
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        sides = ([], [])
        for i in range(4):
            p = Player.objects.create(
                account=self.acct, name=f'P{i}', short_name=f'P{i}',
                handicap_index=10 + i, sex=PlayerSex.MALE)
            teams[i % 2].players.add(p)
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=10 + i, playing_handicap=10 + i)
            sides[i % 2].append(p.pk)
        setup_triple_cup(self.fs, team1_ids=sides[0], team2_ids=sides[1],
                         handicap_mode='gross')

    def test_a_single_foursome_summary_stays_under_the_ceiling(self):
        with CaptureQueriesContext(connection) as ctx:
            triple_cup_summary(self.fs)
        self.assertLess(
            len(ctx), 45,
            f'{len(ctx)} queries for ONE foursome — a 12-group cup multiplies '
            f'this by twelve, over the network. Check for a `values_list` on '
            f'a prefetched relation, which silently bypasses the cache.',
        )

    def test_no_team_player_read_bypasses_the_prefetch(self):
        """The specific regression: `values_list` on `team.players`.

        It reads as an optimisation and is the opposite — the matches
        queryset prefetches `teams__players`, and `values_list` ignores it.
        """
        import services.triple_cup as tc
        src = open(tc.__file__).read()
        self.assertNotIn(
            "players.values_list('id', flat=True)", src,
            'use `[p.id for p in team.players.all()]` so the prefetch counts',
        )
