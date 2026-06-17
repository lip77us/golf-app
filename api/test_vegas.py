"""
api/test_vegas.py
-----------------
Las Vegas setup/result endpoints: the 2v2 team config round-trips through the
serializer/view/urls. (The scoring engine itself is covered by
scoring/tests/test_vegas.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership


User = get_user_model()


class VegasEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Vegas Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['vegas'], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('A', 'B', 'C', 'D')
        ]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.ids = [p.id for p in self.players]

    def _setup_body(self, **over):
        body = {
            'handicap_mode': 'net', 'net_percent': 100,
            'net_max_double_bogey': True, 'birdie_mode': 'flip',
            'carryover': False,
            'team1_player_ids': self.ids[:2], 'team2_player_ids': self.ids[2:],
        }
        body.update(over)
        return body

    def test_setup_creates_teams_and_returns_summary(self):
        resp = self.client.post(
            reverse('api-vegas-setup', args=[self.fs.id]),
            self._setup_body(birdie_mode='multiplier', carryover=True),
            format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['birdie_mode'], 'multiplier')
        self.assertTrue(resp.data['carryover'])
        teams = {t['team_number']: t for t in resp.data['teams']}
        self.assertEqual({p['player_id'] for p in teams[1]['players']},
                         set(self.ids[:2]))
        self.assertEqual({p['player_id'] for p in teams[2]['players']},
                         set(self.ids[2:]))

    def test_result_endpoint_round_trips(self):
        self.client.post(reverse('api-vegas-setup', args=[self.fs.id]),
                         self._setup_body(), format='json')
        resp = self.client.get(reverse('api-vegas-result', args=[self.fs.id]))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['birdie_mode'], 'flip')
        self.assertEqual(len(resp.data['teams']), 2)

    def test_overlapping_players_rejected(self):
        resp = self.client.post(
            reverse('api-vegas-setup', args=[self.fs.id]),
            self._setup_body(team2_player_ids=[self.ids[1], self.ids[2]]),
            format='json')
        self.assertEqual(resp.status_code, 400)
