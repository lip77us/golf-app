"""
api/test_better_ball.py
-----------------------
The Better Ball setup / result endpoints round-trip through the
serializer / view / urls. (The scoring and the money are covered by
scoring/tests/test_better_ball.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from games.models import BetterBallConfig, IrishRumbleConfig
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Better Ball Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['better_ball'])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        for n in ('A', 'B', 'C', 'D'):
            p = Player.objects.create(account=self.acct, name=n,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _setup_url(self):
        return reverse('api-better-ball-setup', args=[self.round.id])

    def _post(self, **over):
        body = {'balls_to_count': 2, 'handicap_mode': 'net',
                'entry_fee': '10.00', 'payouts': []}
        body.update(over)
        return self.client.post(self._setup_url(), body, format='json')


class SetupTests(_Base):

    def test_an_unconfigured_round_answers_with_the_defaults_it_would_use(self):
        """The screen has to READ BACK a choice the TD has not made yet, so
        the `Auto` tags show a real value rather than a blank waiting on a
        save."""
        resp = self.client.get(self._setup_url())
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertFalse(resp.data['configured'])
        self.assertEqual(resp.data['balls_to_count'], 2)
        self.assertEqual(resp.data['name'], 'Best 2 of 4')
        self.assertTrue(resp.data['name_is_auto'])
        self.assertEqual(resp.data['net_percent'], 85)

    def test_the_get_carries_every_count_so_the_stepper_never_waits(self):
        """Four strings and four integers is not a thing to build a request
        for — the field renames on the tap."""
        resp = self.client.get(self._setup_url())
        self.assertEqual(resp.data['names_by_count'][1], 'Better Ball')
        self.assertEqual(resp.data['names_by_count'][4], 'Aggregate')
        self.assertEqual(resp.data['allowance_by_count'][1], 75)
        self.assertEqual(resp.data['allowance_by_count'][4], 100)

    def test_posting_creates_the_config_and_echoes_it(self):
        resp = self._post(balls_to_count=3)
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertTrue(resp.data['configured'])
        self.assertEqual(resp.data['balls_to_count'], 3)
        self.assertEqual(resp.data['name'], 'Best 3 of 4')
        self.assertEqual(resp.data['net_percent'], 95)
        self.assertTrue(
            BetterBallConfig.objects.filter(round=self.round).exists())

    def test_an_omitted_allowance_follows_the_count(self):
        self.assertEqual(self._post(balls_to_count=1).data['net_percent'], 75)

    def test_a_posted_allowance_pins_it_and_both_numbers_come_back(self):
        """The readback says `Set by you — 90% instead of the recommended
        75% at this count`, which needs both."""
        resp = self._post(balls_to_count=1, net_percent=90)
        self.assertEqual(resp.data['net_percent'], 90)
        self.assertEqual(resp.data['recommended_net_percent'], 75)

    def test_a_typed_name_is_kept_and_flagged_as_the_tds(self):
        resp = self._post(name='Saturday Sweep')
        self.assertEqual(resp.data['name'], 'Saturday Sweep')
        self.assertFalse(resp.data['name_is_auto'])

    def test_clearing_the_name_hands_it_back_to_the_count(self):
        """`allow_blank` is what makes this reachable — without it a cleared
        field would read as 'no change'."""
        self._post(name='Saturday Sweep')
        resp = self._post(name='', balls_to_count=4)
        self.assertEqual(resp.data['name'], 'Aggregate')
        self.assertTrue(resp.data['name_is_auto'])

    def test_the_count_is_refused_outside_one_to_four(self):
        self.assertEqual(self._post(balls_to_count=5).status_code, 400)
        self.assertEqual(self._post(balls_to_count=0).status_code, 400)

    def test_a_second_post_updates_rather_than_duplicating(self):
        self._post(balls_to_count=2)
        self._post(balls_to_count=4)
        self.assertEqual(
            BetterBallConfig.objects.filter(round=self.round).count(), 1)
        self.assertEqual(
            BetterBallConfig.objects.get(round=self.round).balls_to_count, 4)

    def test_another_accounts_round_is_not_found(self):
        other = Account.objects.create(name='Someone Else')
        intruder = User.objects.create_user(username='x', account=other)
        self.client.force_authenticate(intruder)
        self.assertEqual(self._post().status_code, 404)


class ExclusionTests(_Base):
    """One round runs one of them, and the endpoint says which is in the way
    rather than failing with a stack trace."""

    def _rumble(self):
        return IrishRumbleConfig.objects.create(
            round=self.round, variant='classic', segments=[
                {'start_hole': 1, 'end_hole': 18, 'balls_to_count': 1}])

    def test_better_ball_is_refused_on_a_rumble_round(self):
        self._rumble()
        resp = self._post()
        self.assertEqual(resp.status_code, 400)
        self.assertIn('Irish Rumble', resp.data['detail'])
        self.assertFalse(
            BetterBallConfig.objects.filter(round=self.round).exists())

    def test_rumble_is_refused_on_a_better_ball_round(self):
        self._post()
        resp = self.client.post(
            reverse('api-irish-rumble-setup', args=[self.round.id]),
            {'handicap_mode': 'net', 'net_percent': 100,
             'entry_fee': '0.00', 'payouts': [], 'variant': 'classic'},
            format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('Better Ball', resp.data['detail'])
        self.assertFalse(
            IrishRumbleConfig.objects.filter(round=self.round).exists())

    def test_the_get_says_the_other_game_is_there_before_a_save_fails(self):
        """The screen can close the controls and say why, instead of letting
        the TD fill a form that cannot be saved."""
        self._rumble()
        resp = self.client.get(self._setup_url())
        self.assertTrue(resp.data['irish_rumble_configured'])


class ResultTests(_Base):

    def _score(self, hole, scores):
        from scoring.models import HoleScore
        members = list(self.fs.memberships.select_related('player')
                       .order_by('player__name'))
        for m, gross in zip(members, scores):
            HoleScore.objects.create(
                foursome=self.fs, player=m.player, hole_number=hole,
                gross_score=gross)

    def test_the_board_comes_back_ranked(self):
        self._post(balls_to_count=2, handicap_mode='gross')
        self._score(1, [4, 4, 6, 6])
        resp = self.client.get(
            reverse('api-better-ball-result', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertTrue(resp.data['configured'])
        row = resp.data['overall'][0]
        self.assertEqual(row['rank'], 1)
        self.assertEqual(row['total_score'], 8)

    def test_an_unconfigured_round_says_so_rather_than_inventing_a_board(self):
        resp = self.client.get(
            reverse('api-better-ball-result', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data['configured'])
        self.assertEqual(resp.data['overall'], [])


class RoundSerializerTests(_Base):

    def test_the_balls_plan_answers_for_better_ball_too(self):
        """The shipped client reads `ir_balls_config` for the score-entry
        banner. The two games are exclusive, so there is one answer and no
        reason to make every installed phone learn a second key."""
        self._post(balls_to_count=3)
        resp = self.client.get(reverse('api-round-detail',
                                       args=[self.round.id]))
        self.assertEqual(resp.data['ir_balls_config'],
                         [{'start_hole': 1, 'end_hole': 18,
                           'balls_to_count': 3}])

    def test_a_configured_better_ball_reports_as_configured(self):
        """Better Ball persists no result rows, so the config itself is what
        says the TD has set it up."""
        self._post()
        resp = self.client.get(reverse('api-round-detail',
                                       args=[self.round.id]))
        fs = resp.data['foursomes'][0]
        self.assertIn('better_ball', fs['configured_games'])
