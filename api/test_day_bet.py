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
        d = r.json()
        self.assertEqual(d['entry_fee'], 0.00)
        self.assertEqual(d['payouts'], [])
        self.assertFalse(d['configured'])
        # The screen is told whether it may configure here and why not, rather
        # than deriving it — the day bet is the final round of a multi-round
        # event only, and a client counting rounds would be a second copy of
        # that rule.
        self.assertIn('eligible', d)
        self.assertIn('reason', d)
        self.assertIn('championship_payouts', d)

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


class ThePotIsTheEligibleCountTests(DayBetEndpointTests):
    """Eight golfers paying two places is a pot of SIX entries, not eight.

    The money winners do not pay in. `day_bet_summary` has always computed
    the pool that way once the round exists; the SETUP screen was multiplying
    by the whole field, so a TD sizing the payouts was shown a pot a third
    bigger than the one that would exist. Reported 10 Oct 2026.
    """

    def _field(self, n):
        """n real golfers across the tournament's rounds."""
        from core.models import Player, Tee
        from tournament.models import Foursome, FoursomeMembership
        tee = Tee.objects.filter(course=self.r1.course).first()
        fs = Foursome.objects.create(round=self.r1, group_number=1)
        for i in range(n):
            p = Player.objects.create(account=self.acct, name=f'G{i}',
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(foursome=fs, player=p, tee=tee,
                                              course_handicap=0,
                                              playing_handicap=0)

    def test_the_paying_places_come_out_of_the_pot(self):
        self._field(8)
        LowNetChampionshipConfig.objects.update_or_create(
            tournament=self.tourn,
            defaults={'payouts': [{'place': 1, 'amount': 60},
                                  {'place': 2, 'amount': 20}]})
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertEqual(d['field_size'], 8)
        self.assertEqual(d['paying_places'], 2)
        self.assertEqual(d['expected_eligible'], 6,
                         'eight golfers, two in the money, six pay in')

    def test_a_place_paying_nothing_does_not_come_out(self):
        """A zero row is a place nobody collects, so that golfer still pays."""
        self._field(8)
        LowNetChampionshipConfig.objects.update_or_create(
            tournament=self.tourn,
            defaults={'payouts': [{'place': 1, 'amount': 60},
                                  {'place': 2, 'amount': 0}]})
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertEqual(d['expected_eligible'], 7)

    def test_no_championship_means_the_whole_field_pays(self):
        self._field(8)
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertEqual(d['paying_places'], 0)
        self.assertEqual(d['expected_eligible'], 8)


class TurningItOffTests(DayBetEndpointTests):
    """A TD who set one up and changed his mind had no way back.

    An entry of 0 is a configured bet worth nothing — it still draws a board
    and a tab. Deleting the config is the honest "we are not playing one".
    """

    def test_delete_removes_it(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '5.00',
                          'payouts': [{'place': 1, 'amount': 20}]},
                         format='json')
        self.assertTrue(DayBetConfig.objects.filter(round=self.r2).exists())

        r = self.client.delete(self._setup_url(self.r2))
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()['configured'])
        self.assertFalse(DayBetConfig.objects.filter(round=self.r2).exists())

    def test_delete_is_idempotent(self):
        """Nothing to remove is not an error — the end state is what matters."""
        r = self.client.delete(self._setup_url(self.r2))
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()['deleted'])

    def test_the_setup_reports_it_gone(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '5.00', 'payouts': []}, format='json')
        self.client.delete(self._setup_url(self.r2))
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertFalse(d['configured'])
        self.assertEqual(d['entry_fee'], 0.00)


class TheHubButtonFollowsTheSwitchTests(DayBetEndpointTests):
    """`has_day_bet` is what takes the hub's button away.

    The hub drew a Configure Day bet button off `is_final_round` alone, so it
    appeared on the last round whether or not a day bet existed — and a TD who
    turned one off on the side games screen was left with a live route into a
    bet nobody was playing. `is_final_round` says one COULD live here;
    `has_day_bet` says one does, and the button needs both.
    """

    def _round_payload(self, round_obj):
        r = self.client.get(reverse('api-round-detail', args=[round_obj.id]))
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def test_false_before_anything_is_set_up(self):
        d = self._round_payload(self.r2)
        self.assertTrue(d['is_final_round'])
        self.assertFalse(d['has_day_bet'])

    def test_true_once_it_is(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '4.00',
                          'payouts': [{'place': 1, 'amount': 20}]},
                         format='json')
        self.assertTrue(self._round_payload(self.r2)['has_day_bet'])

    def test_false_again_once_it_is_turned_off(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '4.00',
                          'payouts': [{'place': 1, 'amount': 20}]},
                         format='json')
        self.client.delete(self._setup_url(self.r2))
        self.assertFalse(self._round_payload(self.r2)['has_day_bet'])

    def test_an_entry_of_zero_still_counts_as_set_up(self):
        """A bet worth nothing is still a bet — it draws a board and a tab.

        Deleting the config is the only honest "we are not playing one", which
        is why the flag asks whether the config exists rather than whether the
        fee is above zero.
        """
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '0.00', 'payouts': []}, format='json')
        self.assertTrue(self._round_payload(self.r2)['has_day_bet'])

    def test_an_earlier_round_is_never_a_day_bet_round(self):
        d = self._round_payload(self.r1)
        self.assertFalse(d['is_final_round'])
        self.assertFalse(d['has_day_bet'])
