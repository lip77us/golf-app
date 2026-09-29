"""
api/test_road_trip.py
---------------------
Road Trip at the edges: the setup endpoint and the board.

The engine is tested in `scoring/tests/test_road_trip.py`; what is here is
what the wiring decides on its own — above all that turning the trip on takes
the championship it replaces OFF, which is a rule about the tournament and so
has to hold wherever a tournament is edited from.
"""
from decimal import Decimal

from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import User
from games.models import RoadTripConfig
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament,
)


class _Base(TestCase):
    def setUp(self):
        self.course = make_course('Links 1')
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tourn = make_tournament(
            name='Ireland', total_rounds=3, rounds_to_count=2,
            active_games=['low_net'])
        self.ann = make_player('Ann', handicap_index=Decimal('0.0'))
        for i in (1, 2, 3):
            r = make_round(course=self.course, tournament=self.tourn,
                           round_number=i)
            make_foursome(r, [(self.ann, 0)], tee=self.tee)

        self.account = self.course.account
        self.user = User.objects.create_user(
            username='td', password='x', account=self.account,
            is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def url(self, suffix=''):
        return f'/api/tournaments/{self.tourn.id}/road-trip/{suffix}'


class SetupTests(_Base):
    def test_the_defaults_are_both_titles_and_updated_indexes(self):
        r = self.client.get(self.url('setup/'))
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data['configured'])
        self.assertTrue(r.data['net_on'])
        self.assertTrue(r.data['gross_on'])
        self.assertEqual(r.data['handicap_mode'], 'updated')
        # Net capped, gross not — they are different competitions.
        self.assertTrue(r.data['net_max_double_bogey'])
        self.assertFalse(r.data['gross_max_double_bogey'])
        # n and m come from the TOURNAMENT, not from the trip.
        self.assertEqual(r.data['counting_rule'], 'Best 2 of 3')

    def test_turning_it_on_takes_the_championship_it_replaces_OFF(self):
        # A trip is its own best-m-of-n competition. Leaving the stroke-play
        # championship on would rank the same golfers by a different rule on
        # the board beside it.
        r = self.client.post(self.url('setup/'), {}, format='json')
        self.assertEqual(r.status_code, 201)
        self.tourn.refresh_from_db()
        self.assertIn('road_trip', self.tourn.active_games)
        self.assertNotIn('low_net', self.tourn.active_games)

    def test_a_trip_with_no_title_is_refused(self):
        r = self.client.post(self.url('setup/'),
                             {'net_on': False, 'gross_on': False},
                             format='json')
        self.assertEqual(r.status_code, 400)
        self.assertFalse(RoadTripConfig.objects.filter(
            tournament=self.tourn).exists())

    def test_the_settings_round_trip(self):
        r = self.client.post(self.url('setup/'), {
            'net_on': True, 'gross_on': False,
            'handicap_mode': 'locked',
            'net_max_double_bogey': False,
            'gross_max_double_bogey': True}, format='json')
        self.assertEqual(r.status_code, 201)
        got = self.client.get(self.url('setup/')).data
        self.assertTrue(got['configured'])
        self.assertFalse(got['gross_on'])
        self.assertEqual(got['handicap_mode'], 'locked')
        self.assertFalse(got['net_max_double_bogey'])

    def test_delete_turns_the_FORMAT_off(self):
        self.client.post(self.url('setup/'), {}, format='json')
        r = self.client.delete(self.url('setup/'))
        self.assertEqual(r.status_code, 204)
        self.tourn.refresh_from_db()
        self.assertNotIn('road_trip', self.tourn.active_games)
        self.assertFalse(RoadTripConfig.objects.filter(
            tournament=self.tourn).exists())

    def test_another_account_cannot_reach_it(self):
        from accounts.models import Account
        other = Account.objects.create(name='Other')
        u = User.objects.create_user(username='x', password='x', account=other)
        c = APIClient(); c.force_authenticate(u)
        self.assertEqual(c.get(self.url('setup/')).status_code, 404)


class ResultTests(_Base):
    def test_the_board_carries_both_titles_and_its_rounds(self):
        self.client.post(self.url('setup/'), {}, format='json')
        r = self.client.get(self.url())
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['titles'], ['net', 'gross'])
        self.assertEqual(len(r.data['rounds']), 3)
        self.assertEqual(r.data['counts'], 2)
        self.assertIn('net', r.data)
        self.assertIn('gross', r.data)

    def test_an_unconfigured_tournament_reports_nothing(self):
        self.assertEqual(self.client.get(self.url()).data, {})
