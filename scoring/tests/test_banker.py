"""
scoring/tests/test_banker.py
----------------------------
Banker — one against three, every hole (Downloads/handoff-banker/HANDOFF.md).

Weighted towards the three asymmetries the format hangs on, because each is a
place a reasonable person would "fix" it into a different game: **a tie is no
action and the banker does not win it**, **the birdie bonus pays out only**,
and **a par 3 replaces the double with a triple rather than adding to it**.
Plus the two rules about time — the lock, and the fact that who banked a hole
is stored rather than recomputed from a score that may later change.
"""
from decimal import Decimal

from django.test import TestCase

from core.models import HandicapMode
from games.models import BankerGame, BankerHole
from services.banker import (ZERO, BankerLocked, banker_settlement,
                             banker_summary,
                             exposure_ladder, hole_exposure,
                             hole_exposure_if_max, lock_bets,
                             open_next_hole, place_bet, set_counter,
                             set_double, set_hole_max, setup_banker)
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class BankerTests(TestCase):
    """Four scratch golfers, $5-$50, Paul banks the 1st. Gross == net."""

    HCPS = [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)]

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.round.primary_game = 'banker'
        self.round.save(update_fields=['primary_game'])
        self.fs = make_foursome(self.round, self.HCPS, tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                                 min_bet=5, max_bet=50)

    # -- helpers -------------------------------------------------------------

    def _bets(self, hole, **amounts):
        set_hole_max(self.fs, hole, max(amounts.values()))
        for name, amt in amounts.items():
            place_bet(self.fs, hole, self.pid[name], amt)
        lock_bets(self.fs, hole)

    def _play(self, hole, paul, dave, sam, lee):
        submit_hole(self.fs, hole, [(self.pid['Paul'], paul),
                                    (self.pid['Dave'], dave),
                                    (self.pid['Sam'], sam),
                                    (self.pid['Lee'], lee)])

    def _hole(self, n):
        return next(h for h in banker_summary(self.fs)['holes']
                    if h['hole'] == n)

    def _line(self, n, who):
        return next(l for l in self._hole(n)['lines']
                    if l['player_id'] == self.pid[who])

    # -- the plain hole ------------------------------------------------------

    def test_beat_the_banker_and_he_pays_you_your_bet(self):
        self._bets(1, Dave=10, Sam=20, Lee=5)
        self._play(1, paul=5, dave=4, sam=6, lee=5)   # Dave wins, Sam loses,
        h = self._hole(1)                             # Lee ties.
        self.assertEqual(self._line(1, 'Dave')['amount'], Decimal('10'))
        self.assertEqual(self._line(1, 'Sam')['amount'], Decimal('20'))
        # +20 collected from Sam, -10 paid to Dave, nothing from the tie.
        self.assertEqual(h['banker_delta'], Decimal('10'))

    def test_a_tie_is_no_action_and_the_banker_does_not_win_it(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=4, dave=4, sam=4, lee=4)
        self.assertEqual(self._hole(1)['banker_delta'], Decimal('0'))
        for who in ('Dave', 'Sam', 'Lee'):
            self.assertEqual(self._line(1, who)['outcome'], 'tied')
            self.assertEqual(self._line(1, who)['amount'], Decimal('0'))

    def test_a_void_bet_still_reports_what_it_had_reached(self):
        """A doubled bet that paid nothing is a fact the group wants to see,
        not an omission — and it is what makes the counter a real gamble."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        set_double(self.fs, 1, self.pid['Dave'])
        set_counter(self.fs, 1)
        self._play(1, paul=4, dave=4, sam=5, lee=5)
        dave = self._line(1, 'Dave')
        self.assertEqual(dave['outcome'], 'tied')
        self.assertEqual(dave['amount'], Decimal('0'))
        self.assertEqual(dave['stake'], Decimal('40'))     # $10 ×2 ×2
        self.assertIn('= $40', dave['chain'])

    # -- the asymmetries -----------------------------------------------------

    def test_a_birdie_doubles_the_winning_players_payout(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=5, dave=3, sam=5, lee=5)      # par 4; Dave birdies
        self.assertEqual(self._line(1, 'Dave')['amount'], Decimal('20'))
        self.assertTrue(self._line(1, 'Dave')['birdie'])

    def test_a_losing_birdie_collects_nothing_extra(self):
        """The bonus pays OUT only — it is not a discount on a lost hole."""
        self.game.holes.all().delete()
        BankerHole.objects.create(game=self.game, hole_number=4,
                                  banker_id=self.pid['Paul'])         # par 5
        self._bets(4, Dave=10, Sam=10, Lee=10)
        self._play(4, paul=3, dave=4, sam=6, lee=6)      # Dave birdies, loses
        dave = self._line(4, 'Dave')
        self.assertEqual(dave['outcome'], 'lost')
        self.assertEqual(dave['amount'], Decimal('10'))
        self.assertFalse(dave['birdie'])

    def test_the_banker_never_gets_the_birdie_bonus(self):
        """One against three is lopsided already; doubling three collections
        at once would make the role unplayable."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=3, dave=4, sam=4, lee=4)   # Paul birdies, wins all
        self.assertEqual(self._hole(1)['banker_delta'], Decimal('30'))

    def test_a_par_3_triples_instead_of_doubling(self):
        """Not a fourth option — the same slot with a different number."""
        self.game.holes.all().delete()
        BankerHole.objects.create(game=self.game, hole_number=3,
                                  banker_id=self.pid['Paul'])
        self._bets(3, Dave=10, Sam=10, Lee=10)
        set_double(self.fs, 3, self.pid['Dave'])
        self.assertEqual(self._line(3, 'Dave')['own_multiplier'], 3)

    def test_the_counter_doubles_every_standing_bet_at_once(self):
        self._bets(1, Dave=10, Sam=20, Lee=5)
        set_double(self.fs, 1, self.pid['Dave'])
        set_counter(self.fs, 1)
        self._play(1, paul=5, dave=4, sam=4, lee=4)
        self.assertEqual(self._line(1, 'Dave')['stake'], Decimal('40'))
        self.assertEqual(self._line(1, 'Sam')['stake'], Decimal('40'))
        self.assertEqual(self._line(1, 'Lee')['stake'], Decimal('10'))

    def test_the_chain_names_every_multiplier_that_produced_the_number(self):
        """The only screen in the app that shows arithmetic, and it earns it:
        the argument is always about the chain, never the outcome."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        set_double(self.fs, 1, self.pid['Dave'])
        set_counter(self.fs, 1)
        self._play(1, paul=5, dave=3, sam=5, lee=5)
        chain = self._line(1, 'Dave')['chain']
        self.assertIn('$10 bet', chain)
        self.assertIn('×2 his double', chain)
        self.assertIn('×2 counter', chain)
        self.assertIn('×2 his birdie', chain)

    # -- the lock ------------------------------------------------------------

    def test_nothing_above_the_lock_moves_once_the_banker_has_teed_off(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        with self.assertRaises(BankerLocked):
            place_bet(self.fs, 1, self.pid['Dave'], 20)
        with self.assertRaises(BankerLocked):
            set_hole_max(self.fs, 1, 30)

    def test_the_lock_refuses_until_every_opponent_has_a_bet(self):
        """A silent floor bet would be the app choosing somebody's stake."""
        set_hole_max(self.fs, 1, 20)
        place_bet(self.fs, 1, self.pid['Dave'], 10)
        with self.assertRaises(ValueError):
            lock_bets(self.fs, 1)

    def test_doubles_close_when_the_first_score_goes_in(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        set_double(self.fs, 1, self.pid['Dave'])          # still open
        submit_hole(self.fs, 1, [(self.pid['Sam'], 4)])
        with self.assertRaises(BankerLocked):
            set_double(self.fs, 1, self.pid['Lee'])
        with self.assertRaises(BankerLocked):
            set_counter(self.fs, 1)

    def test_a_bet_cannot_sit_outside_the_band(self):
        set_hole_max(self.fs, 1, 20)
        with self.assertRaises(ValueError):
            place_bet(self.fs, 1, self.pid['Dave'], 25)   # above his max
        with self.assertRaises(ValueError):
            place_bet(self.fs, 1, self.pid['Dave'], 1)    # below the floor

    def test_the_hole_maximum_cannot_beat_the_round_ceiling(self):
        with self.assertRaises(ValueError):
            set_hole_max(self.fs, 1, 80)

    def test_lowering_the_maximum_brings_a_standing_bet_down_with_it(self):
        set_hole_max(self.fs, 1, 50)
        place_bet(self.fs, 1, self.pid['Dave'], 50)
        set_hole_max(self.fs, 1, 20)
        self.assertEqual(self.game.holes.get(hole_number=1)
                         .bets.get(player_id=self.pid['Dave']).amount,
                         Decimal('20.00'))

    # -- rotation ------------------------------------------------------------

    def test_lowest_net_takes_the_bank(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=5, dave=4, sam=5, lee=5)
        nxt = open_next_hole(self.fs, 1)
        self.assertEqual(nxt.hole_number, 2)
        self.assertEqual(nxt.banker_id, self.pid['Dave'])

    def test_a_tie_for_the_bank_stops_the_round_until_the_group_answers(self):
        """A phone did not see who holed out first and must not pretend it."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=5, dave=4, sam=4, lee=5)
        s = banker_summary(self.fs)
        self.assertEqual(s['awaiting_tie'], 1)
        self.assertEqual({c['player_id'] for c in s['tie_candidates']},
                         {self.pid['Dave'], self.pid['Sam']})
        with self.assertRaises(ValueError):
            open_next_hole(self.fs, 1)

    def test_the_answer_is_recorded_with_its_reason(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=5, dave=4, sam=4, lee=5)
        nxt = open_next_hole(self.fs, 1, banker_id=self.pid['Sam'])
        self.assertEqual(nxt.banker_id, self.pid['Sam'])
        self.assertEqual(self.game.holes.get(hole_number=1).tie_reason,
                         BankerHole.TIE_HOLED_FIRST)

    def test_only_a_golfer_who_tied_can_be_handed_the_bank(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=5, dave=4, sam=4, lee=5)
        with self.assertRaises(ValueError):
            open_next_hole(self.fs, 1, banker_id=self.pid['Lee'])

    def test_a_drawn_tie_draws_the_same_way_every_time(self):
        """A draw that moved on recalculation would rewrite who banked."""
        self.game.rotation_rule = BankerGame.ROTATION_DRAW
        self.game.save(update_fields=['rotation_rule'])
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=5, dave=4, sam=4, lee=5)
        first = open_next_hole(self.fs, 1).banker_id
        self.game.holes.filter(hole_number=2).delete()
        self.assertEqual(open_next_hole(self.fs, 1).banker_id, first)

    def test_who_banked_a_hole_survives_a_corrected_score(self):
        """Every bet was agreed against a named man; a score edit must not
        hand the role to somebody else and re-point three wagers."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=5, dave=4, sam=6, lee=6)
        open_next_hole(self.fs, 1)                       # Dave banks the 2nd
        self._play(1, paul=5, dave=6, sam=3, lee=6)      # correction: Sam low
        self.assertEqual(self.game.holes.get(hole_number=2).banker_id,
                         self.pid['Dave'])

    # -- exposure ------------------------------------------------------------

    def test_the_ladder_states_the_whole_climb_not_one_worst_case(self):
        ladder = exposure_ladder(self.game)
        self.assertEqual([l['amount'] for l in ladder],
                         [Decimal(n) for n in (150, 300, 600, 900, 1800)])

    def test_the_hole_cap_is_a_ceiling_on_what_one_hole_can_cost(self):
        self.game.hole_cap_enabled = True
        self.game.hole_cap_amount = Decimal('100')
        self.game.save(update_fields=['hole_cap_enabled', 'hole_cap_amount'])
        self._bets(1, Dave=50, Sam=50, Lee=50)
        set_counter(self.fs, 1)
        row = self.game.holes.get(hole_number=1)
        # $300 standing, capped to $100.
        self.assertEqual(hole_exposure(self.game, row), Decimal('100'))

    def test_exposure_moves_when_a_double_lands(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        row = self.game.holes.get(hole_number=1)
        self.assertEqual(hole_exposure(self.game, row), Decimal('30'))
        set_double(self.fs, 1, self.pid['Dave'])
        row.refresh_from_db()
        self.assertEqual(hole_exposure(self.game, row), Decimal('40'))

    def test_the_banner_counts_standing_multipliers_not_outcomes(self):
        """The birdie bonus doubles a payout, but it is an OUTCOME — folding
        it in would make the banner read as though somebody had already holed
        a putt, and move the number for a reason the reader cannot see."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        set_counter(self.fs, 1)
        row = self.game.holes.get(hole_number=1)
        self.assertEqual(hole_exposure(self.game, row), Decimal('60'))

    def test_before_every_bet_is_in_the_exposure_is_a_range(self):
        """A total that grows silently as bets arrive tells the banker nothing
        about the decision he is making now."""
        set_hole_max(self.fs, 1, 30)
        place_bet(self.fs, 1, self.pid['Dave'], 10)
        row = self.game.holes.get(hole_number=1)
        opp = [self.pid['Dave'], self.pid['Sam'], self.pid['Lee']]
        self.assertEqual(hole_exposure(self.game, row), Decimal('10'))
        # Two still to bet, and the banker's own maximum is the top of each.
        self.assertEqual(hole_exposure_if_max(self.game, row, opp),
                         Decimal('70'))

    def test_the_summary_names_who_has_still_to_bet(self):
        set_hole_max(self.fs, 1, 30)
        place_bet(self.fs, 1, self.pid['Dave'], 10)
        h = self._hole(1)
        self.assertEqual(set(h['outstanding']), {'S', 'L'})
        self.assertEqual(h['exposure_if_max'], Decimal('70'))

    # -- the money -----------------------------------------------------------

    def test_banking_and_betting_are_reported_separately(self):
        """Different games played by the same man — a golfer can finish level
        having been wildly up in one and down in the other."""
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=6, dave=4, sam=4, lee=4)       # Paul pays 30
        open_next_hole(self.fs, 1, banker_id=self.pid['Dave'])
        self._bets(2, Paul=10, Sam=10, Lee=10)
        self._play(2, paul=4, dave=6, sam=6, lee=6)       # Paul wins 10
        me = next(p for p in banker_summary(self.fs)['players']
                  if p['player_id'] == self.pid['Paul'])
        self.assertEqual(me['banking'], Decimal('-30'))
        self.assertEqual(me['betting'], Decimal('10'))
        self.assertEqual(me['total'], Decimal('-20'))

    def test_the_table_is_zero_sum(self):
        self._bets(1, Dave=10, Sam=20, Lee=5)
        set_double(self.fs, 1, self.pid['Sam'])
        set_counter(self.fs, 1)
        self._play(1, paul=4, dave=3, sam=5, lee=4)
        totals = sum(p['total'] for p in banker_summary(self.fs)['players'])
        self.assertEqual(totals, Decimal('0'))

    def test_settlement_itemises_banked_holes_and_groups_the_rest(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=6, dave=4, sam=4, lee=4)
        open_next_hole(self.fs, 1, banker_id=self.pid['Dave'])
        self._bets(2, Paul=10, Sam=10, Lee=10)
        self._play(2, paul=4, dave=6, sam=6, lee=6)

        s = banker_settlement(self.fs)
        paul = next(p for p in s['players']
                    if p['player_id'] == self.pid['Paul'])
        # The hole he banked, in full — three bets.
        self.assertEqual(len(paul['holes_banked']), 1)
        self.assertEqual(len(paul['holes_banked'][0]['lines']), 3)
        # The hole he played, grouped by whose bank he was betting into.
        dave_short = next(x['short_name'] for x in s['players']
                          if x['player_id'] == self.pid['Dave'])
        self.assertEqual([g['banker'] for g in paul['by_bank']], [dave_short])
        self.assertEqual(paul['by_bank'][0]['subtotal'], Decimal('10'))

    def test_a_zero_line_stays_when_the_stake_was_large(self):
        """A golfer who remembers a $180 hole and cannot find it does not
        trust the receipt."""
        self.game.holes.all().delete()
        BankerHole.objects.create(game=self.game, hole_number=3,
                                  banker_id=self.pid['Paul'])
        self._bets(3, Dave=50, Sam=50, Lee=50)
        for who in ('Dave', 'Sam', 'Lee'):
            set_double(self.fs, 3, self.pid[who])
        self._play(3, paul=3, dave=3, sam=3, lee=3)       # all square
        dave = next(p for p in banker_settlement(self.fs)['players']
                    if p['player_id'] == self.pid['Dave'])
        line = dave['by_bank'][0]['holes'][0]
        self.assertEqual(line['amount'], Decimal('0'))
        self.assertEqual(line['stake'], Decimal('150'))   # $50 ×3

    def test_transfers_collapse_to_the_fewest_handovers(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        self._play(1, paul=6, dave=4, sam=4, lee=4)
        t = banker_summary(self.fs)['money']['transfers']
        self.assertEqual(len(t), 3)
        self.assertEqual(sum(x['amount'] for x in t), Decimal('30'))



class BankerStrokesTests(TestCase):
    """The handicap, which is the shape of this game rather than a detail of it.

    A Banker hole is three separate matches and a match is played off the
    DIFFERENCE between two handicaps, so the banker holds three stroke
    relationships at once while each opponent holds exactly one. Every
    assertion here is really the same one: a stroke belongs to a pair, not to
    a man.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        # Paul banks off 8. Dave is above him, Sam below, Lee level — so one
        # hole carries a give, a take and a scratch at the same time.
        self.fs = make_foursome(self.round,
                                [('Paul', 8), ('Dave', 12), ('Sam', 4),
                                 ('Lee', 8)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'])

    def _open(self, hole):
        if hole != 1:
            self.game.holes.all().delete()
            BankerHole.objects.create(game=self.game, hole_number=hole,
                                      banker_id=self.pid['Paul'])
        set_hole_max(self.fs, hole, 10)
        for who in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, hole, self.pid[who], 10)
        lock_bets(self.fs, hole)

    def _lines(self, hole):
        h = next(x for x in banker_summary(self.fs)['holes']
                 if x['hole'] == hole)
        return h, {l['short_name']: l for l in h['lines']}

    def test_strokes_off_is_the_default(self):
        self.assertEqual(self.game.handicap_mode, HandicapMode.STROKES_OFF)

    def test_the_banker_gives_takes_and_plays_level_on_the_same_hole(self):
        """The whole point: three relationships, one hole. Hole 5 is stroke
        index 1, so every difference shows there."""
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        h, by = self._lines(5)
        # Dave is 4 above Paul — he receives.
        self.assertEqual(by['D']['strokes'], 1)
        # Sam is 4 below — the banker receives in THAT match.
        self.assertEqual(by['S']['strokes'], -1)
        # Lee is level.
        self.assertEqual(by['L']['strokes'], 0)

    def test_the_bankers_net_is_three_numbers_not_one(self):
        """There is no single "his net" to put on a card, which is a fact of
        the format rather than a gap in the data."""
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        h, by = self._lines(5)
        self.assertEqual(h['banker_gross'], 5)
        self.assertNotIn('banker_net', h)
        self.assertEqual({by['D']['banker_net'], by['S']['banker_net'],
                          by['L']['banker_net']}, {5, 4})
        self.assertEqual(by['D']['banker_net'], 5)   # gives, so plays gross
        self.assertEqual(by['S']['banker_net'], 4)   # receives one from Sam

    def test_each_opponent_has_exactly_one(self):
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        _, by = self._lines(5)
        self.assertEqual(by['D']['net'], 4)          # receives one
        self.assertEqual(by['S']['net'], 5)          # gives one, plays gross
        self.assertEqual(by['L']['net'], 5)

    def test_the_same_gross_settles_three_different_ways(self):
        """Four fives, and the hole is not a wash: Dave beats the banker, the
        banker beats Sam, Lee halves."""
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        h, by = self._lines(5)
        self.assertEqual(by['D']['outcome'], 'won')
        self.assertEqual(by['S']['outcome'], 'lost')
        self.assertEqual(by['L']['outcome'], 'tied')
        self.assertEqual(h['banker_delta'], Decimal('0'))

    def test_the_line_names_whoever_strokes_rather_than_saying_you(self):
        """The play screen is the group's phone; the reader is not reliably
        either man in the bet."""
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        _, by = self._lines(5)
        self.assertEqual(by['D']['stroke_note'], 'D strokes')
        self.assertEqual(by['S']['stroke_note'], 'P strokes')
        self.assertEqual(by['L']['stroke_note'], 'scratch hole')

    def test_the_card_carries_each_match_on_the_opponents_side(self):
        """There is no single "his net" to put in the banker's column, so the
        whole handicap of a match rides on the OPPONENT's number and the
        banker's column is his plain gross. The arithmetic is identical and
        every comparison on the card is direct."""
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        card = banker_summary(self.fs)['scorecard']
        rows = {r['short_name']: r for r in card['rows']}
        self.assertEqual(rows['P']['net'][5], 5)      # his gross, unadorned
        self.assertTrue(rows['P']['banked'][5])
        self.assertFalse(rows['P']['beat'][5])
        # Dave receives one, so he is a shot better than the banker's gross.
        self.assertEqual(rows['D']['net'][5], 4)
        self.assertTrue(rows['D']['beat'][5])
        # The banker receives one from Sam — added to SAM rather than taken
        # off the banker, so the column stays one number.
        self.assertEqual(rows['S']['net'][5], 6)
        self.assertFalse(rows['S']['beat'][5])
        self.assertEqual(rows['L']['net'][5], 5)      # level, and a tie
        self.assertFalse(rows['L']['beat'][5])

    def test_the_signed_strokes_still_travel_even_though_the_card_hides_them(self):
        """The card drops the dot — every bet settles on net and gross would
        make the reader subtract four times a row — but the per-pair strokes
        stay in the payload for the surfaces that do name them."""
        plan = banker_summary(self.fs)['stroke_plan']
        self.assertEqual(plan[self.pid['Paul']][self.pid['Dave']][5], 1)
        self.assertEqual(plan[self.pid['Paul']][self.pid['Sam']][5], -1)

    def test_the_plan_is_known_for_every_golfer_as_banker(self):
        """A man choosing a bet needs the shots ahead of him, and in this game
        those depend on who is banking."""
        plan = banker_summary(self.fs)['stroke_plan']
        # Paul banking Dave: Dave receives on the four hardest holes.
        self.assertEqual(sum(1 for v in plan[self.pid['Paul']][self.pid['Dave']]
                             .values() if v > 0), 4)
        # Dave banking Paul: the same four holes, pointing the other way.
        self.assertEqual(sum(1 for v in plan[self.pid['Dave']][self.pid['Paul']]
                             .values() if v < 0), 4)

    def test_net_mode_still_gives_each_golfer_his_own_full_allocation(self):
        """Offered for a group that plays it that way — and it is the one mode
        where the banker really does have a single net."""
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     handicap_mode=HandicapMode.NET)
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        _, by = self._lines(5)
        for line in by.values():
            self.assertEqual(line['banker_net'], 4)   # Paul off 8, SI 1

    def test_gross_mode_strokes_nobody(self):
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     handicap_mode=HandicapMode.GROSS)
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        h, by = self._lines(5)
        self.assertEqual(h['banker_delta'], Decimal('0'))
        self.assertTrue(all(l['strokes'] == 0 for l in by.values()))

    def test_the_rotation_ranks_the_field_on_its_own_scale(self):
        """Two jobs for one handicap, and they must not be confused: bets
        settle strokes-off pairwise, which has no common scale, so the bank
        passes on each golfer's own full allocation."""
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 6),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        # Full allocation on SI 1: Paul 4, Dave 5, Sam 4, Lee 4 — Sam wins the
        # tiebreak only by being named, so this is a tie and the group is asked.
        s = banker_summary(self.fs)
        self.assertEqual(s['awaiting_tie'], 5)
        self.assertEqual({c['short_name'] for c in s['tie_candidates']},
                         {'P', 'S', 'L'})


class BankerActionRulesTests(TestCase):
    """The four switches. Turn any off and the game still works — it just gets
    quieter — so each has to be refused at the source rather than merely hidden
    on a screen."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _game(self, **rules):
        return setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                            min_bet=5, max_bet=50, **rules)

    def _open(self, hole=1):
        if hole != 1:
            self.fs.banker_game.holes.all().delete()
            BankerHole.objects.create(game=self.fs.banker_game,
                                      hole_number=hole,
                                      banker_id=self.pid['Paul'])
        set_hole_max(self.fs, hole, 10)
        for who in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, hole, self.pid[who], 10)
        lock_bets(self.fs, hole)

    def test_a_switched_off_double_is_refused_not_just_hidden(self):
        self._game(allow_player_double=False)
        self._open()
        with self.assertRaises(ValueError):
            set_double(self.fs, 1, self.pid['Dave'])

    def test_a_switched_off_counter_is_refused(self):
        self._game(allow_counter=False)
        self._open()
        with self.assertRaises(ValueError):
            set_counter(self.fs, 1)

    def test_without_the_par_3_rule_a_par_3_doubles_like_any_hole(self):
        self._game(par3_triples=False)
        self._open(3)
        bet = set_double(self.fs, 3, self.pid['Dave'])
        self.assertEqual(bet.own_multiplier, 2)

    def test_without_the_birdie_bonus_a_birdie_just_wins(self):
        self._game(birdie_bonus=False)
        self._open()
        submit_hole(self.fs, 1, [(self.pid['Paul'], 5), (self.pid['Dave'], 3),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        line = next(l for l in banker_summary(self.fs)['holes'][0]['lines']
                    if l['player_id'] == self.pid['Dave'])
        self.assertEqual(line['amount'], Decimal('10'))
        self.assertFalse(line['birdie'])

    def test_the_ladder_drops_rungs_the_group_cannot_reach(self):
        """A ladder overstating what THIS group can lose is not an argument,
        it is a scare."""
        game = self._game(allow_counter=False, birdie_bonus=False)
        labels = [r['label'] for r in exposure_ladder(game)]
        self.assertNotIn('Banker counter-doubles', labels)
        self.assertEqual(labels[-1], 'On a par 3, tripled instead')
        self.assertEqual(exposure_ladder(game)[-1]['amount'], Decimal('450'))

    def test_all_four_on_is_the_full_climb(self):
        game = self._game()
        self.assertEqual([r['amount'] for r in exposure_ladder(game)],
                         [Decimal(n) for n in (150, 300, 600, 900, 1800)])

    def test_the_summary_states_which_rules_are_live(self):
        self._game(allow_counter=False)
        rules = banker_summary(self.fs)['rules']
        self.assertFalse(rules['counter'])
        self.assertTrue(rules['player_double'])


class BankerBoardTests(TestCase):
    """What the leaderboard reads. The board exists because nobody can
    reconstruct fifty-four one-on-ones from memory, so the invariants that make
    it trustworthy are worth pinning."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                                 min_bet=5, max_bet=50)

    def _hole(self, hole, banker, bets, scores, counter=False):
        row = self.game.holes.filter(hole_number=hole).first()
        if row is None:
            row = BankerHole.objects.create(game=self.game, hole_number=hole,
                                            banker_id=self.pid[banker])
        set_hole_max(self.fs, hole, max(bets.values()))
        for n, amt in bets.items():
            place_bet(self.fs, hole, self.pid[n], amt)
        lock_bets(self.fs, hole)
        if counter:
            set_counter(self.fs, hole)
        submit_hole(self.fs, hole,
                    [(self.pid[n], v) for n, v in scores.items()])

    def test_every_hole_row_sums_to_zero(self):
        """Every bet was one-on-one, so the row has to balance — it is the one
        check a reader can run on the whole board at a glance."""
        self._hole(1, 'Paul', {'Dave': 10, 'Sam': 20, 'Lee': 5},
                   {'Paul': 5, 'Dave': 4, 'Sam': 6, 'Lee': 5}, counter=True)
        h = banker_summary(self.fs)['holes'][0]
        moves = {h['banker_id']: h['banker_delta']}
        for l in h['lines']:
            moves[l['player_id']] = (l['amount'] if l['outcome'] == 'won'
                                     else -l['amount'] if l['outcome'] == 'lost'
                                     else ZERO)
        self.assertEqual(sum(moves.values()), Decimal('0'))

    def test_the_biggest_hole_is_named_by_its_largest_single_move(self):
        """Ranking by the banker's own delta would bury the hole where the
        bets cancelled to nothing for him while the money moved around him."""
        # Paul collects 20 from Sam and pays 20 to Dave: he ends level, but
        # forty dollars changed hands.
        self._hole(1, 'Paul', {'Dave': 20, 'Sam': 20, 'Lee': 5},
                   {'Paul': 5, 'Dave': 4, 'Sam': 6, 'Lee': 5})
        w = banker_summary(self.fs)['biggest_swings'][0]
        self.assertEqual(w['hole'], 1)
        # He is exactly level, which is the case that would vanish from a
        # board ranked on the banker's own number.
        self.assertEqual(w['banker_delta'], Decimal('0'))
        self.assertEqual(w['amount'], Decimal('40'))
        self.assertEqual(abs(w['top_amount']), Decimal('20'))
        self.assertIn(w['top_name'], {'D', 'S'})

    def test_the_settled_count_is_one_on_ones_not_holes(self):
        self._hole(1, 'Paul', {'Dave': 10, 'Sam': 10, 'Lee': 10},
                   {'Paul': 5, 'Dave': 4, 'Sam': 6, 'Lee': 5})
        self.assertEqual(banker_summary(self.fs)['bets_settled'], 3)

    def test_an_unplayed_hole_contributes_nothing(self):
        s = banker_summary(self.fs)
        self.assertEqual(s['bets_settled'], 0)
        self.assertEqual(s['biggest_swings'], [])
        self.assertTrue(all(p['total'] == ZERO for p in s['players']))


class BankerRotationAnnouncementTests(TestCase):
    """A role that changed hands unannounced is the fastest way to have two
    golfers both think they are banking the 8th."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'])
        set_hole_max(self.fs, 1, 10)
        for who in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, 1, self.pid[who], 10)
        lock_bets(self.fs, 1)

    def test_an_outright_winner_is_named_before_the_next_hole_opens(self):
        submit_hole(self.fs, 1, [(self.pid['Paul'], 5), (self.pid['Dave'], 4),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        s = banker_summary(self.fs)
        self.assertIsNone(s['awaiting_tie'])
        self.assertEqual(s['next_banker_id'], self.pid['Dave'])
        self.assertEqual(s['next_banker_name'], 'Dave')

    def test_a_tie_names_nobody_and_asks_instead(self):
        submit_hole(self.fs, 1, [(self.pid['Paul'], 5), (self.pid['Dave'], 4),
                                 (self.pid['Sam'], 4), (self.pid['Lee'], 5)])
        s = banker_summary(self.fs)
        self.assertIsNone(s['next_banker_id'])
        self.assertEqual(s['awaiting_tie'], 1)

    def test_an_unfinished_hole_names_nobody(self):
        submit_hole(self.fs, 1, [(self.pid['Paul'], 5)])
        s = banker_summary(self.fs)
        self.assertIsNone(s['next_banker_id'])
        self.assertIsNone(s['awaiting_tie'])
