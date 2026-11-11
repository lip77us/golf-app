"""The Mini Singles score-entry card — on the wire.

The engine is covered in `scoring/tests/test_mini_singles_hole_card.py`;
these cover the two ways the screen gets it: WITH the save, and by a GET for
a hole opened without posting.
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
    names = ('Ann Archer', 'Ben Bell', 'Cal Croft', 'Dee Dunn')

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
            status='in_progress', active_games=['match_play'])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for i, name in enumerate(self.names):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal(i))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=i, playing_handicap=i)
            self.pid[name.split()[0]] = p.id
        if len(self.names) == 4:
            from services.tournament_match_play import (
                setup_tournament_match_play)
            setup_tournament_match_play(
                self.fs, entry_fee=10,
                payout_config={'1st': 24, '2nd': 10, '3rd': 6, '4th': 0},
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
            reverse('api-mini-singles-hole', args=[self.fs.id, hole]))


class MiniSinglesHoleCardEndpointTests(_Base):

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        # Seeds by handicap: Semi 1 is Ann v Dee, Semi 2 is Ben v Cal.
        r = self._post_hole(1, {'Ann': 3, 'Ben': 4, 'Cal': 5, 'Dee': 4})
        card = r.data.get('mini_singles_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        self.assertEqual([b['title'] for b in card['blocks']],
                         ['Semi 1', 'Semi 2'])
        self.assertEqual([b['margin'] for b in card['blocks']],
                         ['1 UP', '1 UP'])
        self.assertTrue(card['hole_complete'])

    def test_the_get_mirrors_it_for_a_hole_opened_without_posting(self):
        self._post_hole(1, {'Ann': 3, 'Ben': 4, 'Cal': 5, 'Dee': 4})
        r = self._card(1)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['blocks'][0]['names'], ['Ann', 'Dee'])
        self.assertEqual(r.data['trailing'], '$40 pot')

    def test_a_fresh_round_has_a_card_on_the_first_hole(self):
        """No card means no keypad."""
        r = self._card(1)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.data['players']), 4)
        self.assertFalse(r.data['hole_complete'])

    def test_another_account_cannot_read_it(self):
        other = Account.objects.create(name='Someone else')
        intruder = User.objects.create_user(username='nope', account=other)
        client = APIClient()
        client.force_authenticate(intruder)
        r = client.get(reverse('api-mini-singles-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)


class NoBracketTests(_Base):
    """A threesome plays a different game under the same slug."""
    names = ('Ann Archer', 'Ben Bell', 'Cal Croft')

    def test_a_group_with_no_bracket_sends_no_card(self):
        r = self._post_hole(1, {'Ann': 3, 'Ben': 4, 'Cal': 5})
        self.assertNotIn('mini_singles_hole', r.data)
        self.assertEqual(self._card(1).data, {})
