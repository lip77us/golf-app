"""
accounts/tests.py
-----------------
Isolation tests for the multi-tenant Account / User schema and the
AccountScopedManager helper.

These tests are the canary for cross-account data leakage: if two
accounts ever see each other's rows, one of these will fail.  Keep
them passing as new tenant-scoped models are added — for every new
model with an `account` FK, add a section here that creates rows in
two accounts and asserts `.for_account(A)` returns only A's rows.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Tournament


User = get_user_model()


def _make_account(name: str, *, admin_username: str = None) -> tuple:
    """Helper: create an Account + an admin user inside it."""
    account = Account.objects.create(name=name)
    user = User.objects.create_user(
        username=(admin_username or f'{name.lower()}_admin'),
        password='testpass',
        account=account,
    )
    user.is_account_admin = True
    user.save(update_fields=['is_account_admin'])
    return account, user


class AccountIsolationTests(TestCase):
    """
    Two independent Accounts, A and B.  Every row created in this
    suite has its tenant tagged so any cross-account leak shows up as
    a test failure rather than a runtime data exposure.
    """

    @classmethod
    def setUpTestData(cls):
        cls.acct_a, cls.user_a = _make_account('Account A',
                                               admin_username='alice')
        cls.acct_b, cls.user_b = _make_account('Account B',
                                               admin_username='bob')

        # One Player per account.
        cls.player_a = Player.objects.create(
            account=cls.acct_a, name='Alice Player',
            handicap_index=Decimal('10.0'),
        )
        cls.player_b = Player.objects.create(
            account=cls.acct_b, name='Bob Player',
            handicap_index=Decimal('20.0'),
        )

        # One Course per account.
        cls.course_a = Course.objects.create(account=cls.acct_a,
                                             name='Course A')
        cls.course_b = Course.objects.create(account=cls.acct_b,
                                             name='Course B')

        # One Tournament + one tournament Round per account.
        cls.tourn_a = Tournament.objects.create(
            account=cls.acct_a, name='Tournament A',
            start_date='2026-01-01',
        )
        cls.tourn_b = Tournament.objects.create(
            account=cls.acct_b, name='Tournament B',
            start_date='2026-01-01',
        )
        cls.round_a = Round.objects.create(
            account=cls.acct_a, tournament=cls.tourn_a,
            course=cls.course_a, round_number=1,
        )
        cls.round_b = Round.objects.create(
            account=cls.acct_b, tournament=cls.tourn_b,
            course=cls.course_b, round_number=1,
        )

    # ── Account-scoped managers ──────────────────────────────────────────────

    def test_player_for_account_isolation(self):
        a = Player.objects.for_account(self.acct_a)
        b = Player.objects.for_account(self.acct_b)
        self.assertEqual(list(a), [self.player_a])
        self.assertEqual(list(b), [self.player_b])

    def test_course_for_account_isolation(self):
        self.assertEqual(
            list(Course.objects.for_account(self.acct_a)),
            [self.course_a],
        )
        self.assertEqual(
            list(Course.objects.for_account(self.acct_b)),
            [self.course_b],
        )

    def test_tournament_for_account_isolation(self):
        self.assertEqual(
            list(Tournament.objects.for_account(self.acct_a)),
            [self.tourn_a],
        )
        self.assertEqual(
            list(Tournament.objects.for_account(self.acct_b)),
            [self.tourn_b],
        )

    def test_round_for_account_isolation(self):
        self.assertEqual(
            list(Round.objects.for_account(self.acct_a)),
            [self.round_a],
        )
        self.assertEqual(
            list(Round.objects.for_account(self.acct_b)),
            [self.round_b],
        )

    def test_for_account_rejects_none(self):
        with self.assertRaises(ValueError):
            list(Player.objects.for_account(None))

    # ── Manager defensiveness ────────────────────────────────────────────────

    def test_create_user_requires_account(self):
        with self.assertRaises(ValueError):
            User.objects.create_user(username='lonely', password='x')

    # NOTE: We don't yet test that the same username can exist in two
    # accounts.  AbstractUser still ships with username=unique globally,
    # and the (account, username) UniqueConstraint is layered on top.
    # Phase 3 (3-field login) will override the username field to drop
    # the global uniqueness — at that point add a
    # `test_same_username_different_accounts_is_allowed` here.
