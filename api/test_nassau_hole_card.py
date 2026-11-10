"""The Nassau score-entry card — on the wire.

The engine is covered in `scoring/tests/test_nassau_hole_card.py`; these
cover the three ways the screen gets it: WITH the save, WITH a manual press
(which changes the bet lines it is showing), and by a GET.
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
            status='in_progress', active_games=['nassau'],
            bet_unit=Decimal('10.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann Archer', 'Ben Bell', 'Cal Croft', 'Dee Dunn'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name.split()[0]] = p.id

        from services.nassau import setup_nassau
        setup_nassau(self.fs,
                     [self.pid['Ann'], self.pid['Ben']],
                     [self.pid['Cal'], self.pid['Dee']],
                     handicap_mode='gross', press_mode='manual')

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
            reverse('api-nassau-hole', args=[self.fs.id, hole]))


class NassauHoleCardEndpointTests(_Base):

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 5, 'Dee': 5})
        card = r.data.get('nassau_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        self.assertEqual(card['winner'], 'team1')
        front = next(l for l in card['lines'] if l['key'] == 'front')
        self.assertEqual([c['text'] for c in front['chips']], ['Front 1 UP'])

    def test_the_card_follows_the_hole_being_posted(self):
        self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4, 'Dee': 4})
        r = self._post_hole(2, {'Ann': 4, 'Ben': 4, 'Cal': 5, 'Dee': 5})
        self.assertEqual(r.data['nassau_hole']['hole'], 2)

    def test_a_press_returns_the_card_too(self):
        """Calling one changes the bet lines the tray is showing, and the
        button has to vanish from the frame it was tapped in."""
        self._post_hole(1, {'Ann': 5, 'Ben': 5, 'Cal': 4, 'Dee': 4})
        self.assertTrue(self._card(1).data['can_press'])

        r = self.client.post(
            reverse('api-nassau-press', args=[self.fs.id]),
            {'start_hole': 2}, format='json')
        self.assertEqual(r.status_code, 200, r.content)
        card = r.data.get('nassau_hole')
        self.assertIsNotNone(card)
        front = next(l for l in card['lines'] if l['key'] == 'front')
        self.assertIn('P1 manual starts 2',
                      [c['text'] for c in front['chips']])
        # The summary is still there — the card is additive.
        self.assertIn('presses', r.data)

    def test_the_get_mirrors_it_for_a_hole_opened_without_posting(self):
        self._post_hole(3, {'Ann': 4, 'Ben': 4, 'Cal': 5, 'Dee': 5})
        r = self._card(3)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 3)
        self.assertEqual([s['label'] for s in r.data['sides']],
                         ['Ann + Ben', 'Cal + Dee'])

    def test_a_fresh_round_has_a_card_on_the_first_hole(self):
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
        r = client.get(reverse('api-nassau-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)


class NassauNineOnTheWireTests(TestCase):
    """Nassau Nine rides the Nassau card's key, endpoint and press.

    It had none of them: the save's tray gate, the press and the screen all
    asked for `nassau` by name, so a Nassau Nine round got the old inline
    picker and no tray at all.
    """

    def setUp(self):
        self.acct = Account.objects.create(name="Paul's Golf")
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        course = Course.objects.create(account=self.acct, name='Tilden')
        tee = Tee.objects.create(course=course, tee_name='White', slope=113,
                                 course_rating=Decimal('72.0'), par=72,
                                 holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, round_number=1,
            status='in_progress', active_games=['nassau_nine'],
            primary_game='nassau_nine', num_holes=9,
            bet_unit=Decimal('10.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann Archer', 'Ben Bell', 'Cal Croft', 'Dee Dunn'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name.split()[0]] = p.id
        from services.nassau import setup_nassau
        setup_nassau(self.fs, [self.pid['Ann'], self.pid['Ben']],
                     [self.pid['Cal'], self.pid['Dee']],
                     handicap_mode='gross', press_mode='manual',
                     single_match=True)

    def _post_hole(self, hole, *gross):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.pid[n], 'gross_score': g}
                        for n, g in zip(('Ann', 'Ben', 'Cal', 'Dee'), gross)]},
            format='json')
        assert r.status_code in (200, 201), r.content
        return r.json()

    def test_the_save_returns_the_card(self):
        card = self._post_hole(1, 4, 5, 5, 5)['nassau_hole']
        self.assertEqual(card['kind'], 'nassau_nine')
        self.assertEqual([l['key'] for l in card['lines']], ['match'])
        self.assertEqual(card['lines'][0]['chips'][0]['text'], 'Match 1 UP')

    def test_the_get_serves_it_too(self):
        r = self.client.get(reverse('api-nassau-hole', args=[self.fs.id, 3]))
        self.assertEqual(r.json()['title'], 'Nassau Nine')

    def test_a_press_returns_the_card_for_the_hole_it_was_called_from(self):
        self._post_hole(1, 5, 5, 4, 5)                 # Cal + Dee 1 up
        r = self.client.post(
            reverse('api-nassau-press', args=[self.fs.id]),
            {'start_hole': 2}, format='json')
        self.assertIn(r.status_code, (200, 201), r.content)
        card = r.json()['nassau_hole']
        self.assertEqual(card['hole'], 1)
        self.assertEqual([c['text'] for c in card['lines'][0]['chips']],
                         ['Match 1 UP', 'P1 manual starts 2'])
        self.assertFalse(card['can_press'])
