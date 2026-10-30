"""The Rabbit score-entry card — on the wire.

The engine is covered in `scoring/tests/test_rabbit.py`; these cover the two
ways the screen gets it: WITH the save, and by a GET for a hole opened without
posting.
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
    games = ['rabbit']

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
            status='in_progress', active_games=self.games,
            bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann', 'Ben', 'Cal'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name] = p.id

        from services.rabbit import setup_rabbit
        setup_rabbit(self.fs, accumulate=True, num_segments=3,
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
            reverse('api-rabbit-hole', args=[self.fs.id, hole]))


class RabbitHoleCardTests(_Base):
    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 3, 'Ben': 5, 'Cal': 5})
        card = r.data.get('rabbit_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        self.assertEqual(card['result']['event'], 'grab')
        self.assertEqual(card['result']['winner_short'], 'A')

    def test_the_card_follows_the_hole_being_posted(self):
        self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4})
        r = self._post_hole(7, {'Ann': 3, 'Ben': 5, 'Cal': 5})
        card = r.data['rabbit_hole']
        self.assertEqual(card['hole'], 7)
        self.assertEqual(card['rabbit']['index'], 2)

    def test_the_get_serves_a_hole_nobody_has_posted(self):
        r = self._card(10)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 10)
        self.assertEqual(r.data['rabbit']['index'], 2)
        self.assertIsNone(r.data['result'])
        self.assertEqual(len(r.data['players']), 3)

    def test_the_card_carries_what_is_riding(self):
        self.assertEqual(float(self._card(1).data['rabbit']['stake']), 5.0)

    def test_a_round_without_rabbit_gets_no_card_on_the_save(self):
        self.round.active_games = []
        self.round.save(update_fields=['active_games'])
        r = self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4})
        self.assertNotIn('rabbit_hole', r.data)

    def test_another_account_cannot_read_the_card(self):
        other = Account.objects.create(name='Someone else')
        user  = User.objects.create_user(username='nobody', account=other)
        c = APIClient()
        c.force_authenticate(user)
        self.assertEqual(
            c.get(reverse('api-rabbit-hole', args=[self.fs.id, 1])).status_code,
            404)
