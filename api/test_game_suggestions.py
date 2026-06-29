"""
api/test_game_suggestions.py
----------------------------
POST /api/game-suggestions/ — a user's "suggest a new game" note, stored for
review (server-side email forwarding is deferred).
"""

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework.authtoken.models import Token

from accounts.models import Account
from core.models import GameSuggestion, Player


User = get_user_model()


class GameSuggestionTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Suggest Co')
        self.user = User.objects.create_user(username='paul', account=self.account)
        self.user.email = 'paul@example.com'
        self.user.save(update_fields=['email'])
        # Linked player → submitter_name is denormalized from it.
        self.player = Player.objects.create(
            account=self.account, name='Paul Lipkin', user=self.user,
            handicap_index=10.0)
        self.client = APIClient()
        token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def test_submit_stores_with_submitter_metadata(self):
        resp = self.client.post(reverse('api-game-suggestions'), {
            'game_name':    'Wolf Hammer',
            'num_players':  '4',
            'num_rounds':   '1',
            'hole_scoring': 'Wolf picks a partner; low ball wins the hole.',
            'betting':      'Points per hole, doubled on a lone wolf.',
            'notes':        'Like Wolf but with a hammer.',
        }, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        obj = GameSuggestion.objects.get()
        self.assertEqual(obj.game_name, 'Wolf Hammer')
        self.assertEqual(obj.submitted_by, self.user)
        self.assertEqual(obj.account, self.account)
        # Submitter name + contact email are filled server-side, not trusted.
        self.assertEqual(obj.submitter_name, 'Paul Lipkin')
        self.assertEqual(obj.contact_email, 'paul@example.com')
        self.assertFalse(obj.handled)

    def test_explicit_contact_email_overrides_user_email(self):
        resp = self.client.post(reverse('api-game-suggestions'), {
            'notes':         'A quick idea.',
            'contact_email': 'other@example.com',
        }, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(GameSuggestion.objects.get().contact_email,
                         'other@example.com')

    def test_empty_suggestion_rejected(self):
        resp = self.client.post(reverse('api-game-suggestions'), {
            'num_players': '4',   # structured-only, nothing descriptive
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(GameSuggestion.objects.count(), 0)

    def test_requires_auth(self):
        resp = APIClient().post(reverse('api-game-suggestions'),
                                {'notes': 'hi'}, format='json')
        self.assertIn(resp.status_code, (401, 403))


class GameSuggestionNotifyTests(TestCase):
    """The post_save trigger POSTs to a webhook when configured, and is a no-op
    (log only) when not — never breaking the insert either way."""

    def test_webhook_fired_when_configured(self):
        from unittest.mock import patch
        with self.settings(GAME_SUGGESTION_WEBHOOK_URL='https://hook.example/x'):
            with patch('core.signals.urllib.request.urlopen') as urlopen:
                GameSuggestion.objects.create(game_name='Skins+', notes='x')
        self.assertTrue(urlopen.called)

    def test_no_webhook_when_unset(self):
        from unittest.mock import patch
        with self.settings(GAME_SUGGESTION_WEBHOOK_URL=''):
            with patch('core.signals.urllib.request.urlopen') as urlopen:
                GameSuggestion.objects.create(game_name='Skins+', notes='x')
        self.assertFalse(urlopen.called)

    def test_webhook_failure_does_not_break_insert(self):
        from unittest.mock import patch
        with self.settings(GAME_SUGGESTION_WEBHOOK_URL='https://hook.example/x'):
            with patch('core.signals.urllib.request.urlopen',
                       side_effect=OSError('boom')):
                obj = GameSuggestion.objects.create(game_name='Skins+', notes='x')
        self.assertIsNotNone(obj.pk)

    def test_email_sent_when_notify_address_set(self):
        from django.core import mail
        with self.settings(GAME_SUGGESTION_NOTIFY_EMAIL='info@halved.golf'):
            GameSuggestion.objects.create(
                game_name='Skins+', notes='x', contact_email='fan@example.com')
        self.assertEqual(len(mail.outbox), 1)
        msg = mail.outbox[0]
        self.assertEqual(msg.to, ['info@halved.golf'])
        self.assertIn('Skins+', msg.subject)
        # Reply goes to the submitter.
        self.assertEqual(msg.reply_to, ['fan@example.com'])

    def test_no_email_when_notify_address_unset(self):
        from django.core import mail
        with self.settings(GAME_SUGGESTION_NOTIFY_EMAIL=''):
            GameSuggestion.objects.create(game_name='Skins+', notes='x')
        self.assertEqual(len(mail.outbox), 0)
