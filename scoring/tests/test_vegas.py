"""
scoring/tests/test_vegas.py
---------------------------
Las Vegas (2v2) engine: team numbers (low=tens/high=ones, capped at 9), lower
number wins by the difference, flip vs multiplier birdie rules, carryover,
net-double-bogey cap, and 1-to-1-per-player settlement with a loss cap.

Players are handicap 0 so net == gross and the digits are controlled directly
by the gross scores entered.
"""
from decimal import Decimal

from django.test import TestCase

from services.vegas import setup_vegas, calculate_vegas, vegas_summary
from ._helpers import make_course, make_tee, make_round, make_foursome, make_player

# DEFAULT_HOLES: hole 1 par 4, hole 2 par 4, hole 3 par 3, hole 4 par 5.


class VegasBase(TestCase):
    def setUp(self):
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['vegas'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.p = [make_player(n, 0, short_name=n) for n in ('A', 'B', 'C', 'D')]
        self.fs = make_foursome(self.round, [(pl, 0) for pl in self.p], tee=self.tee)

    def _setup(self, *, birdie_mode='flip', carryover=False,
               hmode='gross', cap=False, loss_cap=None):
        setup_vegas(
            self.fs,
            [self.p[0].id, self.p[1].id], [self.p[2].id, self.p[3].id],
            handicap_mode=hmode, net_percent=100, net_max_double_bogey=cap,
            birdie_mode=birdie_mode, carryover=carryover, loss_cap=loss_cap)

    def _play(self, hole, g_a, g_b, g_c, g_d):
        from ._helpers import submit_hole
        submit_hole(self.fs, hole, [
            (self.p[0], g_a), (self.p[1], g_b),
            (self.p[2], g_c), (self.p[3], g_d)])
        calculate_vegas(self.fs)

    def _hole(self, hole):
        s = vegas_summary(self.fs)
        return next(h for h in s['holes'] if h['hole'] == hole)


class VegasScoringTests(VegasBase):
    def test_base_lower_number_wins_by_difference(self):
        self._setup(birdie_mode='flip')          # no birdies → flip is inert
        self._play(1, 4, 5, 4, 6)                # team1 45 vs team2 46
        h = self._hole(1)
        self.assertEqual((h['team1_number'], h['team2_number']), (45, 46))
        self.assertEqual(h['winner'], 'team1')
        self.assertEqual(h['points'], 1)

    def test_digit_capped_at_nine(self):
        self._setup(birdie_mode='flip')          # gross mode, no net cap
        self._play(1, 4, 11, 4, 5)               # A&B: 4 & 11 → digit cap → 49
        h = self._hole(1)
        self.assertEqual(h['team1_number'], 49)  # not 4-11
        self.assertEqual(h['team2_number'], 45)
        self.assertEqual(h['winner'], 'team2')   # 45 < 49
        self.assertEqual(h['points'], 4)


class VegasFlipTests(VegasBase):
    def test_birdie_flips_other_team(self):
        self._setup(birdie_mode='flip')
        # Team2 makes a birdie (C gross 3 on par 4) → team1's number flips.
        self._play(1, 4, 5, 3, 6)                # t1 base 45, t2 base 36
        h = self._hole(1)
        self.assertEqual(h['team1_number'], 54)  # 45 flipped (C's birdie)
        self.assertEqual(h['team2_number'], 36)
        self.assertEqual(h['winner'], 'team2')
        self.assertEqual(h['points'], 54 - 36)   # 18

    def test_both_birdie_both_flip_can_swing(self):
        self._setup(birdie_mode='flip')
        # A eagles (gross 2), C birdies (gross 3). Base: t1 24 < t2 35 → t1.
        # Both birdie → both flip: t1 42, t2 53 → still t1, by 11. (Order kept.)
        self._play(1, 2, 4, 3, 5)
        h = self._hole(1)
        self.assertEqual((h['team1_number'], h['team2_number']), (42, 53))
        self.assertEqual(h['winner'], 'team1')
        self.assertEqual(h['points'], 11)


class VegasMultiplierTests(VegasBase):
    def test_winner_birdie_doubles(self):
        self._setup(birdie_mode='multiplier')
        # Team2 wins (C birdie gross 3 → 35) vs team1 44; diff 9 × 2 = 18.
        self._play(1, 4, 4, 3, 5)
        h = self._hole(1)
        self.assertEqual((h['team1_number'], h['team2_number']), (44, 35))
        self.assertEqual(h['winner'], 'team2')
        self.assertEqual(h['multiplier'], 2)
        self.assertEqual(h['points'], 18)

    def test_winner_eagle_triples_best_ball_no_stack(self):
        self._setup(birdie_mode='multiplier')
        # Team2 C eagles (gross 2 on par 4) + D birdies (gross 3) → 23.
        # Winner's BEST ball = eagle → ×3, no stacking. t1 44, diff 21 × 3 = 63.
        self._play(1, 4, 4, 2, 3)
        h = self._hole(1)
        self.assertEqual((h['team1_number'], h['team2_number']), (44, 23))
        self.assertEqual(h['multiplier'], 3)
        self.assertEqual(h['points'], 63)

    def test_loser_birdie_does_not_multiply(self):
        self._setup(birdie_mode='multiplier')
        # Both birdie: t1 A gross3 → 34 ; t2 C eagle gross2 → 23. Winner t2 by 11,
        # uses t2's best (eagle ×3) = 33. t1's birdie is ignored.
        self._play(1, 3, 4, 2, 3)
        h = self._hole(1)
        self.assertEqual((h['team1_number'], h['team2_number']), (34, 23))
        self.assertEqual(h['winner'], 'team2')
        self.assertEqual(h['multiplier'], 3)
        self.assertEqual(h['points'], 33)


class VegasCarryoverTests(VegasBase):
    def test_tie_carries_and_multiplies_next_win(self):
        self._setup(birdie_mode='flip', carryover=True)
        self._play(1, 4, 5, 4, 5)                # tie 45-45 → carry
        self.assertEqual(self._hole(1)['winner'], 'halved')
        self.assertEqual(self._hole(1)['carry'], 1)
        self._play(2, 4, 5, 4, 6)                # t1 wins by 1 × (1+1) = 2
        h2 = self._hole(2)
        self.assertEqual(h2['winner'], 'team1')
        self.assertEqual(h2['carry'], 1)
        self.assertEqual(h2['points'], 2)

    def test_no_carryover_ties_are_zero(self):
        self._setup(birdie_mode='flip', carryover=False)
        self._play(1, 4, 5, 4, 5)
        self._play(2, 4, 5, 4, 6)
        self.assertEqual(self._hole(2)['points'], 1)   # no carry multiplier


class VegasCapTests(VegasBase):
    def test_net_double_bogey_caps_the_digit(self):
        self._setup(birdie_mode='flip', hmode='net', cap=True)
        # D gross 9 on par 4 → net capped at par+2 = 6, so team2 = 46 (not 49).
        self._play(1, 4, 5, 4, 9)
        h = self._hole(1)
        self.assertEqual(h['team2_number'], 46)
        self.assertEqual(h['winner'], 'team1')
        self.assertEqual(h['points'], 1)


class VegasStrokesOffTests(TestCase):
    def test_low_plays_to_zero_others_get_strokes(self):
        from ._helpers import submit_hole
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['vegas'])
        a = make_player('A', 0, short_name='A')
        b = make_player('B', 0, short_name='B')
        c = make_player('C', 0, short_name='C')
        d = make_player('D', 18, short_name='D')   # 18 hcp → 1 stroke every hole
        fs = make_foursome(rnd, [(a, 0), (b, 0), (c, 0), (d, 18)], tee=tee)
        setup_vegas(fs, [a.id, b.id], [c.id, d.id],
                    handicap_mode='strokes_off', net_max_double_bogey=False)
        # Hole 1 par 4. Team2 D gets a stroke (SO 18): gross 5 → net 4.
        submit_hole(fs, 1, [(a, 4), (b, 5), (c, 4), (d, 5)])
        calculate_vegas(fs)
        h = next(x for x in vegas_summary(fs)['holes'] if x['hole'] == 1)
        # team1 = 45 ; team2 net = 4 & (5−1=4) → 44 → team2 wins by 1.
        self.assertEqual((h['team1_number'], h['team2_number']), (45, 44))
        self.assertEqual(h['winner'], 'team2')
        self.assertEqual(h['points'], 1)


class VegasSettlementTests(VegasBase):
    def test_per_player_money_is_point_differential(self):
        self._setup(birdie_mode='flip')
        self._play(1, 4, 5, 4, 6)                # t1 +1
        self._play(2, 4, 4, 4, 6)                # t1 +2  → lead 3
        s = vegas_summary(self.fs)
        t1 = next(t for t in s['teams'] if t['team_number'] == 1)
        t2 = next(t for t in s['teams'] if t['team_number'] == 2)
        self.assertEqual(t1['points'], 3)
        self.assertEqual(t1['money'], 3.0)       # +diff × $1 per player
        self.assertEqual(t2['money'], -3.0)

    def test_loss_cap_clips_each_loser(self):
        self._setup(birdie_mode='flip', loss_cap=Decimal('2.00'))
        self._play(1, 4, 4, 4, 9)                # t1 by 5 (44 vs 49)
        s = vegas_summary(self.fs)
        t1 = next(t for t in s['teams'] if t['team_number'] == 1)
        t2 = next(t for t in s['teams'] if t['team_number'] == 2)
        self.assertEqual(t1['points'], 5)
        self.assertEqual(t2['money'], -2.0)      # clipped at the cap
        self.assertEqual(t1['money'], 2.0)       # winners reduced to stay zero-sum
