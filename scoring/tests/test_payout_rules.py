"""
scoring/tests/test_payout_rules.py
----------------------------------
The money rules every tournament pot shares (services/payout.py,
docs/design-review/handoff-individual-play/SPEC.md §3):

* ties split the money for the PLACES THEY OCCUPY, with no countback;
* a place that pays a GROUP splits among its real golfers — the borrowed 4th
  is not a person and cannot be paid;
* the last paying championship place must clear day-bet 1st, or the placing
  that disqualifies a golfer from the day bet costs him money.

The group-game cases are the ones that were wrong before this phase: Irish
Rumble and the ball game each halved a single place on a tie, leaving the next
place unclaimed in the pot.
"""
from decimal import Decimal

from django.test import TestCase

import random

from core.models import HandicapMode
from games.models import IrishRumbleConfig
from services.irish_rumble import (
    calculate_irish_rumble, ensure_irish_rumble_phantom, irish_rumble_summary,
)
from services.payout import (
    carve_out, check_day_bet_floor, per_person_share, pool_line,
    split_tied_places, validate_payout_table,
)
from ._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, submit_hole,
)


# ---------------------------------------------------------------------------
# The helpers, on their own
# ---------------------------------------------------------------------------

class SplitTiedPlacesTests(TestCase):
    PLACES = {1: 50.0, 2: 20.0, 3: 10.0}

    def test_no_tie_pays_the_table(self):
        self.assertEqual(split_tied_places(self.PLACES, [1, 2, 3, 4]),
                         {1: 50.0, 2: 20.0, 3: 10.0, 4: 0.0})

    def test_tie_for_first_shares_first_and_second(self):
        # NOT 25 each with 2nd left in the pot.
        self.assertEqual(split_tied_places(self.PLACES, [1, 1, 3]),
                         {1: 35.0, 3: 10.0})

    def test_tie_for_second_shares_second_and_third(self):
        # A T2 pair takes $15 each, not $20 each — indexing prize by position
        # would overpay the pool.
        self.assertEqual(split_tied_places(self.PLACES, [1, 2, 2]),
                         {1: 50.0, 2: 15.0})

    def test_three_way_tie_for_first_consumes_the_whole_table(self):
        got = split_tied_places(self.PLACES, [1, 1, 1])
        self.assertAlmostEqual(got[1], 80 / 3, places=2)

    def test_unranked_competitors_are_ignored(self):
        self.assertEqual(split_tied_places(self.PLACES, [1, None, None]),
                         {1: 50.0})

    def test_a_tie_that_returns_every_entry_is_still_a_split(self):
        # Two groups tied for the only paid place in a two-group game: each
        # collects half the pot, which is exactly what its golfers put in.
        # It is still a split, and it has to be stated rather than silent.
        self.assertEqual(split_tied_places({1: 80.0}, [1, 1]), {1: 40.0})


class PerPersonShareTests(TestCase):
    def test_four_way(self):
        self.assertEqual(per_person_share(70.0, 4), 17.50)

    def test_levelled_group_splits_three_ways_and_pays_more_each(self):
        self.assertEqual(per_person_share(70.0, 3), 23.33)

    def test_no_players(self):
        self.assertEqual(per_person_share(70.0, 0), 0.0)


class ValidatePayoutTableTests(TestCase):
    def test_balanced(self):
        self.assertEqual(validate_payout_table(40, [24, 10, 6]), [])

    def test_under_the_pot(self):
        problems = validate_payout_table(40, [24, 10])
        self.assertEqual(len(problems), 1)
        self.assertIn('under', problems[0])
        self.assertIn('$6.00', problems[0])

    def test_over_the_pot(self):
        problems = validate_payout_table(40, [30, 20])
        self.assertIn('over', problems[0])

    def test_a_place_may_not_out_pay_the_one_above(self):
        problems = validate_payout_table(40, [10, 24, 6])
        self.assertTrue(any('pays more than place' in p for p in problems))

    def test_an_empty_table_is_not_yet_a_problem(self):
        # Nothing typed yet — the balance line has nothing to complain about.
        self.assertEqual(validate_payout_table(40, [0, 0, 0]), [])


class DayBetFloorTests(TestCase):
    CHAMP = [{'place': 1, 'amount': 400}, {'place': 2, 'amount': 200}]

    def test_clears(self):
        self.assertIsNone(check_day_bet_floor(
            self.CHAMP, [{'place': 1, 'amount': 100}]))

    def test_equal_clears(self):
        # "last paying place >= day bet 1st" — equal is fine.
        self.assertIsNone(check_day_bet_floor(
            self.CHAMP, [{'place': 1, 'amount': 200}]))

    def test_blocks_when_the_dq_would_cost_a_golfer_money(self):
        reason = check_day_bet_floor(
            self.CHAMP, [{'place': 1, 'amount': 260}])
        self.assertIsNotNone(reason)
        self.assertIn('$60.00', reason)      # what finishing in the money costs
        self.assertIn('day bet', reason)

    def test_no_day_bet_is_never_a_problem(self):
        self.assertIsNone(check_day_bet_floor(self.CHAMP, []))

    def test_no_championship_table_is_never_a_problem(self):
        self.assertIsNone(check_day_bet_floor([], [{'place': 1, 'amount': 100}]))


class PoolLineTests(TestCase):
    def test_field_scope(self):
        self.assertEqual(pool_line(10, 8, 'field'), '$10 × 8 in the field = $80')

    def test_foursome_scope(self):
        self.assertEqual(pool_line(10, 4, 'foursome'),
                         '$10 × 4 in this foursome = $40')


class CarveOutTests(TestCase):
    def test_twenty_five_percent_of_a_640_pool(self):
        self.assertEqual(carve_out(640, 25), (160.0, 480.0))

    def test_no_carve_out(self):
        self.assertEqual(carve_out(640, 0), (0.0, 640.0))


# ---------------------------------------------------------------------------
# Irish Rumble — the group-game case end to end
# ---------------------------------------------------------------------------

class IrishRumbleMoneyTests(TestCase):
    """
    Seven golfers: a four and a three. The threesome borrows a 4th, so the
    money card has to distinguish four BALLS from three PAYEES.
    """

    SEGMENTS = [
        {'start_hole': 1,  'end_hole': 6,  'balls_to_count': 1},
        {'start_hole': 7,  'end_hole': 12, 'balls_to_count': 2},
        {'start_hole': 13, 'end_hole': 17, 'balls_to_count': 3},
        {'start_hole': 18, 'end_hole': 18, 'balls_to_count': 4},
    ]

    def setUp(self):
        random.seed(20260816)          # stable donor rotation
        self.course = make_course()
        self.tee    = make_tee(self.course)
        self.round  = make_round(self.course, active_games=['irish_rumble'])
        self.g1 = make_foursome(
            self.round, [(make_player(n, 0, short_name=n), 0)
                         for n in ('A', 'B', 'C', 'D')],
            tee=self.tee, group_number=1)
        self.g2 = make_foursome(
            self.round, [(make_player(n, 0, short_name=n), 0)
                         for n in ('E', 'F', 'G')],
            tee=self.tee, group_number=2)

    def _configure(self, payouts):
        cfg = IrishRumbleConfig.objects.create(
            round=self.round, variant='classic',
            handicap_mode=HandicapMode.NET, net_percent=100,
            entry_fee=Decimal('10.00'), payouts=payouts,
            segments=self.SEGMENTS)
        # Group 2 is a true threesome and Group 1 has four, so the field levels
        # it with a borrowed 4th — the case the split has to get right.
        ensure_irish_rumble_phantom(self.round)
        return cfg

    def _score(self, foursome, gross_delta):
        # Real golfers only — the borrowed 4th's card is derived from the
        # donor rotation, never entered.
        members = list(foursome.memberships
                       .filter(player__is_phantom=False)
                       .select_related('player'))
        for h in DEFAULT_HOLES:
            submit_hole(foursome, h['number'], [
                (m.player, h['par'] + gross_delta) for m in members
            ])

    def test_pool_is_priced_per_golfer_across_the_field(self):
        self._configure([{'place': 1, 'amount': 70}])
        summary = irish_rumble_summary(self.round)
        # $10 × 7 in the field.
        self.assertEqual(summary['pool'], 70.0)

    def test_levelled_group_splits_its_place_among_real_golfers(self):
        self._configure([{'place': 1, 'amount': 70}])
        self._score(self.g1, 1)   # bogeys — worse
        self._score(self.g2, 0)   # pars — wins

        rows = {r['group']: r for r in irish_rumble_summary(self.round)['overall']}
        winner = rows['Group 2']
        self.assertEqual(winner['rank'], 1)
        self.assertEqual(winner['payout'], 70.0)
        # Three real golfers, not four: the borrowed ball cannot be paid.
        self.assertEqual(winner['n_real_players'], 3)
        self.assertEqual(winner['split_ways'], 3)
        self.assertEqual(winner['per_person_payout'], 23.33)

    def test_tied_groups_share_the_places_they_occupy(self):
        # Two paid places; both groups level. They share 1st AND 2nd rather
        # than halving 1st and orphaning 2nd in the pot.
        self._configure([{'place': 1, 'amount': 50}, {'place': 2, 'amount': 20}])
        self._score(self.g1, 0)
        self._score(self.g2, 0)

        rows = irish_rumble_summary(self.round)['overall']
        self.assertEqual({r['rank'] for r in rows}, {1})
        self.assertEqual({r['payout'] for r in rows}, {35.0})
        paid = sum(r['payout'] for r in rows)
        self.assertEqual(paid, 70.0)   # the whole table is handed out
