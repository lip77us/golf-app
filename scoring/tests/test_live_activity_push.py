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


class ConsoleBackendMixin:
    """Pin the backend to console for every test here.

    Without this the suite reads the developer's real .env — and with a key
    configured it will genuinely post to Apple, which it did once before this
    was added.  A test must never depend on ambient credentials, and must
    never leave the machine.
    """

    def setUp(self):
        patcher = mock.patch.dict(
            os.environ, {'LIVE_ACTIVITY_BACKEND': 'console'})
        patcher.start()
        self.addCleanup(patcher.stop)
        super().setUp()


class PayloadTests(ConsoleBackendMixin, TestCase):

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


class TopicTests(ConsoleBackendMixin, TestCase):

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


class SafetyTests(ConsoleBackendMixin, TestCase):

    def test_the_console_backend_sends_nothing(self):
        with mock.patch.object(lap, '_send_apns') as apns:
            self.assertTrue(lap.send_state('abc123', {'x': 1}))
        apns.assert_not_called()

    def test_console_is_the_default_when_nothing_is_configured(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lap._backend(), 'console')

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


class NeverBreaksScoringTests(ConsoleBackendMixin, TestCase):
    """The promise the whole feature rests on.

    An earlier version wrapped the push in try/except and called it inline.
    That is not enough on Postgres: the first failed statement aborts the
    surrounding transaction, so catching the error in Python still leaves every
    later query failing with InFailedSqlTransaction — and a missing table in
    the lock-screen code took the score post down with it.  Deferring past the
    commit is what actually makes it safe.
    """

    def setUp(self):
        from django.contrib.auth import get_user_model
        from rest_framework.test import APIClient

        from scoring.tests._helpers import make_foursome, make_round, make_tee
        from services.sixes import setup_sixes

        tee = make_tee()
        self.round = make_round(tee.course)
        self.round.active_games = ['sixes']
        self.round.save(update_fields=['active_games'])
        self.fs = make_foursome(
            self.round, [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=tee)
        pid = {m.player.name: m.player_id for m in
               self.fs.memberships.select_related('player')}
        base = {'team_select_method': 'long_drive',
                'team1_player_ids': [pid['Paul'], pid['Dave']],
                'team2_player_ids': [pid['Sam'], pid['Lee']]}
        setup_sixes(self.fs, [{**base, 'start_hole': 1, 'end_hole': 6}],
                    handicap_mode='gross')
        self.pid = pid

        User = get_user_model()
        user = User.objects.create_user(username='td',
                                        account=self.round.account)
        user.is_account_admin = True
        user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(user)

    def _post_hole(self):
        from django.urls import reverse
        return self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': 1,
             'scores': [{'player_id': p, 'gross_score': 4}
                        for p in self.pid.values()]},
            format='json')

    def test_a_score_lands_even_when_the_push_blows_up(self):
        from scoring.models import HoleScore
        with mock.patch('services.live_activity_push.push_round',
                        side_effect=RuntimeError('APNs is on fire')) as push:
            with self.captureOnCommitCallbacks(execute=True):
                resp = self._post_hole()
        self.assertTrue(push.called, 'the deferred push never ran — this test '
                                     'would pass for the wrong reason')
        self.assertEqual(resp.status_code, 200, getattr(resp, 'data', resp))
        self.assertEqual(
            HoleScore.objects.filter(foursome=self.fs, hole_number=1).count(),
            4)

    def test_a_score_lands_when_the_token_table_is_unreachable(self):
        """The exact production shape of the bug: a database error, not a
        Python one, raised from inside the push."""
        from django.db.utils import ProgrammingError
        from scoring.models import HoleScore
        with mock.patch(
                'tournament.models.LiveActivityToken.objects.filter',
                side_effect=ProgrammingError('relation does not exist')):
            with self.captureOnCommitCallbacks(execute=True):
                resp = self._post_hole()
        self.assertEqual(resp.status_code, 200, getattr(resp, 'data', resp))
        self.assertEqual(
            HoleScore.objects.filter(foursome=self.fs, hole_number=1).count(),
            4)
