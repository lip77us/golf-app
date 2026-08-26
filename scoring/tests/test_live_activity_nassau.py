"""
scoring/tests/test_live_activity_nassau.py
------------------------------------------
The Nassau lock screen
(docs/design-review/handoff-live-activities/nassau-HANDOFF.md).

Weighted towards the **exposure range**, because that is the slot the design is
built around and the packet records that four of its five prototype states had
to be corrected for it. The rule it must satisfy is that the range reconciles
against the rows above it — a range that contradicts them is worse than no
range at all.
"""
from decimal import Decimal

from django.test import TestCase

from services.live_activity_nassau import nassau_activity_state
from services.nassau import (HandicapMode, add_manual_press,
                             calculate_nassau, setup_nassau)
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class NassauActivityTests(TestCase):
    """1v1 at $5 a match, gross, so the nets are the scores."""

    STAKE = Decimal('5.00')

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit     = self.STAKE
        self.round.active_games = ['nassau']
        self.round.primary_game = 'nassau'
        self.round.save(update_fields=['bet_unit', 'active_games',
                                       'primary_game'])
        self.fs = make_foursome(self.round, [('Paul', 0), ('Dave', 0)],
                                tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_nassau(self.fs, [self.pid['Paul']], [self.pid['Dave']],
                     handicap_mode=HandicapMode.GROSS,
                     press_mode='manual', press_unit=5.00)

    def _play(self, hole, paul, dave):
        submit_hole(self.fs, hole, [(self.pid['Paul'], paul),
                                    (self.pid['Dave'], dave)])
        # The summary reads STORED results, so the calculator is what settles a
        # nine — the same call the score endpoint makes.
        calculate_nassau(self.fs)

    def _state(self, thru=None, who='Paul'):
        return nassau_activity_state(self.fs, player_id=self.pid[who],
                                     thru=thru)

    def _money(self, thru=None, who='Paul'):
        return self._state(thru=thru, who=who)['footer']['money']

    # -- the range opens at the FULL exposure -----------------------------

    def test_all_three_bets_are_live_from_the_first_tee(self):
        """The back nine has not been played but it is at stake.  Counting only
        the matches under way (-$10) is the mistake the slot exists to avoid."""
        self._play(1, 4, 4)
        self.assertEqual(self._money(thru=1), '-$15 to +$15')

    def test_it_is_symmetric_about_zero_before_anything_settles(self):
        self._play(1, 3, 4)             # Paul 1 up, nothing settled
        self.assertEqual(self._money(thru=1), '-$15 to +$15')

    # -- presses widen it -------------------------------------------------

    def test_a_press_widens_the_range(self):
        """A running total cannot do this job — three open bets at $5 and the
        same round after a press read identically as a total."""
        for hole in range(1, 4):
            self._play(hole, 4, 3)      # Dave 3 up, Paul can press
        before = self._money(thru=3)
        add_manual_press(self.fs, start_hole=4)
        calculate_nassau(self.fs)
        after = self._money(thru=3)
        self.assertNotEqual(before, after)
        self.assertEqual(after, '-$20 to +$20')

    # -- settling moves the midpoint and narrows the span -----------------

    def test_winning_the_front_nine_lifts_the_floor(self):
        """It includes settled money, so it is a forecast rather than a bracket
        around zero."""
        for hole in range(1, 10):
            self._play(hole, 3, 4)      # Paul wins every hole — front is his
        self.assertEqual(self._money(thru=9), '-$5 to +$15')

    def test_the_loser_reads_the_mirror_image(self):
        """The board is neutral; this one figure is not."""
        for hole in range(1, 10):
            self._play(hole, 3, 4)
        self.assertEqual(self._money(thru=9, who='Dave'), '-$15 to +$5')

    def test_it_converges_to_a_single_number(self):
        """Every bet that settles pulls the ends together, until on the 18th
        green they meet at the number that is the final state."""
        for hole in range(1, 19):
            self._play(hole, 3, 4)
        self.assertEqual(self._money(thru=18), '+$15')

    # -- the range must reconcile with the rows ---------------------------

    def test_the_span_is_twice_every_unsettled_stake(self):
        """The reconciliation the packet demands, computed independently.

        Note it is NOT twice the row count: the back nine is live from the 1st
        tee and carries no row until the turn, which is exactly the confusion
        the slot exists to prevent.
        """
        from services.nassau import nassau_summary

        def val(x):
            return float(x.replace('$', '').replace(',', ''))

        for thru in (1, 5, 9, 12, 18):
            for hole in range(1, thru + 1):
                self._play(hole, 3, 4)

            summary = nassau_summary(self.fs)
            unsettled = sum(
                float(summary['bet_unit'])
                for key in ('front9', 'back9', 'overall')
                if not (summary.get(key) or {}).get('result'))
            unsettled += sum(
                float(summary['press_unit'])
                for p in (summary.get('presses') or []) if not p.get('result'))

            money = self._money(thru=thru)
            if ' to ' not in money:
                self.assertEqual(unsettled, 0, f'thru {thru}: converged with '
                                               f'{unsettled} still at stake')
                continue
            low, high = money.split(' to ')
            self.assertAlmostEqual(val(high) - val(low), 2 * unsettled,
                                   delta=0.01,
                                   msg=f'thru {thru} does not reconcile')

    # -- a halved bet is dropped, not banked ------------------------------

    def test_a_halved_nine_banks_nothing(self):
        """Halves pay nothing, per the Sixes ruling — so the stake leaves both
        the midpoint and the span rather than being added to either."""
        for hole in range(1, 10):
            self._play(hole, 4, 4)      # every hole halved → front9 halved
        self.assertEqual(self._money(thru=9), '-$10 to +$10')

    # -- a settled nine leaves the card -----------------------------------

    def test_the_settled_nine_does_not_become_a_third_row(self):
        """It is over, its money is in the exposure figure, and a row that
        cannot change spends space on history."""
        for hole in range(1, 10):
            self._play(hole, 3, 4)
        labels = [r['label'] for r in self._state(thru=9)['rows']]
        self.assertNotIn('FRONT 9', labels)

    def test_late_in_the_round_the_card_holds_one_row(self):
        for hole in range(1, 19):
            self._play(hole, 3, 4)
        self.assertEqual(len(self._state(thru=18)['rows']), 1)

    # -- rows -------------------------------------------------------------

    def test_the_rows_are_the_current_nine_and_the_eighteen(self):
        self._play(1, 3, 4)
        labels = [r['label'] for r in self._state(thru=1)['rows']]
        self.assertEqual(labels, ['FRONT 9', 'OVERALL'])

    def test_the_back_nine_replaces_the_front_after_the_turn(self):
        for hole in range(1, 12):
            self._play(hole, 3, 4)
        labels = [r['label'] for r in self._state(thru=11)['rows']]
        self.assertIn('BACK 9', labels)
        self.assertNotIn('FRONT 9', labels)

    def test_all_square_is_never_mint(self):
        """Mint is the app's colour, not a side's."""
        self._play(1, 4, 4)
        row = self._state(thru=1)['rows'][0]
        self.assertEqual(row['text'], 'ALL SQ')
        self.assertEqual(row['colour'], 'neutral')

    def test_the_press_chip_sits_on_the_row_that_owns_the_bet(self):
        """Floating the count to the header would say the round has presses
        without saying which match carries them, which is the whole content."""
        for hole in range(1, 4):
            self._play(hole, 4, 3)
        add_manual_press(self.fs, start_hole=4)
        calculate_nassau(self.fs)
        rows = {r['label']: r for r in self._state(thru=3)['rows']}
        self.assertEqual(rows['FRONT 9'].get('chip'), '+1 PRESS')
        self.assertIsNone(rows['OVERALL'].get('chip'))

    def test_the_header_names_the_hole_being_played(self):
        """Two live matches means two remaining-hole counts, so one thru figure
        no longer does the work."""
        self._play(1, 3, 4)
        self.assertEqual(self._state(thru=1)['header']['segment'], 'HOLE 2')

    def test_the_sides_are_named_once(self):
        self._play(1, 3, 4)
        sides = self._state(thru=1)['sides']
        self.assertEqual(len(sides), 2)
        self.assertEqual(sides[0]['colour'], 'blue')
        self.assertEqual(sides[1]['colour'], 'orange')


class NassauLossCapTests(TestCase):
    """A cap truncates the floor, which is most of the slot's value."""

    def setUp(self):
        tee = make_tee()
        self.round = make_round(tee.course)
        self.round.bet_unit = Decimal('5.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(self.round, [('Paul', 0), ('Dave', 0)], tee=tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_nassau(self.fs, [self.pid['Paul']], [self.pid['Dave']],
                     handicap_mode=HandicapMode.GROSS,
                     press_mode='manual', press_unit=5.00, loss_cap=10)

    def test_the_card_shows_the_capped_floor(self):
        from services.nassau import calculate_nassau as _calc
        """An uncapped floor on a capped game is a number the golfer cannot
        actually lose."""
        submit_hole(self.fs, 1, [(self.pid['Paul'], 4), (self.pid['Dave'], 4)])
        _calc(self.fs)
        money = nassau_activity_state(self.fs, player_id=self.pid['Paul'],
                                      thru=1)['footer']['money']
        self.assertEqual(money, '-$10 to +$10')


class NassauContractTests(TestCase):
    """The Python state and the Swift `ContentState` are one contract in two
    languages, and a key renamed on this side fails silently on a lock screen
    rather than in a build."""

    SWIFT = 'mobile/ios/SixesActivity/SixesActivity.swift'

    def setUp(self):
        import os
        from django.conf import settings
        with open(os.path.join(settings.BASE_DIR, self.SWIFT)) as fh:
            self.swift = fh.read()

        tee = make_tee()
        self.round = make_round(tee.course)
        self.round.bet_unit     = Decimal('5.00')
        self.round.active_games = ['nassau']
        self.round.primary_game = 'nassau'
        self.round.save(update_fields=['bet_unit', 'active_games',
                                       'primary_game'])
        self.fs = make_foursome(self.round, [('Paul', 0), ('Dave', 0)], tee=tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_nassau(self.fs, [self.pid['Paul']], [self.pid['Dave']],
                     handicap_mode=HandicapMode.GROSS)
        submit_hole(self.fs, 1, [(self.pid['Paul'], 3), (self.pid['Dave'], 4)])
        calculate_nassau(self.fs)

    def test_every_slot_has_a_field_in_the_swift_struct(self):
        from django.contrib.auth import get_user_model
        from services.live_activity_registry import activity_state
        user = get_user_model().objects.create_user(
            username='td', account=self.round.account)
        user.is_account_admin = True
        user.save(update_fields=['is_account_admin'])

        state = activity_state(self.round, user)
        self.assertEqual(state['kind'], 'nassau')
        for key in state:
            self.assertIn(f'let {key}:', self.swift.replace('var rows:',
                                                            'let rows:'),
                          f'`{key}` has no field in ContentState')

    def test_the_row_keys_the_swift_decodes_are_all_emitted(self):
        state = nassau_activity_state(self.fs, player_id=self.pid['Paul'],
                                      thru=1)
        for row in state['rows']:
            self.assertLessEqual(set(row),
                                 {'label', 'text', 'colour', 'note', 'chip'})
            self.assertGreaterEqual(set(row),
                                    {'label', 'text', 'colour', 'note'})
