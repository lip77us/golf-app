"""
api/test_stableford_championship.py
-----------------------------------
Stableford Championship: total points accumulated across all tournament rounds,
ranked desc, pool-paid. Gross mode keeps the fixtures simple.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Tournament, Round, Foursome, FoursomeMembership
from scoring.models import HoleScore

User = get_user_model()
HOLES = [{'number': i, 'par': 4, 'stroke_index': i} for i in range(1, 19)]


class StablefordChampionshipTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.client = APIClient(); self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.acct, name='Pines')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=HOLES)
        self.tourney = Tournament.objects.create(
            account=self.acct, name='Member-Member', start_date=date(2026, 6, 6),
            active_games=[])
        # Two rounds; A birdies (gross 3), B pars (gross 4) in both.
        self.pa = Player.objects.create(account=self.acct, name='A',
                                        handicap_index=Decimal('0.0'))
        self.pb = Player.objects.create(account=self.acct, name='B',
                                        handicap_index=Decimal('0.0'))
        for rn in (1, 2):
            rd = Round.objects.create(
                account=self.acct, tournament=self.tourney, round_number=rn,
                course=self.course, status='in_progress', active_games=[])
            fs = Foursome.objects.create(round=rd, group_number=1)
            for p, gross in ((self.pa, 3), (self.pb, 4)):
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=0, playing_handicap=0)
                for h in range(1, 19):
                    HoleScore.objects.create(
                        foursome=fs, player=p, hole_number=h,
                        gross_score=gross, handicap_strokes=0)

    def _setup(self, **body):
        body.setdefault('handicap_mode', 'gross')
        return self.client.post(
            reverse('api-tournament-stableford-setup', args=[self.tourney.id]),
            body, format='json')

    def _result(self):
        return self.client.get(
            reverse('api-tournament-stableford', args=[self.tourney.id])).data

    def test_setup_activates_championship(self):
        r = self._setup()
        self.assertEqual(r.status_code, 201, r.data)
        self.tourney.refresh_from_db()
        self.assertIn('stableford_championship', self.tourney.active_games)

    def test_points_accumulate_across_rounds(self):
        self._setup()  # standard table, gross
        res = self._result()
        rows = {r['player_name']: r for r in res['results']}
        # 18 holes × 2 rounds: A birdies → 3 pts ×36 = 108; B pars → 2 ×36 = 72.
        self.assertEqual(rows['A']['total_points'], 108)
        self.assertEqual(rows['B']['total_points'], 72)
        self.assertEqual(rows['A']['rounds_played'], 2)
        self.assertEqual(rows['A']['round_totals'], [54, 54])
        self.assertEqual(rows['A']['rank'], 1)
        self.assertEqual(res['total_rounds'], 2)

    def test_modified_table_and_payout(self):
        self._setup(pts_birdie=2, pts_par=0, pts_bogey=-1,
                    entry_fee='20.00',
                    payouts=[{'place': 1, 'amount': '40.00'}])
        res = self._result()
        rows = {r['player_name']: r for r in res['results']}
        self.assertEqual(rows['A']['total_points'], 36 * 2)  # birdies → 2
        self.assertEqual(rows['B']['total_points'], 0)        # pars → 0
        self.assertEqual(res['pool'], 40.0)                   # 20 × 2 players
        self.assertEqual(rows['A']['payout'], 40.0)
        self.assertIsNone(rows['B']['payout'])

    def test_leaderboard_includes_championship(self):
        self._setup()
        data = self.client.get(
            reverse('api-tournament-leaderboard', args=[self.tourney.id])).data
        self.assertIn('stableford_championship', data['games'])

    def test_watch_championship_renders(self):
        self._setup()
        from django.test import Client
        rd = self.tourney.rounds.first()
        resp = Client().get(
            f'/watch/{rd.watch_token}/?view=stableford_championship')
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, 'Stableford')
        self.assertContains(resp, 'A')
