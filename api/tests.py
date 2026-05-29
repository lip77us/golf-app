"""
api/tests.py
------------
Tests for DeleteAccountView (DELETE /api/auth/delete-account/), the
in-app self-service account deletion required by App Store Guideline
5.1.1(v).

Behaviour under test (see CLAUDE.md "in-app account deletion"):
  * The caller's User + auth token are deleted.
  * A linked Player is UNLINKED and anonymized (PII scrubbed) but the row
    and its protected golf history survive.
  * A sole admin of an account that still has other members is blocked;
    a solo user can always delete.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Foursome, FoursomeMembership, Round


User = get_user_model()

DELETE_URL = '/api/auth/delete-account/'


def _make_account(name: str, *, admin_username: str) -> tuple:
    """Create an Account + an admin User inside it."""
    account = Account.objects.create(name=name)
    user = User.objects.create_user(
        username=admin_username, password='testpass', account=account,
    )
    user.is_account_admin = True
    user.save(update_fields=['is_account_admin'])
    return account, user


def _client(token: str) -> APIClient:
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION=f'Token {token}')
    return c


class DeleteAccountTests(TestCase):

    def test_unauthenticated_returns_401(self):
        r = APIClient().delete(DELETE_URL)
        self.assertEqual(r.status_code, 401)

    def test_solo_user_can_delete(self):
        """Sole member of an account: deletion succeeds, user + token gone."""
        acct, user = _make_account('Solo', admin_username='solo')
        token = Token.objects.create(user=user).key

        r = _client(token).delete(DELETE_URL)

        self.assertEqual(r.status_code, 204, r.content)
        self.assertFalse(User.objects.filter(pk=user.pk).exists())
        self.assertFalse(Token.objects.filter(key=token).exists())
        # Account (tenant) is intentionally left intact.
        self.assertTrue(Account.objects.filter(pk=acct.pk).exists())

    def test_user_without_player_can_delete(self):
        """A user with no linked Player deletes without error."""
        _, user = _make_account('NoPlayer', admin_username='noplayer')
        token = Token.objects.create(user=user).key

        r = _client(token).delete(DELETE_URL)

        self.assertEqual(r.status_code, 204, r.content)
        self.assertFalse(User.objects.filter(pk=user.pk).exists())

    def test_linked_player_is_anonymized_and_unlinked(self):
        """The linked Player survives but is scrubbed and detached."""
        acct, user = _make_account('Linked', admin_username='linked')
        player = Player.objects.create(
            account=acct, user=user, name='Paul Lipkin',
            short_name='PL', email='paul@example.com', phone='555-1234',
            handicap_index=Decimal('12.0'),
        )
        token = Token.objects.create(user=user).key

        r = _client(token).delete(DELETE_URL)
        self.assertEqual(r.status_code, 204, r.content)

        player.refresh_from_db()
        self.assertIsNone(player.user_id)
        self.assertEqual(player.name, 'Former Player')
        self.assertEqual(player.short_name, 'FP')
        self.assertEqual(player.email, '')
        self.assertEqual(player.phone, '')
        self.assertFalse(User.objects.filter(pk=user.pk).exists())

    def test_player_with_history_is_preserved(self):
        """A Player with protected scores keeps the row + the history."""
        acct, user = _make_account('WithHist', admin_username='withhist')
        player = Player.objects.create(
            account=acct, user=user, name='Has History',
            email='hh@example.com', handicap_index=Decimal('8.0'),
        )
        course = Course.objects.create(account=acct, name='Test Course')
        round_obj = Round.objects.create(
            account=acct, course=course, round_number=1,
        )
        fs = Foursome.objects.create(round=round_obj, group_number=1)
        membership = FoursomeMembership.objects.create(
            foursome=fs, player=player,
            course_handicap=8, playing_handicap=8,
        )
        token = Token.objects.create(user=user).key

        r = _client(token).delete(DELETE_URL)
        self.assertEqual(r.status_code, 204, r.content)

        # Player row and its membership history both survive, anonymized.
        self.assertTrue(Player.objects.filter(pk=player.pk).exists())
        self.assertTrue(
            FoursomeMembership.objects.filter(pk=membership.pk).exists(),
        )
        player.refresh_from_db()
        self.assertEqual(player.name, 'Former Player')
        self.assertEqual(player.email, '')

    def test_sole_admin_with_other_members_is_blocked(self):
        """Last admin of a populated account can't orphan the others."""
        acct, admin = _make_account('Shared', admin_username='admin')
        # A second, non-admin member in the same account.
        User.objects.create_user(
            username='member', password='memberpw', account=acct,
        )
        admin_player = Player.objects.create(
            account=acct, user=admin, name='Admin Person',
            email='admin@example.com', handicap_index=Decimal('5.0'),
        )
        token = Token.objects.create(user=admin).key

        r = _client(token).delete(DELETE_URL)

        self.assertEqual(r.status_code, 400)
        self.assertIn('admin', r.json().get('detail', '').lower())
        # Nothing was deleted or scrubbed.
        self.assertTrue(User.objects.filter(pk=admin.pk).exists())
        admin_player.refresh_from_db()
        self.assertEqual(admin_player.name, 'Admin Person')
        self.assertEqual(admin_player.email, 'admin@example.com')

    def test_sole_admin_with_another_admin_can_delete(self):
        """A second admin exists, so the first admin may delete."""
        acct, admin = _make_account('TwoAdmins', admin_username='admin1')
        admin2 = User.objects.create_user(
            username='admin2', password='admin2pw', account=acct,
        )
        admin2.is_account_admin = True
        admin2.save(update_fields=['is_account_admin'])
        token = Token.objects.create(user=admin).key

        r = _client(token).delete(DELETE_URL)

        self.assertEqual(r.status_code, 204, r.content)
        self.assertFalse(User.objects.filter(pk=admin.pk).exists())

    def test_non_admin_member_can_delete(self):
        """A plain member in a populated account can always self-delete."""
        acct, _admin = _make_account('HasMember', admin_username='admin')
        member = User.objects.create_user(
            username='member', password='memberpw', account=acct,
        )
        token = Token.objects.create(user=member).key

        r = _client(token).delete(DELETE_URL)

        self.assertEqual(r.status_code, 204, r.content)
        self.assertFalse(User.objects.filter(pk=member.pk).exists())


class PlayerCreateEditPermissionTests(TestCase):
    """
    Creating and editing players is admin-only (matching delete).
    Non-admin members get a read-only roster in the app and a 403 from
    the API if they try to mutate.
    """

    @classmethod
    def setUpTestData(cls):
        cls.acct, cls.admin = _make_account('Acct', admin_username='admin')
        cls.member = User.objects.create_user(
            username='member', password='memberpw', account=cls.acct,
        )
        cls.player = Player.objects.create(
            account=cls.acct, name='Existing Player',
            handicap_index=Decimal('10.0'),
        )
        cls.tok_admin  = Token.objects.create(user=cls.admin).key
        cls.tok_member = Token.objects.create(user=cls.member).key

    def test_admin_can_create_player(self):
        r = _client(self.tok_admin).post(
            '/api/players/',
            {'name': 'New Guy', 'handicap_index': '12.0'},
            format='json',
        )
        self.assertEqual(r.status_code, 201, r.content)

    def test_non_admin_cannot_create_player(self):
        r = _client(self.tok_member).post(
            '/api/players/',
            {'name': 'Sneaky', 'handicap_index': '12.0'},
            format='json',
        )
        self.assertEqual(r.status_code, 403)
        self.assertFalse(Player.objects.filter(name='Sneaky').exists())

    def test_admin_can_edit_player(self):
        r = _client(self.tok_admin).patch(
            f'/api/players/{self.player.id}/',
            {'name': 'Renamed'}, format='json',
        )
        self.assertEqual(r.status_code, 200, r.content)
        self.player.refresh_from_db()
        self.assertEqual(self.player.name, 'Renamed')

    def test_non_admin_cannot_edit_player(self):
        r = _client(self.tok_member).patch(
            f'/api/players/{self.player.id}/',
            {'name': 'Hacked'}, format='json',
        )
        self.assertEqual(r.status_code, 403)
        self.player.refresh_from_db()
        self.assertEqual(self.player.name, 'Existing Player')
