"""The Skins score-entry card — on the wire.

The engine is covered in `scoring/tests/test_skins_hole_card.py`; these
cover the two ways the screen gets it: WITH the save, and by a GET.
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
            status='in_progress', active_games=['skins'],
            primary_game='skins', bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann Archer', 'Ben Bell', 'Cal Croft', 'Dee Dunn'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name.split()[0]] = p.id

        from services.skins import setup_skins
        setup_skins(self.fs, handicap_mode='gross', carryover=True,
                    payout_style='per_point', per_point_mode='all',
                    per_point_rate=5)

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
            reverse('api-skins-hole', args=[self.fs.id, hole]))


class SkinsHoleCardEndpointTests(_Base):

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 4, 'Ben': 5, 'Cal': 5, 'Dee': 5})
        card = r.data.get('skins_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        self.assertEqual(card['outcome'], 'outright')
        self.assertEqual(card['winner_id'], self.pid['Ann'])

    def test_the_card_follows_the_hole_being_posted(self):
        self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 5, 'Dee': 5})
        r = self._post_hole(2, {'Ann': 4, 'Ben': 5, 'Cal': 5, 'Dee': 5})
        card = r.data['skins_hole']
        self.assertEqual(card['hole'], 2)
        self.assertEqual(card['riding'], 2, 'the 1st carried in')

    def test_a_GET_answers_for_a_hole_opened_without_posting(self):
        r = self._card(3)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 3)
        self.assertEqual(r.data['outcome'], 'pending')

    def test_a_hole_with_nothing_entered_still_draws_the_keypad(self):
        """Gated on the GAME, not its status — `SkinsGame.status` is pending
        until a hole is scored, which is every hole before the first."""
        r = self._card(1)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data['players'])
        self.assertEqual(r.data['riding'], 1)

    def test_a_round_with_no_skins_game_gets_an_empty_card(self):
        self.fs.skins_game.delete()
        self.assertEqual(self._card(1).data, {})

    def test_a_stranger_gets_a_404(self):
        other = Account.objects.create(name='Someone Else')
        user  = User.objects.create_user(username='nope', account=other)
        c = APIClient()
        c.force_authenticate(user)
        r = c.get(reverse('api-skins-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)
