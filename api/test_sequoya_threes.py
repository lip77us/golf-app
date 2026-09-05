"""
api/test_sequoya_threes.py
--------------------------
Sequoya 3s over the wire.

The rules the service owns are asserted HERE too, because the packet's
non-negotiable is that a press cannot contradict the match it sits inside —
and a rule enforced only in the UI is not enforced.
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


class SequoyaThreesEndpointTests(TestCase):

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course,
                                active_games=['sequoya_threes'])
        self.round.bet_unit     = Decimal('5.00')
        self.round.primary_game = 'sequoya_threes'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

        self.user = User.objects.create_user(
            username='td', account=self.round.account, is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _setup(self, **kw):
        body = {'side1_player_ids': [self.pid['Ann'], self.pid['Ben']],
                'handicap_mode': 'gross', 'bet_amount': '5.00',
                'press_mode': 'manual_auto'}
        body.update(kw)
        return self.client.post(
            reverse('api-sequoya-threes-setup', args=[self.fs.id]),
            body, format='json')

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a), (self.pid['Ben'], b),
                                    (self.pid['Cal'], c), (self.pid['Dee'], d)])

    def _get(self):
        return self.client.get(
            reverse('api-sequoya-threes', args=[self.fs.id]))

    # -- setup ---------------------------------------------------------------

    def test_setup_returns_six_matches(self):
        resp = self._setup()
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(len(resp.data['matches']), 6)

    def test_only_match_one_is_chosen_the_rest_derive(self):
        resp = self._setup()
        m = resp.data['matches']
        self.assertEqual({p['player_id'] for p in m[0]['side1']},
                         {self.pid['Ann'], self.pid['Ben']})
        # 4-6 repeat 1-3 — the repeat is the format.
        for i in (0, 1, 2):
            self.assertEqual({p['player_id'] for p in m[i]['side1']},
                             {p['player_id'] for p in m[i + 3]['side1']})

    def test_it_refuses_a_pairing_from_outside_the_group(self):
        resp = self._setup(side1_player_ids=[self.pid['Ann'], 999999])
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_a_group_that_is_not_four_is_refused(self):
        """Six 2v2 matches have no other shape."""
        three = make_foursome(self.round,
                              [('X', 0), ('Y', 0), ('Z', 0)], tee=self.tee,
                              group_number=2)
        pids = [m.player_id for m in three.memberships.all()][:2]
        resp = self.client.post(
            reverse('api-sequoya-threes-setup', args=[three.id]),
            {'side1_player_ids': pids}, format='json')
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_result_before_setup_is_404(self):
        self.assertEqual(self._get().status_code, 404)

    # -- the press, over the wire -------------------------------------------

    def _press(self, **kw):
        body = {'match_index': 1, 'side': 2}
        body.update(kw)
        return self.client.post(
            reverse('api-sequoya-threes-press', args=[self.fs.id]),
            body, format='json')

    def test_a_press_covers_the_hole_being_played(self):
        self._setup()
        self._play(1, 4, 4, 5, 5)
        resp = self._press(current_hole=2, called_by_id=self.pid['Cal'])
        self.assertEqual(resp.status_code, 201, resp.data)
        manual = [b for b in resp.data['matches'][0]['bets']
                  if b['kind'] == 'manual_press'][0]
        self.assertEqual(manual['holes'], [2, 3])
        self.assertEqual(manual['called_by'], 'Cal')

    def test_the_last_hole_of_a_match_can_be_pressed(self):
        """Reported from the course: two down on the 9th tee, no press on
        offer. The next hole belongs to the next match, so a press that
        started there could never be called on a match's last hole."""
        self._setup()
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)
        resp = self._press(current_hole=3, called_by_id=self.pid['Cal'])
        self.assertEqual(resp.status_code, 201, resp.data)
        manual = [b for b in resp.data['matches'][0]['bets']
                  if b['kind'] == 'manual_press'][0]
        self.assertEqual(manual['holes'], [3])

    def test_the_first_hole_of_a_match_cannot_be_pressed(self):
        self._setup()
        self.assertEqual(self._press(current_hole=1).status_code, 400)

    def test_the_side_that_is_up_cannot_press(self):
        self._setup()
        self._play(1, 4, 4, 5, 5)          # Ann/Ben 1 up
        resp = self._press(side=1, current_hole=2)
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_a_second_hand_called_press_is_refused(self):
        self._setup()
        self._play(1, 4, 4, 5, 5)
        self.assertEqual(self._press(current_hole=2).status_code, 201)
        self.assertEqual(self._press(current_hole=3).status_code, 400)

    def test_presses_are_refused_when_the_round_is_not_playing_them(self):
        self._setup(press_mode='none')
        self._play(1, 4, 4, 5, 5)
        self.assertEqual(self._press(current_hole=2).status_code, 400)

    # -- the money -----------------------------------------------------------

    def test_the_summary_money_is_zero_sum_and_settles(self):
        self._setup(press_mode='none')
        for h in (1, 2):
            self._play(h, 4, 4, 5, 5)
        data = self._get().data
        self.assertAlmostEqual(sum(p['money'] for p in data['players']), 0,
                               places=2)
        self.assertEqual(len(data['transfers']), 2)

    def test_the_leaderboard_carries_the_game(self):
        self._setup()
        self._play(1, 4, 4, 5, 5)
        from api.views import _build_leaderboard
        games = _build_leaderboard(self.round)
        self.assertIn('sequoya_threes', games)
        self.assertEqual(
            len(games['sequoya_threes']['by_group'][0]['summary']['matches']),
            6)

    def test_another_accounts_foursome_is_not_reachable(self):
        other = Account.objects.create(name='Somebody Else')
        intruder = User.objects.create_user(
            username='them', account=other, is_account_admin=True)
        self.client.force_authenticate(intruder)
        self.assertEqual(self._setup().status_code, 404)
