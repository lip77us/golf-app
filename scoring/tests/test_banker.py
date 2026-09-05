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
from services.banker import (BankerLocked, banker_settlement, banker_summary,
                             exposure_ladder, hole_exposure, lock_bets,
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
        self.assertEqual(hole_exposure(self.game, row), Decimal('100'))

    def test_exposure_moves_when_a_double_lands(self):
        self._bets(1, Dave=10, Sam=10, Lee=10)
        row = self.game.holes.get(hole_number=1)
        before = hole_exposure(self.game, row)
        set_double(self.fs, 1, self.pid['Dave'])
        row.refresh_from_db()
        self.assertGreater(hole_exposure(self.game, row), before)

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

    # -- handicap ------------------------------------------------------------

    def test_strokes_off_low_is_refused(self):
        """A match mechanism with no meaning in three separate one-on-ones."""
        with self.assertRaises(ValueError):
            setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                         handicap_mode=HandicapMode.STROKES_OFF)


class BankerNetTests(TestCase):
    """The same game off real handicaps — every one-on-one settles on net,
    the banker's included."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.fs = make_foursome(self.round,
                                [('Paul', 18), ('Dave', 0), ('Sam', 0),
                                 ('Lee', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.game = setup_banker(self.fs, first_banker_id=self.pid['Paul'])

    def test_the_bankers_own_stroke_counts(self):
        """Paul gets a shot on every hole at 18, so a gross tie is a net win
        for him and the bet pays the banker."""
        set_hole_max(self.fs, 1, 10)
        for who in ('Dave', 'Sam', 'Lee'):
            place_bet(self.fs, 1, self.pid[who], 10)
        lock_bets(self.fs, 1)
        submit_hole(self.fs, 1, [(self.pid['Paul'], 4), (self.pid['Dave'], 4),
                                 (self.pid['Sam'], 4), (self.pid['Lee'], 4)])
        h = next(x for x in banker_summary(self.fs)['holes'] if x['hole'] == 1)
        self.assertEqual(h['banker_net'], 3)
        self.assertEqual(h['banker_delta'], Decimal('30'))
