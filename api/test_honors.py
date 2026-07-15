"""
api/test_honors.py
------------------
Honors setup / result endpoints round-trip through the
serializer/view/urls.  (The carry + settlement math is covered by
scoring/tests/test_honors.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class HonorsEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Honors Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['skins', 'honors'], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('A', 'B', 'C')
        ]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.ids = [p.id for p in self.players]

    def _submit(self, hole, scores):
        for pid, gross in scores:
            HoleScore.objects.update_or_create(
                foursome=self.fs, player_id=pid, hole_number=hole,
                defaults={'gross_score': gross, 'handicap_strokes': 0})

    def _setup(self, **over):
        body = {'handicap_mode': 'gross', 'payout_style': 'per_point',
                'per_point_mode': 'average'}
        body.update(over)
        return self.client.post(
            reverse('api-honors-setup', args=[self.fs.id]), body, format='json')

    def test_setup_returns_summary(self):
        resp = self._setup()
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['handicap']['mode'], 'gross')
        self.assertEqual(resp.data['money']['payout_style'], 'per_point')
        self.assertEqual(resp.data['money']['per_point_mode'], 'average')
        self.assertEqual(resp.data['status'], 'pending')

    def test_setup_scores_existing_holes_and_result_mirrors(self):
        # Pre-existing scores should be reflected in the first summary.
        self._submit(1, [(self.ids[0], 4), (self.ids[1], 5), (self.ids[2], 6)])
        self._submit(2, [(self.ids[0], 5), (self.ids[1], 4), (self.ids[2], 6)])
        resp = self._setup()
        self.assertEqual(resp.status_code, 201, resp.data)
        pts = {p['player_id']: p['points'] for p in resp.data['players']}
        # A won hole 1, B won hole 2 → 1 point each.
        self.assertEqual(pts[self.ids[0]], 1)
        self.assertEqual(pts[self.ids[1]], 1)
        self.assertEqual(pts[self.ids[2]], 0)

        got = self.client.get(reverse('api-honors-result', args=[self.fs.id]))
        self.assertEqual(got.status_code, 200)
        pts2 = {p['player_id']: p['points'] for p in got.data['players']}
        self.assertEqual(pts, pts2)

    def test_result_zero_sum_money(self):
        self._submit(1, [(self.ids[0], 3), (self.ids[1], 4), (self.ids[2], 5)])
        self._setup()
        got = self.client.get(reverse('api-honors-result', args=[self.fs.id]))
        total = sum(p['money'] for p in got.data['players'])
        self.assertAlmostEqual(total, 0.0, places=6)

    def test_participant_subset_excludes_a_player(self):
        # C has the low gross on hole 1 but is excluded; the honor goes to A.
        self._submit(1, [(self.ids[0], 4), (self.ids[1], 5), (self.ids[2], 3)])
        resp = self._setup(
            participant_player_ids=[self.ids[0], self.ids[1]])
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(
            resp.data['participant_player_ids'], [self.ids[0], self.ids[1]])
        ids_in = {p['player_id'] for p in resp.data['players']}
        self.assertEqual(ids_in, {self.ids[0], self.ids[1]})
        pts = {p['player_id']: p['points'] for p in resp.data['players']}
        self.assertEqual(pts[self.ids[0]], 1)  # A held the honor on hole 1

    def test_one_player_subset_rejected(self):
        resp = self._setup(participant_player_ids=[self.ids[0]])
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_requires_auth(self):
        anon = APIClient()
        resp = anon.get(reverse('api-honors-result', args=[self.fs.id]))
        self.assertIn(resp.status_code, (401, 403))
