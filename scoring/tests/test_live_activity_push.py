"""
scoring/tests/test_live_activity_push.py
----------------------------------------
Delivery for the Sixes lock screen.

Everything an Apple key would prove is out of reach here, so these tests cover
the two things that break delivery *silently* — the topic suffix and the `aps`
envelope — plus the rule that a failure never reaches the caller.
"""
import os
from unittest import mock

from django.test import TestCase

from services import live_activity_push as lap


class PayloadTests(TestCase):

    def test_the_envelope_is_an_update(self):
        p = lap._apns_payload({'header': {}})['aps']
        self.assertEqual(p['event'], 'update')
        self.assertEqual(p['content-state'], {'header': {}})
        self.assertNotIn('dismissal-date', p)

    def test_a_timestamp_always_rides_along(self):
        """iOS discards a push that arrives out of order, which on a golf
        course is routine rather than exotic."""
        self.assertIsInstance(lap._apns_payload({})['aps']['timestamp'], int)

    def test_ending_carries_its_own_dismissal(self):
        p = lap._apns_payload({}, event='end')['aps']
        self.assertEqual(p['event'], 'end')
        self.assertGreater(p['dismissal-date'], p['timestamp'])


class TopicTests(TestCase):

    def test_the_topic_is_the_activity_one_not_the_app_one(self):
        """The bare bundle id is the app's topic.  Apple rejects it for a Live
        Activity, and the failure looks exactly like a push that never lands."""
        h = lap._headers('tok')
        self.assertEqual(h['apns-topic'],
                         'us.lipkin.golfapp.push-type.liveactivity')
        self.assertEqual(h['apns-push-type'], 'liveactivity')

    def test_the_bundle_id_is_overridable(self):
        with mock.patch.dict(os.environ, {'APNS_BUNDLE_ID': 'com.example.x'}):
            self.assertEqual(lap._headers('t')['apns-topic'],
                             'com.example.x.push-type.liveactivity')

    def test_sandbox_is_opt_in(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('APNS_SANDBOX', None)
            self.assertIn('api.push.apple.com', lap._host())
        with mock.patch.dict(os.environ, {'APNS_SANDBOX': '1'}):
            self.assertIn('sandbox', lap._host())


class SafetyTests(TestCase):

    def test_the_default_backend_sends_nothing(self):
        self.assertEqual(lap._backend(), 'console')
        self.assertTrue(lap.send_state('abc123', {'x': 1}))

    def test_a_broken_backend_never_reaches_the_caller(self):
        """The caller is a scoring request.  A lock screen must not be able to
        fail one."""
        with mock.patch.object(lap, '_send_console',
                               side_effect=RuntimeError('boom')):
            self.assertFalse(lap.send_state('abc123', {}))

    def test_unconfigured_is_reported_not_guessed(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertFalse(lap.is_configured())
        with mock.patch.dict(os.environ, {'APNS_KEY_P8': 'x',
                                          'APNS_KEY_ID': 'y',
                                          'APNS_TEAM_ID': 'z'}):
            self.assertTrue(lap.is_configured())
