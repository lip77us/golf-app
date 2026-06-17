"""
api/test_shared_rounds.py
-------------------------
Tests for the read-only cross-account "Shared with me" endpoint (Friends
Phase 2a) — WATCHER follows only, phone-matched, no permanent link.

Rounds you're a PLAYER in are NOT here (they live in your own active list via
playing-for-me); see api/test_shared_play.py. Completed follows age off after
SHARED_WATCH_RETENTION_DAYS so the list doesn't grow forever.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import (
    Round, Foursome, FoursomeMembership, Watcher,
)


User = get_user_model()


def _watched_round(account_name, course_name, watcher_phone,
                   *, status='complete', date=None):
    """An account with one casual round the given phone is invited to WATCH."""
    account = Account.objects.create(name=account_name)
    course = Course.objects.create(account=account, name=course_name)
    rnd = Round.objects.create(
        account=account, course=course, status=status,
        active_games=['skins'],
        **({'date': date} if date is not None else {}),
    )
    Watcher.objects.create(round=rnd, phone=watcher_phone, name='Watcher')
    return account, rnd


def _user_with_phone(account_name, username, phone):
    account = Account.objects.create(name=account_name)
    user = User.objects.create_user(username=username, account=account)
    user.phone = phone
    user.save(update_fields=['phone'])
    return account, user


class SharedRoundsTests(TestCase):
    def setUp(self):
        # Account A ran a skins round and invited Bob (by phone) to WATCH it.
        # Completed today → inside the retention window.
        self.acct_a, self.round_a = _watched_round(
            'Paul Group', 'Pebble Beach', '+15105550123', status='complete',
        )
        # Bob signs up — his verified User.phone is E.164 and matches the watch.
        self.acct_b, self.user_b = _user_with_phone(
            'Bob Golf', 'bob', '+15105550123',
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user_b)
        self.url = reverse('api-shared-rounds')

    def test_watch_match_surfaces_other_account_round(self):
        resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        item = resp.data[0]
        self.assertEqual(item['id'], self.round_a.id)
        self.assertEqual(item['course_name'], 'Pebble Beach')
        self.assertEqual(item['group_label'], 'Paul Group')

    def test_status_filter(self):
        self.assertEqual(len(self.client.get(self.url, {'status': 'complete'}).data), 1)
        self.assertEqual(len(self.client.get(self.url, {'status': 'in_progress'}).data), 0)

    def test_own_account_rounds_excluded(self):
        # A watch on a round in Bob's OWN account is never surfaced here.
        course_b = Course.objects.create(account=self.acct_b, name='Home GC')
        rb = Round.objects.create(account=self.acct_b, course=course_b,
                                  status='complete', active_games=['skins'])
        Watcher.objects.create(round=rb, phone='+15105550123', name='Bob')

        ids = [r['id'] for r in self.client.get(self.url).data]
        self.assertIn(self.round_a.id, ids)
        self.assertNotIn(rb.id, ids)  # own account excluded

    def test_player_round_not_in_shared(self):
        # A round Bob is a PLAYER in (another account) belongs in his active
        # list, NOT here.
        acct_c = Account.objects.create(name='Carl Group')
        course_c = Course.objects.create(account=acct_c, name='Spyglass')
        rc = Round.objects.create(account=acct_c, course=course_c,
                                  status='in_progress', active_games=['skins'])
        bob_c = Player.objects.create(
            account=acct_c, name='Bob', phone='(510) 555-0123',
            handicap_index=Decimal('10.0'),
        )
        FoursomeMembership.objects.create(
            foursome=Foursome.objects.create(round=rc, group_number=1),
            player=bob_c, course_handicap=10, playing_handicap=10,
        )
        ids = [r['id'] for r in self.client.get(self.url).data]
        self.assertNotIn(rc.id, ids)

    def test_completed_follow_ages_off(self):
        # A follow completed long ago drops; one completed inside the window stays.
        old_date = timezone.now().date() - timedelta(days=30)
        _acct_old, round_old = _watched_round(
            'Old Group', 'Old GC', '+15105550123',
            status='complete', date=old_date,
        )
        recent_date = timezone.now().date() - timedelta(days=3)
        _acct_recent, round_recent = _watched_round(
            'Recent Group', 'Recent GC', '+15105550123',
            status='complete', date=recent_date,
        )
        ids = [r['id'] for r in self.client.get(self.url).data]
        self.assertNotIn(round_old.id, ids)      # >7 days → aged off
        self.assertIn(round_recent.id, ids)      # <7 days → kept
        self.assertIn(self.round_a.id, ids)      # today → kept

    def test_in_progress_old_follow_kept(self):
        # A still-live round is kept even if its date is old (you're watching it).
        old_date = timezone.now().date() - timedelta(days=30)
        _acct, round_live = _watched_round(
            'Live Group', 'Live GC', '+15105550123',
            status='in_progress', date=old_date,
        )
        ids = [r['id'] for r in self.client.get(self.url).data]
        self.assertIn(round_live.id, ids)

    def test_different_phone_sees_nothing(self):
        _acct_c, user_c = _user_with_phone('Carl Golf', 'carl', '+19995550000')
        client_c = APIClient(); client_c.force_authenticate(user_c)
        self.assertEqual(client_c.get(self.url).data, [])

    def test_no_verified_phone_returns_empty(self):
        _acct_d, user_d = _user_with_phone('Dave Golf', 'dave', '')
        user_d.phone = None
        user_d.save(update_fields=['phone'])
        client_d = APIClient(); client_d.force_authenticate(user_d)
        self.assertEqual(client_d.get(self.url).data, [])
