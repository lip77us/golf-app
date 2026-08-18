"""
scoring/tests/test_day_bet.py
-----------------------------
The day bet (services/day_bet.py,
docs/design-review/handoff-individual-play/SPEC.md §7) — the final round's
18-hole stroke play side bet, and the only board whose result is not knowable
while it is being played.

The two ways out are not the same thing:

* Mini Singles day-2 finalists are **not here at all** — neither charged nor
  ranked, an absence rather than an exclusion.
* Championship money winners are **here but italic** — they play, they show,
  they cannot collect, and they do not contribute.

And the guard that sizes the two pots against each other: the last paying
championship place must clear day-bet 1st, or the placing that disqualifies a
golfer from the day bet costs him money.
"""
from decimal import Decimal

from django.test import TestCase

from games.models import DayBetConfig, LowNetChampionshipConfig, MiniSinglesConfig
from services.day_bet import day_bet_standings, day_bet_summary, places_for_field
from services.payout import check_day_bet_floor
from ._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament, submit_hole,
)


class PlacesForFieldTests(TestCase):
    def test_ten_pays_three(self):
        self.assertEqual(places_for_field(10), 3)
        self.assertEqual(places_for_field(16), 3)

    def test_a_smaller_field_drops_to_two_then_one(self):
        self.assertEqual(places_for_field(9), 2)
        self.assertEqual(places_for_field(6), 2)
        self.assertEqual(places_for_field(5), 1)
        self.assertEqual(places_for_field(2), 1)

    def test_nobody_left_pays_nothing(self):
        self.assertEqual(places_for_field(1), 0)


class DayBetFixture:
    """
    Eight golfers over two rounds. Round 1 separates them on the championship;
    round 2 is the day bet.
    """

    NAMES = ['Petersen', 'Gunst', 'Detomasi', 'Maiolini',
             'Brown', 'Avery', 'Labass', 'Duddy']

    def setUp(self):
        self.course = make_course()
        self.tee    = make_tee(self.course)
        self.tourn  = make_tournament(total_rounds=2)
        LowNetChampionshipConfig.objects.create(
            tournament=self.tourn, handicap_mode='net', net_percent=100,
            entry_fee=Decimal('40.00'),
            payouts=[{'place': 1, 'amount': 200}, {'place': 2, 'amount': 120}])

        self.players = [make_player(n, 0, short_name=n[:5]) for n in self.NAMES]
        self.r1 = make_round(self.course, tournament=self.tourn, round_number=1,
                             active_games=['low_net_round'])
        self.r2 = make_round(self.course, tournament=self.tourn, round_number=2,
                             active_games=['low_net_round'])
        self.fs1 = self._foursomes(self.r1)
        self.fs2 = self._foursomes(self.r2)
        self.bet = DayBetConfig.objects.create(
            round=self.r2, entry_fee=Decimal('20.00'),
            payouts=[{'place': 1, 'amount': 100}, {'place': 2, 'amount': 60}])

    def _foursomes(self, round_obj):
        return [
            make_foursome(round_obj,
                          [(p, 0) for p in self.players[g * 4:(g + 1) * 4]],
                          tee=self.tee, group_number=g + 1)
            for g in range(2)
        ]

    def _score(self, foursomes, over_by_player):
        """``over_by_player`` maps a player's index to strokes over par."""
        for fs in foursomes:
            members = list(fs.memberships.select_related('player'))
            for h in DEFAULT_HOLES:
                submit_hole(fs, h['number'], [
                    (m.player,
                     h['par'] + (1 if DEFAULT_HOLES.index(h) <
                                 over_by_player.get(
                                     self.players.index(m.player), 0) else 0))
                    for m in members
                ])

    def _play_both_rounds(self):
        # Round 1: Petersen (0) and Gunst (1) run away with the championship.
        self._score(self.fs1, {0: 0, 1: 1, 2: 6, 3: 7, 4: 8, 5: 9, 6: 10, 7: 11})
        # Round 2: Brown (index 4) shoots the low round — exactly the golfer
        # this bet exists for.
        self._score(self.fs2, {0: 5, 1: 5, 2: 5, 3: 5, 4: 0, 5: 2, 6: 3, 7: 4})


class DayBetBoardTests(DayBetFixture, TestCase):
    def test_championship_money_winners_are_shown_but_cannot_collect(self):
        self._play_both_rounds()
        rows = {r['player_name']: r for r in day_bet_standings(self.r2)}

        # They played the round, so they are on the board.
        self.assertIn('Petersen', rows)
        self.assertIn('Gunst', rows)
        self.assertFalse(rows['Petersen']['eligible'])
        self.assertIn('36-hole money', rows['Petersen']['ineligible_reason'])
        self.assertIsNone(rows['Petersen']['payout'])

    def test_an_ineligible_row_holds_a_position_but_not_a_paid_place(self):
        self._play_both_rounds()
        rows = day_bet_standings(self.r2)
        paid = [r for r in rows if r['payout']]
        # Prize goes to the first two ELIGIBLE golfers, not the first two rows.
        self.assertTrue(all(r['eligible'] for r in paid))
        self.assertEqual(paid[0]['player_name'], 'Brown')
        self.assertEqual(paid[0]['payout'], 100.0)

    def test_the_pool_counts_only_the_golfers_who_can_win_it(self):
        self._play_both_rounds()
        s = day_bet_summary(self.r2)
        # Eight played, two are in the money and do not contribute.
        self.assertEqual(s['eligible_count'], 6)
        self.assertEqual(s['pool'], 120.0)
        self.assertEqual(s['places_supported'], 2)

    def test_the_board_is_provisional_until_every_round_closes(self):
        self._play_both_rounds()
        self.assertTrue(day_bet_summary(self.r2)['provisional'])
        for r in (self.r1, self.r2):
            r.status = 'completed'
            r.save(update_fields=['status'])
        self.assertFalse(day_bet_summary(self.r2)['provisional'])

    def test_the_dq_note_reads_the_tournament_setting(self):
        self._play_both_rounds()
        self.assertIn('net money', day_bet_summary(self.r2)['dq_note'])

        self.tourn.handicap_mode = 'gross'
        self.tourn.save(update_fields=['handicap_mode'])
        self.assertIn('gross money', day_bet_summary(self.r2)['dq_note'])

    def test_no_config_no_board(self):
        self.bet.delete()
        self.r2.refresh_from_db()
        self.assertIsNone(day_bet_summary(self.r2))


class DayBetAbsentFinalistsTests(DayBetFixture, TestCase):
    """Mini Singles finalists get no row at all — an absence, not an italic."""

    def setUp(self):
        super().setUp()
        MiniSinglesConfig.objects.create(tournament=self.tourn)

    def test_finalists_are_neither_charged_nor_ranked(self):
        from unittest.mock import patch
        self._play_both_rounds()

        with patch('services.mini_singles.derive_day2_field',
                   return_value=[{'player': self.players[2]},
                                 {'player': self.players[3]}]):
            rows = day_bet_standings(self.r2)
            s    = day_bet_summary(self.r2)

        names = {r['player_name'] for r in rows}
        self.assertNotIn('Detomasi', names)
        self.assertNotIn('Maiolini', names)
        self.assertEqual(len(rows), 6)
        # Six shown, two of those in the money → four fund the pot.
        self.assertEqual(s['eligible_count'], 4)
        self.assertEqual(s['pool'], 80.0)
        self.assertEqual(s['absent_count'], 2)


class DayBetFloorApiTests(TestCase):
    """
    The guard where it bites: the payout step. Checked in the reducer, not only
    in the UI, so an API caller cannot post a table that fails it.
    """

    def test_the_reducer_blocks_an_under_paying_last_place(self):
        reason = check_day_bet_floor(
            [{'place': 1, 'amount': 200}, {'place': 2, 'amount': 80}],
            [{'place': 1, 'amount': 100}])
        self.assertIsNotNone(reason)
        self.assertIn('$20.00', reason)

    def test_it_clears_when_the_championship_pays_enough(self):
        self.assertIsNone(check_day_bet_floor(
            [{'place': 1, 'amount': 400}, {'place': 2, 'amount': 200}],
            [{'place': 1, 'amount': 100}]))
