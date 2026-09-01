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
            os.environ, {'LIVE_ACTIVITY_BACKEND': 'console',
                         'LIVE_ACTIVITY_ENABLED': '1'})
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


class DarkTests(ConsoleBackendMixin, TestCase):
    """Shipped dark: the code is present and inert until someone turns it on."""

    def test_off_unless_set(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertFalse(lap.is_enabled())

    def test_a_configured_key_does_not_turn_it_on(self):
        """Going live is a decision, not a side effect of credentials being
        present — otherwise setting up the key on Railway silently ships it."""
        with mock.patch.dict(os.environ, {'APNS_KEY_P8': 'x',
                                          'APNS_KEY_ID': 'y',
                                          'APNS_TEAM_ID': 'z'}, clear=True):
            self.assertTrue(lap.is_configured())
            self.assertFalse(lap.is_enabled())

    def test_nothing_is_pushed_while_off(self):
        with mock.patch.dict(os.environ, {'LIVE_ACTIVITY_ENABLED': '0'}):
            with mock.patch.object(lap, 'send_state') as send:
                self.assertEqual(lap.push_round(mock.Mock()), 0)
            send.assert_not_called()


class StaleTests(ConsoleBackendMixin, TestCase):
    """A board nobody has scored on for an hour should stop looking live.

    iOS does not remove it at that point — it flips `context.isStale`, and the
    card fades and says "No scores in a while". Removal is the eight-hour
    system cap, or the app ending it on round sign.
    """

    def test_updates_carry_a_stale_date(self):
        aps = lap._apns_payload({})['aps']
        self.assertEqual(aps['stale-date'], aps['timestamp'] + lap.STALE_AFTER)

    def test_the_window_survives_the_halfway_house(self):
        """Fifteen minutes a hole, so an hour is three holes — long enough to
        sit through a break at the turn, short enough that an abandoned round
        stops claiming to be live."""
        self.assertGreaterEqual(lap.STALE_AFTER, 45 * 60)
        self.assertLessEqual(lap.STALE_AFTER, 90 * 60)

    def test_the_closing_frame_does_not_go_stale(self):
        """The final state is what you won and who to see. It is true forever,
        and it has a dismissal date instead."""
        aps = lap._apns_payload({}, event='end')['aps']
        self.assertNotIn('stale-date', aps)
        self.assertIn('dismissal-date', aps)


class PushToStartTests(ConsoleBackendMixin, TestCase):
    """Raising the board on a phone that has not raised one itself.

    This is the half that makes the feature worth having.  A Live Activity can
    only be started locally by `Activity.request`, which needs the app in the
    foreground — so before this, the only golfer with a lock screen was the one
    posting scores, and he is the one man in the group already holding a phone.
    """

    def setUp(self):
        from django.contrib.auth import get_user_model

        from core.models import Player
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

        User = get_user_model()
        acct = self.round.account
        # Paul is scoring; Dave is not. Both are in the round.
        self.scorer = User.objects.create_user(username='paul', account=acct)
        self.other  = User.objects.create_user(username='dave', account=acct)
        Player.objects.filter(pk=pid['Paul']).update(user=self.scorer)
        Player.objects.filter(pk=pid['Dave']).update(user=self.other)
        self.pid = pid

        # A hole so there is a board to send at all.
        from scoring.models import HoleScore
        for name, p in pid.items():
            HoleScore.objects.create(foursome=self.fs, player_id=p,
                                     hole_number=1, gross_score=4)

    def _start_token(self, user, token):
        from tournament.models import LiveActivityStartToken
        return LiveActivityStartToken.objects.create(user=user, token=token)

    def _running(self, user, token='live'):
        from tournament.models import LiveActivityToken
        return LiveActivityToken.objects.create(round=self.round, user=user,
                                                token=token)

    def test_the_non_scoring_golfer_gets_a_card_raised(self):
        self._start_token(self.other, 'dave-start')
        with mock.patch.object(lap, 'send_start',
                               return_value=True) as send:
            sent = lap.push_start_to_absent(self.round)
        self.assertEqual(sent, 1)
        self.assertEqual(send.call_args.args[0], 'dave-start')

    def test_a_golfer_already_running_one_is_skipped(self):
        """iOS would happily show two cards for one round.  The scorer's phone
        started its own, so a start push to him is a duplicate."""
        self._start_token(self.scorer, 'paul-start')
        self._running(self.scorer)
        with mock.patch.object(lap, 'send_start') as send:
            sent = lap.push_start_to_absent(self.round)
        self.assertEqual(sent, 0)
        send.assert_not_called()

    def test_a_stranger_with_a_token_gets_nothing(self):
        from django.contrib.auth import get_user_model
        from accounts.models import Account
        User = get_user_model()
        outsider = User.objects.create_user(
            username='nosy', account=Account.objects.create(name='Elsewhere'))
        self._start_token(outsider, 'nosy-start')
        with mock.patch.object(lap, 'send_start') as send:
            sent = lap.push_start_to_absent(self.round)
        self.assertEqual(sent, 0)
        send.assert_not_called()

    def test_a_watcher_gets_one_too(self):
        from django.contrib.auth import get_user_model
        from accounts.models import Account
        from tournament.models import Watcher
        User = get_user_model()
        watcher = User.objects.create_user(
            username='spec', account=Account.objects.create(name='Watch Club'),
            phone='+13105550199')
        Watcher.objects.create(round=self.round, phone='+13105550199')
        self._start_token(watcher, 'watch-start')
        with mock.patch.object(lap, 'send_start',
                               return_value=True) as send:
            sent = lap.push_start_to_absent(self.round)
        self.assertEqual(sent, 1)
        self.assertEqual(send.call_args.args[0], 'watch-start')

    def test_it_is_dark_when_the_feature_is_off(self):
        self._start_token(self.other, 'dave-start')
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(lap, 'send_start') as send:
                self.assertEqual(lap.push_start_to_absent(self.round), 0)
            send.assert_not_called()

    def test_a_second_score_does_not_send_a_second_start(self):
        """The bug real testing found: four cards for two rounds.

        This runs on EVERY score, and a phone takes seconds to register the
        update token that marks it as already carrying a card. Every hole
        scored in that gap sent another start push — and a start push cannot
        see the lock screen, so each one raised another card.
        """
        self._start_token(self.other, 'dave-start')
        with mock.patch.object(lap, 'send_start', return_value=True) as send:
            first = lap.push_start_to_absent(self.round)
            second = lap.push_start_to_absent(self.round)   # next hole
            third = lap.push_start_to_absent(self.round)    # and the next
        self.assertEqual(first, 1)
        self.assertEqual((second, third), (0, 0))
        self.assertEqual(send.call_count, 1)

    def test_the_cooldown_lapses_so_a_phone_that_missed_it_is_re_asked(self):
        """A phone that was off at the tee is exactly why the retry exists —
        the cooldown must not become a permanent block."""
        from datetime import timedelta

        from django.utils import timezone
        from tournament.models import LiveActivityStartPush
        self._start_token(self.other, 'dave-start')
        with mock.patch.object(lap, 'send_start', return_value=True):
            self.assertEqual(lap.push_start_to_absent(self.round), 1)
        # Age the record past the cooldown (auto_now forbids a plain save).
        LiveActivityStartPush.objects.filter(round=self.round).update(
            sent_at=timezone.now() - lap.START_PUSH_COOLDOWN - timedelta(minutes=1))
        with mock.patch.object(lap, 'send_start', return_value=True) as send:
            self.assertEqual(lap.push_start_to_absent(self.round), 1)
        self.assertEqual(send.call_count, 1)

    def test_a_phone_that_registered_its_card_is_skipped_regardless(self):
        """Once the update token lands, the cooldown is irrelevant — that phone
        is carrying a card and must never be sent another start."""
        self._start_token(self.other, 'dave-start')
        self._running(self.other, token='dave-live')
        with mock.patch.object(lap, 'send_start') as send:
            self.assertEqual(lap.push_start_to_absent(self.round), 0)
        send.assert_not_called()

    def test_nobody_holding_a_token_costs_no_push(self):
        with mock.patch.object(lap, 'send_start') as send:
            self.assertEqual(lap.push_start_to_absent(self.round), 0)
        send.assert_not_called()


class StartPayloadTests(ConsoleBackendMixin, TestCase):
    """The three fields that make a start push land, each of which fails
    silently on the phone rather than loudly at Apple."""

    def _aps(self):
        return lap._apns_start_payload({'kind': 'sixes'}, round_id=7,
                                       course_name='Pebble')['aps']

    def test_the_event_is_a_start(self):
        self.assertEqual(self._aps()['event'], 'start')

    def test_the_attributes_type_names_the_swift_struct(self):
        """Apple matches this string against the ActivityAttributes conformer.
        A mismatch is accepted by APNs and dropped on the phone."""
        self.assertEqual(self._aps()['attributes-type'],
                         'SixesActivityAttributes')

    def test_the_attributes_carry_what_request_would_have_been_given(self):
        self.assertEqual(self._aps()['attributes'],
                         {'roundId': 7, 'courseName': 'Pebble'})

    def test_an_alert_rides_along(self):
        """A start push raises UI with the app not running, so iOS insists on
        something it could show; without it Apple rejects the push."""
        self.assertIn('alert', self._aps())
