"""
api/test_sixes_extra_teams.py
-----------------------------
The extra match — the one segment whose pairings are DRAWN rather than derived.

Reported from a round on 28 Sep 2026: three extra holes were played and the
watcher's lock screen never moved off the close-out hole. Two faults, and the
endpoint had no tests at all.
"""
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from games.models import SixesSegment

User = get_user_model()


class SixesExtraTeamsTests(TestCase):

    def setUp(self):
        from scoring.tests._helpers import (make_foursome, make_round,
                                            make_tee, submit_hole)
        from services.sixes import setup_sixes

        self.submit_hole = submit_hole
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.active_games = ['sixes']
        self.round.primary_game = 'sixes'
        self.round.save(update_fields=['active_games', 'primary_game'])
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
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        paul = self.fs.memberships.get(player__name='Paul').player
        paul.user = self.user
        paul.save(update_fields=['user'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    # -- helpers ---------------------------------------------------------

    def _play(self, hole, t1, t2):
        from services.sixes import calculate_sixes
        self.submit_hole(self.fs, hole, [
            (self.pid['Paul'], t1), (self.pid['Dave'], t1),
            (self.pid['Sam'],  t2), (self.pid['Lee'],  t2)])
        calculate_sixes(self.fs)

    def _run_to_an_extra(self):
        """Team 1 wins every hole, so each match closes out at four and the
        tail becomes an extra — exactly how a round ends up with extra holes
        to play."""
        for h in range(1, 15):
            self._play(h, 4, 5)
        return (SixesSegment.objects
                .filter(foursome=self.fs, is_extra=True)
                .order_by('-segment_number').first())

    def _url(self):
        return reverse('api-sixes-extra-teams', args=[self.fs.id])

    def _draw(self):
        return self.client.post(self._url(), {
            'team1_player_ids': [self.pid['Paul'], self.pid['Sam']],
            'team2_player_ids': [self.pid['Dave'], self.pid['Lee']],
        }, format='json')

    # -- the extra exists before anybody draws it ------------------------

    def test_an_early_close_out_creates_an_extra_with_no_teams(self):
        extra = self._run_to_an_extra()
        self.assertIsNotNone(extra, 'the tail holes must become an extra match')
        self.assertEqual(extra.teams.count(), 0)

    # -- fault 1: the board must not read as a live match ----------------

    def test_an_undrawn_extra_says_so_rather_than_reading_all_square(self):
        """`ALL SQ` between two empty names, with a count that never moves,
        is a card a watcher reads as broken. There is no match yet, and the
        card says that instead."""
        from services.live_activity import sixes_activity_state
        self._run_to_an_extra()
        s = sixes_activity_state(self.fs, player_id=self.pid['Paul'], thru=14)
        self.assertEqual(s['number']['text'], '—')
        self.assertEqual(s['state']['to_play'], 'TEAMS NOT SET')
        self.assertEqual([x['names'] for x in s['sides']],
                         ['Waiting on the draw'])

    def test_drawing_the_teams_brings_the_board_back(self):
        from services.live_activity import sixes_activity_state
        self._run_to_an_extra()
        self.assertEqual(self._draw().status_code, 200)
        s = sixes_activity_state(self.fs, player_id=self.pid['Paul'], thru=14)
        self.assertNotEqual(s['state']['to_play'], 'TEAMS NOT SET')
        self.assertEqual([x['names'] for x in s['sides']],
                         ['P & S', 'D & L'])

    def test_the_extra_then_scores_the_holes_it_already_had(self):
        """The holes played before the draw are not lost — they score the
        moment the sides exist."""
        from services.sixes import sixes_summary
        extra = self._run_to_an_extra()
        start = extra.start_hole
        self._play(start, 4, 5)              # played while still undrawn
        self._draw()
        seg = next(s for s in sixes_summary(self.fs)['segments']
                   if s['is_extra'])
        self.assertTrue(seg['holes'],
                        'the hole played before the draw must still count')

    # -- fault 2: the draw is a change the card must show ----------------

    def test_drawing_the_teams_pushes_the_lock_screen(self):
        """Not every change a card must show is a score. A group usually gets
        to the draw on the last hole, and when they do there is no next score
        to carry it — so without this push the extra match never reaches a
        single lock screen."""
        self._run_to_an_extra()
        with mock.patch('api.views._push_lock_screen') as push:
            self.assertEqual(self._draw().status_code, 200)
        push.assert_called_once()
        self.assertEqual(push.call_args.args[0].id, self.round.id)

    def test_a_second_draw_cannot_overwrite_the_first(self):
        self._run_to_an_extra()
        self.assertEqual(self._draw().status_code, 200)
        again = self._draw()
        self.assertEqual(again.status_code, 404)
