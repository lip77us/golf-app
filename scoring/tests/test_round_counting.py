"""
scoring/tests/test_round_counting.py
------------------------------------
Best-N-of-M round selection (services/round_counting.py) and the two
championship calculators that consume it, plus the individual-play rule that
the net double-bogey cap is ALWAYS on rather than Net-100%-only.

The rules under test (docs/design-review/handoff-individual-play/SPEC.md §2):

* Unset / N >= rounds → every round counts, nothing struck.
* Otherwise the best N count; the rest stay on the board struck through.
* A round in progress can NEVER displace a finished one — but it may fill a
  counting slot the finished rounds leave empty, so the board is not blank on
  day one.
"""
from decimal import Decimal

from django.test import TestCase

from games.models import LowNetChampionshipConfig, StablefordChampionshipConfig
from services.low_net_championship import low_net_championship_summary
from services.round_counting import select_counting_rounds
from services.stableford_championship import stableford_championship_summary
from ._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament, submit_hole,
)


# ---------------------------------------------------------------------------
# The selector, on its own
# ---------------------------------------------------------------------------

class SelectCountingRoundsTests(TestCase):
    @staticmethod
    def _r(ntp, complete=True):
        return {'net_to_par': ntp, 'is_complete': complete}

    def test_no_limit_counts_everything(self):
        rows = [self._r(5), self._r(1), self._r(9)]
        self.assertEqual(select_counting_rounds(rows, None), [True, True, True])
        self.assertEqual(select_counting_rounds(rows, 0), [True, True, True])

    def test_limit_at_or_above_round_count_counts_everything(self):
        rows = [self._r(5), self._r(1)]
        self.assertEqual(select_counting_rounds(rows, 2), [True, True])
        self.assertEqual(select_counting_rounds(rows, 7), [True, True])

    def test_best_n_keeps_the_low_rounds(self):
        # Best 3 of 4 drops the +9.
        rows = [self._r(5), self._r(1), self._r(9), self._r(3)]
        self.assertEqual(select_counting_rounds(rows, 3),
                         [True, True, False, True])

    def test_incomplete_round_never_displaces_a_finished_one(self):
        # The 4-hole round is level par and would win on score alone; it must
        # not knock out the finished +7.
        rows = [self._r(7, complete=True), self._r(0, complete=False)]
        self.assertEqual(select_counting_rounds(rows, 1), [True, False])

    def test_incomplete_round_fills_a_vacancy(self):
        # Best 2 of 2 rounds played, only one finished — the live round takes
        # the empty slot rather than leaving the total short.
        rows = [self._r(7, complete=True), self._r(0, complete=False)]
        self.assertEqual(select_counting_rounds(rows, 2), [True, True])

    def test_unscored_round_sorts_last(self):
        rows = [self._r(None), self._r(4), self._r(2)]
        self.assertEqual(select_counting_rounds(rows, 2), [False, True, True])

    def test_empty(self):
        self.assertEqual(select_counting_rounds([], 3), [])


# ---------------------------------------------------------------------------
# Low Net Championship — best N of M
# ---------------------------------------------------------------------------

class LowNetBestNTests(TestCase):
    """
    Three rounds on a par-72 course, one scratch golfer, counting best 2 of 3.
    Scoring every hole at par gives net-to-par 0; adding strokes moves it.
    """

    def setUp(self):
        self.course = make_course()
        self.tee    = make_tee(self.course)
        self.tourn  = make_tournament(total_rounds=3, rounds_to_count=2)
        LowNetChampionshipConfig.objects.create(
            tournament=self.tourn, handicap_mode='net', net_percent=100,
            entry_fee=Decimal('10.00'),
            payouts=[{'place': 1, 'amount': 30.00}])
        self.player = make_player('Alan', 0, short_name='Alan')
        self.rounds = []
        for n in (1, 2, 3):
            r = make_round(self.course, tournament=self.tourn, round_number=n,
                           active_games=['low_net_round'])
            self.rounds.append(r)

    def _play(self, round_obj, over=0, holes=18):
        """Score `holes` holes at par, bogeying the first `over` of them so each
        round has a distinct, controllable total.

        Bogeys rather than one blow-up hole: this is a scratch golfer, so the
        net double-bogey cap is par + 2 and a single big number would be
        swallowed by it — which is the cap working, not the counter failing.
        """
        fs = make_foursome(round_obj, [(self.player, 0)], tee=self.tee)
        for i, h in enumerate(DEFAULT_HOLES[:holes]):
            gross = h['par'] + (1 if i < over else 0)
            submit_hole(fs, h['number'], [(self.player, gross)])
        return fs

    def test_worst_of_three_is_dropped(self):
        self._play(self.rounds[0], over=1)   # +1
        self._play(self.rounds[1], over=5)   # +5  ← dropped
        self._play(self.rounds[2], over=2)   # +2

        row = low_net_championship_summary(self.tourn)['results'][0]
        self.assertEqual(row['round_ntps'], [1, 5, 2])
        self.assertEqual(row['round_counts'], [True, False, True])
        # Total is +1 and +2 only.
        self.assertEqual(row['net_to_par'], 3)
        # Every round the golfer teed off in is still reported.
        self.assertEqual(row['rounds_played'], 3)

    def test_summary_reports_the_counting_rule(self):
        self._play(self.rounds[0], over=1)
        summary = low_net_championship_summary(self.tourn)
        self.assertEqual(summary['rounds_to_count'], 2)
        self.assertEqual(summary['counting_rule'], 'Best 2 of 3')

    def test_all_rounds_count_when_unset(self):
        self.tourn.rounds_to_count = None
        self.tourn.save(update_fields=['rounds_to_count'])
        self._play(self.rounds[0], over=1)
        self._play(self.rounds[1], over=5)
        self._play(self.rounds[2], over=2)

        summary = low_net_championship_summary(self.tourn)
        row = summary['results'][0]
        self.assertEqual(row['round_counts'], [True, True, True])
        self.assertEqual(row['net_to_par'], 8)
        self.assertEqual(summary['counting_rule'], 'All 3 rounds')

    def test_round_in_progress_does_not_displace_a_finished_round(self):
        # Two finished rounds at +1 and +5, then four holes at level par in
        # round 3. Best 2 of 3 must keep the two FINISHED rounds — the live
        # round looks better but has not earned a place.
        self._play(self.rounds[0], over=1)
        self._play(self.rounds[1], over=5)
        self._play(self.rounds[2], holes=4)

        row = low_net_championship_summary(self.tourn)['results'][0]
        self.assertEqual(row['round_counts'], [True, True, False])
        self.assertEqual(row['round_complete'], [True, True, False])
        self.assertEqual(row['net_to_par'], 6)

    def test_round_in_progress_fills_an_empty_slot(self):
        # One finished round and two live ones, counting best 2 of 3. The
        # finished round takes the first slot; the better of the two live
        # rounds fills the vacancy rather than leaving the total short.
        self._play(self.rounds[0], over=1)          # finished, +1
        self._play(self.rounds[1], over=3, holes=4)  # live, +3 thru 4
        self._play(self.rounds[2], holes=4)          # live, level thru 4

        row = low_net_championship_summary(self.tourn)['results'][0]
        self.assertEqual(row['round_complete'], [True, False, False])
        self.assertEqual(row['round_counts'], [True, False, True])


# ---------------------------------------------------------------------------
# Stableford Championship — best N of M, ranked the other way up
# ---------------------------------------------------------------------------

class StablefordBestNTests(TestCase):
    def setUp(self):
        self.course = make_course()
        self.tee    = make_tee(self.course)
        self.tourn  = make_tournament(total_rounds=3, rounds_to_count=2,
                                      scoring_method='stableford',
                                      active_games=['stableford_championship'])
        StablefordChampionshipConfig.objects.create(
            tournament=self.tourn, handicap_mode='net', net_percent=100,
            entry_fee=Decimal('10.00'), payouts=[])
        self.player = make_player('Alan', 0, short_name='Alan')
        self.rounds = [
            make_round(self.course, tournament=self.tourn, round_number=n,
                       active_games=['stableford'])
            for n in (1, 2, 3)
        ]

    def _play(self, round_obj, birdies=0, holes=18):
        fs = make_foursome(round_obj, [(self.player, 0)], tee=self.tee)
        for i, h in enumerate(DEFAULT_HOLES[:holes]):
            gross = h['par'] - 1 if i < birdies else h['par']
            submit_hole(fs, h['number'], [(self.player, gross)])
        return fs

    def test_best_two_of_three_keeps_the_high_scores(self):
        # Standard table: par = 2, birdie = 3. 18 pars = 36.
        self._play(self.rounds[0], birdies=0)   # 36
        self._play(self.rounds[1], birdies=4)   # 40  ← counts
        self._play(self.rounds[2], birdies=2)   # 38  ← counts

        row = stableford_championship_summary(self.tourn)['results'][0]
        self.assertEqual(row['round_totals'], [36, 40, 38])
        self.assertEqual(row['round_counts'], [False, True, True])
        self.assertEqual(row['total_points'], 78)

    def test_live_round_cannot_displace_a_finished_one(self):
        # Four holes with four birdies scores 12, which is worse than either
        # finished round anyway — so make it unambiguous by checking a live
        # round that would win a per-hole rate comparison but not a total.
        self._play(self.rounds[0], birdies=0)   # 36
        self._play(self.rounds[1], birdies=4)   # 40
        self._play(self.rounds[2], birdies=4, holes=4)   # 12, incomplete

        row = stableford_championship_summary(self.tourn)['results'][0]
        self.assertEqual(row['round_complete'], [True, True, False])
        self.assertEqual(row['round_counts'], [True, True, False])
        self.assertEqual(row['total_points'], 76)

    def test_card_carries_gross_and_points_not_net(self):
        self._play(self.rounds[0], birdies=1)
        row = stableford_championship_summary(self.tourn)['results'][0]
        card = row['round_holes'][0]
        self.assertEqual(len(card), 18)
        self.assertIn('gross', card[0])
        self.assertIn('points', card[0])
        self.assertNotIn('net', card[0])


# ---------------------------------------------------------------------------
# The cap is a rule, not a setting
# ---------------------------------------------------------------------------

class AlwaysOnCapTests(TestCase):
    """
    Casual scoring only applies the net double-bogey cap at Net 100%. An
    individual-play tournament applies it at every allowance, because the
    ceiling is stated in terms of the strokes actually received.
    """

    def setUp(self):
        self.course = make_course()
        self.tee    = make_tee(self.course)
        # 18 index at 90% allowance → playing handicap 18, so one stroke a hole.
        self.player = make_player('Alan', 18, short_name='Alan')

    def _summary(self, *, individual: bool):
        active = ['low_net'] if individual else ['team_cup', 'low_net']
        tourn = make_tournament(total_rounds=1, active_games=active,
                                handicap_mode='net', net_percent=90)
        LowNetChampionshipConfig.objects.create(
            tournament=tourn, handicap_mode='net', net_percent=90,
            entry_fee=Decimal('0.00'), payouts=[])
        rnd = make_round(self.course, tournament=tourn, round_number=1,
                         active_games=['low_net_round'])
        fs  = make_foursome(rnd, [(self.player, 18)], tee=self.tee)
        for h in DEFAULT_HOLES:
            # A blow-up 10 on hole 1; par everywhere else.
            gross = 10 if h['number'] == 1 else h['par']
            submit_hole(fs, h['number'], [(self.player, gross)])
        return low_net_championship_summary(tourn)['results'][0]

    # 18 playing handicap at a 90% allowance gives 16 strokes, so every hole
    # gets one except the two easiest (SI 17 and 18 — holes 7 and 16). The 15
    # par-and-a-stroke holes other than hole 1 are −1 each.
    _OTHER_HOLES = -15

    def test_individual_play_caps_at_a_reduced_allowance(self):
        # Hole 1 is a par 4 with one stroke received: the ceiling is 4+2+1 = 7,
        # so a 10 counts as a 7 gross → net 6, i.e. +2 on the hole.
        row = self._summary(individual=True)
        self.assertEqual(row['net_to_par'], 2 + self._OTHER_HOLES)

    def test_cup_keeps_the_historic_net_100_only_behaviour(self):
        # Uncapped: a 10 with one stroke is a net 9 on a par 4 → +5.
        row = self._summary(individual=False)
        self.assertEqual(row['net_to_par'], 5 + self._OTHER_HOLES)
