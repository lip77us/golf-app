"""
scoring/tests/test_live_activity_banker.py
------------------------------------------
The Banker lock screen
(docs/design-review/handoff-banker/live-activity-banker.html).

Weighted almost entirely towards the one thing this card does that no other
card in the set does: **it is personal.** Every other board is the same string
on four phones. Banker's cannot be — there are three one-on-ones on a hole and
no shared score — so the tests that matter are the ones asserting that a
golfer's card shows his own bet and *nobody else's*, and that the banker's
shows all three because every one of them was made against him.
"""
import re
from decimal import Decimal
from pathlib import Path

from django.conf import settings
from django.test import TestCase

from games.models import BankerHole
from services.banker import (lock_bets, open_next_hole, place_bet,
                             set_counter, set_double, set_hole_max,
                             setup_banker)
from services.live_activity_banker import (banker_activity_state,
                                           banker_final_state)
from services.live_activity_registry import (UNSHIPPED_KINDS, card_kind,
                                             round_has_board)
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class BankerCardTests(TestCase):
    """Four scratch golfers, $5–$50. Paul banks the 1st."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.round.primary_game = 'banker'
        self.round.save(update_fields=['primary_game'])
        self.fs = make_foursome(
            self.round,
            [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                                 min_bet=5, max_bet=50)

    def _bets(self, hole, _max=50, **amounts):
        # The maximum is set ABOVE every bet on purpose. It is a public fact —
        # the banker announced it on the tee and nobody can choose a number
        # without it — so it appears on every card, and a test asserting one
        # golfer's bet is absent must not pick an amount the max also prints.
        set_hole_max(self.fs, hole, _max)
        for name, amt in amounts.items():
            place_bet(self.fs, hole, self.pid[name], amt)
        lock_bets(self.fs, hole)

    def _card(self, who=None, thru=0):
        return banker_activity_state(
            self.fs,
            player_id=None if who is None else self.pid[who], thru=thru)

    # -- the departure: the card is personal ---------------------------------

    def test_a_player_sees_his_own_bet_and_no_other_golfers_number(self):
        """A golfer has no business reading Sam's number off Dave's phone.
        Sixes and Sequoya put the same string on four phones; this card cannot
        and must not."""
        self._bets(1, Dave=10, Sam=25, Lee=15)
        card = self._card('Dave')
        blob = repr(card)
        self.assertEqual(card['number']['text'], '$10')
        self.assertNotIn('$25', blob)      # Sam's
        self.assertNotIn('$15', blob)      # Lee's

    def test_the_banker_sees_all_three_because_all_three_are_against_him(self):
        """The exception, and the reason it is one: on a hole he banked, every
        bet on it was his business."""
        self._bets(1, Dave=10, Sam=25, Lee=15)
        card = self._card('Paul')
        names = card['sides'][0]['names']
        for bit in ('$10', '$25', '$15'):
            self.assertIn(bit, names)
        self.assertEqual(card['number']['text'], '$50')
        self.assertEqual(card['state']['word'], 'BANKING')

    def test_a_watcher_is_shown_the_role_and_not_the_wagers(self):
        """He opened somebody else's round; he did not join the game."""
        self._bets(1, Dave=10, Sam=25, Lee=15)
        card = self._card(None)
        blob = repr(card)
        for bit in ('$10', '$25', '$15'):
            self.assertNotIn(bit, blob)
        # The maximum is his to see — it was announced on the tee — and the
        # role with it. The three wagers are not.
        self.assertEqual(card['number']['text'], '$50')
        self.assertEqual(card['footer']['money'], '')

    # -- gold is the role ----------------------------------------------------

    def test_the_headline_wears_gold_on_the_bankers_own_card(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self.assertEqual(self._card('Paul')['number']['colour'], 'gold')

    def test_a_counter_turns_the_players_card_amber_not_blue(self):
        """Blue is a player's own double; amber is the counter. When both are
        true the counter wins the colour, because it is the half he did not
        agree to."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        set_double(self.fs, 1, self.pid['Dave'])
        set_counter(self.fs, 1)
        card = self._card('Dave')
        self.assertEqual(card['number']['colour'], 'amber')
        self.assertIn('countered', card['sides'][1]['names'])

    def test_a_players_own_double_is_blue(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        set_double(self.fs, 1, self.pid['Dave'])
        card = self._card('Dave')
        self.assertEqual(card['number']['colour'], 'blue')
        self.assertEqual(card['number']['text'], '$20')

    # -- the headline is the hole, never the round ---------------------------

    def test_the_headline_is_this_holes_money_and_the_round_is_in_the_footer(self):
        """A round total in the 36pt slot would be the number he already knows,
        and it does not change while he is walking."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        submit_hole(self.fs, 1, [(self.pid['Paul'], 5), (self.pid['Dave'], 4),
                                 (self.pid['Sam'], 4), (self.pid['Lee'], 4)])
        open_next_hole(self.fs, 1, banker_id=self.pid['Dave'])
        self._bets(2, Paul=20, Sam=20, Lee=20)
        card = self._card('Paul', thru=1)
        self.assertEqual(card['number']['text'], '$20')      # this hole
        self.assertEqual(card['footer']['money'], '−$30')    # the round

    # -- the hole is over ----------------------------------------------------

    def _settle_hole_1(self):
        """Paul banks, all three beat him, and Dave is the outright low.

        The three scores are DIFFERENT on purpose: level them and the hole
        ends in a tie for low, which is a different card — see the tie test.
        And nobody makes a BIRDIE, which would double that golfer's collection
        and make these assertions about the bonus rather than the state.
        """
        self._bets(1, Dave=10, Sam=10, Lee=10)
        submit_hole(self.fs, 1, [(self.pid['Paul'], 6), (self.pid['Dave'], 4),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])

    def test_a_settled_hole_shows_what_moved_not_what_was_at_risk(self):
        """Reported from the course: the phone showed the result of hole 1
        while the lock screen still showed what was at risk on it. The card had
        no settled state at all — it drew the open composition for the whole
        life of a hole."""
        self._settle_hole_1()
        card = self._card('Paul')
        self.assertEqual(card['number']['text'], '−$30')
        self.assertNotEqual(card['state']['word'], 'BANKING')

    def test_the_bankers_settled_row_signs_every_bet_from_his_side(self):
        self._settle_hole_1()
        names = self._card('Paul')['sides'][0]['names']
        self.assertIn('−$10', names)
        self.assertNotIn('+$10', names)

    def test_a_player_sees_his_own_result_and_who_he_beat(self):
        self._settle_hole_1()
        card = self._card('Dave')
        self.assertEqual(card['number']['text'], '+$10')
        self.assertIn('You won v', card['sides'][0]['names'])

    def test_the_state_slot_names_who_banks_next(self):
        """The result is already the headline, so the slot beside it owes the
        reader the one thing that has not happened yet."""
        self._settle_hole_1()
        card = self._card('Paul')
        self.assertEqual(card['state']['to_play'], 'BANKS NEXT')
        self.assertTrue(card['state']['word'])

    def test_a_tie_for_low_outranks_the_next_banker(self):
        """Until the group says who holed out first the next hole cannot open,
        so that is the more useful thing to print."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        submit_hole(self.fs, 1, [(self.pid['Paul'], 5), (self.pid['Dave'], 4),
                                 (self.pid['Sam'], 4), (self.pid['Lee'], 6)])
        card = self._card('Paul')
        self.assertEqual(card['state']['word'], 'TIED')
        self.assertEqual(card['state']['to_play'], 'GROUP DECIDES')

    def test_the_stroke_ribbon_comes_down_once_the_hole_is_settled(self):
        """The shots are spent. A band still announcing them reads as a hole
        that has not been played."""
        self._settle_hole_1()
        self.assertEqual(self._card('Dave')['ribbon'], '')

    def test_a_watcher_sees_that_it_is_over_and_not_the_money(self):
        self._settle_hole_1()
        card = self._card(None)
        self.assertEqual(card['number']['text'], '—')
        self.assertNotIn('$10', repr(card))

    # -- the ribbon ----------------------------------------------------------

    def test_a_scratch_hole_says_so_rather_than_leaving_the_ribbon_blank(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self.assertIn('SCRATCH HOLE', self._card('Dave')['ribbon'])

    # -- the gate ------------------------------------------------------------

    def test_the_card_ships_now_that_a_build_draws_it(self):
        """A kind enters `UNSHIPPED_KINDS` with its builder and leaves with its
        build — 2.8.2+33 carries the kind string, the gold and amber palette
        entries and the ribbon's blue tone, so the gate is off.

        Kept rather than deleted because the failure it guards is silent:
        starting an activity the installed app cannot render turns "this game
        has no board" into a lock-screen nag pointing at an update that does
        not exist."""
        self.assertNotIn(card_kind('banker'), UNSHIPPED_KINDS)
        self.assertTrue(round_has_board(self.round))

    def test_the_ios_build_declares_the_kind_and_the_two_colours(self):
        """The half no Python test would otherwise reach. `banker` renders with
        `BoardView`, so the client side of shipping it is the kind string plus
        the two palette entries gold and amber — exactly the kind of thing that
        gets forgotten."""
        base = Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
        swift = (base / 'SixesActivityLiveActivity.swift').read_text()
        known = re.search(r'static let known: Set<String> = \[(.*?)\]',
                          swift, re.S).group(1)
        self.assertIn('"banker"', known)
        palette = (base / 'SixesActivity.swift').read_text()
        self.assertIn('case "gold"', palette)
        self.assertIn('case "amber"', palette)


class BankerCardStrokeTests(TestCase):
    """The blue band, and whose strokes it names.

    **Strokes come off inside each one-on-one**, so there is no field-wide
    allocation to report: Dave off 8 against a scratch banker gets shots the
    banker does not, and the ribbon has to say so from the reader's side.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(
            self.round,
            [('Paul', 0), ('Dave', 8), ('Sam', 0), ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                                 min_bet=5, max_bet=50)
        set_hole_max(self.fs, 1, 10)
        for n in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, 1, self.pid[n], 10)
        lock_bets(self.fs, 1)

    def _card(self, who):
        return banker_activity_state(self.fs, player_id=self.pid[who], thru=0)

    def test_a_players_ribbon_names_only_the_two_men_in_his_bet(self):
        ribbon = self._card('Dave')['ribbon']
        self.assertIn('YOU GET', ribbon)
        self.assertNotIn('SAM', ribbon.upper())
        self.assertNotIn('LEE', ribbon.upper())

    def test_the_bankers_ribbon_names_every_match_he_is_in(self):
        ribbon = self._card('Paul')['ribbon'].upper()
        self.assertIn('D GETS', ribbon)

    def test_the_ribbon_carries_the_stroke_index(self):
        self.assertIn('SI ', self._card('Dave')['ribbon'])


class BankerFinalCardTests(TestCase):
    """Round sign-off. Banking and betting are different games and this is the
    last chance to say which one made the money."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(
            self.round,
            [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                                 min_bet=5, max_bet=50)
        BankerHole.objects.update_or_create(
            game=self.game, hole_number=1,
            defaults={'banker_id': self.pid['Paul']})
        set_hole_max(self.fs, 1, 10)
        for n in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, 1, self.pid[n], 10)
        lock_bets(self.fs, 1)
        submit_hole(self.fs, 1, [(self.pid['Paul'], 5), (self.pid['Dave'], 4),
                                 (self.pid['Sam'], 4), (self.pid['Lee'], 4)])

    def test_the_final_names_which_half_of_the_game_made_the_money(self):
        card = banker_final_state(self.fs, player_id=self.pid['Paul'])
        self.assertEqual(card['final']['headline'], '−$30')
        self.assertIn('banking −$30', card['final']['detail'])
        self.assertIn('betting $0', card['final']['detail'])   # not +$0

    def test_the_final_says_who_to_pay(self):
        card = banker_final_state(self.fs, player_id=self.pid['Paul'])
        self.assertTrue(card['final']['collect'].startswith('Pay '))

    def test_a_watcher_gets_no_final_card(self):
        self.assertEqual(banker_final_state(self.fs, player_id=None), {})
