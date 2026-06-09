"""
api/test_support_access.py
--------------------------
Read-only support access: a User.is_support staffer can look up and READ any
round (cross-account) for issue diagnosis — by watch token or numeric id — and
every lookup is audited. They get NO write access.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, SupportAccessLog
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()
HOLES = [{'number': i, 'par': 4, 'stroke_index': i} for i in range(1, 19)]


class SupportAccessTests(TestCase):
    def setUp(self):
        # Account A — the customer whose round has a reported issue.
        self.acct_a = Account.objects.create(name='Customer A')
        self.owner = User.objects.create_user(username='owner', account=self.acct_a)
        course = Course.objects.create(account=self.acct_a, name='Pines')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct_a, course=course, status='in_progress',
            active_games=['skins'], bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        p = Player.objects.create(account=self.acct_a, name='Al',
                                  handicap_index=Decimal('0.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=p, tee=self.tee,
            course_handicap=0, playing_handicap=0)

        # Account B — support staffer (different tenant) + a normal user.
        self.acct_b = Account.objects.create(name='Support Co')
        self.support = User.objects.create_user(
            username='support', account=self.acct_b, is_support=True)
        self.rando = User.objects.create_user(username='rando', account=self.acct_b)

    def _client(self, user):
        c = APIClient(); c.force_authenticate(user); return c

    # ── Lookup ────────────────────────────────────────────────────────────
    def test_support_lookup_by_token_and_id_logs_access(self):
        c = self._client(self.support)
        url = reverse('api-support-round')

        r1 = c.get(url, {'q': self.round.watch_token})
        self.assertEqual(r1.status_code, 200, r1.data)
        self.assertEqual(r1.data['round_id'], self.round.id)
        self.assertEqual(r1.data['account_name'], 'Customer A')

        # numeric id + a pasted /watch/ URL both resolve
        self.assertEqual(c.get(url, {'q': str(self.round.id)}).data['round_id'],
                         self.round.id)
        self.assertEqual(
            c.get(url, {'q': f'https://halved.golf/watch/{self.round.watch_token}/'})
                .data['round_id'], self.round.id)

        # Every lookup is audited.
        logs = SupportAccessLog.objects.filter(round=self.round, user=self.support)
        self.assertEqual(logs.count(), 3)
        self.assertEqual(logs.first().account_name, 'Customer A')

    def test_support_can_read_cross_account_leaderboard(self):
        c = self._client(self.support)
        resp = c.get(reverse('api-leaderboard', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)

    # ── Non-support is blocked ────────────────────────────────────────────
    def test_non_support_forbidden_on_lookup(self):
        resp = self._client(self.rando).get(
            reverse('api-support-round'), {'q': self.round.watch_token})
        self.assertEqual(resp.status_code, 403)

    def test_non_support_cannot_read_other_account_leaderboard(self):
        resp = self._client(self.rando).get(
            reverse('api-leaderboard', args=[self.round.id]))
        self.assertEqual(resp.status_code, 404)

    def test_lookup_unknown_token_404(self):
        resp = self._client(self.support).get(
            reverse('api-support-round'), {'q': 'ZZZZZZZZ'})
        self.assertEqual(resp.status_code, 404)

    # ── Read-only: support gets NO write access ───────────────────────────
    def test_support_cannot_write_scores(self):
        c = self._client(self.support)
        resp = c.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'scores': []}, format='json')
        self.assertEqual(resp.status_code, 404)
