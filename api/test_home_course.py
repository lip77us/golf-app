"""
api/test_home_course.py
-----------------------
Player.home_course — a golfer's personal home course, set from the Profile
screen and pinned to the top of the course picker's default list.

Covers: set / clear via PATCH, self-edit allowed for a non-admin on their OWN
player, cross-account course rejected, and MeView surfacing the fields.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player


User = get_user_model()


def _member(account, username, *, admin=False):
    u = User.objects.create_user(username=username, account=account)
    if admin:
        u.is_account_admin = True
        u.save(update_fields=['is_account_admin'])
    return u


class HomeCourseTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Home Test')
        # A non-admin member editing their OWN profile — the Profile-screen case.
        self.user = _member(self.account, 'greg', admin=False)
        self.me = Player.objects.create(
            account=self.account, name='Greg', handicap_index=Decimal('12.0'),
            user=self.user)
        self.pebble = Course.objects.create(account=self.account, name='Pebble')
        self.spy    = Course.objects.create(account=self.account, name='Spyglass')

        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-player-detail', args=[self.me.id])

    def test_self_can_set_home_course_without_admin(self):
        resp = self.client.patch(
            self.url, {'home_course_id': self.pebble.id}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['home_course_id'], self.pebble.id)
        self.assertEqual(resp.data['home_course_name'], 'Pebble')
        self.me.refresh_from_db()
        self.assertEqual(self.me.home_course_id, self.pebble.id)

    def test_clear_with_zero(self):
        self.me.home_course = self.spy
        self.me.save(update_fields=['home_course'])
        resp = self.client.patch(self.url, {'home_course_id': 0}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertIsNone(resp.data['home_course_id'])
        self.assertEqual(resp.data['home_course_name'], '')
        self.me.refresh_from_db()
        self.assertIsNone(self.me.home_course_id)

    def test_cross_account_course_rejected(self):
        other = Account.objects.create(name='Other')
        foreign = Course.objects.create(account=other, name='Augusta')
        resp = self.client.patch(
            self.url, {'home_course_id': foreign.id}, format='json')
        self.assertEqual(resp.status_code, 400)
        self.me.refresh_from_db()
        self.assertIsNone(self.me.home_course_id)

    def test_me_endpoint_surfaces_home_course(self):
        self.me.home_course = self.pebble
        self.me.save(update_fields=['home_course'])
        resp = self.client.get(reverse('api-me'))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['player']['home_course_id'], self.pebble.id)
        self.assertEqual(resp.data['player']['home_course_name'], 'Pebble')

    def test_stranger_cannot_edit_someone_elses_player(self):
        # A different non-admin member can't set another golfer's home course.
        other_user = _member(self.account, 'intruder', admin=False)
        c = APIClient(); c.force_authenticate(other_user)
        resp = c.patch(self.url, {'home_course_id': self.pebble.id},
                       format='json')
        self.assertEqual(resp.status_code, 403)
