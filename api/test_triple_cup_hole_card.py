"""The Triple Cup score-entry card — on the wire.

The engine is covered in `scoring/tests/test_triple_cup_hole_card.py`; these
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
            status='in_progress', active_games=['triple_cup'],
            bet_unit=Decimal('25.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann Archer', 'Ben Bell', 'Cal Croft', 'Dee Dunn'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name.split()[0]] = p.id

        from services.triple_cup import setup_triple_cup
        setup_triple_cup(self.fs,
                         team1_ids=[self.pid['Ann'], self.pid['Ben']],
                         team2_ids=[self.pid['Cal'], self.pid['Dee']],
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
            reverse('api-triple-cup-hole', args=[self.fs.id, hole]))


class TripleCupHoleCardEndpointTests(_Base):

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        card = r.data.get('triple_cup_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        line = card['lines'][0]
        self.assertEqual(line['winner'], 1)
        self.assertEqual(line['margin'], '1 UP')
        self.assertEqual(line['reason'],
                         {'label': 'net', 'team1': 3, 'team2': 4})

    def test_the_card_follows_the_hole_being_posted(self):
        self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4, 'Dee': 4})
        r = self._post_hole(2, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        self.assertEqual(r.data['triple_cup_hole']['hole'], 2)

    def test_one_ball_a_side_completes_on_two_scores(self):
        """In the Foursomes one partner posts the side's ball."""
        r = self._post_hole(7, {'Ann': 4, 'Cal': 5})
        card = r.data['triple_cup_hole']
        self.assertEqual(card['kind'], 'one ball a side')
        self.assertTrue(card['hole_complete'])
        self.assertEqual(card['lines'][0]['winner'], 1)

    def test_the_get_mirrors_it_for_a_hole_opened_without_posting(self):
        self._post_hole(1, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        r = self._card(1)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 1)
        self.assertEqual(r.data['lines'][0]['names'],
                         ['Ann + Ben', 'Cal + Dee'])

    def test_a_fresh_round_has_a_card_on_the_first_hole(self):
        """No card means no keypad."""
        r = self._card(1)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data)
        self.assertEqual(len(r.data['players']), 4)
        self.assertFalse(r.data['hole_complete'])

    def test_another_account_cannot_read_it(self):
        other = Account.objects.create(name='Someone else')
        intruder = User.objects.create_user(username='nope', account=other)
        client = APIClient()
        client.force_authenticate(intruder)
        r = client.get(reverse('api-triple-cup-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)

    def test_a_round_without_the_game_sends_no_card(self):
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        r = self._post_hole(1, {'Ann': 3, 'Ben': 5, 'Cal': 4, 'Dee': 5})
        self.assertNotIn('triple_cup_hole', r.data)
