"""The Points 5-3-1 score-entry card — on the wire.

The engine is covered in `scoring/tests/test_points_531_hole_card.py`; these
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
            status='in_progress', active_games=['points_531'],
            bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name, ch in (('Ann', 0), ('Ben', 0), ('Cal', 0)):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal(str(ch)))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=ch, playing_handicap=ch)
            self.pid[name] = p.id

        from services.points_531 import setup_points_531
        setup_points_531(self.fs, handicap_mode='gross')

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
            reverse('api-points-531-hole', args=[self.fs.id, hole]))


class PointsHoleCardEndpointTests(_Base):

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 3, 'Ben': 4, 'Cal': 5})
        card = r.data.get('points_531_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        self.assertEqual([row['points'] for row in card['points_rows']],
                         [5.0, 3.0, 1.0])

    def test_the_card_follows_the_hole_being_posted(self):
        self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4})
        r = self._post_hole(7, {'Ann': 3, 'Ben': 4, 'Cal': 5})
        self.assertEqual(r.data['points_531_hole']['hole'], 7)

    def test_the_get_mirrors_it_for_a_hole_opened_without_posting(self):
        self._post_hole(3, {'Ann': 3, 'Ben': 4, 'Cal': 5})
        r = self._card(3)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 3)
        self.assertEqual([row['points'] for row in r.data['points_rows']],
                         [5.0, 3.0, 1.0])

    def test_a_fresh_round_has_a_card_on_the_first_hole(self):
        """No card means no keypad.  The game's status is still `pending`
        here, which is what used to make this come back empty."""
        r = self._card(1)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data)
        self.assertEqual(len(r.data['players']), 3)
        self.assertFalse(r.data['hole_complete'])

    def test_the_standing_balances_on_the_wire(self):
        self._post_hole(1, {'Ann': 3, 'Ben': 4, 'Cal': 5})
        card = self._card(1).data
        self.assertEqual(
            round(sum(s['money'] for s in card['standing']), 2), 0)

    def test_another_account_cannot_read_it(self):
        other = Account.objects.create(name='Someone else')
        intruder = User.objects.create_user(username='nope', account=other)
        client = APIClient()
        client.force_authenticate(intruder)
        r = client.get(reverse('api-points-531-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)
