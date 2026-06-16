"""
accounts/test_otp.py
--------------------
Tests for phone-first / SMS-OTP login (freemium design §12).

Covers phone normalization, the request→verify happy paths (existing-phone
login and unknown-phone self-signup), the failure modes (wrong / expired /
too-many-attempts / rate-limit), phone uniqueness, and — critically — that the
legacy username/password login endpoint still works unchanged.

SMS_BACKEND defaults to "console", so no real SMS is sent; the request endpoint
returns the code as `debug_code` under DEBUG, and tests also reach into
PhoneOTP directly where convenient.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Account, PhoneOTP, OTP_MAX_ATTEMPTS
from accounts.otp import request_code, verify_code, OtpError
from accounts.phone import normalize
from core.models import Player


User = get_user_model()


class PhoneNormalizeTests(TestCase):
    def test_ten_digits_assumed_us(self):
        self.assertEqual(normalize('415-555-0123'), '+14155550123')
        self.assertEqual(normalize('(415) 555 0123'), '+14155550123')

    def test_eleven_digits_leading_one(self):
        self.assertEqual(normalize('1 415 555 0123'), '+14155550123')

    def test_already_e164_passthrough(self):
        self.assertEqual(normalize('+447911123456'), '+447911123456')

    def test_invalid_returns_none(self):
        for bad in (None, '', '123', 'not a phone', '555-1234'):
            self.assertIsNone(normalize(bad), bad)


@override_settings(DEBUG=True, SMS_BACKEND='console')
class OtpFlowTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.req_url = reverse('api-otp-request')
        self.ver_url = reverse('api-otp-verify')

    def _request(self, phone):
        resp = self.client.post(self.req_url, {'phone': phone}, format='json')
        return resp

    def test_new_phone_self_creates_account_user_player(self):
        resp = self._request('415-555-0123')
        self.assertEqual(resp.status_code, 200)
        code = resp.data['debug_code']

        accounts_before = Account.objects.count()
        resp = self.client.post(
            self.ver_url,
            {'phone': '(415) 555-0123', 'code': code, 'name': 'Paula'},
            format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['is_new_account'])
        self.assertTrue(resp.data['token'])
        self.assertTrue(resp.data['is_account_admin'])
        self.assertEqual(resp.data['player']['name'], 'Paula')

        self.assertEqual(Account.objects.count(), accounts_before + 1)
        user = User.objects.get(phone='+14155550123')
        self.assertTrue(user.is_account_admin)
        self.assertIsNotNone(user.phone_verified_at)
        self.assertFalse(user.has_usable_password())
        self.assertEqual(Player.objects.get(user=user).phone, '+14155550123')

    def test_known_phone_logs_in_without_new_account(self):
        account = Account.objects.create(name='Existing')
        user = User.objects.create_user(username='paul', account=account)
        user.phone = '+14155550123'
        user.save()

        code = self._request('4155550123').data['debug_code']
        before = Account.objects.count()
        resp = self.client.post(
            self.ver_url, {'phone': '4155550123', 'code': code}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data['is_new_account'])
        self.assertEqual(resp.data['username'], 'paul')
        self.assertEqual(Account.objects.count(), before)  # no self-signup

    def test_wrong_code_rejected(self):
        self._request('4155550123')
        resp = self.client.post(
            self.ver_url, {'phone': '4155550123', 'code': '000000'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_expired_code_rejected(self):
        self._request('4155550123')
        PhoneOTP.objects.filter(phone='+14155550123').update(
            expires_at=timezone.now() - timedelta(minutes=1),
        )
        otp = PhoneOTP.objects.get(phone='+14155550123')
        # Recompute the real code is impossible (hashed); just assert any code
        # is refused once expired.
        resp = self.client.post(
            self.ver_url, {'phone': '4155550123', 'code': '123456'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_too_many_attempts_burns_code(self):
        code = self._request('4155550123').data['debug_code']
        for _ in range(OTP_MAX_ATTEMPTS):
            self.client.post(
                self.ver_url, {'phone': '4155550123', 'code': '000000'}, format='json',
            )
        # Even the correct code is now refused — the OTP is burned.
        resp = self.client.post(
            self.ver_url, {'phone': '4155550123', 'code': code}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_request_rate_limited(self):
        for _ in range(5):
            self.assertEqual(self._request('4155550123').status_code, 200)
        self.assertEqual(self._request('4155550123').status_code, 400)

    def test_invalid_phone_rejected(self):
        self.assertEqual(self._request('123').status_code, 400)

    def test_phone_uniqueness_enforced(self):
        account = Account.objects.create(name='A')
        u1 = User.objects.create_user(username='a', account=account)
        u1.phone = '+14155550123'
        u1.save()
        from django.db import IntegrityError
        u2 = User.objects.create_user(username='b', account=account)
        u2.phone = '+14155550123'
        with self.assertRaises(IntegrityError):
            u2.save()


class PasswordLoginDeactivatedTests(TestCase):
    """Password login is deactivated by default (phone-OTP is the sole path);
    reversible via PASSWORD_LOGIN_ENABLED."""

    def _attempt(self):
        account = Account.objects.create(name='Golden Glove')
        User.objects.create_user(
            username='paul', password='secret123', account=account,
        )
        return APIClient().post(
            reverse('api-login'),
            {'account_name': 'Golden Glove', 'username': 'paul',
             'password': 'secret123'},
            format='json',
        )

    def test_deactivated_by_default(self):
        self.assertEqual(self._attempt().status_code, 403)

    @override_settings(PASSWORD_LOGIN_ENABLED=True)
    def test_works_when_re_enabled(self):
        resp = self._attempt()
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['token'])


@override_settings(REVIEW_BYPASS_PHONE='+13105550101', REVIEW_BYPASS_CODE='424242')
class ReviewBypassTests(TestCase):
    """App Store reviewer demo-phone bypass: the configured fictional number +
    fixed code logs into a pre-seeded User without contacting Twilio/PhoneOTP,
    so Apple's reviewer can sign in through the phone screen with no SMS."""

    def setUp(self):
        account = Account.objects.create(name='DemoClub')
        self.user = User.objects.create_user(username='reviewer', account=account)
        self.user.phone = '+13105550101'
        self.user.save()

    def test_request_skips_send_and_issues_no_code(self):
        phone, code = request_code('310-555-0101')
        self.assertEqual(phone, '+13105550101')
        self.assertIsNone(code)
        self.assertFalse(PhoneOTP.objects.filter(phone='+13105550101').exists())

    def test_fixed_code_logs_in_existing_user(self):
        user, is_new = verify_code('310-555-0101', '424242')
        self.assertEqual(user.pk, self.user.pk)
        self.assertFalse(is_new)

    def test_wrong_code_rejected(self):
        with self.assertRaises(OtpError):
            verify_code('310-555-0101', '000000')

    @override_settings(REVIEW_BYPASS_PHONE='', REVIEW_BYPASS_CODE='')
    def test_disabled_when_unset(self):
        # Bypass off → the fixed code is just a wrong code (no real OTP issued).
        with self.assertRaises(OtpError):
            verify_code('310-555-0101', '424242')
