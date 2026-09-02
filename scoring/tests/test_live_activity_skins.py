"""
scoring/tests/test_live_activity_skins.py
-----------------------------------------
The Skins lock screen
(docs/design-review/handoff-live-activities/skins-HANDOFF.md).

Skins is always single-group here, so the packet's `PROVISIONAL` axis has no
reachable state and is not built (`SPEC.md`). What is left is the carry story,
the pool's falling share, and the rule that a money slot shows both directions
or it is not a position.
"""
from decimal import Decimal

from django.test import TestCase

from services.live_activity_skins import skins_activity_state
from services.skins import HandicapMode, calculate_skins, setup_skins
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    STAKE = Decimal('2.00')

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit     = self.STAKE
        self.round.active_games = ['skins']
        self.round.primary_game = 'skins'
        self.round.save(update_fields=['bet_unit', 'active_games',
                                       'primary_game'])
        self.fs = make_foursome(
            self.round, [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.configure()

    def configure(self):
        raise NotImplementedError

    def _play(self, hole, paul, dave, sam, lee):
        submit_hole(self.fs, hole, [(self.pid['Paul'], paul),
                                    (self.pid['Dave'], dave),
                                    (self.pid['Sam'], sam),
                                    (self.pid['Lee'], lee)])
        calculate_skins(self.fs)

    def _state(self, thru, who='Paul'):
        return skins_activity_state(self.fs, player_id=self.pid[who],
                                    thru=thru)


class CarryModeTests(_Base):
    """Per-skin with carries — the `$18, 3 skins carried from the 10th` card."""

    def configure(self):
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=True,
                    payout_style='per_point', per_point_mode='first',
                    per_point_rate=6)

    def test_a_fresh_hole_is_one_skin(self):
        self._play(1, 3, 4, 4, 4)       # Paul wins it outright
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], '$6')
        # The state slot is the READER's standing now, not the hole's carry
        # status — the carry is already the headline and the sub-line.
        self.assertEqual(s['state']['word'], '1 SKIN')
        self.assertEqual(s['state']['to_play'], 'YOU LEAD')

    def test_a_tie_carries_and_the_number_grows(self):
        self._play(1, 4, 4, 4, 4)       # halved — carries
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], '$12')
        self.assertEqual(s['sides'][0]['names'],
                         '2 skins, carried from the 1st')

    def test_the_slot_says_where_the_pot_came_from(self):
        """Nobody is named — in skins the field is the opponent, and naming it
        would be a list."""
        self._play(1, 4, 4, 4, 4)
        self._play(2, 4, 4, 4, 4)
        s = self._state(thru=2)
        self.assertEqual(s['number']['text'], '$18')
        self.assertEqual(s['sides'][0]['names'],
                         '3 skins, carried from the 1st')

    def test_a_broken_carry_puts_the_GOLFER_in_the_headline(self):
        """A running card leads with the money at stake; a card just after a
        payout leads with whoever took it, and the next hole's pot demotes to
        the sub-line. Six dollars after twelve is a footnote."""
        self._play(1, 4, 4, 4, 4)       # carries
        self._play(2, 3, 4, 4, 4)       # Paul takes 2 skins
        s = self._state(thru=2)
        self.assertEqual(s['number']['text'], 'P')
        self.assertEqual(s['state']['word'], 'WON $12')
        self.assertEqual(s['state']['to_play'], 'ON THE 2ND')
        self.assertIn('no carry', s['sides'][0]['names'])

    def test_a_chaser_reads_a_GAP_in_skins_not_a_placing(self):
        """'+2' is how many he has to take to draw level. '1ST OF 4' reads
        like a stroke-play finishing position and means nothing of the kind."""
        self._play(1, 3, 4, 4, 4)       # Paul
        self._play(3, 3, 4, 4, 4)       # Paul again -> 2 skins
        s = self._state(thru=3, who='Dave')
        self.assertEqual(s['state']['word'], '0 SKINS')
        self.assertEqual(s['state']['to_play'], 'P +2')

    def test_the_carryover_footer_counts_what_has_actually_settled(self):
        self._play(1, 3, 4, 4, 4)
        self.assertIn('1 settled', self._state(thru=1)['footer']['context'])

    def test_the_payout_card_gives_way_once_the_next_hole_is_played(self):
        self._play(1, 4, 4, 4, 4)
        self._play(2, 3, 4, 4, 4)       # Paul takes 2
        self._play(3, 4, 4, 4, 4)       # halved, carries again
        s = self._state(thru=3)
        self.assertEqual(s['number']['text'], '$12')

    def test_the_money_is_the_headline_and_that_is_the_exception(self):
        """The one game where the pot is not personal — everyone on the tee is
        playing for the same figure."""
        self._play(1, 4, 4, 4, 4)
        self.assertTrue(self._state(thru=1)['number']['text'].startswith('$'))

    def test_carryover_off_never_carries(self):
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=False,
                    payout_style='per_point', per_point_rate=6)
        self._play(1, 4, 4, 4, 4)
        self.assertEqual(self._state(thru=1)['number']['text'], '$6')


class PoolModeTests(_Base):
    """Pool divides one pot among however many skins get won, so every new skin
    makes yours worth less. The card says so rather than leaving the reader to
    divide."""

    def configure(self):
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=True,
                    payout_style='pool')

    def test_the_headline_is_the_COUNT_and_the_pot_is_a_footer_stat(self):
        """The pot is fixed at the ante and never moves; what changes is the
        divisor above it, so the count leads and $8 goes to the footer."""
        self._play(1, 3, 4, 4, 4)
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], '1 SKIN')
        self.assertIn('$8 pot', s['footer']['context'])
        self.assertIn('POOL', s['header']['game'])

    def test_the_share_falls_as_skins_are_won(self):
        self._play(1, 3, 4, 4, 4)                        # 1 skin -> whole pool
        first = self._state(thru=1)['state']['word']
        self._play(2, 4, 3, 4, 4)                        # 2 skins -> halved
        second = self._state(thru=2)['state']['word']
        self.assertEqual(first, '$8')
        self.assertEqual(second, '$4')
        # 'NOW' carries the falling, in one word rather than a clause.
        self.assertEqual(self._state(thru=2)['state']['to_play'],
                         'A SKIN NOW')

    def test_the_named_line_says_who_took_the_last_skin(self):
        """Reversed by the 2026-09-01 redesign: the slot used to restate the
        arithmetic, which the reader can already see above it. The last skin
        taken is the standing state of the game."""
        self._play(1, 3, 4, 4, 4)
        self.assertEqual(self._state(thru=1)['sides'][0]['names'],
                         'P took the 1st')

    def test_the_named_line_PERSISTS_until_somebody_else_wins(self):
        """It still reads on the next tee. Blanking it would hide the answer
        to the question the headline raises."""
        self._play(1, 3, 4, 4, 4)
        self._play(2, 4, 4, 4, 4)       # halved — nobody wins
        self.assertEqual(self._state(thru=2)['sides'][0]['names'],
                         'P took the 1st')


class FooterTests(_Base):
    def configure(self):
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=True,
                    payout_style='pool')

    def test_nothing_settled_means_an_empty_money_slot(self):
        self._play(1, 4, 4, 4, 4)       # halved, carries, nobody paid
        self.assertEqual(self._state(thru=1)['footer']['money'], '')

    def test_the_money_shows_both_directions(self):
        """A gross count of skins won reads like a win when you are down."""
        self._play(1, 3, 4, 4, 4)       # Paul takes the only skin
        self.assertTrue(self._state(thru=1, who='Paul')['footer']['money']
                        .startswith('+'))
        self.assertTrue(self._state(thru=1, who='Dave')['footer']['money']
                        .startswith('-'))

    def test_par_is_in_the_header(self):
        """The one game where par belongs on a lock screen: net skins turn on
        strokes, and whether a 4 is good enough is what the number is asking."""
        self._play(1, 3, 4, 4, 4)
        self.assertIn('PAR', self._state(thru=1)['header']['segment'])

    def test_the_pool_footer_is_pot_skins_ante_and_not_a_settled_count(self):
        """A pool divides at the end, so how many holes have settled tells the
        reader nothing he can spend. The divisor does, and it is above."""
        self._play(1, 3, 4, 4, 4)
        ctx = self._state(thru=1)['footer']['context']
        self.assertEqual(ctx, '$8 pot · 1 skin · $2 ante')

    def test_a_watcher_gets_the_leader_and_the_field_not_a_standing(self):
        """Nothing on a watcher's card is personal: he trades the reader's own
        count and money for who is ahead and how many are playing."""
        self._play(1, 3, 4, 4, 4)
        s = skins_activity_state(self.fs, player_id=None, thru=1)
        self.assertEqual(s['state']['word'], 'P')
        self.assertEqual(s['state']['to_play'], 'LEADS · 1')
        self.assertEqual(s['footer']['money'], '4 playing')
        self.assertNotIn('settled · ', s['footer']['money'])




class DispatchTests(_Base):
    def configure(self):
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=True,
                    payout_style='pool')

    def test_the_kind_is_skins_and_the_slots_are_the_contract(self):
        from django.contrib.auth import get_user_model
        from services.live_activity_registry import activity_state
        self._play(1, 3, 4, 4, 4)
        user = get_user_model().objects.create_user(
            username='td', account=self.round.account)
        user.is_account_admin = True
        user.save(update_fields=['is_account_admin'])
        state = activity_state(self.round, user)
        self.assertEqual(state['kind'], 'skins')
        self.assertEqual(set(state),
                         {'kind', 'header', 'number', 'sides', 'state', 'pips',
                          'final', 'footer'})


class PoolJunkTests(_Base):
    """Junk is a skin by another name — one pot, not two.

    A junk point is worth exactly what a skin is worth and divides the same
    money. An earlier draft buried it in the sub-line as a second, smaller pot,
    which made it look like a side bet and understated what the round is
    actually dividing.
    """

    def configure(self):
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=False,
                    payout_style='pool', allow_junk=True)

    def _junk(self, hole, who, count):
        from games.models import SkinsGame, SkinsPlayerHoleResult
        game = SkinsGame.objects.get(foursome=self.fs)
        SkinsPlayerHoleResult.objects.update_or_create(
            game=game, hole_number=hole, player_id=self.pid[who],
            defaults={'junk_count': count})
        calculate_skins(self.fs)

    def test_junk_counts_toward_the_headline_because_it_divides_the_same_pot(self):
        self._play(1, 3, 4, 4, 4)      # Paul: 1 skin
        self._junk(1, 'Paul', 1)       # ...and a junk point on the same hole
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], '2 SKINS')   # 1 skin + 1 junk
        self.assertEqual(s['state']['word'], '1 JUNK')

    def test_the_share_is_the_pot_over_EVERY_share_not_just_skins(self):
        """$8 over 2 shares is $4. Counting only skins would say $8 and be
        wrong by exactly the junk."""
        self._play(1, 3, 4, 4, 4)
        self._junk(1, 'Paul', 1)
        self.assertEqual(self._state(thru=1)['state']['to_play'], '$4 EACH NOW')

    def test_the_named_line_carries_the_split(self):
        """One hole can produce two shares, which is the thing about this
        variation a reader has to see once to understand."""
        self._play(1, 3, 4, 4, 4)
        self._junk(1, 'Paul', 1)
        self.assertEqual(self._state(thru=1)['sides'][0]['names'],
                         'P took the 1st — 1 skin, 1 junk')

    def test_junk_is_named_in_the_footer_rather_than_the_ante(self):
        self._play(1, 3, 4, 4, 4)
        self._junk(1, 'Paul', 1)
        self.assertEqual(self._state(thru=1)['footer']['context'],
                         '$8 pot · 1 skin · 1 junk')


class ClosingFrameTests(_Base):
    """Round sign. The one card that opens with a sentence rather than a value,
    and the only place a pool's per-skin figure is knowable."""

    def configure(self):
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=False,
                    payout_style='pool')

    def _final(self, who='Paul'):
        from services.live_activity_skins import skins_final_state
        return skins_final_state(self.fs, player_id=self.pid[who])

    def test_the_final_slot_matches_the_swift_struct_exactly(self):
        """{amount, detail, collect}, none optional. A shape Swift cannot
        decode is silent: APNs takes the push and the phone drops it."""
        self._play(1, 3, 4, 4, 4)
        self.assertEqual(set(self._final()['final']),
                         {'amount', 'detail', 'collect'})

    def test_the_per_skin_value_is_knowable_only_here(self):
        self._play(1, 3, 4, 4, 4)
        self._play(2, 4, 3, 4, 4)          # Dave takes one -> 2 shares of $8
        f = self._final()
        self.assertEqual(f['number']['text'], '$4')
        self.assertEqual(f['final']['detail'], 'per skin — 2 won')

    def test_it_lists_holders_without_ranking_them(self):
        """In a pool there is no overall winner, only golfers holding skins."""
        self._play(1, 3, 4, 4, 4)
        self._play(2, 4, 3, 4, 4)
        self.assertIn('Winners:', self._final()['sides'][0]['names'])

    def test_a_round_nobody_won_says_so_rather_than_dividing_by_zero(self):
        self._play(1, 4, 4, 4, 4)          # halved
        f = self._final()
        self.assertEqual(f['sides'][0]['names'], 'No skins were won')
        self.assertEqual(f['number']['text'], '$0')
