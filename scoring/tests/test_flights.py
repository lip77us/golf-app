"""Flight assignment and in-flight ranking — the pure layer.

No database: `assign_flights` and `rank_in_flights` take plain data on purpose,
so the two rules that are easiest to get subtly wrong can be pinned cheaply.
"""
from django.test import SimpleTestCase

from services.flights import assign_flights, flight_sizes, rank_in_flights


def _field(*indexes):
    """(1, idx), (2, idx), … — ids in the order given, so a test can assert on
    which golfer landed where without inventing a roster."""
    return [(i + 1, idx) for i, idx in enumerate(indexes)]


class AssignFlightsTests(SimpleTestCase):

    def test_even_field_splits_evenly(self):
        a = assign_flights(_field(*range(22)), 2)
        self.assertEqual(flight_sizes(a, 2), [11, 11])

    def test_remainder_goes_to_the_LOWER_flight(self):
        # The rule most likely to be "fixed" backwards: 23 is 12/11, not 11/12.
        a = assign_flights(_field(*range(23)), 2)
        self.assertEqual(flight_sizes(a, 2), [12, 11])

    def test_remainder_fills_the_lower_flights_in_order(self):
        a = assign_flights(_field(*range(23)), 3)
        self.assertEqual(flight_sizes(a, 3), [8, 8, 7])

    def test_lowest_index_is_flight_one(self):
        a = assign_flights([(1, 24.0), (2, 3.1), (3, 11.5), (4, 18.0)], 2)
        self.assertEqual(a[2], 1)      # 3.1
        self.assertEqual(a[3], 1)      # 11.5
        self.assertEqual(a[4], 2)      # 18.0
        self.assertEqual(a[1], 2)      # 24.0

    def test_a_field_smaller_than_the_flight_count_leaves_flights_empty(self):
        a = assign_flights(_field(4.0, 9.0), 4)
        self.assertEqual(flight_sizes(a, 4), [1, 1, 0, 0])

    def test_empty_field(self):
        self.assertEqual(assign_flights([], 2), {})

    def test_one_flight_is_everybody(self):
        a = assign_flights(_field(*range(7)), 1)
        self.assertEqual(flight_sizes(a, 1), [7])

    def test_zero_flights_is_refused(self):
        with self.assertRaises(ValueError):
            assign_flights(_field(1.0), 0)

    def test_equal_indexes_break_on_player_id_not_queryset_order(self):
        # Two golfers on 11.4 either side of the boundary must not swap flights
        # because the rows came back in a different order.
        forward  = assign_flights([(1, 11.4), (2, 11.4)], 2)
        backward = assign_flights([(2, 11.4), (1, 11.4)], 2)
        self.assertEqual(forward, backward)
        self.assertEqual(forward[1], 1)

    # -- the no-index rule --------------------------------------------------

    def test_unindexed_go_bottom_and_do_not_count_toward_the_split(self):
        # 23 golfers, 3 with no index. Split the 20 indexed (10/10), then add
        # the 3 to the bottom: A=10, B=13. NOT A=12, B=11.
        field = _field(*range(20)) + [(21, None), (22, None), (23, None)]
        a = assign_flights(field, 2)
        self.assertEqual(flight_sizes(a, 2), [10, 13])
        for pid in (21, 22, 23):
            self.assertEqual(a[pid], 2)

    def test_a_wholly_unindexed_field_is_all_bottom_flight(self):
        a = assign_flights([(1, None), (2, None), (3, None)], 3)
        self.assertEqual(flight_sizes(a, 3), [0, 0, 3])

    def test_unindexed_do_not_push_an_indexed_golfer_up_a_flight(self):
        # The whole point of excluding them from the sizing. With 4 indexed and
        # 2 unindexed the cut is 2/2 among the indexed — golfer 3 (the third
        # best) stays in flight 2 rather than being promoted to make room.
        field = [(1, 2.0), (2, 6.0), (3, 12.0), (4, 20.0),
                 (5, None), (6, None)]
        a = assign_flights(field, 2)
        self.assertEqual(a[1], 1)
        self.assertEqual(a[2], 1)
        self.assertEqual(a[3], 2)
        self.assertEqual(flight_sizes(a, 2), [2, 4])

    def test_plus_handicaps_sort_to_the_top(self):
        a = assign_flights([(1, 10.0), (2, -2.3), (3, 4.0), (4, 30.0)], 2)
        self.assertEqual(a[2], 1)      # +2.3 stored as -2.3


# ---------------------------------------------------------------------------

def _low_net(rows):
    """(sort_key, rank_key) for a Low-Net-shaped aggregate."""
    return (lambda kv: (kv[1]['ntp'], -kv[1]['holes']),
            lambda kv: kv[1]['ntp'])


class RankInFlightsTests(SimpleTestCase):
    """Ranking and paying inside a flight, with the Low Net shape."""

    TABLE = {1: 100.0, 2: 60.0, 3: 40.0}

    def _run(self, agg, flights, **kw):
        sort_key, rank_key = _low_net(agg)
        return rank_in_flights(agg, sort_key=sort_key, rank_key=rank_key,
                               flight_of=lambda pid: flights[pid],
                               payouts_cfg=self.TABLE, **kw)

    def test_ranks_restart_in_each_flight(self):
        agg = {p: {'ntp': p, 'holes': 18} for p in range(1, 5)}
        ranked, _ = self._run(agg, {1: 1, 2: 1, 3: 2, 4: 2})
        self.assertEqual([(pid, r, f) for pid, _d, r, f in ranked],
                         [(1, 1, 1), (2, 2, 1), (3, 1, 2), (4, 2, 2)])

    def test_rows_come_back_in_flight_order(self):
        agg = {p: {'ntp': p, 'holes': 18} for p in range(1, 5)}
        ranked, _ = self._run(agg, {1: 2, 2: 1, 3: 2, 4: 1})
        self.assertEqual([f for _p, _d, _r, f in ranked], [1, 1, 2, 2])

    def test_each_flight_pays_the_same_table(self):
        agg = {p: {'ntp': p, 'holes': 18} for p in range(1, 7)}
        _ranked, pay = self._run(agg, {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2})
        self.assertEqual(pay[1], 100.0)
        self.assertEqual(pay[4], 100.0)          # flight 2's winner, same money
        self.assertEqual(pay[3], 40.0)
        self.assertEqual(pay[6], 40.0)

    def test_the_event_pays_the_table_once_per_flight_and_no_more(self):
        agg = {p: {'ntp': p, 'holes': 18} for p in range(1, 9)}
        _ranked, pay = self._run(
            agg, {1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 2, 7: 2, 8: 2})
        total = sum(v for v in pay.values() if v)
        self.assertAlmostEqual(total, sum(self.TABLE.values()) * 2)

    def test_a_tie_inside_a_flight_splits_that_flights_places_only(self):
        # 1 and 2 tie for first in flight 1: they share 1st+2nd = $80 each, and
        # flight 2 is untouched.
        agg = {1: {'ntp': -4, 'holes': 18}, 2: {'ntp': -4, 'holes': 18},
               3: {'ntp': 2, 'holes': 18},
               4: {'ntp': -1, 'holes': 18}, 5: {'ntp': 5, 'holes': 18}}
        _ranked, pay = self._run(agg, {1: 1, 2: 1, 3: 1, 4: 2, 5: 2})
        self.assertEqual(pay[1], 80.0)
        self.assertEqual(pay[2], 80.0)
        self.assertEqual(pay[3], 40.0)
        self.assertEqual(pay[4], 100.0)

    def test_a_tie_does_not_let_a_flight_overpay_its_table(self):
        # Three tied for 1st share places 1+2+3.
        #
        # PRE-EXISTING, NOT A FLIGHT BUG: services.payout.split_tied_places
        # rounds each share to the cent (`round(total / n, 2)`), so $200 three
        # ways pays $66.67 each and the flight pays $200.01 — a cent invented.
        # It can also lose one ($100 three ways is $99.99). This asserts the
        # real behaviour rather than hiding it; the fix is a remainder
        # distribution in split_tied_places, which is app-wide money code and
        # wants its own change.
        agg = {1: {'ntp': 0, 'holes': 18}, 2: {'ntp': 0, 'holes': 18},
               3: {'ntp': 0, 'holes': 18}, 4: {'ntp': 9, 'holes': 18}}
        _ranked, pay = self._run(agg, {p: 1 for p in range(1, 5)})
        self.assertAlmostEqual(sum(v for v in pay.values() if v),
                               sum(self.TABLE.values()), delta=0.05)

    def test_rank_key_is_narrower_than_sort_key(self):
        # Level on net-to-par, different holes played: sorts apart, ranks level.
        agg = {1: {'ntp': -2, 'holes': 18}, 2: {'ntp': -2, 'holes': 9}}
        ranked, pay = self._run(agg, {1: 1, 2: 1})
        self.assertEqual([r for _p, _d, r, _f in ranked], [1, 1])
        self.assertEqual(pay[1], 80.0)          # 1st+2nd shared, not 100/60
        self.assertEqual(pay[2], 80.0)

    def test_an_excluded_golfer_ranks_but_does_not_take_a_place(self):
        # Shipped Stableford behaviour: he keeps his display rank, and the man
        # behind him moves UP a paid place rather than the place going unclaimed.
        agg = {p: {'ntp': p, 'holes': 18} for p in range(1, 4)}
        ranked, pay = self._run(agg, {1: 1, 2: 1, 3: 1}, eligible={1, 3})
        self.assertEqual([r for _p, _d, r, _f in ranked], [1, 2, 3])
        self.assertIsNone(pay.get(2))
        self.assertEqual(pay[1], 100.0)
        self.assertEqual(pay[3], 60.0)          # 2nd money, not 3rd

    def test_a_flight_shorter_than_the_table_pays_only_its_places(self):
        agg = {1: {'ntp': -3, 'holes': 18}, 2: {'ntp': 1, 'holes': 18}}
        _ranked, pay = self._run(agg, {1: 1, 2: 1})
        self.assertAlmostEqual(sum(v for v in pay.values() if v), 160.0)
