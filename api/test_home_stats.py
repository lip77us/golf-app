"""api/test_home_stats.py — the home screen's last-five-rounds card."""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership
from services.skins import setup_skins, calculate_skins
from scoring.tests._helpers import make_tee, submit_round

User = get_user_model()


class HomeStatsTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='G')
        self.user = User.objects.create_user(username='me', account=self.account)
        self.me = Player.objects.create(account=self.account, name='Me Me',
                                        handicap_index=Decimal('0.0'), user=self.user)
        self.pal = Player.objects.create(account=self.account, name='Pal Pal',
                                         handicap_index=Decimal('0.0'))
        self.course = Course.objects.create(account=self.account, name='Tilden')
        self.tee = make_tee(self.course)
        self.c = APIClient()
        self.c.force_authenticate(self.user)
        self.url = reverse('api-home-stats')

    def _round(self, mine, theirs, bet='2.00', games=('skins',)):
        rnd = Round.objects.create(account=self.account, course=self.course,
                                   status='complete', active_games=list(games),
                                   primary_game=games[0], bet_unit=Decimal(bet))
        fs = Foursome.objects.create(round=rnd, group_number=1)
        for p in (self.me, self.pal):
            FoursomeMembership.objects.create(foursome=fs, player=p, tee=self.tee,
                                              course_handicap=0, playing_handicap=0)
        setup_skins(fs, handicap_mode='gross')
        submit_round(fs, {h: [(self.me, mine), (self.pal, theirs)] for h in range(1, 19)})
        calculate_skins(fs)
        return rnd

    def test_fewer_than_two_rounds_is_not_enough(self):
        self._round(4, 5)
        self.assertFalse(self.c.get(self.url).data['enough'])

    def test_five_rounds(self):
        for mine in (4, 5, 4, 5, 4):
            self._round(mine, 5 if mine == 4 else 4)
        d = self.c.get(self.url).data
        self.assertTrue(d['enough'])
        self.assertEqual(d['count'], 5)
        self.assertEqual(len(d['rounds']), 5)
        self.assertEqual(sum(1 for r in d['rounds'] if r['best']), 1)
        self.assertEqual(d['won'], 3)
        self.assertIsNotNone(d['money'])

    def test_money_hidden_without_a_stake(self):
        for _ in range(2):
            self._round(4, 5, bet='0')
        self.assertIsNone(self.c.get(self.url).data['money'])
