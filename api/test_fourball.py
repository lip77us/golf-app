"""
api/test_fourball.py
--------------------
Fourball setup/result endpoints: the 2v2 team config round-trips through the
serializer/view/urls. (The scoring engine itself is covered by
scoring/tests/test_fourball.py.)
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


class FourballEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Fourball Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['fourball'], bet_unit=Decimal('3.00'))
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

    def _body(self, **over):
        body = {
            'handicap_mode': 'net', 'net_percent': 100,
            'team1_player_ids': self.ids[:2], 'team2_player_ids': self.ids[2:],
        }
        body.update(over)
        return body

    def test_setup_creates_teams_and_returns_summary(self):
        resp = self.client.post(
            reverse('api-fourball-setup', args=[self.fs.id]),
            self._body(handicap_mode='strokes_off', net_percent=90),
            format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['handicap']['mode'], 'strokes_off')
        self.assertEqual(resp.data['handicap']['net_percent'], 90)
        self.assertEqual({pid for pid in resp.data['team1']['player_ids']},
                         set(self.ids[:2]))
        # bet_amount inherits the round bet_unit when omitted.
        self.assertEqual(resp.data['money']['bet_amount'], 3.0)

    def test_overlapping_teams_rejected(self):
        resp = self.client.post(
            reverse('api-fourball-setup', args=[self.fs.id]),
            self._body(team2_player_ids=[self.ids[1], self.ids[2]]),
            format='json')
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_result_404_before_setup(self):
        resp = self.client.get(reverse('api-fourball-result', args=[self.fs.id]))
        self.assertEqual(resp.status_code, 404)

    def test_result_round_trips_after_setup(self):
        self.client.post(reverse('api-fourball-setup', args=[self.fs.id]),
                         self._body(), format='json')
        resp = self.client.get(reverse('api-fourball-result', args=[self.fs.id]))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'pending')
        self.assertEqual(resp.data['result_label'], '—')
