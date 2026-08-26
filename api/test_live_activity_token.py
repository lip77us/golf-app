"""
api/test_live_activity_token.py
-------------------------------
The Live Activity token endpoint
(docs/design-review/handoff-sixes-lock/SPEC.md).

The row is a mailbox for one golfer's activity on one round.  iOS may reissue
the token mid-round, so the interesting behaviour is that a second POST
*replaces* rather than appends — a duplicate would mean pushing the same board
twice, once to an address that no longer resolves.
"""
import os
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import (Foursome, FoursomeMembership, LiveActivityToken,
                               Round)

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class LiveActivityTokenTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Sixes Club')
        course = Course.objects.create(account=self.acct, name='Pebble')
        tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['sixes'], bet_unit=Decimal('1.00'))
        fs = Foursome.objects.create(round=self.round, group_number=1)

        self.user = User.objects.create_user(username='dune',
                                             account=self.acct)
        player = Player.objects.create(account=self.acct, name='Dune',
                                       handicap_index=Decimal('10'),
                                       user=self.user)
        FoursomeMembership.objects.create(
            foursome=fs, player=player, tee=tee,
            course_handicap=10, playing_handicap=10)

        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-round-live-activity-token',
                           args=[self.round.id])

    def _post(self, token):
        return self.client.post(self.url, {'token': token}, format='json')

    # -- registering ------------------------------------------------------

    def test_post_stores_the_token(self):
        resp = self._post('abc123')
        self.assertEqual(resp.status_code, 200, resp.data)
        row = LiveActivityToken.objects.get(round=self.round, user=self.user)
        self.assertEqual(row.token, 'abc123')

    def test_reissued_token_replaces_rather_than_appends(self):
        """iOS can hand out a new token mid-round.  Pushing to the old one
        after that is a request into the void, so the row must move."""
        self._post('first')
        self._post('second')
        rows = LiveActivityToken.objects.filter(round=self.round,
                                                user=self.user)
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows.first().token, 'second')

    def test_empty_token_is_rejected(self):
        resp = self._post('   ')
        self.assertEqual(resp.status_code, 400)
        self.assertFalse(LiveActivityToken.objects.exists())

    # -- ending -----------------------------------------------------------

    def test_delete_clears_it(self):
        self._post('abc123')
        resp = self.client.delete(self.url)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertFalse(LiveActivityToken.objects.exists())

    def test_delete_with_nothing_registered_is_fine(self):
        """The app calls this on every round sign, whether or not an activity
        ever started."""
        self.assertEqual(self.client.delete(self.url).status_code, 200)

    # -- access -----------------------------------------------------------

    def test_a_stranger_cannot_register_against_the_round(self):
        """Same-account users are readers by design — that is how the
        leaderboard works.  The stranger is someone from another club."""
        elsewhere = Account.objects.create(name='Another Club')
        other = User.objects.create_user(username='nobody', account=elsewhere)
        self.client.force_authenticate(other)
        self.assertNotEqual(self._post('abc123').status_code, 200)
        self.assertFalse(LiveActivityToken.objects.exists())

    def test_two_golfers_hold_separate_rows(self):
        """All four run their own activity — the money line differs."""
        self._post('dune-token')
        mate = User.objects.create_user(username='slate', account=self.acct)
        player = Player.objects.create(account=self.acct, name='Slate',
                                       handicap_index=Decimal('8'),
                                       user=mate)
        FoursomeMembership.objects.create(
            foursome=self.round.foursomes.first(), player=player,
            tee=Tee.objects.first(), course_handicap=8, playing_handicap=8)
        self.client.force_authenticate(mate)
        self._post('slate-token')
        self.assertEqual(
            LiveActivityToken.objects.filter(round=self.round).count(), 2)


class LiveActivityStateTests(TestCase):
    """The opening and closing frames the app fetches
    (docs/design-review/handoff-sixes-lock/SPEC.md)."""

    def setUp(self):
        from scoring.tests._helpers import (make_foursome, make_round,
                                            make_tee, submit_hole)
        from services.sixes import setup_sixes

        self.submit_hole = submit_hole
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.active_games = ['sixes']
        self.round.save(update_fields=['active_games'])
        self.fs = make_foursome(
            self.round,
            [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        base = {'team_select_method': 'long_drive',
                'team1_player_ids': [self.pid['Paul'], self.pid['Dave']],
                'team2_player_ids': [self.pid['Sam'], self.pid['Lee']]}
        setup_sixes(self.fs, [
            {**base, 'start_hole':  1, 'end_hole':  6},
            {**base, 'start_hole':  7, 'end_hole': 12},
            {**base, 'start_hole': 13, 'end_hole': 18},
        ], handicap_mode='gross')

        acct = self.round.account
        self.user = User.objects.create_user(username='paul', account=acct)
        paul = self.fs.memberships.get(player__name='Paul').player
        paul.user = self.user
        paul.save(update_fields=['user'])

        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-round-live-activity-state',
                           args=[self.round.id])
        on = mock.patch.dict(os.environ, {'LIVE_ACTIVITY_ENABLED': '1'})
        on.start()
        self.addCleanup(on.stop)

    def _play(self, hole, t1, t2):
        self.submit_hole(self.fs, hole, [
            (self.pid['Paul'], t1), (self.pid['Dave'], t1),
            (self.pid['Sam'],  t2), (self.pid['Lee'],  t2),
        ])

    def test_returns_the_five_slots_once_a_hole_is_in(self):
        self._play(1, 4, 5)
        resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200, resp.data)
        state = resp.data['state']
        self.assertEqual(
            set(state), {'kind', 'header', 'number', 'sides', 'state', 'pips',
                         'final', 'footer'})
        self.assertEqual(state['kind'], 'sixes')
        self.assertEqual(resp.data['course_name'], self.tee.course.name)

    def test_thru_is_the_group_not_the_leader(self):
        """A card reads 'thru 7' when the GROUP is through 7 — one golfer
        running ahead does not move it."""
        self._play(1, 4, 5)
        self._play(2, 4, 5)
        self.submit_hole(self.fs, 3, [(self.pid['Paul'], 4)])
        self.assertIn('Thru 2', self.client.get(self.url).data['state']
                                    ['footer']['context'])

    def test_final_frame_is_the_personal_one(self):
        for h in range(1, 19):
            self._play(h, 4, 5)
        resp = self.client.get(self.url, {'final': '1'})
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertIsNotNone(resp.data['state']['final'])

    def test_a_round_with_no_sixes_returns_nothing(self):
        """The app treats {} as 'don't start', so eligibility is decided here
        rather than in the client."""
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        self.fs.active_games = []
        self.fs.save(update_fields=['active_games'])
        self._play(1, 4, 5)
        self.assertEqual(self.client.get(self.url).data, {})

    def test_the_board_is_valid_before_a_ball_is_struck(self):
        """The endpoint does not gate on play — it answers with the board as it
        stands.  WHEN the activity starts is the app's decision (first score
        posted), which also lets it restart cleanly after an app kill."""
        state = self.client.get(self.url).data['state']
        self.assertEqual(state['number']['text'], 'ALL SQ')
        self.assertEqual(state['state']['to_play'], '6 TO PLAY')

    def test_a_watcher_gets_the_board_without_a_money_line(self):
        elsewhere = Account.objects.create(name='Watcher Club')
        watcher = User.objects.create_user(username='watch', account=elsewhere,
                                           phone='+13105550101')
        from tournament.models import Watcher
        Watcher.objects.create(round=self.round, phone='+13105550101')
        self._play(1, 4, 5)
        self.client.force_authenticate(watcher)
        resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertFalse(resp.data['state']['footer']['money'])


class StateIsDarkWhenOffTests(TestCase):
    """The switch gates the CLIENT, not only delivery.

    Off has to mean no phone raises an activity in the first place.  Gating
    only the sender would leave boards frozen wherever one had already gone
    up, which reads as broken rather than absent.
    """

    def test_the_state_endpoint_says_nothing_while_off(self):
        from scoring.tests._helpers import make_foursome, make_round, make_tee
        from services.sixes import setup_sixes

        tee = make_tee()
        rnd = make_round(tee.course)
        rnd.active_games = ['sixes']
        rnd.save(update_fields=['active_games'])
        fs = make_foursome(rnd, [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=tee)
        pid = [m.player_id for m in fs.memberships.all()]
        setup_sixes(fs, [{'team_select_method': 'long_drive',
                          'team1_player_ids': pid[:2],
                          'team2_player_ids': pid[2:],
                          'start_hole': 1, 'end_hole': 6}],
                    handicap_mode='gross')

        user = User.objects.create_user(username='td', account=rnd.account)
        user.is_account_admin = True
        user.save(update_fields=['is_account_admin'])
        client = APIClient()
        client.force_authenticate(user)
        url = reverse('api-round-live-activity-state', args=[rnd.id])

        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(client.get(url).data, {})
        with mock.patch.dict(os.environ, {'LIVE_ACTIVITY_ENABLED': '1'}):
            self.assertIn('state', client.get(url).data)


class OwnershipTests(TestCase):
    """One activity per round, owned by the primary game named at setup.

    There is nothing to arbitrate at runtime — the group already answered it.
    A game with no card, or a side game, gets no activity at all.
    """

    def setUp(self):
        from scoring.tests._helpers import (make_foursome, make_round,
                                            make_tee, submit_hole)
        from services.sixes import setup_sixes

        tee = make_tee()
        self.round = make_round(tee.course)
        self.fs = make_foursome(
            self.round, [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=tee)
        pid = [m.player_id for m in self.fs.memberships.all()]
        setup_sixes(self.fs, [{'team_select_method': 'long_drive',
                               'team1_player_ids': pid[:2],
                               'team2_player_ids': pid[2:],
                               'start_hole': 1, 'end_hole': 6}],
                    handicap_mode='gross')
        submit_hole(self.fs, 1, [(p, 4) for p in pid])
        self.user = User.objects.create_user(username='td',
                                             account=self.round.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])

    def _state(self):
        from services.live_activity_registry import activity_state
        return activity_state(self.round, self.user)

    def _set(self, primary, active):
        self.round.primary_game = primary
        self.round.active_games = active
        self.round.save(update_fields=['primary_game', 'active_games'])
        self.fs.active_games = []
        self.fs.save(update_fields=['active_games'])

    def test_the_primary_game_owns_the_card(self):
        self._set('sixes', ['sixes', 'skins'])
        self.assertEqual(self._state()['kind'], 'sixes')

    def test_a_side_game_never_gets_one(self):
        """Sixes running alongside a primary with no card gets nothing — the
        pick at setup decides, not which game happens to have a builder."""
        self._set('stableford', ['stableford', 'sixes'])
        self.assertEqual(self._state(), {})

    def test_a_game_with_no_card_gets_nothing(self):
        self._set('wolf', ['wolf'])
        self.assertEqual(self._state(), {})

    def test_a_legacy_round_falls_back_to_the_active_set(self):
        """primary_game is null on tournament and legacy rounds, where the set
        was never an explicit pick."""
        self._set(None, ['sixes'])
        self.assertEqual(self._state()['kind'], 'sixes')
