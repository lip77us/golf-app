"""
api/test_shared_rounds.py
-------------------------
Tests for the read-only cross-account "Shared with me" history endpoint
(Friends Phase 2a) — phone-matched, no permanent link.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership


User = get_user_model()


def _round_with_player(account_name, course_name, player_name, player_phone):
    """An account with one casual, completed round containing one player."""
    account = Account.objects.create(name=account_name)
    course = Course.objects.create(account=account, name=course_name)
    player = Player.objects.create(
        account=account, name=player_name, phone=player_phone,
        handicap_index=Decimal('10.0'),
    )
    rnd = Round.objects.create(
        account=account, course=course, status='complete',
        active_games=['skins'],
    )
    fs = Foursome.objects.create(round=rnd, group_number=1)
    FoursomeMembership.objects.create(
        foursome=fs, player=player, course_handicap=10, playing_handicap=10,
    )
    return account, rnd, player


def _user_with_phone(account_name, username, phone):
    account = Account.objects.create(name=account_name)
    user = User.objects.create_user(username=username, account=account)
    user.phone = phone
    user.save(update_fields=['phone'])
    return account, user


class SharedRoundsTests(TestCase):
    def setUp(self):
        # Account A (a friend's group) ran a skins round with a login-less
        # player whose phone was typed in a non-E.164 format.
        self.acct_a, self.round_a, self.player_a = _round_with_player(
            'Paul Group', 'Pebble Beach', 'Bob', '(510) 555-0123',
        )
        # Bob signs up — his verified User.phone is E.164.
        self.acct_b, self.user_b = _user_with_phone(
            'Bob Golf', 'bob', '+15105550123',
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user_b)
        self.url = reverse('api-shared-rounds')

    def test_phone_match_surfaces_other_account_round(self):
        resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        item = resp.data[0]
        self.assertEqual(item['id'], self.round_a.id)
        self.assertEqual(item['course_name'], 'Pebble Beach')
        self.assertEqual(item['group_label'], 'Paul Group')
        self.assertEqual(item['your_name'], 'Bob')

    def test_status_filter(self):
        self.assertEqual(len(self.client.get(self.url, {'status': 'complete'}).data), 1)
        self.assertEqual(len(self.client.get(self.url, {'status': 'in_progress'}).data), 0)

    def test_own_account_rounds_excluded(self):
        # Give Bob a round in his own account with his own player+phone.
        course_b = Course.objects.create(account=self.acct_b, name='Home GC')
        bob_self = Player.objects.create(
            account=self.acct_b, user=self.user_b, name='Bob',
            phone='+15105550123', handicap_index=Decimal('10.0'),
        )
        rb = Round.objects.create(account=self.acct_b, course=course_b,
                                   status='complete', active_games=['skins'])
        fb = Foursome.objects.create(round=rb, group_number=1)
        FoursomeMembership.objects.create(
            foursome=fb, player=bob_self, course_handicap=10, playing_handicap=10,
        )

        ids = [r['id'] for r in self.client.get(self.url).data]
        self.assertIn(self.round_a.id, ids)
        self.assertNotIn(rb.id, ids)  # own account excluded

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
