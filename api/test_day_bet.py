"""
api/test_day_bet.py
-------------------
Day-bet setup/board endpoints, and the payout-step guard that sizes the two
pots against each other.

The guard belongs in the reducer, not only in the UI: an API caller must not
be able to post a championship table whose last paying place is worth less
than day-bet 1st, because that placing DISQUALIFIES a golfer from the day bet
and would therefore cost him money. Nobody should be worse off for playing
better. (Rule and helper: services/payout.py; spec §3.)
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Tee
from games.models import DayBetConfig, LowNetChampionshipConfig
from tournament.models import Round, Tournament

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class DayBetEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Duddy Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        Tee.objects.create(course=course, tee_name='White', slope=113,
                           course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Duddy Cup', start_date=date(2026, 6, 1),
            total_rounds=2, active_games=['low_net'])
        self.r1 = Round.objects.create(account=self.acct, course=course,
                                       tournament=self.tourn, round_number=1,
                                       status='in_progress')
        self.r2 = Round.objects.create(account=self.acct, course=course,
                                       tournament=self.tourn, round_number=2,
                                       status='in_progress')

    def _setup_url(self, round_obj):
        return reverse('api-day-bet-setup', args=[round_obj.id])

    # -- setup ------------------------------------------------------------

    def test_defaults_when_no_day_bet_is_configured(self):
        r = self.client.get(self._setup_url(self.r2))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), {'entry_fee': 0.00, 'payouts': []})

    def test_configure_round_trips(self):
        r = self.client.post(self._setup_url(self.r2), {
            'entry_fee': '20.00',
            'payouts'  : [{'place': 1, 'amount': 100}, {'place': 2, 'amount': 60}],
        }, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['entry_fee'], 20.0)
        self.assertTrue(DayBetConfig.objects.filter(round=self.r2).exists())

    def test_a_one_round_event_has_no_day_bet(self):
        self.tourn.total_rounds = 1
        self.tourn.save(update_fields=['total_rounds'])
        r = self.client.post(self._setup_url(self.r2),
                             {'entry_fee': '20.00', 'payouts': []},
                             format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('more than one round', r.json()['detail'])

    # -- the floor guard, from both directions ----------------------------

    def test_posting_a_day_bet_that_out_pays_the_championship_is_blocked(self):
        LowNetChampionshipConfig.objects.create(
            tournament=self.tourn, entry_fee=Decimal('40.00'),
            payouts=[{'place': 1, 'amount': 400}, {'place': 2, 'amount': 80}])

        r = self.client.post(self._setup_url(self.r2), {
            'entry_fee': '20.00',
            'payouts'  : [{'place': 1, 'amount': 140}],
        }, format='json')
        self.assertEqual(r.status_code, 400)
        detail = r.json()['detail']
        self.assertIn('day bet', detail)
        self.assertIn('$60.00', detail)      # what the DQ would cost him
        self.assertFalse(DayBetConfig.objects.filter(round=self.r2).exists())

    def test_lowering_the_championship_below_the_day_bet_is_blocked(self):
        DayBetConfig.objects.create(
            round=self.r2, entry_fee=Decimal('20.00'),
            payouts=[{'place': 1, 'amount': 140}])

        r = self.client.post(
            reverse('api-tournament-low-net-setup', args=[self.tourn.id]),
            {'entry_fee': '40.00',
             'payouts': [{'place': 1, 'amount': 400}, {'place': 2, 'amount': 80}]},
            format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('day bet', r.json()['detail'])
        self.assertFalse(
            LowNetChampionshipConfig.objects.filter(tournament=self.tourn).exists())

    def test_a_table_that_clears_the_floor_saves(self):
        DayBetConfig.objects.create(
            round=self.r2, entry_fee=Decimal('20.00'),
            payouts=[{'place': 1, 'amount': 100}])

        r = self.client.post(
            reverse('api-tournament-low-net-setup', args=[self.tourn.id]),
            {'entry_fee': '40.00',
             'payouts': [{'place': 1, 'amount': 400}, {'place': 2, 'amount': 200}]},
            format='json')
        self.assertEqual(r.status_code, 200)

    # -- board ------------------------------------------------------------

    def test_board_reports_unconfigured(self):
        r = self.client.get(reverse('api-day-bet', args=[self.r2.id]))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), {'configured': False})
