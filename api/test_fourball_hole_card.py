"""The Fourball score-entry card — on the wire.

The engine is covered in `scoring/tests/test_fourball_hole_card.py`; these
cover the two ways the screen gets it: WITH the save, and by a GET for a hole
opened without posting.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
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
            status='in_progress', active_games=['fourball'],
            bet_unit=Decimal('20.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann Archer', 'Ben Bell', 'Cal Croft', 'Dee Dunn'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name.split()[0]] = p.id

        from services.fourball import setup_fourball
        setup_fourball(self.fs,
                       [self.pid['Ann'], self.pid['Ben']],
                       [self.pid['Cal'], self.pid['Dee']],
                       handicap_mode='gross')

    def _post_hole(self, hole, gross):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.pid[n], 'gross_score': g}
                        for n, g in gross.items()]},
            format='json')
        assert r.status_code in (200, 201), r.content
        return r

    def _card(self, hole):
        return self.client.get(
            reverse('api-fourball-hole', args=[self.fs.id, hole]))


class FourballHoleCardEndpointTests(_Base):

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        card = r.data.get('fourball_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        self.assertEqual([s['best'] for s in card['sides']], [3, 4])
        self.assertEqual(card['match']['figure'], '1 UP')

    def test_the_card_follows_the_hole_being_posted(self):
        self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4, 'Dee': 4})
        r = self._post_hole(7, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        self.assertEqual(r.data['fourball_hole']['hole'], 7)

    def test_the_get_mirrors_it_for_a_hole_opened_without_posting(self):
        self._post_hole(3, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        r = self._card(3)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 3)
        counted = [p['first'] for p in r.data['players'] if p['counted']
                   and p['side'] == 1]
        self.assertEqual(counted, ['Ann'])

    def test_a_fresh_round_has_a_card_on_the_first_hole(self):
        """No card means no keypad.  The game's status is still `pending`
        here, which is what used to make this come back empty."""
        r = self._card(1)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data)
        self.assertEqual(len(r.data['players']), 4)
        self.assertFalse(r.data['hole_complete'])
        self.assertEqual([s['label'] for s in r.data['sides']],
                         ['Ann + Ben', 'Cal + Dee'])

    def test_the_money_balances_on_the_wire(self):
        self._post_hole(1, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        card = self._card(1).data
        self.assertEqual([m['amount'] for m in card['money']], [20.0, -20.0])

    def test_another_account_cannot_read_it(self):
        other = Account.objects.create(name='Someone else')
        intruder = User.objects.create_user(username='nope', account=other)
        client = APIClient()
        client.force_authenticate(intruder)
        r = client.get(reverse('api-fourball-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)
