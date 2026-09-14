"""
scoring/tests/test_live_activity_las_vegas.py
---------------------------------------------
The Las Vegas lock screen.

**The card carries arithmetic, not news**, which is the whole argument for it:
each hole a side's two net scores become a two-digit number, the lower number
wins, and the difference is the points. Nobody does that subtraction between
shots.
"""
from decimal import Decimal

from django.test import TestCase

from services.vegas import setup_vegas, calculate_vegas, vegas_summary
from services.live_activity_las_vegas import (las_vegas_activity_state,
                                              las_vegas_final_state)
from ._helpers import (make_course, make_tee, make_round, make_foursome,
                       make_player, submit_hole)


class _Base(TestCase):
    """A and B against C and D, gross, a quarter a point — so the digits are
    the gross scores and the tests read as the golf did."""

    def setUp(self):
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['vegas'])
        self.round.bet_unit = Decimal('0.25')
        self.round.primary_game = 'vegas'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.p = [make_player(n, 0, short_name=n) for n in ('A', 'B', 'C', 'D')]
        self.fs = make_foursome(self.round, [(pl, 0) for pl in self.p],
                                tee=self.tee)

    def _setup(self, **kw):
        kw.setdefault('handicap_mode', 'gross')
        kw.setdefault('net_percent', 100)
        kw.setdefault('net_max_double_bogey', False)
        kw.setdefault('birdie_mode', 'flip')
        kw.setdefault('carryover', False)
        setup_vegas(self.fs, [self.p[0].id, self.p[1].id],
                    [self.p[2].id, self.p[3].id], **kw)

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [(self.p[0], a), (self.p[1], b),
                                    (self.p[2], c), (self.p[3], d)])
        calculate_vegas(self.fs)

    def _state(self, thru, who=0):
        return las_vegas_activity_state(self.fs, player_id=self.p[who].id,
                                        thru=thru)


class HeadlineTests(_Base):

    def test_the_headline_is_the_margin_not_the_two_totals(self):
        """Two numbers in the headline would make the reader subtract them to
        get the one he wanted. The margin IS the state of a game whose only
        output is points times a stake."""
        self._setup()
        self._play(1, 4, 5, 5, 7)        # 45 v 57 → team 1 by 12
        s = self._state(1)
        self.assertEqual(s['number']['text'], '+12')

    def test_it_is_signed_from_the_readers_side(self):
        """A departure from every other match card, and the sides being fixed
        at setup is what pays for it — there is no partner confusion to solve,
        and a signed figure that agrees with the money two rows below is worth
        more than a neutral one that does not."""
        self._setup()
        self._play(1, 4, 5, 5, 7)
        self.assertEqual(self._state(1, who=0)['number']['text'], '+12')
        self.assertEqual(self._state(1, who=2)['number']['text'], '−12')

    def test_the_readers_own_side_is_blue_on_his_own_phone(self):
        """The packet's sharpest open question. Assigned per reader, never per
        team record — two golfers in one group would otherwise see the same
        hole in opposite colours, and on a signed card that is not cosmetic."""
        self._setup()
        self._play(1, 4, 5, 5, 7)
        self.assertEqual(self._state(1, who=0)['number']['colour'], 'blue')
        self.assertEqual(self._state(1, who=2)['number']['colour'], 'orange')
        self.assertEqual(self._state(1, who=0)['sides'][0]['colour'], 'blue')
        self.assertEqual(self._state(1, who=2)['sides'][0]['colour'], 'blue')

    def test_level_is_white_and_never_mint(self):
        """Mint is the app's colour; this slot belongs to whichever side is
        ahead, and at level it belongs to neither."""
        self._setup()
        self._play(1, 4, 4, 4, 4)
        s = self._state(1)
        self.assertEqual(s['number']['text'], 'LEVEL')
        self.assertEqual(s['number']['colour'], 'neutral')


class SidesLineTests(_Base):

    def test_it_carries_the_holes_two_numbers(self):
        """**The number is the game**, so it is not at footnote size — and it
        does not get a row of its own either, because a dedicated number row
        is 24pt and the names were going on the card regardless."""
        self._setup()
        self._play(1, 4, 5, 5, 7)
        sides = self._state(1)['sides']
        self.assertEqual([x['figure'] for x in sides], ['45', '57'])

    def test_the_winning_side_is_the_one_at_full_weight(self):
        """That opacity difference is the ONLY thing marking who won the hole,
        and it replaces the *who took that one* sentence."""
        self._setup()
        self._play(1, 4, 5, 5, 7)
        sides = self._state(1)['sides']
        self.assertTrue(sides[0]['leading'])
        self.assertFalse(sides[1]['leading'])

    def test_the_reader_reads_his_own_side_first(self):
        self._setup()
        self._play(1, 4, 5, 5, 7)
        self.assertEqual(self._state(1, who=0)['sides'][0]['figure'], '45')
        self.assertEqual(self._state(1, who=2)['sides'][0]['figure'], '57')

    def test_a_number_never_needs_three_digits(self):
        """The packet asked this to be confirmed rather than assumed: each
        digit is capped at 9 before the number is composed, so 99 is the
        ceiling whatever the blow-up guard is set to. The line is built for
        two."""
        self._setup()
        self._play(1, 12, 14, 11, 13)
        for side in self._state(1)['sides']:
            self.assertEqual(len(side['figure']), 2)


class SpecialRuleTests(_Base):
    """Each surfaces on the hole it applied to, then goes away — not in a
    legend and not in the header. **Orange for all three:** across this set
    orange means somebody did this, or this is not the standard case."""

    def test_a_flip_shows_the_number_it_was(self):
        """The swing is visible rather than asserted — `67` struck through,
        then `76`."""
        self._setup(birdie_mode='flip')
        par = self.tee.hole(1)['par']
        self._play(1, par - 1, par + 2, par + 2, par + 3)
        s = self._state(1)
        self.assertEqual(s['state']['to_play'], 'FLIPPED')
        self.assertEqual(s['state']['colour'], 'orange')
        self.assertTrue(any(x.get('was') for x in s['sides']))

    def test_the_struck_number_is_the_one_before_the_flip(self):
        """Recoverable because the engine records the flag — the stored number
        is post-flip and the flip is its own inverse. Re-deriving it from
        gross scores would have been a second copy of the birdie rule."""
        self._setup(birdie_mode='flip')
        par = self.tee.hole(1)['par']
        self._play(1, par - 1, par + 2, par + 2, par + 3)
        flipped = next(x for x in self._state(1)['sides'] if x.get('was'))
        self.assertEqual(int(flipped['was']),
                         int(flipped['figure'][1]) * 10
                         + int(flipped['figure'][0]))

    def test_the_nine_cap_is_named_on_the_hole_it_held(self):
        """`49` is a 10 and a 4, not 410 — the one place that reads as a ten
        rather than as a typo."""
        self._setup()
        self._play(1, 10, 4, 5, 6)
        st = self._state(1)['state']
        self.assertEqual(st['to_play'], 'THE 9 CAP HELD')
        self.assertEqual(st['colour'], 'orange')
        self.assertEqual(self._state(1)['sides'][0]['figure'], '49')

    def test_a_carried_tie_says_the_next_hole_doubles(self):
        self._setup(carryover=True)
        self._play(1, 4, 5, 4, 5)
        s = self._state(1)
        self.assertEqual(s['state']['word'], 'TIED')
        self.assertEqual(s['state']['to_play'], 'NEXT HOLE DOUBLES')
        self.assertEqual(s['header']['chip'], 'CARRY')

    def test_a_tie_with_carry_off_is_just_nothing(self):
        self._setup(carryover=False)
        self._play(1, 4, 5, 4, 5)
        s = self._state(1)
        self.assertEqual(s['state']['word'], '0 PTS')
        self.assertNotIn('chip', s['header'])

    def test_the_carry_chip_is_a_state_not_a_setting(self):
        """A permanent chip would say the round has carries without saying
        which hole is carrying one."""
        self._setup(carryover=True)
        self._play(1, 4, 5, 4, 5)        # tie: carrying
        self._play(2, 4, 5, 5, 7)        # settled: not
        self.assertNotIn('chip', self._state(2)['header'])

    def test_a_settled_hole_says_what_the_carry_paid_for(self):
        """A settled hole's `carry` is the one it ABSORBED — the engine records
        it on the row that consumed it and then resets. Saying only what the
        hole paid would leave the reader wondering why one was worth triple."""
        self._setup(carryover=True)
        self._play(1, 4, 5, 4, 5)        # tied, carries
        self._play(2, 4, 5, 5, 7)        # settles, worth double
        st = self._state(2)['state']
        self.assertEqual(st['to_play'], 'THE CARRY DOUBLED')
        self.assertEqual(st['colour'], 'orange')

    def test_multiply_is_drawn_even_though_the_packet_never_drew_it(self):
        """Under multiply a birdie changes what the hole is WORTH rather than
        what the numbers are — so the state names the multiple and the sides
        line carries no strike-through."""
        self._setup(birdie_mode='multiplier')
        par = self.tee.hole(1)['par']
        self._play(1, par - 1, par + 2, par + 2, par + 3)
        s = self._state(1)
        self.assertIn(s['state']['to_play'], ('DOUBLED', '×3', '×4'))
        self.assertFalse(any(x.get('was') for x in s['sides']))


class HeaderAndFooterTests(_Base):

    def test_the_birdie_rule_is_named_in_the_header(self):
        """Two groups on the same numbers under flip and multiply are not
        playing the same game — the words are the configuration screen's."""
        self._setup(birdie_mode='flip')
        self._play(1, 4, 5, 5, 7)
        self.assertEqual(self._state(1)['header']['game'], 'LAS VEGAS · FLIP')

    def test_the_handicap_mode_does_not_take_that_slot(self):
        """It changes the INPUTS to the number; the birdie rule changes what a
        hole can be worth, and the card cannot show that any other way. One
        slot, and it goes to the rule that moves the money."""
        self._setup(handicap_mode='strokes_off')
        self._play(1, 4, 5, 5, 7)
        game = self._state(1)['header']['game']
        self.assertNotIn('STROKE', game)
        self.assertIn('FLIP', game)

    def test_the_stake_is_priced_in_cents(self):
        """`25¢ a point`, not `$0.25` — that is how it is set and how it is
        said, and a dollar figure on a card whose points run to three figures
        invites the reader to do the multiplication."""
        self._setup()
        self._play(1, 4, 5, 5, 7)
        self.assertEqual(self._state(1)['footer']['context'], '25¢ a point')

    def test_the_money_is_live_from_the_first_hole(self):
        """A hole settles the moment four scores are in, so there is nothing
        pending to hedge about. Points is the only other card in the set where
        that is true."""
        self._setup()
        self._play(1, 4, 5, 5, 7)
        self.assertTrue(self._state(1)['footer']['money'].startswith('+$'))

    def test_the_cap_earns_a_state_because_a_frozen_figure_would_mislead(self):
        """A pair 212 points down is not tracking the arithmetic, and a frozen
        money figure with no explanation beside it is the one way this card
        could be wrong."""
        self._setup(loss_cap=Decimal('1.00'))
        for h in range(1, 5):
            self._play(h, 4, 4, 9, 9)    # a rout, into the cap
        s = self._state(4)
        self.assertEqual(s['state']['word'], 'CAP HELD')
        self.assertIn('MAX A SIDE', s['state']['to_play'])
        self.assertEqual(s['footer']['context'], 'Cap reached')


class FinalTests(_Base):

    def test_it_keeps_its_board_and_settles_the_state_slot(self):
        self._setup()
        for h in range(1, 19):
            self._play(h, 4, 5, 5, 7)
        s = las_vegas_final_state(self.fs, player_id=self.p[0].id)
        self.assertTrue(s['closed'])
        self.assertEqual(s['state']['to_play'], 'SETTLED')
        self.assertTrue(s['sides'][1]['names'].startswith(
            ('Collect from', 'Pay', 'Level')))


class ContractTests(_Base):

    def test_it_pushes_nothing(self):
        """Two fixed pairs, one group, every hole watched by all four. A
        ninety-point hole is the loudest thing in a round of golf and it
        happens in front of everybody — five casual cards in a row with no
        notification."""
        from services.live_activity_cup_push import cup_alert
        self._setup()
        self._play(1, 4, 5, 5, 7)
        self.assertIsNone(cup_alert(self.round))

    def test_the_kind_is_gated_until_a_build_carries_the_layout(self):
        from services.live_activity_registry import (BUILDERS, card_kind,
                                                     UNSHIPPED_KINDS)
        self.assertIn('vegas', BUILDERS)
        self.assertIn(card_kind('vegas'), UNSHIPPED_KINDS)

    def test_the_widget_can_already_draw_it(self):
        """The Swift lands first; the gate comes off in the commit that bumps
        the build carrying it."""
        import re
        from pathlib import Path
        from django.conf import settings
        swift = (Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
                 / 'SixesActivityLiveActivity.swift').read_text()
        known = re.search(r'static let known: Set<String> = \[(.*?)\]',
                          swift, re.S).group(1)
        self.assertIn('"vegas"', known)

    def test_every_slot_it_sends_decodes(self):
        import re
        from pathlib import Path
        from django.conf import settings
        contract = (Path(settings.BASE_DIR) / 'mobile' / 'ios'
                    / 'SixesActivity' / 'SixesActivity.swift').read_text()
        self._setup(carryover=True)
        self._play(1, 4, 5, 4, 5)
        s = self._state(1)
        for key in s:
            self.assertTrue(f'let {key}:' in contract or f'var {key}:' in contract,
                            f'`{key}` has no field in ContentState')
        for key in s['header']:
            self.assertTrue(f'let {key}:' in contract or f'var {key}:' in contract)
        for key in s['sides'][0]:
            self.assertTrue(f'let {key}:' in contract or f'var {key}:' in contract,
                            f'sides.{key} has no field')
