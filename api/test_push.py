"""
api/test_push.py
----------------
Push notifications — Phase 0 infra: device-token registration, per-category
prefs, recipient resolution, and once-only event delivery (console backend).
No Firebase needed — PUSH_BACKEND=console logs and sends nothing.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, DeviceToken, SentNotification
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership, Watcher


User = get_user_model()


def _member(fs, player):
    return FoursomeMembership.objects.create(
        foursome=fs, player=player, course_handicap=10, playing_handicap=10)


class DeviceAndPrefsTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='A')
        self.u = User.objects.create_user(username='u', account=self.acct)
        self.c = APIClient(); self.c.force_authenticate(self.u)

    def test_register_and_unregister(self):
        r = self.c.post(reverse('api-device-register'),
                        {'token': 'tok1', 'platform': 'ios'}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertTrue(DeviceToken.objects.filter(
            token='tok1', user=self.u).exists())
        # Re-registering the same token on another user moves it.
        u2 = User.objects.create_user(username='u2', account=self.acct)
        c2 = APIClient(); c2.force_authenticate(u2)
        c2.post(reverse('api-device-register'),
                {'token': 'tok1', 'platform': 'ios'}, format='json')
        self.assertEqual(DeviceToken.objects.filter(token='tok1').count(), 1)
        self.assertEqual(DeviceToken.objects.get(token='tok1').user_id, u2.id)
        # Unregister.
        c2.post(reverse('api-device-unregister'), {'token': 'tok1'},
                format='json')
        self.assertFalse(DeviceToken.objects.filter(token='tok1').exists())

    def test_prefs_defaults_and_update(self):
        r = self.c.get(reverse('api-notification-prefs'))
        self.assertTrue(r.data['skins'])           # default on
        r = self.c.patch(reverse('api-notification-prefs'),
                         {'skins': False}, format='json')
        self.assertFalse(r.data['skins'])
        self.assertFalse(self.c.get(reverse('api-notification-prefs')).data['skins'])


@override_settings(PUSH_BACKEND='console')
class NotifyRoundEventTests(TestCase):
    def setUp(self):
        self.acct_a = Account.objects.create(name='Host')
        course = Course.objects.create(account=self.acct_a, name='Pebble')
        self.round = Round.objects.create(
            account=self.acct_a, course=course, status='in_progress',
            active_games=['skins'])
        fs = Foursome.objects.create(round=self.round, group_number=1)
        _member(fs, Player.objects.create(
            account=self.acct_a, name='Bob', phone='(310) 555-0101',
            handicap_index=Decimal('9.0')))

        # Bob has his own account + device token (a phone-matched participant).
        self.acct_b = Account.objects.create(name='Bob')
        self.bob = User.objects.create_user(username='bob', account=self.acct_b)
        self.bob.phone = '+13105550101'; self.bob.save(update_fields=['phone'])
        DeviceToken.objects.create(user=self.bob, token='tok-bob', platform='ios')

    def test_sends_once_then_dedupes(self):
        from services.push import notify_round_event
        key = f'skin_won:round={self.round.id}:hole=7'
        sent1 = notify_round_event(
            self.round, category='skins', dedup_key=key,
            title='Skin!', body='Bob won hole 7')
        self.assertTrue(sent1)
        self.assertTrue(SentNotification.objects.filter(dedup_key=key).exists())
        # Re-running (e.g. on a score recalculation) does NOT resend.
        sent2 = notify_round_event(
            self.round, category='skins', dedup_key=key,
            title='Skin!', body='Bob won hole 7')
        self.assertFalse(sent2)
        self.assertEqual(SentNotification.objects.filter(dedup_key=key).count(), 1)

    def test_recipients_include_watchers_respect_prefs(self):
        from services.push import users_for_round, tokens_for_users
        # Add a watcher with an account + token.
        acct_w = Account.objects.create(name='Wanda')
        wanda = User.objects.create_user(username='wanda', account=acct_w)
        wanda.phone = '+14155557777'; wanda.save(update_fields=['phone'])
        DeviceToken.objects.create(user=wanda, token='tok-w', platform='ios')
        Watcher.objects.create(round=self.round, phone='+14155557777',
                               name='Wanda')

        users = users_for_round(self.round)
        ids = {u.id for u in users}
        self.assertIn(self.bob.id, ids)
        self.assertIn(wanda.id, ids)

        # Wanda mutes skins → her token drops out for that category.
        wanda.notification_prefs = {'skins': False}
        wanda.save(update_fields=['notification_prefs'])
        toks = tokens_for_users(users_for_round(self.round), 'skins')
        self.assertIn('tok-bob', toks)
        self.assertNotIn('tok-w', toks)
