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


class LeaderboardTests(_Base):
    """The trip's block on the tournament board."""

    def test_the_board_carries_the_trip_and_drops_the_championship(self):
        self.client.post(self.url('setup/'), {}, format='json')
        data = self.client.get(
            f'/api/tournaments/{self.tourn.id}/leaderboard/').data
        self.assertIn('road_trip', data['active_games'])
        self.assertIn('road_trip', data['games'])
        self.assertEqual(data['games']['road_trip']['label'], 'Road Trip')
        # The board it replaced is gone, not sitting beside it ranking the
        # same golfers by a different rule.
        self.assertNotIn('low_net', data['games'])

    def test_an_unconfigured_trip_draws_no_block(self):
        # The marker without the config is a game configured by not being
        # configured — the tab would be empty. `road_trip_summary` returns
        # nothing and the block is absent, which is the honest state.
        self.tourn.active_games = ['road_trip']
        self.tourn.save()
        data = self.client.get(
            f'/api/tournaments/{self.tourn.id}/leaderboard/').data
        self.assertNotIn('road_trip', data['games'])


class FieldGamesTests(_Base):
    """The organiser's games for one round — editable until it closes."""

    def setUp(self):
        super().setUp()
        self.round = self.tourn.rounds.order_by('round_number').first()

    def url_fg(self, r=None):
        return f'/api/rounds/{(r or self.round).id}/field-games/'

    def test_setting_them_writes_the_round_s_list(self):
        r = self.client.post(self.url_fg(),
                             {'games': ['irish_rumble', 'forty_balls']},
                             format='json')
        self.assertEqual(r.status_code, 200)
        self.round.refresh_from_db()
        self.assertEqual(self.round.active_games,
                         ['irish_rumble', 'forty_balls'])

    def test_a_group_s_OWN_games_are_left_alone(self):
        # This endpoint speaks for the organiser. Skins is the group's, set
        # and settled by the group, and must survive a field-game edit.
        self.round.active_games = ['skins', 'irish_rumble']
        self.round.save()
        r = self.client.post(self.url_fg(), {'games': ['forty_balls']},
                             format='json')
        self.assertEqual(r.status_code, 200)
        self.round.refresh_from_db()
        self.assertIn('skins', self.round.active_games)
        self.assertIn('forty_balls', self.round.active_games)
        self.assertNotIn('irish_rumble', self.round.active_games)

    def test_a_COMPLETE_round_refuses(self):
        from core.models import RoundStatus
        self.round.status = RoundStatus.COMPLETE
        self.round.save()
        r = self.client.post(self.url_fg(), {'games': ['irish_rumble']},
                             format='json')
        self.assertEqual(r.status_code, 409)
        self.assertIn('final', r.data['detail'])

    def test_a_round_IN_PROGRESS_still_accepts(self):
        # The packet's rule: any time before or during the round. A game added
        # mid-round is scored from hole 1 off the scores already entered.
        r = self.client.post(self.url_fg(), {'games': ['irish_rumble']},
                             format='json')
        self.assertEqual(r.status_code, 200)

    def test_only_a_FIELD_game_is_accepted(self):
        r = self.client.post(self.url_fg(), {'games': ['skins']},
                             format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('Not a field game', r.data['detail'])

    def test_the_group_is_told_what_changed(self):
        from tournament.models import Message
        self.client.post(self.url_fg(), {'games': ['irish_rumble']},
                         format='json')
        bodies = [m.body for m in Message.objects.all()]
        self.assertTrue(any('Irish Rumble' in b for b in bodies), bodies)
        self.assertTrue(any('added' in b for b in bodies), bodies)

    def test_no_change_says_nothing(self):
        from tournament.models import Message
        self.round.active_games = ['irish_rumble']
        self.round.save()
        self.client.post(self.url_fg(), {'games': ['irish_rumble']},
                         format='json')
        self.assertEqual(Message.objects.count(), 0)


class HandicapTests(_Base):
    """The trip's indexes, and the organiser's manual adjustment."""

    def setUp(self):
        super().setUp()
        self.client.post(self.url('setup/'), {}, format='json')

    def url_h(self):
        return self.url('handicaps/')

    def test_it_lists_the_field_and_where_an_adjustment_would_start(self):
        r = self.client.get(self.url_h())
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['handicap_mode'], 'updated')
        self.assertEqual([g['name'] for g in r.data['golfers']], ['Ann'])
        self.assertEqual(r.data['next_round']['round_number'], 1)

    def test_a_reason_is_REQUIRED(self):
        r = self.client.post(self.url_h(), {
            'player_id': self.ann.id, 'handicap_index': 5.0, 'reason': '  '},
            format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('reason is required', r.data['detail'])

    def test_it_applies_from_the_next_UNPLAYED_round(self):
        from scoring.tests._helpers import submit_hole
        from scoring.tests._helpers import DEFAULT_HOLES
        r1 = self.tourn.rounds.order_by('round_number').first()
        submit_hole(r1.foursomes.first(), 1, [(self.ann.id, 4)])
        r = self.client.post(self.url_h(), {
            'player_id': self.ann.id, 'handicap_index': 5.0,
            'reason': 'Four net rounds under par'}, format='json')
        self.assertEqual(r.status_code, 201)
        adj = r.data['golfers'][0]['adjustment']
        # Round 1 has a score on it, so the change starts at round 2 — the
        # card already signed for is not rewritten.
        self.assertEqual(adj['from_round'], 2)
        self.assertEqual(adj['reason'], 'Four net rounds under par')

    def test_it_reaches_the_rounds_it_governs(self):
        # An adjustment is not a note. The engine reads the MEMBERSHIP, so the
        # number has to be on the round before the round is scored.
        self.client.post(self.url_h(), {
            'player_id': self.ann.id, 'handicap_index': 10.0,
            'reason': 'Playing off too low'}, format='json')
        m = (self.tourn.rounds.order_by('round_number').last()
             .foursomes.first().memberships.first())
        m.refresh_from_db()
        self.assertEqual(m.playing_handicap_override, 10)
        self.assertEqual(m.playing_handicap, 10)

    def test_a_round_already_PLAYED_keeps_the_handicap_it_was_scored_with(self):
        # The packet's firmest rule, and the one an organiser is trusted on:
        # nothing a golfer has signed for moves under him. Round 1 has a score
        # on it, so its membership must be exactly as it was.
        from scoring.tests._helpers import submit_hole
        r1 = self.tourn.rounds.order_by('round_number').first()
        submit_hole(r1.foursomes.first(), 1, [(self.ann.id, 4)])
        m1 = r1.foursomes.first().memberships.first()
        before_override = m1.playing_handicap_override
        before_playing  = m1.playing_handicap

        self.client.post(self.url_h(), {
            'player_id': self.ann.id, 'handicap_index': 18.0,
            'reason': 'Way off'}, format='json')

        m1.refresh_from_db()
        self.assertEqual(m1.playing_handicap_override, before_override)
        self.assertEqual(m1.playing_handicap, before_playing)
        # And the rounds ahead of it DID move.
        m2 = (self.tourn.rounds.order_by('round_number')[1]
              .foursomes.first().memberships.first())
        self.assertEqual(m2.playing_handicap_override, 18)

    def test_a_moving_ROSTER_index_does_not_rewrite_a_played_round(self):
        # The case the unplayed-only guard is actually for. In `updated` mode
        # the trip follows the roster — and on a trip whose own rounds feed
        # the index, the roster moves mid-trip. A later write must not carry
        # the new number back onto a round already scored on the old one.
        from scoring.tests._helpers import submit_hole
        from services.road_trip import apply_indexes
        r1 = self.tourn.rounds.order_by('round_number').first()
        submit_hole(r1.foursomes.first(), 1, [(self.ann.id, 4)])
        m1 = r1.foursomes.first().memberships.first()
        # Setting the trip up stamped every round with the index of the day —
        # they were all unplayed then, and that is the right moment for it.
        before_playing  = m1.playing_handicap
        before_override = m1.playing_handicap_override

        self.ann.handicap_index = Decimal('18.0')
        self.ann.save()
        self.tourn.refresh_from_db()
        apply_indexes(self.tourn)

        m1.refresh_from_db()
        self.assertEqual(m1.playing_handicap, before_playing)
        self.assertEqual(m1.playing_handicap_override, before_override)
        # The rounds ahead DID pick the new index up.
        m2 = (self.tourn.rounds.order_by('round_number')[1]
              .foursomes.first().memberships.first())
        self.assertEqual(m2.playing_handicap_override, 18)

    def test_a_trip_with_every_round_played_has_nothing_to_adjust(self):
        from core.models import RoundStatus
        from scoring.tests._helpers import submit_hole
        for r in self.tourn.rounds.all():
            submit_hole(r.foursomes.first(), 1, [(self.ann.id, 4)])
        r = self.client.post(self.url_h(), {
            'player_id': self.ann.id, 'handicap_index': 5.0,
            'reason': 'too late'}, format='json')
        self.assertEqual(r.status_code, 409)


class LockedIndexTests(_Base):
    """`locked` has to hold a number, or it is a label on nothing."""

    def test_setting_up_a_locked_trip_records_what_everybody_started_on(self):
        self.client.post(self.url('setup/'), {'handicap_mode': 'locked'},
                         format='json')
        from games.models import RoadTripConfig
        cfg = RoadTripConfig.objects.get(tournament=self.tourn)
        self.assertEqual(cfg.starting_indexes[str(self.ann.id)], '0.0')

    def test_a_locked_index_does_not_follow_the_roster(self):
        from services.road_trip import index_for
        self.client.post(self.url('setup/'), {'handicap_mode': 'locked'},
                         format='json')
        # His roster index moves mid-trip — on a trip whose own rounds feed
        # the index, it moves BECAUSE of the trip.
        self.ann.handicap_index = Decimal('6.0')
        self.ann.save()
        self.tourn.refresh_from_db()
        self.assertEqual(index_for(self.tourn, self.ann, 3), Decimal('0.0'))

    def test_updated_mode_DOES_follow_it(self):
        from services.road_trip import index_for
        self.client.post(self.url('setup/'), {}, format='json')
        self.ann.handicap_index = Decimal('6.0')
        self.ann.save()
        self.tourn.refresh_from_db()
        self.assertEqual(index_for(self.tourn, self.ann, 3), Decimal('6.0'))

    def test_an_adjustment_outranks_a_locked_index(self):
        # The packet is explicit that a manual change is available in EITHER
        # mode. A locked trip ignoring the organiser's own ruling would be
        # locking him out.
        from services.road_trip import index_for
        self.client.post(self.url('setup/'), {'handicap_mode': 'locked'},
                         format='json')
        self.client.post(self.url('handicaps/'), {
            'player_id': self.ann.id, 'handicap_index': 4.0,
            'reason': 'Scratch is generous'}, format='json')
        self.tourn.refresh_from_db()
        self.assertEqual(index_for(self.tourn, self.ann, 2), Decimal('4.0'))

    def test_resaving_the_setup_does_not_relock_a_drifted_index(self):
        self.client.post(self.url('setup/'), {'handicap_mode': 'locked'},
                         format='json')
        self.ann.handicap_index = Decimal('9.9')
        self.ann.save()
        self.client.post(self.url('setup/'), {'handicap_mode': 'locked'},
                         format='json')
        from games.models import RoadTripConfig
        cfg = RoadTripConfig.objects.get(tournament=self.tourn)
        self.assertEqual(cfg.starting_indexes[str(self.ann.id)], '0.0')
