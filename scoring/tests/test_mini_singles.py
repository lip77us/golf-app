"""
scoring/tests/test_mini_singles.py
----------------------------------
The Mini Singles Bracket's tournament-level layer (services/mini_singles.py,
docs/design-review/handoff-individual-play/SPEC.md §4):

* the field gate — 9 to 16, three or four groups, four is the ceiling;
* day-1 group champions collected into a derived day-2 foursome;
* day-2 seeding by WIDEST DAY-1 MARGIN, then lowest index — not index again;
* the empty-seat rule, answered once at setup rather than on Sunday morning;
* the champions' foursome filled by SWAPPING memberships, so tees and the
  TD's group sizes survive;
* two pots — a day-1 side bet per group, and a day-2 carve-out off the top of
  the championship pool.
"""
from decimal import Decimal

from django.test import TestCase

from games.models import (
    LowNetChampionshipConfig, MatchPlayBracket, MiniSinglesConfig,
    ThreePersonMatch,
)
from services.mini_singles import (
    check_field, day2_finalist_ids, derive_day2_field, mini_singles_summary,
    sync_day2_champions,
)
from services.tournament_match_play import (
    calculate_tournament_match_play, setup_tournament_match_play,
)
from ._helpers import (
    make_course, make_foursome, make_player, make_round, make_tee,
    make_tournament, submit_hole,
)


class FieldGateTests(TestCase):
    def test_eight_or_fewer_is_not_a_bracket(self):
        ok, groups, reason = check_field(8)
        self.assertFalse(ok)
        self.assertEqual(groups, 0)
        self.assertIn('not a bracket', reason)

    def test_nine_to_twelve_is_three_groups(self):
        for n in (9, 10, 11, 12):
            ok, groups, _ = check_field(n)
            self.assertTrue(ok)
            self.assertEqual(groups, 3)

    def test_thirteen_to_sixteen_is_four_groups(self):
        for n in (13, 14, 15, 16):
            ok, groups, _ = check_field(n)
            self.assertTrue(ok)
            self.assertEqual(groups, 4)

    def test_over_sixteen_needs_a_third_day(self):
        ok, _groups, reason = check_field(17)
        self.assertFalse(ok)
        self.assertIn('third day', reason)


class MiniSinglesBase(TestCase):
    """
    A 16-golfer, two-round tournament: four groups of four on both days, with
    day 2's group 4 reserved for the champions.
    """

    NAMES = ['Petersen', 'Gunst', 'Detomasi', 'Maiolini',
             'Brown', 'Avery', 'Labass', 'Duddy',
             'Nolan', 'Hart', 'Quinn', 'Rowe',
             'Shaw', 'Tate', 'Usher', 'Vance']

    def setUp(self):
        self.course = make_course()
        self.tee    = make_tee(self.course)
        self.tourn  = make_tournament(total_rounds=2, mini_singles_carve_pct=25)
        LowNetChampionshipConfig.objects.create(
            tournament=self.tourn, entry_fee=Decimal('40.00'), payouts=[])
        self.config = MiniSinglesConfig.objects.create(
            tournament=self.tourn, handicap_mode='strokes_off',
            day1_entry_fee=Decimal('10.00'),
            day1_payouts=[{'place': 1, 'amount': 24},
                          {'place': 2, 'amount': 10},
                          {'place': 3, 'amount': 6}],
            day2_payouts=[{'place': 1, 'amount': 90},
                          {'place': 2, 'amount': 40},
                          {'place': 3, 'amount': 30}])

        self.players = [make_player(n, 0, short_name=n[:5]) for n in self.NAMES]

        self.r1 = make_round(self.course, tournament=self.tourn, round_number=1,
                             active_games=['match_play'])
        self.r2 = make_round(self.course, tournament=self.tourn, round_number=2,
                             active_games=['match_play', 'low_net_round'])

        self.g1 = self._groups(self.r1)
        self.g2 = self._groups(self.r2)
        # Day 2's last group is the reserved champions' foursome.
        self.reserved = self.g2[-1]
        self.reserved.is_champions_foursome = True
        self.reserved.save(update_fields=['is_champions_foursome'])

    def _groups(self, round_obj, n_groups=4):
        out = []
        for g in range(n_groups):
            members = self.players[g * 4:(g + 1) * 4]
            out.append(make_foursome(round_obj, [(p, 0) for p in members],
                                     tee=self.tee, group_number=g + 1))
        return out

    def _play_group(self, foursome, *, winner_margin):
        """
        Score a day-1 group so its bracket resolves with the group's FIRST
        seed taking the final by ``winner_margin`` holes.

        Semis: each semi's player1 wins hole 1 outright, then halves out.
        Final: player1 wins `winner_margin` holes on the back, halves the rest.
        3rd place: every hole halved.
        """
        bracket = setup_tournament_match_play(foursome, handicap_mode='gross')
        r1 = [m for m in bracket.matches.order_by('round_number', 'id')
              if m.round_number == 1]
        s1, s2 = r1

        def score(hole, s1p1, s1p2, s2p1, s2p2):
            submit_hole(foursome, hole, [
                (s1.player1_id, s1p1), (s1.player2_id, s1p2),
                (s2.player1_id, s2p1), (s2.player2_id, s2p2)])
            calculate_tournament_match_play(foursome)

        score(1, 3, 5, 3, 5)                      # both semis go 1 up
        for h in range(2, 10):
            score(h, 4, 4, 4, 4)                  # …and stay there

        # Back nine: the final is s1.player1 vs s2.player1 (both semi winners).
        for i, h in enumerate(range(10, 19)):
            if i < winner_margin:
                score(h, 3, 4, 4, 4)              # final p1 wins
            else:
                score(h, 4, 4, 4, 4)              # halved
        return bracket


class DeriveDay2FieldTests(MiniSinglesBase):
    def test_champions_are_seeded_by_widest_day_one_margin(self):
        # Group 1's winner wins by 4, group 2's by 1, group 3's by 3,
        # group 4's by 2 — so seeding is 1, 3, 4, 2.
        for fs, margin in zip(self.g1, (4, 1, 3, 2)):
            self._play_group(fs, winner_margin=margin)

        field = derive_day2_field(self.tourn)
        self.assertEqual([w['group_number'] for w in field], [1, 3, 4, 2])
        self.assertEqual([w['margin'] for w in field], [4, 3, 2, 1])
        self.assertTrue(all(not w['promoted'] for w in field))

    def test_lowest_index_breaks_a_margin_tie(self):
        # Two 2-hole winners: the lower playing handicap seeds ahead.
        for fs in self.g1[:2]:
            self._play_group(fs, winner_margin=2)
        # Give group 2's champion a higher handicap than group 1's.
        winner2 = MatchPlayBracket.objects.get(foursome=self.g1[1]).winner
        m = self.g1[1].memberships.get(player=winner2)
        m.playing_handicap = 12
        m.save(update_fields=['playing_handicap'])

        field = derive_day2_field(self.tourn)
        self.assertEqual([w['group_number'] for w in field[:2]], [1, 2])
        self.assertEqual([w['index'] for w in field[:2]], [0, 12])


class EmptySeatRuleTests(MiniSinglesBase):
    def test_promote_fills_the_seat_with_the_best_beaten_finalist(self):
        # Only three groups produce a champion.
        for fs in self.g1[:3]:
            self._play_group(fs, winner_margin=2)

        field = derive_day2_field(self.tourn)
        self.assertEqual(len(field), 4)
        promoted = [w for w in field if w['promoted']]
        self.assertEqual(len(promoted), 1)
        # A promoted golfer has no margin, so he seeds behind every winner.
        self.assertIs(field[-1], promoted[0])

    def test_short_handed_refills_nobody(self):
        self.config.empty_seat_rule = 'short'
        self.config.save(update_fields=['empty_seat_rule'])
        for fs in self.g1[:3]:
            self._play_group(fs, winner_margin=2)

        field = derive_day2_field(self.tourn)
        self.assertEqual(len(field), 3)
        self.assertTrue(all(not w['promoted'] for w in field))

    def test_points_then_a_match_builds_a_three_person_match(self):
        self.config.empty_seat_rule = 'points'
        self.config.save(update_fields=['empty_seat_rule'])
        for fs in self.g1[:3]:
            self._play_group(fs, winner_margin=2)

        reserved = sync_day2_champions(self.tourn)
        self.assertIsNotNone(reserved)
        # Points over the front, the two leaders play the back — and a tie in
        # the points round plays on rather than going to a card-off.
        self.assertTrue(ThreePersonMatch.objects.filter(foursome=reserved).exists())
        self.assertFalse(MatchPlayBracket.objects.filter(foursome=reserved).exists())


class SyncDay2ChampionsTests(MiniSinglesBase):
    def test_champions_are_swapped_into_the_reserved_foursome(self):
        for fs, margin in zip(self.g1, (4, 1, 3, 2)):
            self._play_group(fs, winner_margin=margin)

        before = {fs.id: fs.memberships.count() for fs in self.g2}
        reserved = sync_day2_champions(self.tourn)

        champion_ids = {w['player'].id for w in derive_day2_field(self.tourn)}
        seated = set(reserved.memberships.values_list('player_id', flat=True))
        self.assertEqual(seated, champion_ids)

        # A swap, not a rebuild: every day-2 group is still the size the TD
        # set it, and every golfer still has exactly one seat.
        after = {fs.id: fs.memberships.count() for fs in self.g2}
        self.assertEqual(before, after)
        seats = list(self.r2.foursomes.values_list('memberships__player_id',
                                                   flat=True))
        self.assertEqual(len(seats), len(set(seats)))

    def test_the_day_two_bracket_is_seeded_by_margin(self):
        for fs, margin in zip(self.g1, (4, 1, 3, 2)):
            self._play_group(fs, winner_margin=margin)
        reserved = sync_day2_champions(self.tourn)

        bracket = MatchPlayBracket.objects.get(foursome=reserved)
        semis = list(bracket.matches.filter(round_number=1).order_by('id'))
        field = derive_day2_field(self.tourn)
        # Seed 1 meets seed 4; seed 2 meets seed 3.
        self.assertEqual(semis[0].player1_id, field[0]['player'].id)
        self.assertEqual(semis[0].player2_id, field[3]['player'].id)
        self.assertEqual(semis[1].player1_id, field[1]['player'].id)
        self.assertEqual(semis[1].player2_id, field[2]['player'].id)

    def test_the_bracket_defaults_to_strokes_off_low(self):
        for fs, margin in zip(self.g1, (4, 1, 3, 2)):
            self._play_group(fs, winner_margin=margin)
        reserved = sync_day2_champions(self.tourn)
        self.assertEqual(
            MatchPlayBracket.objects.get(foursome=reserved).handicap_mode,
            'strokes_off')

    def test_nothing_happens_without_a_config(self):
        # Nothing downstream may assume the bracket exists.
        self.config.delete()
        self.tourn.refresh_from_db()
        self.assertIsNone(sync_day2_champions(self.tourn))
        self.assertIsNone(mini_singles_summary(self.tourn))
        self.assertEqual(day2_finalist_ids(self.tourn), set())


class MiniSinglesMoneyTests(MiniSinglesBase):
    def test_two_pots_funded_differently(self):
        for fs, margin in zip(self.g1, (4, 1, 3, 2)):
            self._play_group(fs, winner_margin=margin)
        sync_day2_champions(self.tourn)

        s = mini_singles_summary(self.tourn)
        self.assertTrue(s['configured'])

        # Day 1: $10 a golfer, paid inside each group of four.
        self.assertEqual(s['day1']['entry_fee'], 10.0)
        self.assertEqual([p['pot'] for p in s['day1']['pots']], [40.0] * 4)

        # Day 2: 25% off the top of a $40 x 16 = $640 championship pool.
        self.assertEqual(s['day2']['championship_pool'], 640.0)
        self.assertEqual(s['day2']['carve_pct'], 25)
        self.assertEqual(s['day2']['pot'], 160.0)
        self.assertEqual(s['day2']['left_for_championship'], 480.0)

    def test_the_field_block_reports_the_gate(self):
        s = mini_singles_summary(self.tourn)
        self.assertEqual(s['field']['golfers'], 16)
        self.assertEqual(s['field']['groups'], 4)
        self.assertTrue(s['field']['fits'])

    def test_finalists_are_named_for_the_day_bet_to_exclude(self):
        for fs, margin in zip(self.g1, (4, 1, 3, 2)):
            self._play_group(fs, winner_margin=margin)
        ids = day2_finalist_ids(self.tourn)
        self.assertEqual(len(ids), 4)
