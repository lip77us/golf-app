"""
api/test_recent_courses.py
--------------------------
GET /api/courses/recent/ — the account's most recently played distinct courses
(up to 3, newest first), for the course picker's recents quick-pick.
"""

from datetime import date

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework.authtoken.models import Token

from accounts.models import Account
from core.models import Course
from tournament.models import Round


User = get_user_model()


def _round(account, course, d):
    return Round.objects.create(
        account=account, course=course, status='complete',
        active_games=['skins'], date=d)


class RecentCoursesTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='RC')
        self.user = User.objects.create_user(username='u', account=self.account)
        self.client = APIClient()
        token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def _names(self):
        resp = self.client.get(reverse('api-recent-courses'))
        self.assertEqual(resp.status_code, 200)
        return [c['name'] for c in resp.data]

    def test_distinct_newest_first_capped_at_three(self):
        c1 = Course.objects.create(account=self.account, name='Pebble')
        c2 = Course.objects.create(account=self.account, name='Brookside')
        c3 = Course.objects.create(account=self.account, name='Rancho')
        c4 = Course.objects.create(account=self.account, name='Older')
        _round(self.account, c4, date(2026, 1, 1))
        _round(self.account, c1, date(2026, 6, 1))
        _round(self.account, c2, date(2026, 5, 1))
        _round(self.account, c1, date(2026, 6, 29))   # dup, most recent → c1 first
        _round(self.account, c3, date(2026, 4, 1))
        # Distinct by recency: Pebble (6/29), Brookside (5/1), Rancho (4/1).
        # 'Older' (1/1) falls outside the top 3.
        self.assertEqual(self._names(), ['Pebble', 'Brookside', 'Rancho'])

    def test_empty_when_no_rounds(self):
        Course.objects.create(account=self.account, name='Unplayed')
        self.assertEqual(self._names(), [])

    def test_scoped_to_account(self):
        other = Account.objects.create(name='Other')
        oc = Course.objects.create(account=other, name='Theirs')
        _round(other, oc, date(2026, 6, 1))
        self.assertEqual(self._names(), [])

    def test_requires_auth(self):
        resp = APIClient().get(reverse('api-recent-courses'))
        self.assertIn(resp.status_code, (401, 403))
