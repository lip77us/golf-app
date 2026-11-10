"""The Sequoya 3s score-entry card — on the wire.

The engine is covered in `scoring/tests/test_sequoya_hole_card.py`; these
cover the three ways the screen gets it: WITH the save, WITH the press (the
other thing that changes what a hole's tray reads), and by a GET for a hole
opened without posting either.
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


class SequoyaHoleCardEndpointTests(TestCase):

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
            status='in_progress', active_games=['sequoya_threes'],
            bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann Archer', 'Ben Bell', 'Cal Croft', 'Dee Dunn'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name.split()[0]] = p.id

        from services.sequoya_threes import setup_sequoya_threes
        setup_sequoya_threes(self.fs, [self.pid['Ann'], self.pid['Ben']],
                             handicap_mode='gross', bet_amount=5,
                             press_mode='manual_auto')

    def _post_hole(self, hole, ann, ben, cal, dee):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.pid[n], 'gross_score': g}
                        for n, g in (('Ann', ann), ('Ben', ben),
                                     ('Cal', cal), ('Dee', dee))]},
            format='json')
        assert r.status_code in (200, 201), r.content
        return r

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        card = self._post_hole(1, 4, 5, 5, 5).json()['sequoya_hole']
        self.assertEqual(card['hole'], 1)
        self.assertEqual(card['result']['text'], 'Won hole 1')
        self.assertEqual(card['standing']['text'], 'Ann + Ben 1 UP')

    def test_a_round_without_the_game_sends_no_card(self):
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        self.assertNotIn('sequoya_hole',
                         self._post_hole(1, 4, 5, 5, 5).json())

    def test_a_hole_can_be_fetched_without_posting(self):
        r = self.client.get(
            reverse('api-sequoya-threes-hole', args=[self.fs.id, 4]))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['match']['index'], 2)
        self.assertEqual(r.json()['scored'], 0)

    def test_the_press_returns_the_card_beside_the_summary(self):
        self._post_hole(1, 5, 5, 5, 5)             # halved: no auto press
        self._post_hole(2, 5, 5, 4, 5)             # Cal + Dee 1 up
        offered = self.client.get(reverse(
            'api-sequoya-threes-hole', args=[self.fs.id, 2])).json()['press']
        self.assertEqual(offered['side'], 1)

        r = self.client.post(
            reverse('api-sequoya-threes-press', args=[self.fs.id]),
            {'match_index': 1, 'side': offered['side'], 'current_hole': 2},
            format='json')
        self.assertEqual(r.status_code, 201, r.content)
        body = r.json()
        self.assertIn('matches', body)                 # still the summary
        card = body['sequoya_hole']
        self.assertIsNone(card['press'])
        self.assertEqual(card['bets'][-1]['text'],
                         'Press · Ann + Ben starts 3')

    def test_another_accounts_group_is_not_readable(self):
        other = Account.objects.create(name='Elsewhere')
        stranger = User.objects.create_user(username='x', account=other)
        c = APIClient()
        c.force_authenticate(stranger)
        r = c.get(reverse('api-sequoya-threes-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)
