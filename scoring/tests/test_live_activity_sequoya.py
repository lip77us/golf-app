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
import re
from decimal import Decimal
from pathlib import Path

from django.conf import settings
from django.test import TestCase

from core.models import HandicapMode
from games.models import SequoyaThreesGame
from services.live_activity_registry import (UNSHIPPED_KINDS, card_kind,
                                             round_has_board)
from services.live_activity_sequoya import (sequoya_activity_state,
                                            sequoya_final_state)
from services.sequoya_threes import call_press, setup_sequoya_threes
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class SequoyaCardTests(TestCase):
    """Four golfers, gross, $5 a golfer. Ann is the reader unless said."""

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
                         '$10 a golfer · + AUTO PRESS')

    def test_a_hand_called_press_shows_in_the_footer_too(self):
        self._play(1, 4, 4, 4, 4)          # halved, so no auto press
        self._play(2, 5, 5, 4, 4)          # Cal/Dee 1 up
        call_press(self.fs, match_index=1, side=1,
                   called_by_id=self.pid['Ann'], current_hole=3)
        self.assertIn('+ PRESS', self._card()['footer']['context'])

    def test_the_stake_counts_every_bet_in_the_match(self):
        self.assertEqual(self._card()['footer']['context'], '$5 a golfer')

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

    # -- and it reaches a phone that can draw it ------------------------------

    def test_the_card_ships_now_that_a_build_draws_it(self):
        """A kind enters `UNSHIPPED_KINDS` with its builder and leaves with its
        build — 2.8.1+32 is the one carrying this layout, so the gate is off.
        The assertion is kept rather than deleted because the failure it guards
        against is silent: starting an activity the installed app cannot render
        turns `no board` into a lock-screen nag pointing at an update that does
        not exist."""
        self.assertNotIn(card_kind('sequoya_threes'), UNSHIPPED_KINDS)

    def test_the_ios_build_declares_the_kind_the_server_now_sends(self):
        """The other half of that gate, and the half no Python test would
        otherwise reach: the server may only send a kind the Swift knows how to
        draw. `sequoya` has no layout of its own — it renders with `BoardView`
        — so the client side of shipping it is one string in `known`, which is
        exactly the kind of thing that gets forgotten."""
        swift = (Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
                 / 'SixesActivityLiveActivity.swift').read_text()
        known = re.search(r'static let known: Set<String> = \[(.*?)\]',
                          swift, re.S).group(1)
        self.assertIn('"sequoya"', known)

    def test_the_round_now_reports_that_it_has_a_board(self):
        """The gate's whole effect was that this game answered "no board" to
        every caller; with it off, a Sequoya round has one."""
        self.assertTrue(round_has_board(self.round))


class SequoyaStrokeRibbonTests(TestCase):
    """The gold band, and the reader it belongs to.

    Ann plays off 4 in Strokes Off against three scratch golfers, so she pops
    on stroke indexes 1–4 — holes 5, 14, 2 and 11 on the test card. Two of
    those matter here: hole 2 falls inside match 1, hole 11 inside match 4, so
    the ribbon has to keep firing after the pairings have rotated twice.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course,
                                active_games=['sequoya_threes'])
        self.round.bet_unit     = Decimal('5.00')
        self.round.primary_game = 'sequoya_threes'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 4), ('Ben', 0), ('Cal', 0), ('Dee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_sequoya_threes(
            self.fs, [self.pid['Ann'], self.pid['Ben']],
            handicap_mode=HandicapMode.STROKES_OFF, bet_amount=5,
            press_mode=SequoyaThreesGame.PRESS_AUTO)

    def _play(self, hole, a=4, b=4, c=4, d=4):
        submit_hole(self.fs, hole, [(self.pid['Ann'], a), (self.pid['Ben'], b),
                                    (self.pid['Cal'], c), (self.pid['Dee'], d)])

    def _ribbon(self, who='Ann'):
        return sequoya_activity_state(
            self.fs, player_id=self.pid[who])['ribbon']

    def test_the_ribbon_fires_on_the_hole_about_to_be_played(self):
        """Hole 2 is stroke index 3, so Ann is told BEFORE she plays it — which
        is the only moment the news is worth anything."""
        self._play(1)
        self.assertEqual(self._ribbon(), 'POPPING ON HOLE 2')

    def test_the_hole_in_play_is_unscored_so_the_plan_is_read_not_derived(self):
        """Hole 1 is the hole in play before a ball is struck and it carries no
        stroke for Ann. A ribbon derived from played holes could not answer
        either way, which is why it comes off the allocator."""
        self.assertEqual(self._ribbon(), '')

    def test_it_keeps_firing_after_the_pairings_have_rotated(self):
        """Hole 11 is stroke index 4 and sits in match 4 — the ribbon belongs
        to the golfer and the card, not to the match being played."""
        for h in range(1, 11):
            self._play(h)
        self.assertEqual(self._ribbon(), 'POPPING ON HOLE 11')

    def test_a_scratch_partner_is_told_nothing(self):
        self._play(1)
        self.assertEqual(self._ribbon('Ben'), '')

    def test_a_watcher_never_pops(self):
        """A watcher is not playing, so no hole strokes for him — and the card
        he reads is otherwise the same one."""
        self._play(1)
        self.assertEqual(
            sequoya_activity_state(self.fs, player_id=None)['ribbon'], '')

    def test_it_goes_quiet_once_the_round_is_over(self):
        """Running states only. The hole number is clamped at 18, so a stroke
        on 18 would keep popping under a header that already says ROUND
        COMPLETE — Ann is moved to 6 here precisely so that hole (index 6)
        carries one and the guard has something to suppress."""
        m = self.fs.memberships.get(player_id=self.pid['Ann'])
        m.playing_handicap = 6
        m.save(update_fields=['playing_handicap'])
        for h in range(1, 19):
            self._play(h)
        card = sequoya_activity_state(self.fs, player_id=self.pid['Ann'])
        self.assertEqual(card['header']['segment'], 'ROUND COMPLETE')
        self.assertEqual(card['ribbon'], '')

    def test_the_shared_board_draws_the_ribbon_the_server_now_sends(self):
        """The half no Python test would otherwise reach, and the failure it
        guards is silent: Sequoya renders with `BoardView`, and only
        `SurvivorBoardView` drew the band. The server would send POPPING ON
        HOLE 11 and the phone would show nothing — exactly the bug the
        Survivor ribbon already shipped once."""
        swift = (Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
                 / 'SixesActivityLiveActivity.swift').read_text()
        board = swift.split('private struct BoardView')[1]
        board = board.split('private struct')[0]
        self.assertIn('StrokeRibbon(text: ribbon)', board)

    def test_gross_scoring_has_no_strokes_to_announce(self):
        setup_sequoya_threes(
            self.fs, [self.pid['Ann'], self.pid['Ben']],
            handicap_mode=HandicapMode.GROSS, bet_amount=5,
            press_mode=SequoyaThreesGame.PRESS_AUTO)
        self._play(1)
        self.assertEqual(self._ribbon(), '')
