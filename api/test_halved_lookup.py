"""
api/test_halved_lookup.py
-------------------------
Look up a registered Halved member by phone number so you can add them to a
round even if they're not in your roster yet. You must know the number (no
browsable directory) and we never leak contact info.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Player


User = get_user_model()


class HalvedLookupTests(TestCase):
    def setUp(self):
        self.acct_b = Account.objects.create(name='Sam Account')
        self.sam = User.objects.create_user(username='sam', account=self.acct_b)
        self.sam.phone = '+13105550199'
        self.sam.save(update_fields=['phone'])
        Player.objects.create(
            account=self.acct_b, name='Sam Eyeballs', short_name='SE',
            phone='+13105550199', handicap_index=Decimal('8.0'), sex='M',
            user=self.sam)

        self.acct_a = Account.objects.create(name='Caller')
        self.caller = User.objects.create_user(username='cal', account=self.acct_a)
        self.c = APIClient(); self.c.force_authenticate(self.caller)

    def test_found_returns_profile_without_contact_info(self):
        r = self.c.get(reverse('api-halved-user-lookup'),
                       {'phone': '(310) 555-0199'})
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data['found'])
        self.assertEqual(r.data['name'], 'Sam Eyeballs')
        self.assertEqual(r.data['short_name'], 'SE')
        self.assertEqual(r.data['handicap_index'], '8.0')
        self.assertEqual(r.data['sex'], 'M')
        # Privacy: never echo contact details back.
        self.assertNotIn('phone', r.data)
        self.assertNotIn('email', r.data)

    def test_unknown_number(self):
        r = self.c.get(reverse('api-halved-user-lookup'),
                       {'phone': '+19998887777'})
        self.assertFalse(r.data['found'])

    def test_blank_number(self):
        r = self.c.get(reverse('api-halved-user-lookup'))
        self.assertFalse(r.data['found'])
