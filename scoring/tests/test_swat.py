"""
scoring/tests/test_swat.py
--------------------------
Oakmont SWAT — a field-wide team game (docs/design-review/handoff-oakmont-swat).

The rules are pure where they can be (the snake deal, the shape check, the
phantom draw) and derived on read everywhere else, so the second half plays a
real thirteen-golfer round through the engine.
"""
import random

from django.test import TestCase

from games.models import SwatConfig
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
    make_tournament, submit_hole,
)
from services import swat

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}

# swat.js's example field: name, index, ch
FIELD = [('Paul Lipkin', 3.2, 4), ('Kelly Brandt', 4.8, 6),
         ('Dave Moran', 6.1, 7), ('Sam Reid', 7.4, 9),
         ('Mike Alvarez', 8.9, 10), ('Lee Naylor', 10.2, 12),
         ('Tom Okafor', 11.5, 13), ('Chris Hale', 12.7, 15),
         ('Ray Dunn', 14.0, 16), ('Ben Ortiz', 15.3, 18),
         ('Jim Castle', 16.8, 19), ('Phil Grant', 18.2, 21),
         ('Gary Wu', 20.5, 24), ('Nick Prior', 23.1, 27)]


def golfers():
    return [{'id': i, 'name': n, 'index': hi, 'ch': ch}
            for i, (n, hi, ch) in enumerate(FIELD, start=1)]


class SnakeDealTests(TestCase):
    def test_fourteen_golfers_make_four_teams_two_of_them_threesomes(self):
        out = swat.snake_deal(golfers())
        self.assertEqual(sorted(len(t) for t in out['teams']), [3, 3, 4, 4])

    def test_it_deals_one_two_three_four_then_back(self):
        t = swat.snake_deal(golfers())['teams']
        self.assertEqual([x[0] for x in t], [1, 2, 3, 4])       # the four lowest
        self.assertEqual([x[1] for x in t], [8, 7, 6, 5])       # then reversed
        self.assertEqual([x[2] for x in t][:2], [9, 10])        # then forward

    def test_the_teams_the_last_pass_does_not_reach_are_the_threesomes(self):
        t = swat.snake_deal(golfers())['teams']
        self.assertEqual([len(x) for x in t], [3, 3, 4, 4])  # last pass runs backwards

    def test_bands_are_the_rows_of_the_deal(self):
        b = swat.snake_deal(golfers())['bands']
        self.assertEqual([b[i] for i in (1, 4, 5, 8, 9, 12, 13)],
                         ['A', 'A', 'B', 'B', 'C', 'C', 'D'])

    def test_a_tie_on_index_goes_to_course_handicap_then_surname(self):
        gs = [{'id': 1, 'name': 'A Zed', 'index': 5.0, 'ch': 6},
              {'id': 2, 'name': 'B Abel', 'index': 5.0, 'ch': 6},
              {'id': 3, 'name': 'C Mid', 'index': 5.0, 'ch': 5}]
        order = [g['id'] for g in sorted(gs, key=swat._sort_key)]
        self.assertEqual(order, [3, 2, 1])

    def test_a_team_is_named_for_its_lowest_index_golfer(self):
        self.assertEqual(swat.team_name(golfers()[:4]), 'Team Lipkin')
        moved = [golfers()[1], golfers()[4]]
        self.assertEqual(swat.team_name(moved), 'Team Brandt')


class ShapeTests(TestCase):
    def test_under_twelve_cannot_start(self):
        self.assertIn('at least 12', swat.shape_problem([4, 4, 3]))

    def test_a_team_needs_three(self):
        self.assertIn('three', swat.shape_problem([4, 4, 4, 2]))

    def test_five_needs_the_switch(self):
        self.assertIsNotNone(swat.shape_problem([5, 4, 4]))
        self.assertIsNone(swat.shape_problem([5, 4, 4], allow_fivesomes=True))

    def test_a_threesome_needs_a_team_of_four_to_draw_from(self):
        self.assertIsNotNone(swat.shape_problem([3, 3, 3, 3]))

    def test_a_plain_field_is_fine(self):
        self.assertIsNone(swat.shape_problem([4, 4, 4]))
        self.assertIsNone(swat.shape_problem([4, 3, 3, 3]))


class PhantomDrawTests(TestCase):
    def test_every_pass_uses_each_donor_once(self):
        order = swat.draw_phantom_order([1, 2, 3], random.Random(4))
        self.assertEqual(len(order), 18)
        for k in range(0, 18, 3):
            self.assertEqual(sorted(order[k:k + 3]), [1, 2, 3])

    def test_one_donor_is_the_phantom_on_every_hole(self):
        self.assertEqual(swat.draw_phantom_order([7]), [7] * 18)

    def test_no_donors_no_order(self):
        self.assertEqual(swat.draw_phantom_order([]), [])

    def test_an_uneven_pass_still_fills_eighteen(self):
        order = swat.draw_phantom_order([1, 2, 3, 4, 5], random.Random(1))
        self.assertEqual(len(order), 18)
        self.assertTrue(set(order) <= {1, 2, 3, 4, 5})


class _Round(TestCase):
    """Thirteen golfers: one team of four and three threesomes."""

    def setUp(self):
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tourn = make_tournament(name='SWAT Day')
        self.round = make_round(course=self.course, tournament=self.tourn,
                                active_games=['oakmont_swat'])
        self.a = make_foursome(self.round, [('A1 Ames', 1), ('A2 Bell', 2),
                                            ('A3 Cole', 3), ('A4 Dunn', 9)],
                               tee=self.tee, group_number=1)
        self.b = make_foursome(self.round, [('B1 Eyre', 4), ('B2 Ford', 5),
                                            ('B3 Gage', 6)],
                               tee=self.tee, group_number=2)
        self.c = make_foursome(self.round, [('C1 Hale', 7), ('C2 Ives', 8),
                                            ('C3 Jain', 10)],
                               tee=self.tee, group_number=3)
        self.d = make_foursome(self.round, [('D1 Kerr', 11), ('D2 Lowe', 12),
                                            ('D3 Mann', 13)],
                               tee=self.tee, group_number=4)
        self.bottom = self.a.memberships.order_by('-player__handicap_index'
                                                  ).first().player_id
        self.cfg = SwatConfig.objects.create(
            round=self.round, stake=6, phantom_order=[self.bottom] * 18)

    def pids(self, fs):
        return [m.player_id for m in fs.memberships.order_by('id')]

    def play(self, fs, hole, *deltas):
        submit_hole(fs, hole, [(p, PAR[hole] + d)
                               for p, d in zip(self.pids(fs), deltas)])

    def play_all(self, a, b, c, d, holes=range(1, 19)):
        """Team A: one par and three bogeys (best = par); the rest bogey."""
        for h in holes:
            self.play(self.a, h, *a)
            self.play(self.b, h, *b)
            self.play(self.c, h, *c)
            self.play(self.d, h, *d)

    def summary(self):
        return swat.swat_summary(self.round)

    def team(self, s, fs):
        return next(t for t in s['teams'] if t['id'] == fs.pk)


class MoneyTests(_Round):
    def setUp(self):
        super().setUp()
        # A's best is par; everyone else's is a bogey (the phantom is A's
        # bottom golfer, who bogeys).
        self.play_all((0, 1, 1, 1), (1, 1, 1), (1, 1, 1), (1, 1, 1))

    def test_the_leader_wins_nine_bets_at_the_team_stake(self):
        a = self.team(self.summary(), self.a)
        self.assertEqual((a['wins'], a['losses'], a['pushes']), (9, 0, 0))
        self.assertEqual(a['money'], 9 * 24)
        self.assertEqual(a['each'], 54.0)           # a foursome golfer's quarter

    def test_a_threesome_golfer_pays_a_third_of_the_team_stake(self):
        b = self.team(self.summary(), self.b)
        self.assertEqual(b['money'], -72.0)         # three lost bets at $24
        self.assertEqual(b['each'], -24.0)          # 4/3 of a foursome golfer
        self.assertEqual((b['wins'], b['losses'], b['pushes']), (0, 3, 6))

    def test_teams_that_tie_every_hole_push(self):
        s = self.summary()
        m = next(m for m in s['matches']
                 if {m['a'], m['b']} == {self.b.pk, self.c.pk})
        self.assertTrue(all(b['result'] == 'P' for b in m['bets']))

    def test_the_money_is_zero_sum(self):
        s = self.summary()
        self.assertAlmostEqual(sum(t['money'] for t in s['teams']), 0)

    def test_the_leader_is_first_and_ties_share_a_place(self):
        s = self.summary()
        places = {t['id']: t['place'] for t in s['teams']}
        self.assertEqual(places[self.a.pk], 1)
        self.assertEqual({places[self.b.pk], places[self.c.pk],
                          places[self.d.pk]}, {2})
        self.assertTrue(s['final'])

    def test_a_fivesome_golfer_collects_a_fifth(self):
        self.assertEqual(swat._each(2400, 5), 4.8)

    def test_cents_round_half_away_from_zero(self):
        self.assertEqual(swat._each(500, 3), 1.67)
        self.assertEqual(swat._each(-500, 3), -1.67)


class SharedHolesTests(_Round):
    def test_a_match_reads_only_the_holes_both_teams_have_finished(self):
        for h in range(1, 6):
            self.play(self.a, h, 0, 1, 1, 1)
        for h in range(1, 4):
            self.play(self.b, h, 1, 1, 1)
            self.play(self.c, h, 1, 1, 1)
        s = self.summary()
        m = next(m for m in s['matches']
                 if {m['a'], m['b']} == {self.a.pk, self.b.pk})
        self.assertEqual(m['thru'], 3)
        self.assertEqual(m['bets'][0]['played'], 3)

    def test_a_bet_is_closed_out_when_the_margin_beats_the_holes_left(self):
        # The front nine: A wins the first five of nine holes outright.
        for h in range(1, 6):
            self.play(self.a, h, 0, 1, 1, 1)
            self.play(self.b, h, 1, 1, 1)
        s = self.summary()
        m = next(m for m in s['matches']
                 if {m['a'], m['b']} == {self.a.pk, self.b.pk})
        front = m['bets'][0]
        self.assertEqual(front['margin'], 5)
        self.assertTrue(front['done'] and front['closed'])
        self.assertEqual(front['result'], 'W')
        self.assertFalse(m['bets'][2]['done'])          # the overall is not


class PhantomTests(_Round):
    def test_the_phantom_is_the_donors_gross_on_the_hole(self):
        for h in (1,):
            self.play(self.a, h, 0, 1, 1, -1)            # A4 (donor) birdies
            self.play(self.b, h, 1, 1, 1)
        s = self.summary()
        b = self.team(s, self.b)
        self.assertEqual(b['best'][1], PAR[1] - 1)       # the phantom counts

    def test_the_hole_waits_until_the_donor_has_played_it(self):
        self.play(self.b, 1, 1, 1, 1)
        b = self.team(self.summary(), self.b)
        self.assertEqual(b['thru'], 0)
        self.assertNotIn(1, b['best'])

    def test_a_correction_to_the_donors_score_moves_the_threesomes_hole(self):
        self.play(self.b, 1, 1, 1, 1)
        self.play(self.a, 1, 0, 1, 1, 1)
        self.assertEqual(self.team(self.summary(), self.b)['best'][1],
                         PAR[1] + 1)
        from scoring.models import HoleScore
        HoleScore.objects.filter(player_id=self.bottom, hole_number=1
                                 ).update(gross_score=PAR[1] - 1)
        self.assertEqual(self.team(self.summary(), self.b)['best'][1],
                         PAR[1] - 1)

    def test_a_threesomes_phantom_score_is_hidden_until_its_golfers_are_in(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        b = self.team(self.summary(), self.b)
        self.assertIsNone(b['phantom'][1])              # donor played, B has not
        self.play(self.b, 1, 1, 1, 1)
        b = self.team(self.summary(), self.b)
        self.assertEqual(b['phantom'][1], PAR[1] + 1)

    def test_the_donor_is_never_named_before_the_round_is_over(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        self.play(self.b, 1, 1, 1, 1)
        s = self.summary()
        blob = repr(s)
        self.assertNotIn('phantom_donors', blob)
        self.assertNotIn('phantom_order', blob)
        self.assertNotIn('A4', blob.replace('A4 Dunn', ''))   # short names only
        self.assertNotIn(str(self.bottom), repr(
            [t['phantom'] for t in s['teams']]))

    def test_the_donor_is_named_once_every_group_has_finished(self):
        for h in range(1, 19):
            self.play(self.a, h, 0, 1, 1, 1)
            for fs in (self.b, self.c, self.d):
                self.play(fs, h, 1, 1, 1)
        s = self.summary()
        self.assertTrue(s['final'])
        b = self.team(s, self.b)
        self.assertEqual(set(b['phantom_donors'].values()),
                         {self.a.memberships.get(player_id=self.bottom
                                                 ).player.short_name})
        self.assertNotIn('phantom_donors', self.team(s, self.a))


class SetupTests(TestCase):
    def test_the_game_is_exclusive_with_the_other_group_games(self):
        from services.group_field import ONE_POOL_GAMES
        self.assertIn('oakmont_swat', ONE_POOL_GAMES)

    def test_a_round_of_swat_groups_may_hold_five(self):
        from services.round_setup import max_group_size
        course = make_course()
        r = make_round(course=course, tournament=make_tournament(name='x'),
                       active_games=['oakmont_swat'])
        self.assertEqual(max_group_size(r), 5)

    def test_the_preview_names_teams_and_flags_a_short_field(self):
        from core.models import Player
        from scoring.tests._helpers import make_player
        ids = [make_player(f'P{i} Name{i}', handicap_index=i).pk
               for i in range(1, 11)]
        out = swat.preview_teams(ids)
        self.assertIn('at least 12', out['problem'])
