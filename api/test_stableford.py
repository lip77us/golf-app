"""
api/test_stableford.py
----------------------
Casual Stableford: editable 6-bucket points table (Net%/Gross, no Strokes-Off),
ranked standings, and Low-Net-style prize payouts. Gross mode is used here so
the table + ranking + money are exercised without handicap allocation.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership
from scoring.models import HoleScore


User = get_user_model()

# 18 par-4 holes, stroke index 1..18.
HOLES = [{'number': i, 'par': 4, 'stroke_index': i} for i in range(1, 19)]


class StablefordTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.client = APIClient(); self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.acct, name='Pines')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=self.course, status='in_progress',
            active_games=[])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        # Three players: A all birdies, B all pars, C all bogeys.
        self.pa = self._player('A', gross=3)
        self.pb = self._player('B', gross=4)
        self.pc = self._player('C', gross=5)

    def _player(self, name, *, gross):
        p = Player.objects.create(
            account=self.acct, name=name, handicap_index=Decimal('0.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=p, tee=self.tee,
            course_handicap=0, playing_handicap=0)
        for h in range(1, 19):
            HoleScore.objects.create(
                foursome=self.fs, player=p, hole_number=h,
                gross_score=gross, handicap_strokes=0)
        return p

    def _setup(self, **body):
        body.setdefault('handicap_mode', 'gross')
        return self.client.post(
            reverse('api-stableford-setup', args=[self.round.id]),
            body, format='json')

    def _result(self):
        return self.client.get(
            reverse('api-stableford-result', args=[self.round.id])).data

    # ---- setup ----
    def test_setup_activates_game_and_defaults(self):
        r = self._setup()
        self.assertEqual(r.status_code, 201, r.data)
        self.round.refresh_from_db()
        self.assertIn('stableford', self.round.active_games)
        self.assertEqual(r.data['pts_birdie'], 3)   # standard default

    # ---- standard table: birdie 3 / par 2 / bogey 1 ----
    def test_standard_table_ranking(self):
        self._setup()
        res = self._result()
        rows = {row['player_name']: row for row in res['results']}
        self.assertEqual(rows['A']['total_points'], 18 * 3)  # birdies
        self.assertEqual(rows['B']['total_points'], 18 * 2)  # pars
        self.assertEqual(rows['C']['total_points'], 18 * 1)  # bogeys
        self.assertEqual(rows['A']['rank'], 1)
        self.assertEqual(rows['C']['rank'], 3)

    # ---- modified table (8/5/2/0/-1/-3) changes the spread ----
    def test_modified_table(self):
        self._setup(pts_eagle=5, pts_birdie=2, pts_par=0,
                    pts_bogey=-1, pts_double=-3, pts_albatross=8)
        rows = {r['player_name']: r for r in self._result()['results']}
        self.assertEqual(rows['A']['total_points'], 18 * 2)    # birdies → 2
        self.assertEqual(rows['B']['total_points'], 0)          # pars → 0
        self.assertEqual(rows['C']['total_points'], 18 * -1)    # bogeys → -1
        self.assertEqual(rows['A']['rank'], 1)

    # ---- money: pool + payout to the winner ----
    def test_payouts(self):
        self._setup(entry_fee='10.00',
                    payouts=[{'place': 1, 'amount': '30.00'}])
        res = self._result()
        self.assertEqual(res['pool'], 30.0)        # 10 × 3 players
        rows = {r['player_name']: r for r in res['results']}
        self.assertEqual(rows['A']['payout'], 30.0)
        self.assertIsNone(rows['B']['payout'])

    def test_per_point_pay_everyone_above_you(self):
        # 3 players, points 54 / 36 / 18 (birdies/pars/bogeys), $1 a point.
        self._setup(payout_style='per_point', per_point_rate='1.00')
        rows = {r['player_name']: r for r in self._result()['results']}
        # net = rate × (n·pts − total); total = 108, n = 3.
        self.assertEqual(rows['A']['payout'], 3 * 54 - 108)   # +54
        self.assertEqual(rows['B']['payout'], 3 * 36 - 108)   #   0
        self.assertEqual(rows['C']['payout'], 3 * 18 - 108)   # -54
        # Zero-sum.
        self.assertEqual(sum(r['payout'] for r in rows.values()), 0)

    def test_excluded_player_gets_no_money(self):
        self._setup(entry_fee='10.00',
                    payouts=[{'place': 1, 'amount': '30.00'}],
                    excluded_player_ids=[self.pa.id])
        rows = {r['player_name']: r for r in self._result()['results']}
        # A excluded → no payout; the prize falls to the next eligible (B).
        self.assertIsNone(rows['A']['payout'])
        self.assertTrue(rows['A']['excluded'])
        self.assertEqual(rows['B']['payout'], 30.0)
