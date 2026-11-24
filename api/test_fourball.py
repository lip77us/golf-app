"""
api/test_fourball.py
--------------------
Fourball setup/result endpoints: the 2v2 team config round-trips through the
serializer/view/urls. (The scoring engine itself is covered by
scoring/tests/test_fourball.py.)
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class FourballEndpointTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Fourball Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['fourball'], bet_unit=Decimal('3.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('A', 'B', 'C', 'D')
        ]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.ids = [p.id for p in self.players]

    def _body(self, **over):
        body = {
            'handicap_mode': 'net', 'net_percent': 100,
            'team1_player_ids': self.ids[:2], 'team2_player_ids': self.ids[2:],
        }
        body.update(over)
        return body

    def test_setup_creates_teams_and_returns_summary(self):
        resp = self.client.post(
            reverse('api-fourball-setup', args=[self.fs.id]),
            self._body(handicap_mode='strokes_off', net_percent=90),
            format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['handicap']['mode'], 'strokes_off')
        self.assertEqual(resp.data['handicap']['net_percent'], 90)
        self.assertEqual({pid for pid in resp.data['team1']['player_ids']},
                         set(self.ids[:2]))
        # bet_amount inherits the round bet_unit when omitted.
        self.assertEqual(resp.data['money']['bet_amount'], 3.0)

    def test_overlapping_teams_rejected(self):
        resp = self.client.post(
            reverse('api-fourball-setup', args=[self.fs.id]),
            self._body(team2_player_ids=[self.ids[1], self.ids[2]]),
            format='json')
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_result_404_before_setup(self):
        resp = self.client.get(reverse('api-fourball-result', args=[self.fs.id]))
        self.assertEqual(resp.status_code, 404)

    def test_result_round_trips_after_setup(self):
        self.client.post(reverse('api-fourball-setup', args=[self.fs.id]),
                         self._body(), format='json')
        resp = self.client.get(reverse('api-fourball-result', args=[self.fs.id]))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'pending')
        self.assertEqual(resp.data['result_label'], '—')


class PairMatchEndpointTests(FourballEndpointTests):
    """Two-man scramble / alternate shot ride the Fourball endpoints."""

    def test_scramble_setup_round_trips_and_reports_its_slug(self):
        self.round.active_games = ['scramble_match']
        self.round.save(update_fields=['active_games'])
        url = reverse('api-fourball-setup', args=[self.fs.id])
        r = self.client.post(url, self._body(
            handicap_mode='net', ball_format='scramble', allowance_pct=40),
            format='json')
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.data['ball_format'], 'scramble')
        self.assertEqual(r.data['game_slug'], 'scramble_match')
        self.assertEqual(r.data['allowance_pct'], 40)

    def test_alternate_shot_first_tee_round_trips(self):
        self.round.active_games = ['alternate_shot_match']
        self.round.save(update_fields=['active_games'])
        r = self.client.post(
            reverse('api-fourball-setup', args=[self.fs.id]),
            self._body(ball_format='alternate_shot',
                       team1_first_tee=self.ids[1]), format='json')
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.data['first_tee']['1'], self.ids[1])

    def test_configured_games_reports_the_format_slug_not_fourball(self):
        self.round.active_games = ['scramble_match']
        self.round.save(update_fields=['active_games'])
        self.client.post(
            reverse('api-fourball-setup', args=[self.fs.id]),
            self._body(ball_format='scramble'), format='json')
        from api.serializers import FoursomeSerializer
        data = FoursomeSerializer(self.fs).data
        self.assertIn('scramble_match', data['configured_games'])
        self.assertNotIn('fourball', data['configured_games'])


class PairMatchDriveAndWatchTests(FourballEndpointTests):
    def _setup_scramble(self, **extra):
        self.round.active_games = ['scramble_match']
        self.round.save(update_fields=['active_games'])
        return self.client.post(
            reverse('api-fourball-setup', args=[self.fs.id]),
            self._body(ball_format='scramble', **extra), format='json')

    def test_a_drive_pick_round_trips_through_the_card(self):
        r = self._setup_scramble(drive_rule='per_nine', drives_required=1)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.data['drive_rule'], 'per_nine')
        r = self.client.post(
            reverse('api-fourball-drive', args=[self.fs.id]),
            {'team': 1, 'hole': 1, 'player_id': self.ids[0]}, format='json')
        self.assertEqual(r.status_code, 200, r.content)
        side = r.data['fourball_hole']['drive']['sides'][0]
        self.assertEqual(side['picked'], self.ids[0])

    def test_the_other_sides_golfer_is_a_400(self):
        self._setup_scramble(drive_rule='per_nine')
        r = self.client.post(
            reverse('api-fourball-drive', args=[self.fs.id]),
            {'team': 1, 'hole': 1, 'player_id': self.ids[2]}, format='json')
        self.assertEqual(r.status_code, 400)

    def test_no_quota_no_drive_endpoint(self):
        self._setup_scramble()
        r = self.client.post(
            reverse('api-fourball-drive', args=[self.fs.id]),
            {'team': 1, 'hole': 1, 'player_id': self.ids[0]}, format='json')
        self.assertEqual(r.status_code, 400)

    def test_the_watch_page_carries_a_tab_named_for_the_game(self):
        from api.watch_views import _fourball_tab_label, _has_casual_fourball
        self.round.active_games = ['alternate_shot_match']
        self.assertTrue(_has_casual_fourball(self.round))
        self.assertEqual(_fourball_tab_label(self.round), 'Alternate Shot')

    def test_the_watch_page_renders_and_names_the_game(self):
        self._setup_scramble()
        from django.test import Client
        body = Client().get(
            f'/watch/{self.round.watch_token}/?view=fourball').content.decode()
        self.assertIn('Two-man Scramble', body)
