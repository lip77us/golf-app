"""
api/test_handicap_override.py
-----------------------------
Forcing a playing handicap over the wire (`PATCH /api/foursomes/{id}/tees/`).

The endpoint that reassigns tees is also the one that recomputes handicaps from
the index, so it is the one place an override can be silently undone. That is
what most of this file is about.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from scoring.tests._helpers import (make_foursome, make_round, make_tee,
                                    submit_hole)

User = get_user_model()


class HandicapOverrideEndpointTests(TestCase):

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['low_net_round'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(self.round, [('Paul', 12), ('Sam', 20)],
                                tee=self.tee)
        self.m = {m.player.name: m
                  for m in self.fs.memberships.select_related('player')}
        self.pid = {n: m.player_id for n, m in self.m.items()}

        self.user = User.objects.create_user(
            username='td', account=self.round.account, is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _url(self):
        return reverse('api-foursome-tees', args=[self.fs.id])

    def _set(self, name, value):
        return self.client.patch(
            self._url(),
            {'handicaps': [{'player_id': self.pid[name],
                            'playing_handicap_override': value}]},
            format='json')

    def _reload(self, name):
        m = self.m[name]
        m.refresh_from_db()
        return m

    # -- setting it ----------------------------------------------------------

    def test_it_sets_the_forced_handicap_and_the_displayed_figures(self):
        resp = self._set('Paul', 17)
        self.assertEqual(resp.status_code, 200, resp.data)
        m = self._reload('Paul')
        self.assertEqual(m.playing_handicap_override, 17)
        # Displayed CH and PH follow it, so the hub cannot show one number
        # while the golfer plays off another.
        self.assertEqual(m.playing_handicap, 17)
        self.assertEqual(m.course_handicap, 17)

    def test_it_touches_nobody_else(self):
        before = self._reload('Sam').playing_handicap
        self._set('Paul', 17)
        sam = self._reload('Sam')
        self.assertIsNone(sam.playing_handicap_override)
        self.assertEqual(sam.playing_handicap, before)

    def test_the_roster_index_is_untouched(self):
        before = self.m['Paul'].player.handicap_index
        self._set('Paul', 30)
        self.m['Paul'].player.refresh_from_db()
        self.assertEqual(self.m['Paul'].player.handicap_index, before)

    def test_zero_is_a_real_forced_handicap(self):
        self._set('Paul', 0)
        self.assertEqual(self._reload('Paul').playing_handicap_override, 0)

    def test_null_clears_it_and_recomputes(self):
        self._set('Paul', 17)
        self._set('Paul', None)
        m = self._reload('Paul')
        self.assertIsNone(m.playing_handicap_override)
        self.assertEqual(m.course_handicap, m.player.course_handicap(m.tee))

    def test_a_non_numeric_handicap_is_refused(self):
        resp = self._set('Paul', 'scratch')
        self.assertEqual(resp.status_code, 400, resp.data)
        self.assertIsNone(self._reload('Paul').playing_handicap_override)

    # -- the way it would die unnoticed --------------------------------------

    def test_a_tee_change_in_the_same_request_does_not_wipe_it(self):
        """The tee loop recomputes course_handicap from the index. An override
        set in the same breath must survive it."""
        resp = self.client.patch(
            self._url(),
            {'tees'     : [{'player_id': self.pid['Paul'],
                            'tee_id': self.tee.id}],
             'handicaps': [{'player_id': self.pid['Paul'],
                            'playing_handicap_override': 17}]},
            format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        m = self._reload('Paul')
        self.assertEqual(m.playing_handicap_override, 17)
        self.assertEqual(m.playing_handicap, 17)

    def test_a_later_tee_change_does_not_wipe_it_either(self):
        self._set('Paul', 17)
        resp = self.client.patch(
            self._url(),
            {'tees': [{'player_id': self.pid['Paul'], 'tee_id': self.tee.id}]},
            format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        m = self._reload('Paul')
        self.assertEqual(m.playing_handicap_override, 17)
        self.assertEqual(m.playing_handicap, 17)

    # -- the gate ------------------------------------------------------------

    def test_it_is_accepted_inside_the_edit_ceiling_and_rescores(self):
        """Same threshold as a tee change, and for the same reason — but the
        threshold moved. Inside the first three holes it re-nets the holes
        already played rather than refusing, because a forced handicap typed
        from the wrong line of a club sheet is exactly the setup mistake the
        window exists for."""
        from scoring.models import HoleScore
        submit_hole(self.fs, 1, [(self.pid['Paul'], 4), (self.pid['Sam'], 5)])
        # Hole 1 is stroke index 7, so Paul off 12 gets a stroke on it. Forced
        # down to 5 he does not — 12 -> 17 would have left the row alone, which
        # is a real answer but not a test of the rescore.
        self.assertEqual(
            HoleScore.objects.get(foursome=self.fs, player_id=self.pid['Paul'],
                                  hole_number=1).handicap_strokes, 1)
        resp = self._set('Paul', 5)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(self._reload('Paul').playing_handicap_override, 5)
        self.assertEqual(resp.data['holes_rescored'], 1)

        hs = HoleScore.objects.get(foursome=self.fs,
                                   player_id=self.pid['Paul'], hole_number=1)
        self.assertEqual(hs.handicap_strokes, 0)
        self.assertEqual(hs.net_score, 4)        # derived on save, not written

    def test_it_is_refused_past_the_ceiling(self):
        for h in range(1, 5):
            submit_hole(self.fs, h, [(self.pid['Paul'], 4),
                                     (self.pid['Sam'], 5)])
        resp = self._set('Paul', 17)
        self.assertEqual(resp.status_code, 400, resp.data)
        self.assertIsNone(self._reload('Paul').playing_handicap_override)

    def test_another_accounts_foursome_is_not_reachable(self):
        other = Account.objects.create(name='Somebody Else')
        intruder = User.objects.create_user(
            username='them', account=other, is_account_admin=True)
        self.client.force_authenticate(intruder)
        self.assertEqual(self._set('Paul', 17).status_code, 404)
