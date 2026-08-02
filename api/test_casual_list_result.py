"""
api/test_casual_list_result.py
------------------------------
The rounds-list card shows a result: on COMPLETED rounds the caller's gross
total and their net settlement across every nettable game; on in-progress
rounds neither (the card shows the stake instead).  This covers the payload
fields the redesigned card reads (my_player_id / my_gross / my_net /
primary_game).
"""

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


class CasualListResultTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='My Group')
        self.user = User.objects.create_user(username='me', account=self.account)
        self.me = Player.objects.create(
            account=self.account, name='Paul Lipkin',
            handicap_index=Decimal('8.0'), user=self.user)
        self.pal = Player.objects.create(
            account=self.account, name='Steve Etingoff',
            handicap_index=Decimal('12.0'))
        self.course = Course.objects.create(account=self.account, name='Tilden Park')
        self.tee = make_tee(self.course)

        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-casual-rounds')

    def _round(self, status, primary='skins'):
        rnd = Round.objects.create(
            account=self.account, course=self.course, status=status,
            active_games=['skins'], primary_game=primary,
            bet_unit=Decimal('2.00'),
        )
        fs = Foursome.objects.create(round=rnd, group_number=1)
        for p in (self.me, self.pal):
            FoursomeMembership.objects.create(
                foursome=fs, player=p, tee=self.tee,
                course_handicap=int(p.handicap_index),
                playing_handicap=int(p.handicap_index))
        setup_skins(fs, handicap_mode='gross')
        return rnd, fs

    def test_completed_round_carries_gross_and_net(self):
        rnd, fs = self._round('complete')
        # I shoot 4s (gross 72); my pal shoots 5s (gross 90). Gross skins → I win.
        submit_round(fs, {h: [(self.me, 4), (self.pal, 5)] for h in range(1, 19)})
        calculate_skins(fs)   # populate winners (the score-submit view's job)

        data = self.client.get(self.url, {'status': 'complete'}).data
        self.assertEqual(len(data), 1)
        item = data[0]
        self.assertEqual(item['primary_game'], 'skins')
        self.assertEqual(item['my_player_id'], self.me.id)
        self.assertEqual(item['my_gross'], 72)
        # A settleable game is configured, so a net is reported (I won skins → +).
        self.assertIsNotNone(item['my_net'])
        self.assertGreater(item['my_net'], 0)

    def test_in_progress_round_omits_result(self):
        rnd, fs = self._round('in_progress')
        submit_round(fs, {h: [(self.me, 4), (self.pal, 5)] for h in range(1, 6)})

        data = self.client.get(self.url, {'status': 'in_progress'}).data
        self.assertEqual(len(data), 1)
        item = data[0]
        # No mid-round settlement / partial gross — the card shows the stake.
        self.assertIsNone(item['my_gross'])
        self.assertIsNone(item['my_net'])
        self.assertEqual(item['my_player_id'], self.me.id)

    def test_round_with_no_nettable_game_has_null_net(self):
        # A Nassau round isn't in the settlement engine → my_net stays null even
        # when completed (the card simply shows no money).
        rnd = Round.objects.create(
            account=self.account, course=self.course, status='complete',
            active_games=['nassau'], primary_game='nassau',
        )
        fs = Foursome.objects.create(round=rnd, group_number=1)
        for p in (self.me, self.pal):
            FoursomeMembership.objects.create(
                foursome=fs, player=p, tee=self.tee,
                course_handicap=int(p.handicap_index),
                playing_handicap=int(p.handicap_index))
        submit_round(fs, {h: [(self.me, 4), (self.pal, 5)] for h in range(1, 19)})

        item = self.client.get(self.url, {'status': 'complete'}).data[0]
        self.assertEqual(item['my_gross'], 72)
        self.assertIsNone(item['my_net'])
