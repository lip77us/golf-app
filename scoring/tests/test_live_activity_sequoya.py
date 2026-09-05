"""
scoring/tests/test_live_activity_sequoya.py
-------------------------------------------
The Sequoya 3s lock screen
(docs/design-review/handoff-sequoya-threes/live-activity-sequoya-threes.html).

Weighted towards the three things this card does that the Sixes card it copies
does not: **the header names the match being played**, **the press rides in the
footer with the money**, and **the state word is only ever true of the
position**.
"""
from decimal import Decimal

from django.test import TestCase

from games.models import SequoyaThreesGame
from services.live_activity_registry import UNSHIPPED_KINDS, card_kind
from services.live_activity_sequoya import (sequoya_activity_state,
                                            sequoya_final_state)
from services.sequoya_threes import call_press, setup_sequoya_threes
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class SequoyaCardTests(TestCase):
    """Four golfers, gross, $5 a man. Ann is the reader unless said."""

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
        setup_sequoya_threes(
            self.fs, [self.pid['Ann'], self.pid['Ben']],
            handicap_mode='gross', bet_amount=5,
            press_mode=SequoyaThreesGame.PRESS_MANUAL_AUTO)

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a), (self.pid['Ben'], b),
                                    (self.pid['Cal'], c), (self.pid['Dee'], d)])

    def _card(self, who='Ann'):
        return sequoya_activity_state(self.fs, player_id=self.pid[who])

    # -- the header names the match ------------------------------------------

    def test_the_header_names_the_match_being_played(self):
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 4, 4)
        self._play(3, 4, 4, 4, 4)
        self.assertEqual(self._card()['header']['game'],
                         'SEQUOYA 3s · MATCH 2')

    def test_the_locked_corner_carries_the_hole_the_reader_stands_on(self):
        self._play(1, 4, 4, 5, 5)
        self.assertTrue(self._card()['header']['segment'].startswith('HOLE 2'))

    def test_the_lower_corner_says_tee_off_before_a_hole_is_finished(self):
        self.assertEqual(self._card()['thru'], 'TEE OFF')

    # -- the state word is only ever true ------------------------------------

    def test_one_up_with_two_to_play_is_not_dormie(self):
        """A state word that is not true of the position is worse than none."""
        self._play(1, 4, 4, 5, 5)
        c = self._card()
        self.assertEqual(c['number']['text'], '1 UP')
        self.assertEqual(c['state']['word'], '—')
        self.assertEqual(c['state']['to_play'], '2 TO PLAY')

    def test_dormie_when_the_lead_equals_the_holes_left(self):
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 4, 4)
        c = self._card()
        self.assertEqual(c['state']['word'], 'DORMIE')
        self.assertEqual(c['state']['to_play'], '1 TO PLAY')

    def test_a_closed_match_puts_the_margin_in_the_headline(self):
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)
        c = self._card()
        self.assertEqual(c['number']['text'], '2 & 1')
        self.assertEqual(c['state']['word'], 'CLOSED')
        self.assertEqual(c['state']['to_play'], 'MATCH BET')

    # -- the sides are the MATCH's, and rotate -------------------------------

    def test_the_sides_are_this_match_not_the_round(self):
        """The pairing rotates every third hole, so a colour belongs to a side
        of a match rather than to a golfer for the round."""
        self._play(1, 4, 4, 5, 5)
        first = self._card()['sides'][0]['names']
        for h in (2, 3):
            self._play(h, 4, 4, 4, 4)
        self.assertNotEqual(self._card()['sides'][0]['names'], first)

    # -- the press rides in the footer ---------------------------------------

    def test_the_footer_names_the_auto_press_beside_the_stake(self):
        """Money that has silently appeared is worse than no money at all, so
        the cause is printed with the effect."""
        self._play(1, 4, 4, 5, 5)          # opens the auto press over 2-3
        self.assertEqual(self._card()['footer']['context'],
                         '$10 a man · + AUTO PRESS')

    def test_a_hand_called_press_shows_in_the_footer_too(self):
        self._play(1, 4, 4, 4, 4)          # halved, so no auto press
        self._play(2, 5, 5, 4, 4)          # Cal/Dee 1 up
        call_press(self.fs, match_index=1, side=1,
                   called_by_id=self.pid['Ann'], current_hole=3)
        self.assertIn('+ PRESS', self._card()['footer']['context'])

    def test_the_stake_counts_every_bet_in_the_match(self):
        self.assertEqual(self._card()['footer']['context'], '$5 a man')

    def test_money_is_the_readers_own_and_empty_until_it_settles(self):
        self.assertEqual(self._card()['footer']['money'], '')
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)
        self._play(3, 4, 4, 5, 5)
        self.assertTrue(self._card()['footer']['money'].startswith('+$'))

    def test_an_observer_gets_the_same_card_without_the_money(self):
        """The three rows name both pairs and never say `you`, so an observer
        reads the identical composition minus the personal slots."""
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)
        self._play(3, 4, 4, 5, 5)
        watcher = sequoya_activity_state(self.fs, player_id=None)
        mine    = self._card()
        self.assertEqual(watcher['sides'], mine['sides'])
        self.assertEqual(watcher['number'], mine['number'])
        self.assertEqual(watcher['footer']['money'], '')

    # -- the final frame answers the format's own question -------------------

    def test_the_final_frame_names_the_partner_who_carried_you(self):
        """You played every other golfer twice, so this round has an answer to
        *who* — which no other game in the app produces."""
        self._play(1, 4, 4, 5, 5)
        self._play(2, 4, 4, 5, 5)
        f = sequoya_final_state(self.fs, player_id=self.pid['Ann'])['final']
        self.assertIn('best with', f['detail'])

    # -- and it does not reach a phone that cannot draw it --------------------

    def test_the_card_is_held_until_a_build_can_draw_it(self):
        """A kind enters this set with its builder and leaves with its build.
        Starting an activity the installed app cannot render turns `no board`
        into a lock-screen nag pointing at an update that does not exist."""
        self.assertIn(card_kind('sequoya_threes'), UNSHIPPED_KINDS)
