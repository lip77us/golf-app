"""
api/test_recent_courses.py
--------------------------
GET /api/courses/recent/ — the account's most recently played distinct courses
(up to 3, newest first), for the course picker's recents quick-pick.
"""

from datetime import date, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework.authtoken.models import Token

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership


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


HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


def _course_with_tee(account, name, *, golf_api_id=''):
    c = Course.objects.create(account=account, name=name, golf_api_id=golf_api_id)
    Tee.objects.create(course=c, tee_name='White', slope=113,
                       course_rating=Decimal('72.0'), par=72, holes=HOLES)
    return c


class RecentCoursesCrossAccountTests(TestCase):
    """Courses of rounds I played in OTHER accounts (phone-matched) feed my
    recents and get cloned into my account so they're selectable."""

    def setUp(self):
        self.acct = Account.objects.create(name='Mine')
        self.user = User.objects.create_user(username='me', account=self.acct)
        self.user.phone = '+13105550101'
        self.user.save(update_fields=['phone'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _friend_round(self, course_name, golf_api_id, when, player_phone):
        facct = Account.objects.create(name=f'Friend {course_name}')
        fcourse = _course_with_tee(facct, course_name, golf_api_id=golf_api_id)
        rnd = Round.objects.create(account=facct, course=fcourse,
                                   status='complete', active_games=['skins'],
                                   date=when)
        fs = Foursome.objects.create(round=rnd, group_number=1)
        me = Player.objects.create(account=facct, name='Paul Guest',
                                   handicap_index=Decimal('0'),
                                   phone=player_phone)
        FoursomeMembership.objects.create(foursome=fs, player=me,
                                          tee=fcourse.tees.first(),
                                          course_handicap=0, playing_handicap=0)
        return rnd

    def _names(self):
        resp = self.client.get(reverse('api-recent-courses'))
        self.assertEqual(resp.status_code, 200, resp.data)
        return [c['name'] for c in resp.data]

    def test_friend_round_course_cloned_and_returned(self):
        # Added by a friend (formatted phone) to a round I never hosted.
        self._friend_round('Tilden Park GC', 'api-tilden', date.today(),
                           '(310) 555-0101')
        self.assertIn('Tilden Park GC', self._names())
        mine = Course.objects.filter(account=self.acct, golf_api_id='api-tilden')
        self.assertTrue(mine.exists())
        self.assertTrue(mine.first().tees.exists())

    def test_more_recent_cross_round_sorts_first(self):
        old = _course_with_tee(self.acct, 'Old Home', golf_api_id='api-old')
        Round.objects.create(account=self.acct, course=old, status='complete',
                             active_games=['skins'],
                             date=date.today() - timedelta(days=10))
        self._friend_round('New Friend Course', 'api-new', date.today(),
                           '+13105550101')
        self.assertEqual(self._names()[0], 'New Friend Course')

    def test_own_and_cross_same_course_not_duplicated(self):
        c = _course_with_tee(self.acct, 'Shared Links', golf_api_id='api-shared')
        Round.objects.create(account=self.acct, course=c, status='complete',
                             active_games=['skins'],
                             date=date.today() - timedelta(days=3))
        self._friend_round('Shared Links', 'api-shared', date.today(),
                           '+13105550101')
        self.assertEqual(self._names().count('Shared Links'), 1)

    def test_custom_cross_course_without_api_id_skipped(self):
        self._friend_round('Backyard Custom', '', date.today(), '+13105550101')
        self.assertNotIn('Backyard Custom', self._names())

    def test_no_phone_no_cross_courses(self):
        self.user.phone = None
        self.user.save(update_fields=['phone'])
        self._friend_round('Unseen Course', 'api-unseen', date.today(),
                           '+13105550101')
        self.assertEqual(self._names(), [])
