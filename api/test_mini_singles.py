"""
api/test_mini_singles.py
------------------------
Mini Singles setup / board / day-2 sync endpoints, and the tournament
leaderboard's new tabs.

The engine itself is covered by scoring/tests/test_mini_singles.py; this is
the surface the wizard and the boards talk to.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from games.models import MiniSinglesConfig
from tournament.models import Foursome, FoursomeMembership, Round, Tournament

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class MiniSinglesEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Duddy Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Duddy Cup', start_date=date(2026, 6, 1),
            total_rounds=2, active_games=['low_net', 'match_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')
        self.players = [
            Player.objects.create(account=self.acct, name=f'Golfer {i}',
                                  handicap_index=Decimal('0'))
            for i in range(16)
        ]
        for g in range(4):
            fs = Foursome.objects.create(round=self.round, group_number=g + 1)
            for p in self.players[g * 4:(g + 1) * 4]:
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=0, playing_handicap=0)

    def _setup_url(self):
        return reverse('api-mini-singles-setup', args=[self.tourn.id])

    def test_defaults_report_the_field_gate(self):
        r = self.client.get(self._setup_url())
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertFalse(body['configured'])
        # Strokes off low is the default here — a match has a low man to
        # anchor to, unlike the field games.
        self.assertEqual(body['handicap_mode'], 'strokes_off')
        self.assertEqual(body['field'], {'golfers': 16, 'groups': 4,
                                         'fits': True, 'reason': ''})

    def test_configure_round_trips_and_stores_the_carve_out(self):
        r = self.client.post(self._setup_url(), {
            'day1_entry_fee' : '10.00',
            'day1_payouts'   : [{'place': 1, 'amount': 24}],
            'day2_payouts'   : [{'place': 1, 'amount': 90}],
            'empty_seat_rule': 'points',
            'carve_pct'      : 25,
        }, format='json')
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertTrue(body['configured'])
        self.assertEqual(body['empty_seat_rule'], 'points')
        self.assertEqual(body['carve_pct'], 25)
        self.tourn.refresh_from_db()
        self.assertEqual(self.tourn.mini_singles_carve_pct, 25)

    def test_a_field_that_cannot_fit_is_refused_with_the_reason(self):
        # A 17th golfer gives five group winners, and five cannot play a
        # knockout in one round.
        fs = Foursome.objects.create(round=self.round, group_number=5)
        extra = Player.objects.create(account=self.acct, name='Seventeen',
                                      handicap_index=Decimal('0'))
        FoursomeMembership.objects.create(foursome=fs, player=extra,
                                          tee=self.tee, course_handicap=0,
                                          playing_handicap=0)
        r = self.client.post(self._setup_url(), {'day1_entry_fee': '10.00'},
                             format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('third day', r.json()['detail'])

    def test_switching_it_off_takes_the_carve_out_with_it(self):
        self.client.post(self._setup_url(),
                         {'day1_entry_fee': '10.00', 'carve_pct': 25},
                         format='json')
        r = self.client.delete(self._setup_url())
        self.assertEqual(r.status_code, 204)
        self.tourn.refresh_from_db()
        self.assertEqual(self.tourn.mini_singles_carve_pct, 0)
        self.assertFalse(
            MiniSinglesConfig.objects.filter(tournament=self.tourn).exists())

    def test_the_board_reports_unconfigured(self):
        r = self.client.get(reverse('api-mini-singles', args=[self.tourn.id]))
        self.assertEqual(r.json(), {'configured': False})

    def test_sync_is_a_no_op_before_day_one_resolves(self):
        MiniSinglesConfig.objects.create(tournament=self.tourn)
        r = self.client.post(
            reverse('api-mini-singles-sync', args=[self.tourn.id]))
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()['synced'])


class TournamentLeaderboardChipsTests(MiniSinglesEndpointTests):
    def test_the_board_carries_the_scoring_chip_strip(self):
        r = self.client.get(
            reverse('api-tournament-leaderboard', args=[self.tourn.id]))
        self.assertEqual(r.status_code, 200)
        scoring = r.json()['scoring']
        self.assertEqual(scoring['method'], 'stroke')
        self.assertEqual(scoring['handicap_mode'], 'net')
        self.assertEqual(scoring['counting_rule'], 'All 2 rounds')
        self.assertIn('net double bogey', scoring['cap_note'])
