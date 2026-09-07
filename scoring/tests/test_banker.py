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
from games.models import BankerBet, BankerGame, BankerHole
from services.banker import (ZERO, BankerLocked, banker_settlement, cap_for,
                             banker_summary,
                             exposure_ladder, hole_exposure,
                             hole_exposure_if_max, lock_bets,
                             open_next_hole, pair_strokes, place_bet,
                             set_counter,
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

    def test_the_rotation_ranks_on_the_scale_the_card_shows(self):
        """The bank passes on strokes off the LOW golfer — what the card
        draws, what the dots show, what the `gets` chips state.

        Sam is the low man off 4, so on this stroke index 1 hole Paul and Lee
        (off 8) stroke and Dave (off 12) does too, while Sam plays gross:
        nets 4, 5, 5, 4. Paul and Lee tie.
        """
        self._open(5)
        submit_hole(self.fs, 5, [(self.pid['Paul'], 5), (self.pid['Dave'], 6),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        s = banker_summary(self.fs)
        self.assertEqual(s['awaiting_tie'], 5)
        self.assertEqual({c['short_name'] for c in s['tie_candidates']},
                         {'P', 'L'})

    def test_a_golfer_is_not_offered_a_tie_the_card_says_he_lost(self):
        """The bug this replaced, in miniature.

        Ranking on each golfer's FULL allocation is not the same as ranking
        off the low man, and the gap is not a constant — allocation is not
        linear. A golfer off 11 strokes down to index 11 on the full scale but
        only to index 5 off a low man of 6, so on an index 9 hole the full
        scale hands him a shot the card plainly does not, and he was offered a
        bank he had not tied for.
        """
        self._open(9)          # stroke index 5 on the test card
        submit_hole(self.fs, 9, [(self.pid['Paul'], 5), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 5), (self.pid['Lee'], 5)])
        s = banker_summary(self.fs)
        # Read the net straight off the CARD the group sees: gross minus the
        # dots drawn on it. If the rotation and the card can disagree, one of
        # them is lying to somebody standing on a tee.
        grid = next(x for x in s['grid'] if x['hole'] == 9)
        short = {p['player_id']: p['short_name'] for p in s['players']}
        rot = {short[sc['player_id']]: sc['gross'] - sc['strokes']
               for sc in grid['scores'] if sc['gross'] is not None}
        best = min(rot.values())
        for c in s['tie_candidates']:
            name = c['short_name']
            self.assertEqual(rot[name], best,
                             f'{name} was offered the bank at {rot[name]} '
                             f'when the card says {best} won the hole')


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


class BankerDisplayedHandicapTests(TestCase):
    """The screen shows each golfer off the LOW one, because a gap is easier to
    read when one end is zero. That is a display convention and must never
    reach the money."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 16), ('Sean', 6), ('Jim', 17),
                                 ('Ryan', 11)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Jim'])
        set_hole_max(self.fs, 1, 10)
        for who in ('Paul', 'Sean', 'Ryan'):
            place_bet(self.fs, 1, self.pid[who], 10)
        lock_bets(self.fs, 1)
        submit_hole(self.fs, 1, [(self.pid[n], 5)
                                 for n in ('Paul', 'Sean', 'Jim', 'Ryan')])

    def _hole(self):
        return next(h for h in banker_summary(self.fs)['holes']
                    if h['hole'] == 1)

    def test_the_low_golfer_shows_zero_and_the_rest_their_gap(self):
        h = self._hole()
        shown = {l['short_name']: l['playing_handicap'] for l in h['lines']}
        self.assertEqual(shown['S'], 0)      # Sean is the low man
        self.assertEqual(shown['R'], 5)
        self.assertEqual(shown['P'], 10)
        self.assertEqual(h['banker_handicap'], 11)   # Jim, off 17

    def test_the_difference_of_two_shown_numbers_is_the_strokes_in_that_match(self):
        """The whole point of showing it this way — and the invariant that
        makes it safe, since subtracting the same constant from everybody
        cannot change a difference."""
        h = self._hole()
        for l in h['lines']:
            s_b, s_o = pair_strokes(self.game, self.fs, self.pid['Jim'],
                                    l['player_id'], 1)
            gap = (l['playing_handicap'] or 0) - (h['banker_handicap'] or 0)
            # The sign of the gap is the direction of the shot, every time.
            if gap > 0:
                self.assertEqual(s_b, 0)
            elif gap < 0:
                self.assertEqual(s_o, 0)
            else:
                self.assertEqual((s_b, s_o), (0, 0))
            # And the row's own signed figure agrees with the gap's sign.
            self.assertEqual(l['strokes'] > 0, gap > 0 and s_o > 0)
            self.assertEqual(l['strokes'] < 0, gap < 0 and s_b > 0)

    def test_the_money_is_unchanged_by_how_the_handicap_is_displayed(self):
        """Every bet settles off the raw numbers; showing them off the low
        golfer is arithmetic on the screen and nowhere else.

        Four identical fives, and the hole is not a wash — which is the shape
        of this game in one line. Hole 1 is stroke index 7, so a gap only pays
        a shot when it reaches that far down the card: Jim is 11 clear of Sean
        and takes one from him, but only 6 clear of Ryan and 1 clear of Paul,
        so those two halve.
        """
        h = self._hole()
        by = {l['short_name']: l for l in h['lines']}
        self.assertEqual(by['S']['outcome'], 'lost')
        self.assertEqual(by['R']['outcome'], 'tied')
        self.assertEqual(by['P']['outcome'], 'tied')
        self.assertEqual(h['banker_delta'], Decimal('10'))


class BankerCardPlanTests(TestCase):
    """The shared card shows the stroke PLAN, so it has to be complete on the
    first tee — a card that fills in as it is played cannot be read forwards,
    which is most of what a card is for."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 16), ('Sean', 6), ('Jim', 17),
                                 ('Ryan', 11)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_banker(self.fs, first_banker_id=self.pid['Jim'])

    def _grid(self):
        return {h['hole']: h for h in banker_summary(self.fs)['grid']}

    def test_the_whole_plan_is_there_before_a_ball_is_struck(self):
        grid = self._grid()
        self.assertEqual(len(grid), 18)
        planned = sum(1 for h in grid.values()
                      for sc in h['scores'] if sc['strokes'] > 0)
        self.assertGreater(planned, 0)

    def test_holes_nobody_has_reached_still_carry_their_strokes(self):
        """The bug this replaced: with no banker on a future hole there was
        nobody for a pairwise dot to be pairwise with, so every hole ahead
        showed an empty plan."""
        grid = self._grid()
        # Hole 18 has no banker and never will until it is reached.
        self.assertIsNone(grid[18]['banker_id'])
        self.assertTrue(any(sc['strokes'] > 0 for sc in grid[18]['scores']))

    def test_the_low_golfer_never_carries_a_dot(self):
        grid = self._grid()
        for h in grid.values():
            for sc in h['scores']:
                if sc['player_id'] == self.pid['Sean']:
                    self.assertEqual(sc['strokes'], 0)

    def test_each_golfer_gets_his_whole_allocation_over_the_round(self):
        """Off the low man, so the totals are the gaps: Ryan 5, Paul 10,
        Jim 11 — the same numbers the `gets` chips state."""
        grid = self._grid()
        got = {}
        for h in grid.values():
            for sc in h['scores']:
                got[sc['player_id']] = got.get(sc['player_id'], 0) + sc['strokes']
        self.assertEqual(got[self.pid['Ryan']], 5)
        self.assertEqual(got[self.pid['Paul']], 10)
        self.assertEqual(got[self.pid['Jim']], 11)

    def test_gold_marks_who_banked_and_nothing_else(self):
        grid = self._grid()
        self.assertEqual(grid[1]['banker_id'], self.pid['Jim'])
        self.assertIsNone(grid[1]['winner_id'])


class BankerHoleShapeTests(TestCase):
    """Every hole in the summary answers the same questions, opened or not — a
    reader that works for sixteen holes and trips on the seventeenth is worse
    than one that never worked."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_banker(self.fs, first_banker_id=self.pid['Paul'])

    def test_an_unopened_hole_has_the_same_keys_as_an_opened_one(self):
        holes = banker_summary(self.fs)['holes']
        opened = next(h for h in holes if h['banker_id'] is not None)
        unopened = next(h for h in holes if h['banker_id'] is None)
        self.assertEqual(set(opened), set(unopened))

    def test_an_unopened_hole_still_knows_its_own_card(self):
        h = next(x for x in banker_summary(self.fs)['holes'] if x['hole'] == 3)
        self.assertEqual(h['par'], 3)
        self.assertEqual(h['stroke_index'], 15)
        self.assertTrue(h['is_par_3'])


class BankerThreeHandedTests(TestCase):
    """One banker and TWO opponents. The format does not need a fourth — it
    needs somebody to bank and somebody to bet against him — so every count
    that assumes three bets has to hold at two."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 8), ('Dave', 12), ('Sam', 4)],
                                tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                                 min_bet=5, max_bet=50)

    def _play(self, hole, bets, scores, counter=False):
        set_hole_max(self.fs, hole, max(bets.values()))
        for n, amt in bets.items():
            place_bet(self.fs, hole, self.pid[n], amt)
        lock_bets(self.fs, hole)
        if counter:
            set_counter(self.fs, hole)
        submit_hole(self.fs, hole,
                    [(self.pid[n], v) for n, v in scores.items()])

    def test_the_lock_wants_two_bets_not_three(self):
        set_hole_max(self.fs, 1, 20)
        place_bet(self.fs, 1, self.pid['Dave'], 10)
        with self.assertRaises(ValueError):
            lock_bets(self.fs, 1)          # Sam still to bet
        place_bet(self.fs, 1, self.pid['Sam'], 10)
        self.assertIsNotNone(lock_bets(self.fs, 1).locked_at)

    def test_two_one_on_ones_settle_and_the_table_is_zero_sum(self):
        self._play(1, {'Dave': 10, 'Sam': 20},
                   {'Paul': 5, 'Dave': 4, 'Sam': 6}, counter=True)
        s = banker_summary(self.fs)
        self.assertEqual(s['bets_settled'], 2)
        self.assertEqual(sum(p['total'] for p in s['players']), Decimal('0'))

    def test_the_ladder_counts_two_opponents(self):
        """Nobody setting up a three-handed game should be shown a four-handed
        worst case."""
        ladder = exposure_ladder(self.game, 2)
        self.assertEqual(ladder[0]['label'], '2 opponents at the max')
        self.assertEqual(ladder[0]['amount'], Decimal('100'))
        self.assertEqual(ladder[-1]['amount'], Decimal('1200'))

    def test_the_summary_reports_a_two_opponent_ladder_by_itself(self):
        rungs = banker_summary(self.fs)['exposure_ladder']
        self.assertEqual(rungs[0]['label'], '2 opponents at the max')

    def test_the_bank_still_rotates_between_three(self):
        self._play(1, {'Dave': 10, 'Sam': 10},
                   {'Paul': 6, 'Dave': 4, 'Sam': 6})
        nxt = open_next_hole(self.fs, 1)
        self.assertEqual(nxt.banker_id, self.pid['Dave'])

    def test_the_card_carries_all_three_rows(self):
        self._play(1, {'Dave': 10, 'Sam': 10},
                   {'Paul': 5, 'Dave': 4, 'Sam': 6})
        s = banker_summary(self.fs)
        self.assertEqual(len(s['grid_players']), 3)
        self.assertEqual(len(s['grid'][0]['scores']), 3)


class BankerLossCapTests(TestCase):
    """The loss cap is a THRESHOLD, not a clamp.

    Nothing already owed is forgiven and no total is scaled — which is what
    keeps this game's itemised receipt honest, since it is the only settlement
    in the app that names who owes whom for which hole. What the cap changes is
    the future: at his ceiling a golfer is cut off from the ACTION, not from
    the game.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        # Each golfer names his own number. Dave says $40; nobody else caps.
        self.game = setup_banker(
            self.fs, first_banker_id=self.pid['Paul'], min_bet=5, max_bet=50,
            loss_caps={self.pid['Dave']: 40})

    def _hole(self, hole, banker, bets, scores, doubles=(), counter=False):
        row = self.game.holes.filter(hole_number=hole).first()
        if row is None:
            row = BankerHole.objects.create(game=self.game, hole_number=hole,
                                            banker_id=self.pid[banker])
        set_hole_max(self.fs, hole, max(bets.values()))
        for n, amt in bets.items():
            place_bet(self.fs, hole, self.pid[n], amt)
        lock_bets(self.fs, hole)
        for n in doubles:
            set_double(self.fs, hole, self.pid[n])
        if counter:
            set_counter(self.fs, hole)
        submit_hole(self.fs, hole,
                    [(self.pid[n], v) for n, v in scores.items()])

    def _open(self, hole, banker='Paul'):
        BankerHole.objects.get_or_create(
            game=self.game, hole_number=hole,
            defaults={'banker_id': self.pid[banker]})

    def _sink_dave(self, amount=50):
        """Dave loses in one hole — past a $40 cap."""
        self._hole(1, 'Paul', {'Dave': amount, 'Sam': 5, 'Lee': 5},
                   {'Paul': 4, 'Dave': 5, 'Sam': 4, 'Lee': 4})

    def _totals(self):
        return {p['short_name']: p for p in banker_summary(self.fs)['players']}

    # -- what the screen has to be able to draw --------------------------

    def test_the_hole_in_play_names_who_is_cut_off(self):
        """The play screen cannot grey out what it cannot see.

        Phase 1 offered a cut off golfer the whole ladder and then showed the
        floor lighting up instead, and phase 2 lit his double button and
        answered the tap with a server error. Both need the set on the HOLE,
        not only the round totals — a golfer cut off on the 3rd is in the
        action on the 1st, and the same payload draws both.
        """
        self._sink_dave()
        self._open(2)
        cur = banker_summary(self.fs)['current']
        self.assertEqual(cur['hole'], 2)
        self.assertEqual(cur['cut_off'], [self.pid['Dave']])

    def test_the_floor_goes_down_for_him_the_moment_the_hole_has_a_maximum(self):
        """He has one bet available and no way to change it, so the app puts
        it down rather than asking him to tap a chip that cannot say anything
        else — and rather than holding the lock while the other two wait."""
        self._sink_dave()
        self._open(2)
        set_hole_max(self.fs, 2, 50)
        bet = BankerBet.objects.get(hole__game=self.game, hole__hole_number=2,
                                    player_id=self.pid['Dave'])
        self.assertEqual(bet.amount, Decimal('5'))
        # Only him. The other two still name their own numbers.
        self.assertEqual(
            BankerBet.objects.filter(hole__game=self.game,
                                     hole__hole_number=2).count(), 1)

    def test_a_bet_placed_before_the_lock_already_says_it_is_capped(self):
        """Phase 2 draws its rows and its buttons off the lines, and it draws
        them while the hole is still open. A `capped` flag that only appeared
        once the hole resolved would be right at the one moment nobody can act
        on it."""
        self._sink_dave()
        self._open(2)
        set_hole_max(self.fs, 2, 50)
        for n in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, 2, self.pid[n], 50)
        lines = {l['player_id']: l
                 for l in banker_summary(self.fs)['current']['lines']}
        self.assertTrue(lines[self.pid['Dave']]['capped'])
        self.assertFalse(lines[self.pid['Sam']]['capped'])
        # And the floor is what he actually has on it, whatever he tapped.
        self.assertEqual(lines[self.pid['Dave']]['bet'], Decimal('5'))

    # -- the threshold -------------------------------------------------------

    def test_nothing_already_owed_is_forgiven(self):
        """He is $50 down against a $40 cap and he owes all fifty. A clamp
        would have quietly rewritten a hole the group had already read out."""
        self._sink_dave()
        self.assertEqual(self._totals()['D']['total'], Decimal('-50'))
        self.assertEqual(self._totals()['P']['total'], Decimal('50'))

    def test_the_table_still_balances(self):
        self._sink_dave()
        self.assertEqual(
            sum(p['total'] for p in banker_summary(self.fs)['players']),
            Decimal('0'))

    def test_crossing_the_line_cuts_him_off(self):
        self._sink_dave()
        me = self._totals()['D']
        self.assertTrue(me['cut_off'])
        self.assertEqual(me['cut_off_hole'], 1)
        self.assertFalse(self._totals()['S']['cut_off'])

    # -- what being cut off costs him ---------------------------------------

    def test_he_is_held_to_the_floor(self):
        self._sink_dave()
        self._open(2)
        set_hole_max(self.fs, 2, 50)
        bet = place_bet(self.fs, 2, self.pid['Dave'], 50)
        self.assertEqual(bet.amount, Decimal('5'))     # the round's floor

    def test_he_cannot_double(self):
        self._sink_dave()
        self._open(2)
        set_hole_max(self.fs, 2, 20)
        for n in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, 2, self.pid[n], 20 if n != 'Dave' else 5)
        lock_bets(self.fs, 2)
        with self.assertRaises(ValueError):
            set_double(self.fs, 2, self.pid['Dave'])
        set_double(self.fs, 2, self.pid['Sam'])        # unaffected

    def test_the_counter_goes_past_him(self):
        """One decision that lands on every standing bet — except the one the
        cap has taken out of the action."""
        self._sink_dave()
        self._hole(2, 'Paul', {'Dave': 5, 'Sam': 20, 'Lee': 20},
                   {'Paul': 5, 'Dave': 6, 'Sam': 6, 'Lee': 6}, counter=True)
        lines = {l['short_name']: l
                 for l in banker_summary(self.fs)['holes'][1]['lines']}
        self.assertEqual(lines['D']['stake'], Decimal('5'))    # not doubled
        self.assertTrue(lines['D']['capped'])
        self.assertFalse(lines['D']['countered'])
        self.assertEqual(lines['S']['stake'], Decimal('40'))   # doubled

    def test_he_cannot_take_the_bank(self):
        """The role is the biggest exposure in the game — three bets at once —
        so handing it to the man the cap protects would undo it in one hole."""
        self._sink_dave()
        self._open(2)
        # Dave has the low net and cannot have it; Sam is next, outright.
        self._hole(2, 'Paul', {'Dave': 5, 'Sam': 20, 'Lee': 20},
                   {'Paul': 5, 'Dave': 3, 'Sam': 4, 'Lee': 5})
        nxt = open_next_hole(self.fs, 2)
        self.assertEqual(nxt.banker_id, self.pid['Sam'])

    def test_when_the_low_net_is_cut_off_the_rest_can_still_tie_for_it(self):
        """Skipping him does not skip the question — the two behind him are
        level, and a phone still cannot see who holed out first."""
        self._sink_dave()
        self._open(2)
        self._hole(2, 'Paul', {'Dave': 5, 'Sam': 20, 'Lee': 20},
                   {'Paul': 5, 'Dave': 3, 'Sam': 5, 'Lee': 5})
        s = banker_summary(self.fs)
        self.assertEqual(s['awaiting_tie'], 2)
        # Paul is among them: he banked the hole, and a banker with the low
        # net keeps the role like anybody else. Dave, who actually had it, is
        # the only man skipped.
        self.assertEqual({c['short_name'] for c in s['tie_candidates']},
                         {'P', 'S', 'L'})

    # -- and what it does not do --------------------------------------------

    def test_he_can_still_drift_past_his_own_ceiling(self):
        """A soft landing, not an exit — the cap buys him the minimum, not
        immunity."""
        self._sink_dave()
        self._open(2)
        self._hole(2, 'Paul', {'Dave': 5, 'Sam': 5, 'Lee': 5},
                   {'Paul': 4, 'Dave': 6, 'Sam': 4, 'Lee': 4})
        self.assertEqual(self._totals()['D']['total'], Decimal('-55'))

    def test_winning_back_does_not_restore_his_doubles(self):
        """Cut off by the house until the next round. A cap that switched off
        and on again would be a free option: lose to the line, take the
        protection, win a hole, hand it back."""
        # $42 down against a $40 cap, so ONE floor win puts him back above it —
        # which is the whole point of the test.
        self._sink_dave(42)
        self._open(2)
        self._hole(2, 'Paul', {'Dave': 5, 'Sam': 50, 'Lee': 50},
                   {'Paul': 6, 'Dave': 3, 'Sam': 3, 'Lee': 3})
        # Gross 3 on a par 4 is a birdie, so his floor $5 doubles to $10 —
        # the cap took his CALLS, not his golf.
        me = self._totals()['D']
        self.assertEqual(me['total'], Decimal('-32'))     # back above the line
        self.assertTrue(me['cut_off'])

    def test_the_birdie_bonus_still_reaches_him(self):
        """The cap takes away what he can CALL, not what he earns. A birdie is
        not aggression — it is a good shot — and a capped golfer holing one
        still doubles his own floor bet."""
        self._sink_dave()
        self._open(2)
        self._hole(2, 'Paul', {'Dave': 5, 'Sam': 5, 'Lee': 5},
                   {'Paul': 5, 'Dave': 3, 'Sam': 5, 'Lee': 5})
        line = next(l for l in banker_summary(self.fs)['holes'][1]['lines']
                    if l['short_name'] == 'D')
        self.assertTrue(line['birdie'])
        self.assertEqual(line['amount'], Decimal('10'))   # $5 floor, doubled

    def test_the_live_hole_never_moves_the_line(self):
        """Settled holes only — Nassau's non-aggressive rule. Being cut off has
        to be a fact about what has already happened, or a golfer would lose
        his double halfway through calling it."""
        set_hole_max(self.fs, 1, 50)
        for n in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, 1, self.pid[n], 50)
        lock_bets(self.fs, 1)
        set_double(self.fs, 1, self.pid['Dave'])          # still allowed
        self.assertEqual(self.game.holes.get(hole_number=1)
                         .bets.get(player_id=self.pid['Dave'])
                         .own_multiplier, 2)

    def test_no_cap_means_no_cut_off(self):
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     min_bet=5, max_bet=50)
        self._sink_dave()
        self.assertFalse(self._totals()['D']['cut_off'])
        self.assertEqual(self._totals()['D']['total'], Decimal('-50'))

    def test_each_golfer_carries_his_own_number(self):
        """Four golfers, four appetites — one man's ceiling must not cut
        anybody else off."""
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     min_bet=5, max_bet=50,
                     loss_caps={self.pid['Dave']: 40, self.pid['Sam']: 200})
        self._hole(1, 'Paul', {'Dave': 50, 'Sam': 50, 'Lee': 50},
                   {'Paul': 4, 'Dave': 5, 'Sam': 5, 'Lee': 5})
        t = self._totals()
        self.assertTrue(t['D']['cut_off'])        # $50 down against $40
        self.assertFalse(t['S']['cut_off'])       # $50 down against $200
        self.assertFalse(t['L']['cut_off'])       # no number at all
        self.assertEqual(t['D']['loss_cap'], Decimal('40'))
        self.assertIsNone(t['L']['loss_cap'])

    def test_a_zero_is_not_a_cap(self):
        """A golfer who declined to name one is playing without a cap, not
        with a cap of nothing."""
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     min_bet=5, max_bet=50, loss_caps={self.pid['Dave']: 0})
        self._sink_dave()
        self.assertFalse(self._totals()['D']['cut_off'])


class BankerCapInputTests(TestCase):
    """`loss_caps` arrives as JSON from a client, so the keys are whatever the
    client sent. A key that names no golfer caps nobody — it must not take the
    whole setup down."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self, caps):
        return setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                            min_bet=5, max_bet=50, loss_caps=caps)

    def test_a_key_that_names_nobody_is_dropped_not_raised(self):
        """A client once sent the literal string '$k' for every key — an
        un-interpolated template — and it raised out of a POST that was
        otherwise perfectly good."""
        game = self._setup({'$k': 100, self.pid['Dave']: 40})
        self.assertEqual(cap_for(game, self.pid['Dave']), Decimal('40'))

    def test_an_amount_that_is_not_a_number_is_dropped(self):
        game = self._setup({self.pid['Dave']: 'lots'})
        self.assertIsNone(cap_for(game, self.pid['Dave']))

    def test_string_keys_and_int_keys_both_land(self):
        """JSON round-trips the map with string keys; the app sends ints."""
        game = self._setup({str(self.pid['Dave']): 40})
        self.assertEqual(cap_for(game, self.pid['Dave']), Decimal('40'))


class BankerHoleCapTests(TestCase):
    """The hole cap: one ceiling on what a single hole can reach, all bets and
    doubles included.

    It used to live only inside `hole_exposure`, so the banner obeyed it and
    the settlement did not — the screen promised a ceiling and the money went
    straight through it.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 0), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _game(self, cap=None):
        return setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                            min_bet=5, max_bet=50,
                            hole_cap_enabled=cap is not None,
                            hole_cap_amount=cap)

    def _play(self, bets, scores, counter=False):
        set_hole_max(self.fs, 1, max(bets.values()))
        for n, amt in bets.items():
            place_bet(self.fs, 1, self.pid[n], amt)
        lock_bets(self.fs, 1)
        if counter:
            set_counter(self.fs, 1)
        submit_hole(self.fs, 1,
                    [(self.pid[n], v) for n, v in scores.items()])
        return banker_summary(self.fs)['holes'][0]

    def test_the_settlement_obeys_the_ceiling(self):
        self._game(cap=60)
        # $150 at stake, doubled by the counter to $300, capped to $60.
        h = self._play({'Dave': 50, 'Sam': 50, 'Lee': 50},
                       {'Paul': 4, 'Dave': 5, 'Sam': 5, 'Lee': 5},
                       counter=True)
        self.assertTrue(h['hole_capped'])
        self.assertEqual(sum(l['stake'] for l in h['lines']), Decimal('60'))
        self.assertEqual(h['banker_delta'], Decimal('60'))

    def test_without_the_cap_the_same_hole_runs_to_three_hundred(self):
        self._game()
        h = self._play({'Dave': 50, 'Sam': 50, 'Lee': 50},
                       {'Paul': 4, 'Dave': 5, 'Sam': 5, 'Lee': 5},
                       counter=True)
        self.assertFalse(h['hole_capped'])
        self.assertEqual(h['banker_delta'], Decimal('300'))

    def test_the_banner_and_the_settlement_agree(self):
        """They disagreed before: the exposure obeyed the cap and the money
        did not, so the screen was quietly lying about both."""
        self._game(cap=60)
        h = self._play({'Dave': 50, 'Sam': 50, 'Lee': 50},
                       {'Paul': 4, 'Dave': 5, 'Sam': 5, 'Lee': 5},
                       counter=True)
        self.assertEqual(h['exposure'], Decimal('60'))
        self.assertEqual(sum(l['stake'] for l in h['lines']), h['exposure'])

    def test_every_bet_is_scaled_by_the_same_factor(self):
        """A hole is one closed settlement, so scaling inside it is honest —
        and each golfer keeps his share of the hole."""
        self._game(cap=50)
        # $100 at stake against a $50 ceiling — everything halves, and Dave
        # still owns half the hole.
        h = self._play({'Dave': 50, 'Sam': 25, 'Lee': 25},
                       {'Paul': 4, 'Dave': 5, 'Sam': 5, 'Lee': 5})
        by = {l['short_name']: l['stake'] for l in h['lines']}
        self.assertEqual(by['D'], Decimal('25.00'))
        self.assertEqual(by['S'], Decimal('12.50'))
        self.assertEqual(by['L'], Decimal('12.50'))
        self.assertEqual(sum(by.values()), Decimal('50.00'))

    def test_a_hole_under_the_ceiling_is_untouched(self):
        self._game(cap=500)
        h = self._play({'Dave': 10, 'Sam': 10, 'Lee': 10},
                       {'Paul': 4, 'Dave': 5, 'Sam': 5, 'Lee': 5})
        self.assertFalse(h['hole_capped'])
        self.assertEqual(h['banker_delta'], Decimal('30'))

    def test_the_table_still_balances_under_the_cap(self):
        self._game(cap=60)
        self._play({'Dave': 50, 'Sam': 50, 'Lee': 50},
                   {'Paul': 4, 'Dave': 3, 'Sam': 5, 'Lee': 5}, counter=True)
        self.assertEqual(
            sum(p['total'] for p in banker_summary(self.fs)['players']),
            Decimal('0'))
