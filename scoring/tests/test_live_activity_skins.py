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
        self.assertEqual(s['state']['word'], '—')

    def test_a_tie_carries_and_the_number_grows(self):
        self._play(1, 4, 4, 4, 4)       # halved — carries
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], '$12')
        self.assertEqual(s['state']['word'], 'CARRIED')

    def test_the_slot_says_where_the_pot_came_from(self):
        """Nobody is named — in skins the field is the opponent, and naming it
        would be a list."""
        self._play(1, 4, 4, 4, 4)
        self._play(2, 4, 4, 4, 4)
        s = self._state(thru=2)
        self.assertEqual(s['number']['text'], '$18')
        self.assertEqual(s['sides'][0]['names'],
                         '3 skins, carried from the 1st')

    def test_a_carry_breaking_resets_the_number(self):
        self._play(1, 4, 4, 4, 4)       # carries
        self._play(2, 3, 4, 4, 4)       # Paul takes 2 skins
        s = self._state(thru=2)
        self.assertEqual(s['number']['text'], '$6')
        self.assertEqual(s['sides'][0]['names'], 'A fresh skin')

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

    def test_the_headline_is_the_pool_not_the_hole(self):
        self._play(1, 3, 4, 4, 4)
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], '$8')      # 4 players x $2
        self.assertIn('POOL', s['header']['game'])

    def test_the_share_falls_as_skins_are_won(self):
        self._play(1, 3, 4, 4, 4)                        # 1 skin -> whole pool
        first = self._state(thru=1)['state']['word']
        self._play(2, 4, 3, 4, 4)                        # 2 skins -> halved
        second = self._state(thru=2)['state']['word']
        self.assertEqual(first, '$8')
        self.assertEqual(second, '$4')
        self.assertEqual(self._state(thru=2)['state']['to_play'],
                         'A SKIN, FALLING')

    def test_the_story_line_is_the_arithmetic_not_the_origin(self):
        """The pool is fixed and the share falls, so the reader needs the count
        rather than where a carry started."""
        self._play(1, 3, 4, 4, 4)
        self.assertIn('in the pool', self._state(thru=1)['sides'][0]['names'])


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

    def test_the_footer_counts_what_has_actually_settled(self):
        self._play(1, 3, 4, 4, 4)
        self.assertIn('1 settled', self._state(thru=1)['footer']['context'])


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
