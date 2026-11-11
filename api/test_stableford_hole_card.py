"""The Stableford score-entry card — on the wire."""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from games.models import StablefordGame
from tournament.models import Foursome, FoursomeMembership, Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class StablefordHoleCardEndpointTests(TestCase):

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
            status='in_progress', active_games=['stableford'],
            primary_game='stableford')
        StablefordGame.objects.create(round=self.round, handicap_mode='gross')
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann Archer', 'Ben Bell'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name.split()[0]] = p.id

    def _post_hole(self, hole, gross):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.pid[n], 'gross_score': g}
                        for n, g in gross.items()]},
            format='json')
        assert r.status_code in (200, 201), r.content
        return r

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 3, 'Ben': 5})
        card = r.data.get('stableford_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertTrue(card['points'])
        self.assertEqual([p['points_text'] for p in card['players']],
                         ['3 pts', '1 pt'])
        self.assertEqual(card['standing'][0]['total_text'], '3')

    def test_the_get_mirrors_it(self):
        self._post_hole(1, {'Ann': 3, 'Ben': 5})
        r = self.client.get(
            reverse('api-stableford-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['label'], 'Stableford')

    def test_a_fresh_round_has_a_card_on_the_first_hole(self):
        r = self.client.get(
            reverse('api-stableford-hole', args=[self.fs.id, 1]))
        self.assertEqual(len(r.data['players']), 2)

    def test_another_account_cannot_read_it(self):
        other = Account.objects.create(name='Someone else')
        intruder = User.objects.create_user(username='nope', account=other)
        client = APIClient()
        client.force_authenticate(intruder)
        r = client.get(reverse('api-stableford-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)

    def test_a_round_without_the_game_sends_no_card(self):
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        r = self._post_hole(1, {'Ann': 3, 'Ben': 5})
        self.assertNotIn('stableford_hole', r.data)
