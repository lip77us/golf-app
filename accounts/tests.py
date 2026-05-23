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

    def test_same_username_different_accounts_is_allowed(self):
        """Two accounts may both contain a user named 'paul'."""
        u1 = User.objects.create_user(
            username='paul', password='x', account=self.acct_a,
        )
        u2 = User.objects.create_user(
            username='paul', password='x', account=self.acct_b,
        )
        self.assertNotEqual(u1.pk, u2.pk)
        self.assertNotEqual(u1.account_id, u2.account_id)

    def test_duplicate_username_within_account_rejected(self):
        from django.db import IntegrityError, transaction
        User.objects.create_user(username='dup', password='x',
                                 account=self.acct_a)
        with self.assertRaises(IntegrityError), transaction.atomic():
            User.objects.create_user(username='dup', password='y',
                                     account=self.acct_a)

    def test_username_case_insensitive_within_account(self):
        from django.db import IntegrityError, transaction
        User.objects.create_user(username='Paul', password='x',
                                 account=self.acct_a)
        with self.assertRaises(IntegrityError), transaction.atomic():
            User.objects.create_user(username='PAUL', password='y',
                                     account=self.acct_a)


# ─────────────────────────────────────────────────────────────────────────────
# HTTP-level API isolation
# ─────────────────────────────────────────────────────────────────────────────

from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient


class APIIsolationTests(TestCase):
    """
    Drive the real API as user A and confirm that endpoints can't
    see / read / update user B's rows.  Catches any view we forgot
    to scope: this is the canary suite for the phase 2b view sweep.
    """

    @classmethod
    def setUpTestData(cls):
        cls.acct_a, cls.user_a = _make_account('Account A',
                                               admin_username='alice')
        cls.acct_b, cls.user_b = _make_account('Account B',
                                               admin_username='bob')

        # Token auth for each.
        cls.token_a = Token.objects.create(user=cls.user_a).key
        cls.token_b = Token.objects.create(user=cls.user_b).key

        # One Player + Course + Tournament + Round per account, with
        # data that's identifiable so we can spot a leak in the JSON.
        cls.player_a = Player.objects.create(
            account=cls.acct_a, name='Alice Player',
            handicap_index=Decimal('10.0'),
        )
        cls.player_b = Player.objects.create(
            account=cls.acct_b, name='Bob Player',
            handicap_index=Decimal('20.0'),
        )
        cls.course_a = Course.objects.create(account=cls.acct_a,
                                             name='Course A-only')
        cls.course_b = Course.objects.create(account=cls.acct_b,
                                             name='Course B-only')
        cls.tourn_a = Tournament.objects.create(
            account=cls.acct_a, name='Tournament A-only',
            start_date='2026-01-01',
        )
        cls.tourn_b = Tournament.objects.create(
            account=cls.acct_b, name='Tournament B-only',
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

    def _client_as(self, token: str) -> APIClient:
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        return client

    # ── List endpoints only return the caller's rows ─────────────────────────

    def test_players_list_isolated(self):
        c = self._client_as(self.token_a)
        resp = c.get('/api/players/')
        self.assertEqual(resp.status_code, 200)
        names = [p['name'] for p in resp.json()]
        self.assertIn('Alice Player', names)
        self.assertNotIn('Bob Player', names)

    def test_courses_list_isolated(self):
        c = self._client_as(self.token_a)
        resp = c.get('/api/courses/')
        self.assertEqual(resp.status_code, 200)
        names = [c['name'] for c in resp.json()]
        self.assertIn('Course A-only', names)
        self.assertNotIn('Course B-only', names)

    def test_tournaments_list_isolated(self):
        c = self._client_as(self.token_a)
        resp = c.get('/api/tournaments/')
        self.assertEqual(resp.status_code, 200)
        names = [t['name'] for t in resp.json()]
        self.assertIn('Tournament A-only', names)
        self.assertNotIn('Tournament B-only', names)

    # ── Detail endpoints reject foreign-account PKs with 404 ────────────────

    def test_player_detail_foreign_pk_returns_404(self):
        c = self._client_as(self.token_a)
        resp = c.get(f'/api/players/{self.player_b.id}/')
        self.assertEqual(resp.status_code, 404)

    def test_tournament_detail_foreign_pk_returns_404(self):
        c = self._client_as(self.token_a)
        resp = c.get(f'/api/tournaments/{self.tourn_b.id}/')
        self.assertEqual(resp.status_code, 404)

    def test_round_detail_foreign_pk_returns_404(self):
        c = self._client_as(self.token_a)
        resp = c.get(f'/api/rounds/{self.round_b.id}/')
        self.assertEqual(resp.status_code, 404)

    # ── Own-account access still works ──────────────────────────────────────

    def test_player_detail_own_pk_returns_200(self):
        c = self._client_as(self.token_a)
        resp = c.get(f'/api/players/{self.player_a.id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()['name'], 'Alice Player')

    def test_round_detail_own_pk_returns_200(self):
        c = self._client_as(self.token_a)
        resp = c.get(f'/api/rounds/{self.round_a.id}/')
        self.assertEqual(resp.status_code, 200)


class LoginEndpointTests(TestCase):
    """
    /api/auth/login/ accepts (account_name, username, password) and
    returns a token only when all three match the same user row.
    """

    @classmethod
    def setUpTestData(cls):
        cls.acct_a, _ = _make_account('Golden Glove')
        cls.acct_b, _ = _make_account('Saturday Group')

        cls.paul_a = User.objects.create_user(
            username='paul', password='aaaa1111', account=cls.acct_a,
        )
        cls.paul_b = User.objects.create_user(
            username='paul', password='bbbb2222', account=cls.acct_b,
        )

    def _login(self, **body):
        client = APIClient()
        return client.post('/api/auth/login/', body, format='json')

    def test_login_resolves_to_correct_account(self):
        # Both Pauls share a username; only the account_name + password
        # combo picks one row.
        r = self._login(account_name='Golden Glove',
                        username='paul', password='aaaa1111')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()['account']['name'], 'Golden Glove')

        r = self._login(account_name='Saturday Group',
                        username='paul', password='bbbb2222')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()['account']['name'], 'Saturday Group')

    def test_login_account_name_is_case_insensitive(self):
        r = self._login(account_name='golden glove',
                        username='paul', password='aaaa1111')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()['account']['name'], 'Golden Glove')

    def test_login_username_is_case_insensitive(self):
        r = self._login(account_name='Golden Glove',
                        username='Paul', password='aaaa1111')
        self.assertEqual(r.status_code, 200, r.content)

    def test_login_wrong_password_for_correct_account(self):
        r = self._login(account_name='Golden Glove',
                        username='paul', password='bbbb2222')
        self.assertEqual(r.status_code, 401)

    def test_login_cross_account_password_rejected(self):
        # paul/bbbb2222 lives in Saturday Group, not Golden Glove.
        r = self._login(account_name='Golden Glove',
                        username='paul', password='bbbb2222')
        self.assertEqual(r.status_code, 401)

    def test_login_unknown_account_returns_401(self):
        r = self._login(account_name='No Such Group',
                        username='paul', password='aaaa1111')
        self.assertEqual(r.status_code, 401)

    def test_login_missing_account_name_400(self):
        r = self._login(username='paul', password='aaaa1111')
        self.assertEqual(r.status_code, 400)

    def test_login_response_includes_account_and_admin_flag(self):
        r = self._login(account_name='Golden Glove',
                        username='paul', password='aaaa1111')
        body = r.json()
        self.assertIn('token', body)
        self.assertEqual(body['account']['name'], 'Golden Glove')
        self.assertEqual(body['is_account_admin'], False)


# ─────────────────────────────────────────────────────────────────────────────
# Member management — /api/account/members/
# ─────────────────────────────────────────────────────────────────────────────


class MemberManagementTests(TestCase):
    """
    Admin can list / create / update / delete members of their own
    account, and only their own.  Non-admins can list / read self.
    """

    @classmethod
    def setUpTestData(cls):
        cls.acct_a, cls.admin_a = _make_account('Acct A',
                                                admin_username='alice')
        cls.acct_b, cls.admin_b = _make_account('Acct B',
                                                admin_username='bob')

        # Regular (non-admin) member in Acct A.
        cls.member_a = User.objects.create_user(
            username='charlie', password='charliepw', account=cls.acct_a,
        )

        cls.tok_admin_a  = Token.objects.create(user=cls.admin_a).key
        cls.tok_member_a = Token.objects.create(user=cls.member_a).key
        cls.tok_admin_b  = Token.objects.create(user=cls.admin_b).key

    def _client(self, token: str) -> APIClient:
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        return c

    # ── List ────────────────────────────────────────────────────────────────

    def test_list_returns_only_own_account_members(self):
        c = self._client(self.tok_admin_a)
        r = c.get('/api/account/members/')
        self.assertEqual(r.status_code, 200)
        usernames = {m['username'] for m in r.json()}
        self.assertEqual(usernames, {'alice', 'charlie'})

    def test_list_open_to_non_admin_members(self):
        c = self._client(self.tok_member_a)
        r = c.get('/api/account/members/')
        self.assertEqual(r.status_code, 200)

    # ── Create ──────────────────────────────────────────────────────────────

    def test_admin_creates_new_member(self):
        c = self._client(self.tok_admin_a)
        r = c.post('/api/account/members/', {
            'username': 'dave',
            'password': 'davepass1',
            'email':    'dave@example.com',
        }, format='json')
        self.assertEqual(r.status_code, 201, r.content)
        # The new member is in Acct A.
        new = User.objects.get(username='dave')
        self.assertEqual(new.account_id, self.acct_a.id)
        self.assertFalse(new.is_account_admin)

    def test_non_admin_cannot_create_member(self):
        c = self._client(self.tok_member_a)
        r = c.post('/api/account/members/', {
            'username': 'ghost',
            'password': 'ghostpass1',
        }, format='json')
        self.assertEqual(r.status_code, 403)

    def test_create_duplicate_username_in_same_account_rejected(self):
        c = self._client(self.tok_admin_a)
        r = c.post('/api/account/members/', {
            'username': 'charlie',  # already exists in Acct A
            'password': 'newpass12',
        }, format='json')
        self.assertEqual(r.status_code, 400)

    def test_create_same_username_other_account_ok(self):
        # Acct B admin can add a "charlie" — that name only exists in A.
        c = self._client(self.tok_admin_b)
        r = c.post('/api/account/members/', {
            'username': 'charlie',
            'password': 'b_charlie1',
        }, format='json')
        self.assertEqual(r.status_code, 201, r.content)

    def test_create_short_password_rejected(self):
        c = self._client(self.tok_admin_a)
        r = c.post('/api/account/members/', {
            'username': 'eve',
            'password': 'short',
        }, format='json')
        self.assertEqual(r.status_code, 400)

    # ── Update ──────────────────────────────────────────────────────────────

    def test_admin_can_promote_member_to_admin(self):
        c = self._client(self.tok_admin_a)
        r = c.patch(f'/api/account/members/{self.member_a.id}/', {
            'is_account_admin': True,
        }, format='json')
        self.assertEqual(r.status_code, 200, r.content)
        self.member_a.refresh_from_db()
        self.assertTrue(self.member_a.is_account_admin)

    def test_admin_cannot_demote_self_when_sole_admin(self):
        # alice is the only admin in Acct A.
        c = self._client(self.tok_admin_a)
        r = c.patch(f'/api/account/members/{self.admin_a.id}/', {
            'is_account_admin': False,
        }, format='json')
        self.assertEqual(r.status_code, 400)
        self.admin_a.refresh_from_db()
        self.assertTrue(self.admin_a.is_account_admin)

    def test_admin_can_demote_self_when_other_admin_exists(self):
        # Promote charlie first, then alice can step down.
        c = self._client(self.tok_admin_a)
        c.patch(f'/api/account/members/{self.member_a.id}/', {
            'is_account_admin': True,
        }, format='json')
        r = c.patch(f'/api/account/members/{self.admin_a.id}/', {
            'is_account_admin': False,
        }, format='json')
        self.assertEqual(r.status_code, 200, r.content)

    def test_password_reset_via_patch(self):
        c = self._client(self.tok_admin_a)
        r = c.patch(f'/api/account/members/{self.member_a.id}/', {
            'password': 'reset12345',
        }, format='json')
        self.assertEqual(r.status_code, 200, r.content)
        self.member_a.refresh_from_db()
        self.assertTrue(self.member_a.check_password('reset12345'))

    # ── Cross-account ──────────────────────────────────────────────────────

    def test_admin_cannot_see_other_account_member(self):
        c = self._client(self.tok_admin_a)
        r = c.get(f'/api/account/members/{self.admin_b.id}/')
        self.assertEqual(r.status_code, 404)

    def test_admin_cannot_patch_other_account_member(self):
        c = self._client(self.tok_admin_a)
        r = c.patch(f'/api/account/members/{self.admin_b.id}/', {
            'is_account_admin': False,
        }, format='json')
        self.assertEqual(r.status_code, 404)

    def test_admin_cannot_delete_other_account_member(self):
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/account/members/{self.admin_b.id}/')
        self.assertEqual(r.status_code, 404)

    # ── Delete ──────────────────────────────────────────────────────────────

    def test_admin_can_delete_non_admin_member(self):
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/account/members/{self.member_a.id}/')
        self.assertEqual(r.status_code, 204)
        self.assertFalse(
            User.objects.filter(pk=self.member_a.pk).exists(),
        )

    def test_admin_cannot_delete_self(self):
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/account/members/{self.admin_a.id}/')
        self.assertEqual(r.status_code, 400)
        self.assertTrue(
            User.objects.filter(pk=self.admin_a.pk).exists(),
        )

    def test_non_admin_member_self_read_allowed(self):
        c = self._client(self.tok_member_a)
        r = c.get(f'/api/account/members/{self.member_a.id}/')
        self.assertEqual(r.status_code, 200)

    def test_non_admin_member_other_read_forbidden(self):
        c = self._client(self.tok_member_a)
        r = c.get(f'/api/account/members/{self.admin_a.id}/')
        self.assertEqual(r.status_code, 403)


# ─────────────────────────────────────────────────────────────────────────────
# Player ↔ Member linking via PATCH /api/players/{id}/
# ─────────────────────────────────────────────────────────────────────────────


class PlayerLinkingTests(TestCase):
    """
    Admins can link a Player row to one of their account's members via
    PATCH user_id, and unlink with user_id: null.  Cross-account user
    ids are rejected.  Re-linking moves the user atomically — the old
    Player gets its `user` cleared without raising an IntegrityError.
    """

    @classmethod
    def setUpTestData(cls):
        cls.acct_a, cls.admin_a = _make_account('Acct A',
                                                admin_username='alice')
        cls.acct_b, cls.admin_b = _make_account('Acct B',
                                                admin_username='bob')

        # Two members + two empty Player rows in Acct A.
        cls.member_x = User.objects.create_user(
            username='xavier', password='xavierpw', account=cls.acct_a,
        )
        cls.member_y = User.objects.create_user(
            username='yannick', password='yannickpw', account=cls.acct_a,
        )
        cls.player_p = Player.objects.create(
            account=cls.acct_a, name='Player P',
            handicap_index=Decimal('10.0'),
        )
        cls.player_q = Player.objects.create(
            account=cls.acct_a, name='Player Q',
            handicap_index=Decimal('15.0'),
        )

        cls.tok_admin_a = Token.objects.create(user=cls.admin_a).key

    def _client(self):
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION=f'Token {self.tok_admin_a}')
        return c

    def test_link_user_to_player(self):
        c = self._client()
        r = c.patch(
            f'/api/players/{self.player_p.id}/',
            {'user_id': self.member_x.id},
            format='json',
        )
        self.assertEqual(r.status_code, 200, r.content)
        self.player_p.refresh_from_db()
        self.assertEqual(self.player_p.user_id, self.member_x.id)

    def test_unlink_user_from_player(self):
        self.player_p.user = self.member_x
        self.player_p.save(update_fields=['user'])
        c = self._client()
        r = c.patch(
            f'/api/players/{self.player_p.id}/',
            {'user_id': None},
            format='json',
        )
        self.assertEqual(r.status_code, 200, r.content)
        self.player_p.refresh_from_db()
        self.assertIsNone(self.player_p.user_id)

    def test_zero_user_id_unlinks(self):
        # Mobile dropdowns sometimes coerce "no selection" to 0;
        # serializer treats it as unlink.
        self.player_p.user = self.member_x
        self.player_p.save(update_fields=['user'])
        c = self._client()
        r = c.patch(
            f'/api/players/{self.player_p.id}/',
            {'user_id': 0},
            format='json',
        )
        self.assertEqual(r.status_code, 200, r.content)
        self.player_p.refresh_from_db()
        self.assertIsNone(self.player_p.user_id)

    def test_relinking_moves_member_off_previous_player(self):
        # member_x starts linked to player_p; link them to player_q
        # in one PATCH and confirm player_p drops the link cleanly.
        self.player_p.user = self.member_x
        self.player_p.save(update_fields=['user'])
        c = self._client()
        r = c.patch(
            f'/api/players/{self.player_q.id}/',
            {'user_id': self.member_x.id},
            format='json',
        )
        self.assertEqual(r.status_code, 200, r.content)
        self.player_p.refresh_from_db()
        self.player_q.refresh_from_db()
        self.assertIsNone(self.player_p.user_id)
        self.assertEqual(self.player_q.user_id, self.member_x.id)

    def test_cross_account_user_id_rejected(self):
        c = self._client()
        r = c.patch(
            f'/api/players/{self.player_p.id}/',
            {'user_id': self.admin_b.id},   # Acct B
            format='json',
        )
        self.assertEqual(r.status_code, 400)
        self.player_p.refresh_from_db()
        self.assertIsNone(self.player_p.user_id)

    def test_create_player_with_existing_user_id(self):
        c = self._client()
        r = c.post('/api/players/', {
            'name':           'New Player',
            'handicap_index': '12.3',
            'user_id':        self.member_y.id,
        }, format='json')
        self.assertEqual(r.status_code, 201, r.content)
        created = Player.objects.get(name='New Player')
        self.assertEqual(created.user_id, self.member_y.id)

    def test_create_player_rejects_both_user_id_and_credentials(self):
        c = self._client()
        r = c.post('/api/players/', {
            'name':           'Conflict',
            'handicap_index': '5.0',
            'user_id':        self.member_y.id,
            'username':       'fresh',
            'password':       'freshpass1',
        }, format='json')
        self.assertEqual(r.status_code, 400)


# ─────────────────────────────────────────────────────────────────────────────
# DELETE /api/players/{id}/
# ─────────────────────────────────────────────────────────────────────────────


class PlayerDeleteTests(TestCase):
    """
    Admins can delete a Player row from their own account.  Players
    who have played in any rounds are PROTECT-blocked and return a
    400.  Non-admins can't delete.  Cross-account 404s.
    """

    @classmethod
    def setUpTestData(cls):
        cls.acct_a, cls.admin_a = _make_account('Acct A',
                                                admin_username='alice')
        cls.acct_b, cls.admin_b = _make_account('Acct B',
                                                admin_username='bob')

        # Plain member in Acct A (non-admin).
        cls.member_a = User.objects.create_user(
            username='m_a', password='memberapw', account=cls.acct_a,
        )

        cls.player_a = Player.objects.create(
            account=cls.acct_a, name='Spare Player A',
            handicap_index=Decimal('10.0'),
        )
        cls.player_b = Player.objects.create(
            account=cls.acct_b, name='Spare Player B',
            handicap_index=Decimal('11.0'),
        )

        cls.tok_admin_a  = Token.objects.create(user=cls.admin_a).key
        cls.tok_member_a = Token.objects.create(user=cls.member_a).key

    def _client(self, token):
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        return c

    def test_admin_can_delete_unused_player(self):
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/players/{self.player_a.id}/')
        self.assertEqual(r.status_code, 204, r.content)
        self.assertFalse(
            Player.objects.filter(pk=self.player_a.pk).exists(),
        )

    def test_non_admin_cannot_delete(self):
        c = self._client(self.tok_member_a)
        r = c.delete(f'/api/players/{self.player_a.id}/')
        self.assertEqual(r.status_code, 403)

    def test_cross_account_delete_returns_404(self):
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/players/{self.player_b.id}/')
        self.assertEqual(r.status_code, 404)

    def test_protected_player_returns_400(self):
        # Wire the player up to a foursome so the FK PROTECT fires.
        from core.models import Course
        course = Course.objects.create(account=self.acct_a,
                                       name='Test Course')
        round_obj = Round.objects.create(
            account=self.acct_a, course=course, round_number=1,
        )
        from tournament.models import Foursome, FoursomeMembership
        fs = Foursome.objects.create(round=round_obj, group_number=1)
        FoursomeMembership.objects.create(
            foursome=fs, player=self.player_a,
            course_handicap=10, playing_handicap=10,
        )

        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/players/{self.player_a.id}/')
        self.assertEqual(r.status_code, 400)
        self.assertIn('rounds', r.json().get('detail', '').lower())
        # Player still exists.
        self.assertTrue(
            Player.objects.filter(pk=self.player_a.pk).exists(),
        )


# ─────────────────────────────────────────────────────────────────────────────
# DELETE /api/courses/{id}/  and  /api/tees/{id}/
# ─────────────────────────────────────────────────────────────────────────────


class CourseAndTeeDeleteTests(TestCase):
    """
    Admins delete courses (CASCADE drops their tees) and individual
    tee sets within their own account.  Cross-account → 404.
    Non-admins → 403.  Courses / tees used in any round → 400 PROTECT.
    """

    @classmethod
    def setUpTestData(cls):
        from core.models import Course, Tee

        cls.acct_a, cls.admin_a = _make_account('Acct A',
                                                admin_username='alice')
        cls.acct_b, cls.admin_b = _make_account('Acct B',
                                                admin_username='bob')

        cls.member_a = User.objects.create_user(
            username='m_a', password='memberapw', account=cls.acct_a,
        )

        cls.course_a = Course.objects.create(account=cls.acct_a,
                                             name='Acct A Course')
        cls.course_b = Course.objects.create(account=cls.acct_b,
                                             name='Acct B Course')
        cls.tee_a = Tee.objects.create(
            course=cls.course_a, tee_name='White',
            slope=120, course_rating=Decimal('70.0'),
            par=72,
            holes=[
                {'number': i, 'par': 4, 'stroke_index': i, 'yards': 380}
                for i in range(1, 19)
            ],
        )

        cls.tok_admin_a  = Token.objects.create(user=cls.admin_a).key
        cls.tok_member_a = Token.objects.create(user=cls.member_a).key
        cls.tok_admin_b  = Token.objects.create(user=cls.admin_b).key

    def _client(self, token):
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION=f'Token {token}')
        return c

    # ── Course ──────────────────────────────────────────────────────────────

    def test_admin_deletes_unused_course_and_cascades_tees(self):
        from core.models import Course, Tee
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/courses/{self.course_a.id}/')
        self.assertEqual(r.status_code, 204)
        self.assertFalse(
            Course.objects.filter(pk=self.course_a.pk).exists(),
        )
        # Tee should have CASCADE'd away with the course.
        self.assertFalse(
            Tee.objects.filter(pk=self.tee_a.pk).exists(),
        )

    def test_non_admin_cannot_delete_course(self):
        c = self._client(self.tok_member_a)
        r = c.delete(f'/api/courses/{self.course_a.id}/')
        self.assertEqual(r.status_code, 403)

    def test_cross_account_course_delete_404s(self):
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/courses/{self.course_b.id}/')
        self.assertEqual(r.status_code, 404)

    def test_course_used_in_round_protected(self):
        round_obj = Round.objects.create(
            account=self.acct_a, course=self.course_a, round_number=1,
        )
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/courses/{self.course_a.id}/')
        self.assertEqual(r.status_code, 400)
        self.assertIn('rounds', r.json().get('detail', '').lower())
        # Course + tee both intact.
        from core.models import Course, Tee
        self.assertTrue(
            Course.objects.filter(pk=self.course_a.pk).exists(),
        )
        self.assertTrue(
            Tee.objects.filter(pk=self.tee_a.pk).exists(),
        )
        # Tidy up the round we created so other tests aren't affected
        # (TestCase rolls back, but be explicit anyway).
        round_obj.delete()

    # ── Tee ─────────────────────────────────────────────────────────────────

    def test_admin_deletes_individual_tee(self):
        from core.models import Tee
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/tees/{self.tee_a.id}/')
        self.assertEqual(r.status_code, 204)
        self.assertFalse(
            Tee.objects.filter(pk=self.tee_a.pk).exists(),
        )

    def test_cross_account_tee_delete_404s(self):
        from core.models import Tee
        tee_b = Tee.objects.create(
            course=self.course_b, tee_name='Blue',
            slope=125, course_rating=Decimal('71.5'),
            par=72,
            holes=[
                {'number': i, 'par': 4, 'stroke_index': i, 'yards': 400}
                for i in range(1, 19)
            ],
        )
        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/tees/{tee_b.id}/')
        self.assertEqual(r.status_code, 404)
        self.assertTrue(
            Tee.objects.filter(pk=tee_b.pk).exists(),
        )

    def test_tee_used_in_round_protected(self):
        round_obj = Round.objects.create(
            account=self.acct_a, course=self.course_a, round_number=1,
        )
        from tournament.models import Foursome, FoursomeMembership
        fs = Foursome.objects.create(round=round_obj, group_number=1)
        # Need a Player to attach to a membership — borrow alice's
        # user via a quick Player row.
        player = Player.objects.create(
            account=self.acct_a, name='Alice P',
            handicap_index=Decimal('10.0'),
        )
        FoursomeMembership.objects.create(
            foursome=fs, player=player, tee=self.tee_a,
            course_handicap=10, playing_handicap=10,
        )

        c = self._client(self.tok_admin_a)
        r = c.delete(f'/api/tees/{self.tee_a.id}/')
        self.assertEqual(r.status_code, 400)
        from core.models import Tee
        self.assertTrue(
            Tee.objects.filter(pk=self.tee_a.pk).exists(),
        )
