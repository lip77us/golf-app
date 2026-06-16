"""
api/test_players_on_app.py
--------------------------
Tests the `is_on_app` flag on GET /api/players/ — a golfer is "on the app" when
a registered user's verified phone matches the golfer's (normalized) phone.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Player


User = get_user_model()


class PlayersOnAppTests(TestCase):
    def setUp(self):
        # The viewing account + its admin.
        self.account = Account.objects.create(name='My Group')
        self.me = User.objects.create_user(username='me', account=self.account)
        self.client = APIClient()
        self.client.force_authenticate(self.me)

        # A registered user in ANOTHER account with a verified phone.
        other = Account.objects.create(name='Other')
        u = User.objects.create_user(username='bob', account=other)
        u.phone = '+13105550101'
        u.save(update_fields=['phone'])

        # Golfers in my roster:
        self.signed_up = Player.objects.create(
            account=self.account, name='Bob', phone='(310) 555-0101',  # formatted
            handicap_index=Decimal('9.0'),
        )
        self.not_signed = Player.objects.create(
            account=self.account, name='Carl', phone='415-555-7777',
            handicap_index=Decimal('12.0'),
        )
        self.no_phone = Player.objects.create(
            account=self.account, name='Dave', handicap_index=Decimal('5.0'),
        )

    def _by_name(self):
        resp = self.client.get(reverse('api-players'))
        self.assertEqual(resp.status_code, 200)
        return {p['name']: p for p in resp.data}

    def test_on_app_flag(self):
        byname = self._by_name()
        # Formatted golfer phone matches the E.164 registered user.
        self.assertTrue(byname['Bob']['is_on_app'])
        # Unmatched phone and no-phone golfers are not on the app.
        self.assertFalse(byname['Carl']['is_on_app'])
        self.assertFalse(byname['Dave']['is_on_app'])

    def test_create_response_flags_on_app_immediately(self):
        # Regression: a golfer added via "Add Halved golfer" (POST /players/)
        # must come back is_on_app=True in the create response, not only after
        # the next My Golfers reload.
        self.me.is_account_admin = True
        self.me.save(update_fields=['is_account_admin'])
        resp = self.client.post(reverse('api-players'), {
            'name': 'Erin', 'handicap_index': '7.0',
            'phone': '(310) 555-0101', 'sex': 'M',
        }, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertTrue(resp.data['is_on_app'])
