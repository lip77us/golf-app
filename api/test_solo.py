"""The solo endpoints.

One golfer against par. The engine is covered in scoring/tests/test_solo.py;
these cover the wire: that the setup round-trips, that the board is readable,
and that nothing about money or a handicap mode can be posted — because a
solo game that grew a stake would be a different product.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from games.models import SoloGame
from tournament.models import Foursome, FoursomeMembership, Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name="Paul's Golf")
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('72.0'),
                                      par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, round_number=1,
            status='in_progress', active_games=['solo_stroke'])
        fs = Foursome.objects.create(round=self.round, group_number=1)
        p = Player.objects.create(account=self.acct, name='Paul',
                                  handicap_index=Decimal('12'))
        FoursomeMembership.objects.create(foursome=fs, player=p, tee=self.tee,
                                          course_handicap=12,
                                          playing_handicap=12)

    def _setup_url(self):
        return reverse('api-solo-setup', args=[self.round.id])

    def _result_url(self):
        return reverse('api-solo-result', args=[self.round.id])


class SetupTests(_Base):
    def test_defaults_before_anything_is_configured(self):
        d = self.client.get(self._setup_url()).data
        self.assertFalse(d['configured'])
        self.assertEqual(d['variant'], 'stroke')
        self.assertEqual(d['net_percent'], 100)

    def test_it_names_the_golfer_for_the_setup_screen(self):
        """So the screen can write "12 strokes" without a second request."""
        d = self.client.get(self._setup_url()).data
        self.assertEqual(d['player_name'], 'Paul')
        self.assertEqual(d['course_handicap'], 12)
        self.assertEqual(d['tee_name'], 'White')

    def test_configure_round_trips(self):
        r = self.client.post(self._setup_url(),
                             {'variant': 'nassau', 'net_percent': 90},
                             format='json')
        self.assertEqual(r.status_code, 201, r.content)
        d = self.client.get(self._setup_url()).data
        self.assertTrue(d['configured'])
        self.assertEqual(d['variant'], 'nassau')
        self.assertEqual(d['net_percent'], 90)

    def test_an_allowance_above_100_is_accepted(self):
        """Deliberate, and unique in the app. Nobody is paying."""
        r = self.client.post(self._setup_url(),
                             {'variant': 'stroke', 'net_percent': 130},
                             format='json')
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(SoloGame.objects.get().net_percent, 130)

    def test_an_absurd_allowance_is_refused(self):
        for pct in (0, 10, 40, 140, 200):
            r = self.client.post(self._setup_url(),
                                 {'variant': 'stroke', 'net_percent': pct},
                                 format='json')
            self.assertEqual(r.status_code, 400, f'{pct} should be refused')

    def test_there_is_no_handicap_mode_to_set(self):
        """Always net. Posting one is ignored rather than honoured — a gross
        solo game against par is stroke play with extra words."""
        self.client.post(self._setup_url(),
                         {'variant': 'stroke', 'net_percent': 100,
                          'handicap_mode': 'gross'}, format='json')
        cfg = SoloGame.objects.get()
        self.assertFalse(hasattr(cfg, 'handicap_mode'))

    def test_there_is_nothing_to_stake(self):
        self.client.post(self._setup_url(),
                         {'variant': 'stroke', 'net_percent': 100,
                          'entry_fee': 20}, format='json')
        cfg = SoloGame.objects.get()
        for field in ('entry_fee', 'payouts', 'bet_unit'):
            self.assertFalse(hasattr(cfg, field),
                             msg=f'a solo game has no {field}')


class ResultTests(_Base):
    def test_unconfigured_says_so(self):
        d = self.client.get(self._result_url()).data
        self.assertFalse(d['configured'])

    def test_the_board_carries_the_holes_and_the_reading(self):
        self.client.post(self._setup_url(),
                         {'variant': 'match', 'net_percent': 100},
                         format='json')
        d = self.client.get(self._result_url()).data
        self.assertTrue(d['configured'])
        self.assertEqual(len(d['holes']), 18)
        self.assertIn('match', d)
        self.assertNotIn('nassau', d)

    def test_a_stranger_cannot_read_it(self):
        self.client.post(self._setup_url(),
                         {'variant': 'stroke', 'net_percent': 100},
                         format='json')
        other = Account.objects.create(name='Someone Else')
        nosy = User.objects.create_user(username='nosy', account=other)
        c = APIClient()
        c.force_authenticate(nosy)
        self.assertEqual(c.get(self._result_url()).status_code, 404)
