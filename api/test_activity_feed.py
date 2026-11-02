"""The operator's Slack feed: signups, rounds started, rounds finished."""
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from services import activity_feed
from tournament.models import Foursome, FoursomeMembership, Round

URL = 'https://hooks.slack.example/T/B/secret'


def _run_inline(fn, *, label=''):
    fn()
    return False


@override_settings(SLACK_ACTIVITY_WEBHOOK_URL=URL)
class ActivityFeedBase(TestCase):
    def setUp(self):
        p = patch('services.activity_feed.run_off_request', side_effect=_run_inline)
        p.start()
        self.addCleanup(p.stop)
        p = patch('services.activity_feed.httpx.post')
        self.post = p.start()
        self.addCleanup(p.stop)
        self.api = APIClient()

    def texts(self):
        return [c.kwargs['json']['text'] for c in self.post.call_args_list]


class SignupTests(ActivityFeedBase):
    def _verify(self, phone, **extra):
        with patch('accounts.otp.PhoneOTP.check_code', return_value=True), \
                self.captureOnCommitCallbacks(execute=True):
            return self.api.post('/api/auth/otp/verify/',
                                 {'phone': phone, 'code': '123456', **extra},
                                 format='json')

    def test_a_new_account_is_announced_without_its_phone(self):
        self.assertEqual(self._verify('4155550123', name='Jim <B>').status_code, 200)
        user = get_user_model().objects.get(username='+14155550123')
        self.assertEqual(len(self.texts()), 1)
        self.assertEqual(self.texts()[0], '\n'.join([
            ':wave: New Halved account', 'Name: Jim &lt;B&gt;',
            f'User: {user.id}', 'Device: unknown']))
        self.assertNotIn('555', self.texts()[0])

    def test_the_client_states_its_device(self):
        self._verify('4155550123', platform='ios')
        self.assertIn('Device: iOS', self.texts()[0])

    def test_a_push_token_names_the_device_on_an_older_build(self):
        body = self._verify('4155550123').json()
        from accounts.models import DeviceToken
        user = get_user_model().objects.get(username=body['username'])
        DeviceToken.objects.create(user=user, token='t', platform='android')
        self.post.reset_mock()
        with self.captureOnCommitCallbacks(execute=True):
            activity_feed.user_registered(user)
        self.assertIn('Device: Android', self.texts()[0])

    def test_nonsense_platform_is_not_believed(self):
        self._verify('4155550123', platform='<x>')
        self.assertIn('Device: unknown', self.texts()[0])

    def test_a_returning_golfer_is_not(self):
        self._verify('4155550123')
        self.post.reset_mock()
        self._verify('4155550123')
        self.assertEqual(self.texts(), [])

    def test_no_name_says_so_and_profile_setup_supplies_it(self):
        body = self._verify('4155550123').json()
        self.assertIn('Name: not given', self.texts()[0])
        self.post.reset_mock()
        self.api.credentials(HTTP_AUTHORIZATION=f"Token {body['token']}")
        with self.captureOnCommitCallbacks(execute=True):
            r = self.api.patch(f"/api/players/{body['player']['id']}/",
                               {'name': 'Jim Reid', 'email': 'jim@example.com'}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertIn('Name: Jim Reid', self.texts()[0])
        self.assertNotIn('jim@example.com', self.texts()[0])

    def test_the_log_carries_no_phone(self):
        with self.assertNoLogs('services.activity_feed', 'INFO'):
            self._verify('4155550123')


class RoundTests(ActivityFeedBase):
    def setUp(self):
        super().setUp()
        self.account = Account.objects.create(name='Feed Golf')
        self.user = get_user_model().objects.create_user(
            username='feed', account=self.account, is_account_admin=True)
        self.api.credentials(
            HTTP_AUTHORIZATION=f'Token {Token.objects.create(user=self.user).key}')
        course = Course.objects.create(account=self.account, name='Tilden Park')
        holes = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
                 for n in range(1, 19)]
        tee = Tee.objects.create(course=course, tee_name='White', slope=113,
                                 course_rating=Decimal('72.0'), par=72, holes=holes)
        self.round = Round.objects.create(
            account=self.account, course=course, status='in_progress',
            active_games=['skins', 'low_net_round'], primary_game='low_net_round')
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = []
        for name in ('Paul', 'Jim'):
            p = Player.objects.create(account=self.account, name=name,
                                      handicap_index=Decimal('5.0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=tee,
                course_handicap=5, playing_handicap=5)
            self.players.append(p)
        self.players[0].user = self.user
        self.players[0].save()
        self.round.created_by = self.players[0]
        self.round.save()
        # A guest whose phone, formatted, matches a real login is On Halved.
        get_user_model().objects.create_user(
            username='jim', account=Account.objects.create(name='Jim Golf'),
            phone='+14155550199')
        self.players[1].phone = '(415) 555-0199'
        self.players[1].save()
        guest = Player.objects.create(account=self.account, name='Guest',
                                      handicap_index=Decimal('5.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=guest, tee=tee,
            course_handicap=5, playing_handicap=5)
        self.players.append(guest)

    def _post(self, hole, gross=4):
        with self.captureOnCommitCallbacks(execute=True):
            r = self.api.post(f'/api/foursomes/{self.fs.id}/scores/', {
                'hole_number': hole,
                'scores': [{'player_id': p.id, 'gross_score': gross}
                           for p in self.players],
            }, format='json')
        self.assertEqual(r.status_code, 200, r.content)

    @override_settings(PUBLIC_BASE_URL='https://link.example/')
    def test_only_the_first_score_announces_the_start(self):
        self._post(1)
        self._post(2)
        self.assertEqual(len(self.texts()), 1)
        self.assertEqual(
            self.texts()[0],
            '\n'.join([
                ':golf: Round started', 'Name: Paul', 'Course: Tilden Park',
                'Games: Stroke Play, Skins',
                'Players: 3 (2 on Halved, 1 not)',
                'Golfers: Paul, Jim, Guest',
                f'Watch: https://link.example/watch/{self.round.watch_token}/']))

    def test_completing_announces_once(self):
        for _ in range(2):
            with self.captureOnCommitCallbacks(execute=True):
                self.api.post(f'/api/rounds/{self.round.id}/complete/', {}, format='json')
        self.assertEqual(len(self.texts()), 1)
        self.assertIn('Round finished', self.texts()[0])
        self.assertNotIn('Watch:', self.texts()[0])

    def test_a_failed_post_does_not_touch_the_score(self):
        self.post.side_effect = RuntimeError('boom')
        self._post(1)

    @override_settings(SLACK_ACTIVITY_WEBHOOK_URL='')
    def test_unset_is_off(self):
        self._post(1)
        self.assertEqual(self.texts(), [])


class FailureLogTests(TestCase):
    def test_the_log_never_carries_the_webhook(self):
        with patch('services.activity_feed.httpx.post',
                   side_effect=RuntimeError(URL)), \
                self.assertLogs('services.activity_feed', 'WARNING') as logs:
            activity_feed._deliver(URL, 'x')
        self.assertNotIn('secret', ''.join(logs.output))
