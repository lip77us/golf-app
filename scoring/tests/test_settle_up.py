"""The shared settle-up logic — ``~/Downloads/design_handoff_settle_up`` §2.

Every number here is the handoff's own, so these tests pin the SPEC rather
than the implementation.  The one that matters most is
:meth:`TheConsolidationIsSafeTests.test_the_three_old_copies_agree_with_this_one`:
this module replaces three existing greedy settles, and that test is what says
the replacement does not move anybody's money.
"""
from decimal import Decimal

from django.test import SimpleTestCase

from services.payout import split_to_cents
from services.settle_up import (Transfer, classify_recipients, combine,
                                for_display, settle, settle_pool, split_cents)


class SettleTests(SimpleTestCase):
    """§2.1."""

    # Dave +26, Paul +10, Sam −18, Mike −18
    REFERENCE = {'Dave': 2600, 'Paul': 1000, 'Sam': -1800, 'Mike': -1800}

    def test_the_handoff_reference_case(self):
        """§2.1 states this answer outright, so it is the anchor."""
        got = {(t.frm, t.to, t.amount)
               for t in settle(self.REFERENCE, order=list(self.REFERENCE))}
        self.assertEqual(got, {('Sam', 'Dave', 1800),
                               ('Mike', 'Paul', 1000),
                               ('Mike', 'Dave', 800)})

    def test_the_receipt_shows_them_largest_first(self):
        """The handoff lists the reference as 18, 10, 8 — amount descending,
        not the greedy emission order (18, 8, 10).  §4 says it outright for
        tournaments ("ordered by amount"), so the sort is a display rule."""
        rows = for_display(settle(self.REFERENCE, order=list(self.REFERENCE)))
        self.assertEqual([t.amount for t in rows], [1800, 1000, 800])
        self.assertEqual([(t.frm, t.to) for t in rows],
                         [('Sam', 'Dave'), ('Mike', 'Paul'), ('Mike', 'Dave')])

    def test_at_most_n_minus_one_lines(self):
        """§2.1's guarantee.  Six golfers, so five lines at the outside."""
        nets = {'a': 500, 'b': 400, 'c': 300, 'd': -200, 'e': -400, 'f': -600}
        self.assertLessEqual(len(settle(nets)), len(nets) - 1)

    def test_everyone_level_settles_to_nothing(self):
        self.assertEqual(settle({'a': 0, 'b': 0}), [])

    def test_a_ledger_that_does_not_balance_is_refused(self):
        """A game that does not sum to zero is a bug in that game.  Settling it
        would invent or lose money, so it surfaces here."""
        with self.assertRaises(ValueError) as cm:
            settle({'a': 100, 'b': -99})
        self.assertIn('sum to zero', str(cm.exception))

    def test_floats_are_refused(self):
        """§2.1 says integer cents.  The three old copies carried three
        different answers to 'how close to zero is zero' because floats made
        the question unavoidable; a float arriving here would bring it back."""
        with self.assertRaises(TypeError):
            settle({'a': 10.0, 'b': -10.0})

    def test_ties_break_by_display_order(self):
        """Two golfers down the same amount is the ordinary end of a four-ball,
        so the tie is not an edge case.  Display order decides which pays the
        bigger creditor, and reversing it reverses the answer."""
        nets = {'win': 2000, 'x': -1000, 'y': -1000}
        first = settle(nets, order=['win', 'x', 'y'])
        second = settle(nets, order=['win', 'y', 'x'])
        self.assertEqual(first[0].frm, 'x')
        self.assertEqual(second[0].frm, 'y')


class CombineTests(SimpleTestCase):
    """§2.2."""

    def test_two_games_settle_once_on_the_sum(self):
        nassau = {'a': 1000, 'b': -1000}
        skins  = {'a': -400, 'b': 400}
        self.assertEqual(combine([nassau, skins]), {'a': 600, 'b': -600})

    def test_a_golfer_absent_from_a_side_game_scores_nothing_in_it(self):
        """Somebody sitting out one game must not break the total."""
        self.assertEqual(combine([{'a': 500, 'b': -500},
                                  {'a': 200, 'c': -200}]),
                         {'a': 700, 'b': -500, 'c': -200})

    def test_one_bad_game_is_named_rather_than_hidden(self):
        with self.assertRaises(ValueError) as cm:
            combine([{'a': 100, 'b': -100}, {'a': 50, 'b': -49}])
        self.assertIn('ledger 1', str(cm.exception))


class SplitCentsTests(SimpleTestCase):
    """§2.3's odd cent."""

    def test_split_cents_agrees_with_split_to_cents(self):
        """``payout.split_to_cents`` is the float form of this same rule, and
        has six callers.  Two implementations of one rule is how they come to
        disagree, so the equivalence is checked rather than assumed."""
        for total, n in [(28750, 4), (14375, 3), (20000, 3), (1, 2), (0, 4),
                         (6667, 3), (999, 7)]:
            with self.subTest(total=total, n=n):
                self.assertEqual(
                    split_cents(total, n),
                    [int(round(c * 100)) for c in split_to_cents(total / 100, n)])

    def test_the_shares_always_sum_to_the_total(self):
        for total, n in [(20000, 3), (1, 3), (6667, 7), (28750, 4)]:
            self.assertEqual(sum(split_cents(total, n)), total,
                             f'{total} over {n} did not add up')


class SettlePoolTests(SimpleTestCase):
    """§2.3."""

    def test_the_pot_is_entry_times_entrants(self):
        r = settle_pool(entry=2000, ranks={'a': 1, 'b': 2, 'c': 3, 'd': 4},
                        payouts_by_place={1: 8000}, entries_at_signup=True)
        self.assertEqual(r.pot, 8000)

    def test_a_tie_shares_the_places_it_occupies(self):
        """Two tied for 2nd take 2nd + 3rd — not 2nd each, which overpays a
        place the pot holds once, and not half of 2nd, which leaves 3rd
        unclaimed."""
        r = settle_pool(entry=2000, ranks={'a': 1, 'b': 2, 'c': 2, 'd': 4},
                        payouts_by_place={1: 4000, 2: 3000, 3: 1000},
                        entries_at_signup=True)
        self.assertEqual(r.payouts['a'], 4000)
        self.assertEqual(r.payouts['b'] + r.payouts['c'], 4000)
        self.assertEqual(r.payouts['d'], 0)

    def test_the_odd_cent_goes_to_the_higher_handicap(self):
        """§2.3.  Not a new rule — Team Play established it and says so on
        screen; this promotes it to every pool."""
        # The two tied for 1st pool places 1 + 2 = 2001c, which does not
        # halve.  Entry 1500 x 2 keeps the 3000c pot clear of it.
        r = settle_pool(entry=1500, ranks={'lo': 1, 'hi': 1},
                        payouts_by_place={1: 1000, 2: 1001},
                        handicaps={'lo': 4.1, 'hi': 18.3},
                        entries_at_signup=True)
        self.assertEqual(r.payouts['hi'], 1001)
        self.assertEqual(r.payouts['lo'], 1000)

    def test_net_is_payout_minus_entry(self):
        r = settle_pool(entry=2000, ranks={'a': 1, 'b': 2},
                        payouts_by_place={1: 4000}, entries_at_signup=True)
        self.assertEqual(r.nets, {'a': 2000, 'b': -2000})

    def test_a_td_event_pays_from_the_td_and_settles_nothing_peer_to_peer(self):
        """Entries are already collected, so transfers between golfers would be
        handovers nobody owes."""
        r = settle_pool(entry=2000, ranks={'a': 1, 'b': 2, 'c': 3},
                        payouts_by_place={1: 6000}, entries_at_signup=True,
                        td='TD', td_name='Paul Kelly')
        self.assertEqual(r.transfers, [Transfer(frm='TD', to='a', amount=6000)])
        self.assertEqual(r.pays_label,
                         'Paul Kelly pays out · entries taken at signup')

    def test_a_casual_pool_settles_peer_to_peer(self):
        """Nobody is holding the money, so the nets go through settle()."""
        r = settle_pool(entry=1000, ranks={'a': 1, 'b': 2, 'c': 3},
                        payouts_by_place={1: 3000},
                        order=['a', 'b', 'c'])
        self.assertIsNone(r.pays_label)
        self.assertEqual({(t.frm, t.to, t.amount) for t in r.transfers},
                         {('b', 'a', 1000), ('c', 'a', 1000)})

    def test_a_table_that_overpays_the_pot_is_refused(self):
        with self.assertRaises(ValueError) as cm:
            settle_pool(entry=1000, ranks={'a': 1, 'b': 2},
                        payouts_by_place={1: 5000}, entries_at_signup=True)
        self.assertIn('never promise more than was collected', str(cm.exception))

    def test_an_uncollected_pot_must_be_paid_out_in_full(self):
        """With entries uncollected the shortfall belongs to nobody, so there
        is no set of transfers that clears it.  Said here rather than as a
        sum-to-zero error the caller cannot interpret."""
        with self.assertRaises(ValueError) as cm:
            settle_pool(entry=1000, ranks={'a': 1, 'b': 2, 'c': 3},
                        payouts_by_place={1: 2000})
        self.assertIn('whole pot', str(cm.exception))


class RecipientTests(SimpleTestCase):
    """§2.5."""

    FOUR = [
        {'id': 1, 'name': 'Paul', 'on_halved': True,  'mobile': '+1310'},
        {'id': 2, 'name': 'Dave', 'on_halved': True,  'mobile': ''},
        {'id': 3, 'name': 'Sam',  'on_halved': False, 'mobile': '+1415'},
        {'id': 4, 'name': 'Mike', 'on_halved': False, 'mobile': ''},
    ]

    def test_the_note_is_the_handoffs_own_sentence(self):
        r = classify_recipients(self.FOUR, scorer_id=99)
        self.assertEqual(r.note, 'Paul and Dave have it in Halved. '
                                 'Sam gets a text. Mike has no mobile on file.')

    def test_on_halved_gets_a_push_even_with_a_mobile(self):
        """The order of the test matters: a golfer on Halved WITH a mobile is a
        push, not a text, or the scorer texts people who already have it."""
        r = classify_recipients(self.FOUR, scorer_id=99)
        self.assertEqual(r.push, [1, 2])
        self.assertEqual(r.text, [3])
        self.assertEqual(r.none, [4])

    def test_the_scorer_is_excluded(self):
        """He is holding the phone that sends them."""
        r = classify_recipients(self.FOUR, scorer_id=1)
        self.assertNotIn(1, r.push + r.text + r.none)
        self.assertNotIn('Paul', r.note)

    def test_three_names_join_with_commas(self):
        """§2.5 as written, which gives no conjunction at three.  Copy is
        declared final; flagged in _join's docstring as the one line worth a
        second look on a real four-ball."""
        r = classify_recipients(
            [{'id': i, 'name': n, 'on_halved': True, 'mobile': ''}
             for i, n in enumerate(['Paul', 'Dave', 'Sam'])], scorer_id=99)
        self.assertEqual(r.note, 'Paul, Dave, Sam have it in Halved.')

    def test_nothing_to_say_says_nothing(self):
        r = classify_recipients([{'id': 1, 'name': 'Paul',
                                  'on_halved': True, 'mobile': ''}],
                                scorer_id=1)
        self.assertEqual(r.note, '')


class TheConsolidationIsSafeTests(SimpleTestCase):
    """This module replaces three existing greedy settles.

    ``settlement._who_owes_whom``, ``banker._transfers`` and
    ``sequoya_threes._transfers`` are the same algorithm written three times —
    the shape this codebase has scars from (four ``gross_total`` traversals;
    three ``gross_to_par``, one of which failed invisibly).  They were compared
    BEFORE this module was written and they agree; this keeps them agreeing
    until they are deleted, and is the evidence that deleting them was safe.
    """

    CASES = [
        {'Dave': 2600, 'Paul': 1000, 'Sam': -1800, 'Mike': -1800},
        {'a': 500, 'b': -500},
        {'a': 1500, 'b': 300, 'c': -900, 'd': -900},
        {'a': 0, 'b': 1200, 'c': -1200},
        {'a': 777, 'b': -259, 'c': -259, 'd': -259},
    ]

    def _old(self, fn, nets, *, decimal=False, dict_names=False):
        names = ({p: {'short_name': p} for p in nets} if dict_names
                 else {p: p for p in nets})
        src = ({p: Decimal(n) / 100 for p, n in nets.items()} if decimal
               else {p: n / 100 for p, n in nets.items()})
        return {(r['from'], r['to'], int(round(float(r['amount']) * 100)))
                for r in fn(src, names)}

    def test_the_three_old_copies_agree_with_this_one(self):
        from services.banker import _transfers as banker_t
        from services.sequoya_threes import _transfers as sequoya_t
        from services.settlement import _who_owes_whom

        for nets in self.CASES:
            with self.subTest(nets=nets):
                new = {(t.frm, t.to, t.amount)
                       for t in settle(nets, order=list(nets))}
                self.assertEqual(
                    self._old(_who_owes_whom, nets, dict_names=True), new,
                    'settlement._who_owes_whom disagrees')
                self.assertEqual(
                    self._old(banker_t, nets, decimal=True), new,
                    'banker._transfers disagrees')
                self.assertEqual(
                    self._old(sequoya_t, nets), new,
                    'sequoya_threes._transfers disagrees')


class MoneyFormatTests(SimpleTestCase):
    """§2.4.  A flag on the existing formatter, not a second one."""

    def test_the_ticket_form(self):
        from services.settlement_receipt import money
        self.assertEqual(money(26, sign=True), '+$26')
        self.assertEqual(money(-18, sign=True), '−$18')
        self.assertEqual(money(46.87, sign=True), '+$46.87')

    def test_level_is_never_signed(self):
        """§2.4 writes it as "$0 when level" — level is a direction, not a
        gain, so a '+' on it would read as a win of nothing."""
        from services.settlement_receipt import money
        self.assertEqual(money(0, sign=True), '$0')

    def test_a_true_minus_sign(self):
        """U+2212, not a hyphen.  At 11px beside a '+' the hyphen is visibly
        the wrong length, which is why the ticket cares."""
        from services.settlement_receipt import money
        self.assertEqual(money(-18, sign=True)[0], '−')

    def test_the_thirty_odd_existing_callers_are_untouched(self):
        """The flag defaults off, so every surface rendering today keeps the
        bare '$26' it renders now."""
        from services.settlement_receipt import money
        self.assertEqual(money(26), '$26')
        self.assertEqual(money(26, plain=True), '+$26')   # SMS always signed
