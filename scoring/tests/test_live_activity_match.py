"""
scoring/tests/test_live_activity_match.py
-----------------------------------------
The match-play lock screen — singles and fourball
(docs/design-review/handoff-live-activities/match-HANDOFF.md).

Weighted towards the two states the format actually needs and a naive card
gets wrong: **a match that closes early** (the number becomes the result, the
money finally fills, and the header keeps advancing because the group is still
playing golf), and **a round with no stake** (the footer is removed, not
emptied, and gross moves up into the header).

Both games are asserted through the SAME expectations wherever the handoff
says they are identical — that is the test that stops one card becoming two.
"""
from decimal import Decimal

from django.test import TestCase

from services.fourball import setup_fourball, calculate_fourball
from services.live_activity_match import match_activity_state, match_final_state
from services.live_activity_registry import activity_state, primary_game
from services.nassau import HandicapMode, calculate_nassau, setup_nassau
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class SinglesMatchActivityTests(TestCase):
    """A 1-v-1 Singles Match at $20, gross, so the nets are the scores."""

    STAKE = Decimal('20.00')

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit     = self.STAKE
        self.round.active_games = ['match_18']
        self.round.primary_game = 'match_18'
        self.round.save(update_fields=['bet_unit', 'active_games',
                                       'primary_game'])
        self.fs = make_foursome(self.round, [('Paul Kelly', 0), ('Sam Reid', 0)],
                                tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_nassau(self.fs, [self.pid['Paul Kelly']], [self.pid['Sam Reid']],
                     handicap_mode=HandicapMode.GROSS,
                     game_type='match_18')

    def _play(self, hole, paul, sam):
        submit_hole(self.fs, hole, [(self.pid['Paul Kelly'], paul),
                                    (self.pid['Sam Reid'], sam)])
        calculate_nassau(self.fs, game_type='match_18')

    def _state(self, who='Paul Kelly', thru=None):
        return match_activity_state(self.fs, slug='match_18',
                                    player_id=self.pid[who], thru=thru)

    def _win(self, upto, start=1):
        """Paul wins every hole from `start` to `upto`."""
        for h in range(start, upto + 1):
            self._play(h, 4, 5)

    def _halve(self, start, upto):
        for h in range(start, upto + 1):
            self._play(h, 4, 4)

    # ── the ordinary running state ------------------------------------------

    def test_the_header_names_the_game_and_the_hole_being_played(self):
        self._win(3)
        head = self._state()['header']
        self.assertEqual(head['game'], 'SINGLES MATCH')
        self.assertEqual(head['segment'], 'HOLE 4')

    def test_the_big_number_is_the_lead_in_the_leaders_colour(self):
        self._win(3)
        num = self._state()['number']
        self.assertEqual(num['text'], '3 UP')
        self.assertEqual(num['colour'], 'blue')

    def test_all_square_is_neutral_never_mint(self):
        """Mint is the app's colour and cannot name a side."""
        self._halve(1, 4)
        num = self._state()['number']
        self.assertEqual(num['text'], 'ALL SQ')
        self.assertEqual(num['colour'], 'neutral')

    def test_both_sides_are_named_in_full_with_the_leader_flagged(self):
        """Two Pauls in a group is common; initials do not settle it."""
        self._win(2)
        sides = self._state()['sides']
        self.assertEqual([s['names'] for s in sides],
                         ['Paul Kelly', 'Sam Reid'])
        self.assertEqual([s['colour'] for s in sides], ['blue', 'orange'])
        self.assertEqual([s['leading'] for s in sides], [True, False])

    def test_to_play_counts_against_the_eighteen_not_a_segment(self):
        self._halve(1, 5)
        self.assertEqual(self._state()['state']['to_play'], '13 TO PLAY')

    def test_dormie_is_the_lead_equalling_the_holes_left(self):
        # Paul wins 1-5, then eight are halved: 5 up with 5 to play.
        self._win(5)
        self._halve(6, 13)
        state = self._state()['state']
        self.assertEqual(state['word'], 'DORMIE')
        self.assertEqual(state['to_play'], '5 TO PLAY')

    def test_a_lead_that_is_not_dormie_gets_the_dash(self):
        self._win(3)
        self.assertEqual(self._state()['state']['word'], '—')

    # ── the state the format needs: a match that closes early ---------------

    def test_a_match_closing_early_shows_the_result_and_the_hole(self):
        # Paul wins 1-4, halves to the 15th: 4 up with 3 to play.
        self._win(4)
        self._halve(5, 15)
        st = self._state()
        self.assertEqual(st['number']['text'], '4 & 3')
        self.assertEqual(st['number']['colour'], 'blue')
        self.assertEqual(st['state']['word'], 'CLOSED')
        self.assertEqual(st['state']['to_play'], 'ON THE 15TH')

    def test_the_header_keeps_advancing_after_the_match_closes(self):
        """The group is still playing golf and the reader's gross is still
        moving. The card does not freeze and does not dismiss."""
        self._win(4)
        self._halve(5, 15)
        self.assertEqual(self._state()['header']['segment'], 'HOLE 16')
        self._halve(16, 16)
        self.assertEqual(self._state()['header']['segment'], 'HOLE 17')

    def test_the_match_line_never_changes_again_once_closed(self):
        self._win(4)
        self._halve(5, 15)
        closed = self._state()
        self._halve(16, 17)
        later = self._state()
        self.assertEqual(later['number'], closed['number'])
        self.assertEqual(later['state'], closed['state'])

    # ── money -----------------------------------------------------------------

    def test_the_money_slot_is_empty_until_the_match_closes(self):
        """An in-progress match is worth nothing yet, and `$0` reads as a match
        played for nothing. Never render a zero here."""
        self._win(3)
        footer = self._state()['footer']
        self.assertEqual(footer['money'], '')

    def test_the_money_fills_when_the_match_closes(self):
        self._win(4)
        self._halve(5, 15)
        self.assertEqual(self._state(who='Paul Kelly')['footer']['money'], '+$20')

    def test_the_loser_sees_the_same_match_and_his_own_money(self):
        """Everything but the money line is the same string on every phone."""
        self._win(4)
        self._halve(5, 15)
        paul, sam = self._state(who='Paul Kelly'), self._state(who='Sam Reid')
        self.assertEqual(paul['number'], sam['number'])
        self.assertEqual(paul['sides'], sam['sides'])
        self.assertEqual(paul['footer']['money'], '+$20')
        self.assertEqual(sam['footer']['money'], '−$20')

    # ── gross, and the no-stake round -----------------------------------------

    def test_gross_leads_the_footer_with_thru_and_the_stake(self):
        self._play(1, 5, 4)      # Paul +1
        self._play(2, 4, 4)      # level par
        self.assertEqual(self._state()['footer']['context'],
                         '+1 · Thru 2 · $20 match')

    def test_a_no_stake_round_removes_the_footer_and_moves_gross_up(self):
        """Not emptied — removed. A footer whose right edge is permanently
        blank looks like a failed fetch for eighteen holes."""
        self.round.bet_unit = Decimal('0')
        self.round.save(update_fields=['bet_unit'])
        setup_nassau(self.fs, [self.pid['Paul Kelly']], [self.pid['Sam Reid']],
                     handicap_mode=HandicapMode.GROSS, game_type='match_18')
        self._play(1, 5, 4)
        self._play(2, 4, 4)
        st = self._state()
        self.assertEqual(st['footer'], {'context': '', 'money': ''})
        self.assertEqual(st['header']['segment'], 'HOLE 3 · +1 THRU 2')

    def test_gross_is_on_the_card_in_every_state(self):
        """Stake or no stake — it is the one personal figure a neutral board
        can afford, and the number a golfer checks without meaning to."""
        self._play(1, 5, 4)
        staked = self._state()
        self.assertIn('+1', staked['footer']['context'])

        self.round.bet_unit = Decimal('0')
        self.round.save(update_fields=['bet_unit'])
        self.assertIn('+1', self._state()['header']['segment'])

    def test_level_par_reads_as_E_not_plus_zero(self):
        self._play(1, 4, 4)
        self.assertIn('E ·', self._state()['footer']['context'])

    # ── the card never pushes -------------------------------------------------

    def test_this_card_exposes_no_push_builder(self):
        """A deliberate zero, not an oversight: in a two-side match inside one
        group, both sides were within earshot of every putt."""
        import services.live_activity_match as m
        self.assertEqual([n for n in dir(m) if 'push' in n.lower()], [])

    # ── the final state -------------------------------------------------------

    def test_the_final_state_says_what_you_won_and_who_to_see(self):
        self._win(4)
        self._halve(5, 18)
        final = match_final_state(self.fs, slug='match_18',
                                  player_id=self.pid['Sam Reid'])['final']
        self.assertEqual(final['amount'], '−$20')
        self.assertEqual(final['detail'], 'Lost 4 & 3')
        self.assertEqual(final['collect'], 'Pay Paul Kelly')


class FourballActivityTests(TestCase):
    """Two pairings, one ball each — the same card, one conjunction wider."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.active_games = ['fourball']
        self.round.primary_game = 'fourball'
        self.round.save(update_fields=['active_games', 'primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Paul Kelly', 0), ('Dave Moran', 0),
             ('Sam Reid', 0), ('Lee Naylor', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_fourball(
            self.fs,
            [self.pid['Paul Kelly'], self.pid['Dave Moran']],
            [self.pid['Sam Reid'], self.pid['Lee Naylor']],
            handicap_mode='gross', bet_amount=Decimal('20.00'))

    def _play(self, hole, t1, t2):
        submit_hole(self.fs, hole, [
            (self.pid['Paul Kelly'], t1), (self.pid['Dave Moran'], t1),
            (self.pid['Sam Reid'], t2),   (self.pid['Lee Naylor'], t2)])
        calculate_fourball(self.fs)

    def _state(self, who='Paul Kelly', thru=None):
        return match_activity_state(self.fs, slug='fourball',
                                    player_id=self.pid[who], thru=thru)

    def test_the_header_names_fourball(self):
        self._play(1, 4, 5)
        self.assertEqual(self._state()['header']['game'], 'FOURBALL')

    def test_the_sides_line_carries_both_pairings_in_full(self):
        self._play(1, 4, 5)
        self.assertEqual([s['names'] for s in self._state()['sides']],
                         ['Paul Kelly & Dave Moran', 'Sam Reid & Lee Naylor'])

    def test_it_answers_every_slot_the_way_singles_does(self):
        """The two games are one card. If this ever diverges, they have
        started to become two."""
        for h in range(1, 4):
            self._play(h, 4, 5)
        st = self._state()
        self.assertEqual(st['kind'], 'match')
        self.assertEqual(st['number']['text'], '3 UP')
        self.assertEqual(st['number']['colour'], 'blue')
        self.assertEqual(st['state']['to_play'], '15 TO PLAY')
        self.assertEqual(st['pips'], [])

    def test_the_footer_gross_is_the_readers_own_not_the_teams_better_ball(self):
        """A team figure on a neutral board is a number nobody can check
        against their own card."""
        submit_hole(self.fs, 1, [
            (self.pid['Paul Kelly'], 6), (self.pid['Dave Moran'], 4),
            (self.pid['Sam Reid'], 5),   (self.pid['Lee Naylor'], 5)])
        calculate_fourball(self.fs)
        # The pair's better ball is 4 (level); Paul himself is +2.
        self.assertIn('+2', self._state(who='Paul Kelly')['footer']['context'])
        self.assertIn('E',  self._state(who='Dave Moran')['footer']['context'])


class MatchRegistryTests(TestCase):
    """Both slugs reach the card, and the card names itself."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit     = Decimal('20.00')
        self.round.active_games = ['match_18']
        self.round.primary_game = 'match_18'
        self.round.save(update_fields=['bet_unit', 'active_games',
                                       'primary_game'])
        self.fs = make_foursome(self.round, [('Paul Kelly', 0), ('Sam Reid', 0)],
                                tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_nassau(self.fs, [self.pid['Paul Kelly']], [self.pid['Sam Reid']],
                     handicap_mode=HandicapMode.GROSS, game_type='match_18')
        submit_hole(self.fs, 1, [(self.pid['Paul Kelly'], 4),
                                 (self.pid['Sam Reid'], 5)])
        calculate_nassau(self.fs, game_type='match_18')

    def test_both_slugs_have_a_board(self):
        from services.live_activity_registry import BUILDERS
        self.assertIn('match_18', BUILDERS)
        self.assertIn('fourball', BUILDERS)

    def test_the_state_declares_the_card_not_the_slug(self):
        """One card serves two games, so the Swift switches on `match` rather
        than learning that two slugs mean one layout.

        Asserted on the BUILDER, not through `activity_state`: the card is in
        `UNSHIPPED_KINDS` until a build carrying its Swift goes out, so the
        edge deliberately returns `{}`. The property under test is what the
        builder declares, which is unaffected by the gate — see
        `UnshippedCardTests` for the gate itself.
        """
        self.assertEqual(primary_game(self.round), 'match_18')
        state = match_activity_state(self.fs, slug='match_18',
                                     player_id=self.pid['Paul Kelly'])
        self.assertEqual(state['kind'], 'match')

    def test_other_cards_still_declare_their_own_slug(self):
        """`setdefault` must not stop a single-game builder naming itself.

        Goes through `activity_state` on purpose — skins is shipped, so the
        gate lets it past, which is half of what that test is worth.
        """
        from django.contrib.auth import get_user_model
        from services.live_activity_registry import activity_state as st
        self.round.active_games = ['skins']
        self.round.primary_game = 'skins'
        self.round.save(update_fields=['active_games', 'primary_game'])
        user = get_user_model().objects.create_user(
            username='reader2', account=self.round.account)
        state = st(self.round, user)
        if state:
            self.assertEqual(state['kind'], 'skins')


class CardReleaseGateTests(TestCase):
    """A card the installed app cannot draw must not reach a lock screen.

    `match` shipped server-side while the newest build's known set was
    sixes/rabbit/nassau/skins, so every fourball raised the Swift's
    "Update Halved to follow this round here" card — a nag pointing at an
    update that did not exist, in place of the nothing it replaced.
    """

    def setUp(self):
        from django.contrib.auth import get_user_model
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit     = Decimal('20.00')
        self.round.active_games = ['match_18']
        self.round.primary_game = 'match_18'
        self.round.save(update_fields=['bet_unit', 'active_games',
                                       'primary_game'])
        self.fs = make_foursome(self.round, [('Paul Kelly', 0), ('Sam Reid', 0)],
                                tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_nassau(self.fs, [self.pid['Paul Kelly']], [self.pid['Sam Reid']],
                     handicap_mode=HandicapMode.GROSS, game_type='match_18')
        submit_hole(self.fs, 1, [(self.pid['Paul Kelly'], 4),
                                 (self.pid['Sam Reid'], 5)])
        calculate_nassau(self.fs, game_type='match_18')
        self.user = get_user_model().objects.create_user(
            username='reader3', account=self.round.account)

    def test_the_card_now_reaches_the_wire(self):
        """Released in 2.8.0+27, the build carrying its Swift."""
        from services.live_activity_registry import (UNSHIPPED_KINDS,
                                                     round_has_board)
        self.assertNotIn('match', UNSHIPPED_KINDS)
        self.assertTrue(round_has_board(self.round))
        self.assertEqual(activity_state(self.round, self.user)['kind'], 'match')

    def test_the_gate_still_works_for_the_next_card(self):
        """The set is empty, not gone. This is the mechanism that stops a
        server deploy raising a card no installed app can draw — which is
        exactly what `match` did on 2026-09-02."""
        from unittest.mock import patch
        import services.live_activity_registry as reg
        from services.live_activity_registry import round_has_board
        with patch.object(reg, 'UNSHIPPED_KINDS', {'match'}):
            self.assertEqual(activity_state(self.round, self.user), {})
            self.assertFalse(round_has_board(self.round))

    def test_the_builder_is_only_ever_gated_at_the_edge(self):
        """Whatever the gate says, the card itself is complete."""
        st = match_activity_state(self.fs, slug='match_18',
                                  player_id=self.pid['Paul Kelly'])
        self.assertEqual(st['kind'], 'match')
        self.assertEqual(st['number']['text'], '1 UP')

    def test_a_card_that_was_never_gated_is_unaffected(self):
        from services.live_activity_registry import round_has_board
        self.round.active_games = ['skins']
        self.round.primary_game = 'skins'
        self.round.save(update_fields=['active_games', 'primary_game'])
        self.assertTrue(round_has_board(self.round))

    def test_both_match_slugs_map_to_the_one_card(self):
        """Gating by `kind` and not by slug is what makes one flip enough."""
        from services.live_activity_registry import card_kind
        self.assertEqual(card_kind('match_18'), 'match')
        self.assertEqual(card_kind('fourball'), 'match')
        self.assertEqual(card_kind('skins'), 'skins')
