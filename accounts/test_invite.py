"""
accounts/test_invite.py
-----------------------
Tests for the personal invite link (Friends Phase 1): the per-user invite code,
the GET /api/invite/ endpoint, and the public /i/<code>/ landing page.
"""

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework.authtoken.models import Token

from accounts.models import Account


User = get_user_model()


class InviteCodeTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Invite Co')
        self.user = User.objects.create_user(username='paul', account=self.account)

    def test_code_minted_once_and_stable(self):
        first = self.user.ensure_invite_code()
        self.assertTrue(first)
        self.assertEqual(len(first), 8)
        # Stable across calls and reloads.
        self.assertEqual(self.user.ensure_invite_code(), first)
        self.user.refresh_from_db()
        self.assertEqual(self.user.invite_code, first)

    def test_invite_endpoint_returns_link_and_text(self):
        client = APIClient()
        token, _ = Token.objects.get_or_create(user=self.user)
        client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')
        resp = client.get(reverse('api-invite'))
        self.assertEqual(resp.status_code, 200)
        code = resp.data['code']
        self.assertTrue(code)
        self.assertIn(f'/i/{code}/', resp.data['url'])
        self.assertIn(resp.data['url'], resp.data['share_text'])

    def test_invite_endpoint_requires_auth(self):
        resp = APIClient().get(reverse('api-invite'))
        self.assertIn(resp.status_code, (401, 403))

    def test_landing_page_renders_for_real_code(self):
        code = self.user.ensure_invite_code()
        resp = self.client.get(f'/i/{code}/')
        self.assertEqual(resp.status_code, 200)
        self.assertIn(b'Halved', resp.content)

    def test_landing_page_404_for_bogus_code(self):
        resp = self.client.get('/i/NOPECODE/')
        self.assertEqual(resp.status_code, 404)
