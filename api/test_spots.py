"""
api/test_spots.py
-----------------
Spots setup / tally / result endpoints round-trip through the
serializer/view/urls. (The settlement math is covered by
scoring/tests/test_spots.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class SpotsEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Spots Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['nassau', 'spots'], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('A', 'B', 'C', 'D')
        ]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.ids = [p.id for p in self.players]

    def _setup(self, **over):
        body = {'bet_unit': '1.00', 'payout_style': 'pay_around'}
        body.update(over)
        return self.client.post(
            reverse('api-spots-setup', args=[self.fs.id]), body, format='json')

    def test_setup_returns_summary(self):
        resp = self._setup()
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['payout_style'], 'pay_around')
        self.assertEqual(resp.data['money']['total_spots'], 0)

    def test_tally_then_summary_reflects_counts(self):
        self._setup()
        resp = self.client.post(
            reverse('api-spots-tally', args=[self.fs.id]),
            {'hole_number': 3, 'entries': [{'player_id': self.ids[0], 'count': 2}]},
            format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['money']['total_spots'], 2)
        winner = next(p for p in resp.data['players'] if p['spots'] == 2)
        self.assertEqual(winner['player_id'], self.ids[0])
        self.assertEqual(winner['payout'], 6.0)  # pay-around, foursome

        # GET mirrors it.
        got = self.client.get(reverse('api-spots-result', args=[self.fs.id]))
        self.assertEqual(got.data['money']['total_spots'], 2)

    def test_tally_without_setup_is_400(self):
        resp = self.client.post(
            reverse('api-spots-tally', args=[self.fs.id]),
            {'hole_number': 1, 'entries': [{'player_id': self.ids[0], 'count': 1}]},
            format='json')
        self.assertEqual(resp.status_code, 400)
