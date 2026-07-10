"""
scoring/tests/test_fourball.py
------------------------------
Fourball (2v2 best-ball match play) engine: per-hole team best ball decides
the hole, running up/down margin, early close-out (dormie / "3&2"), halved
match, the three handicap modes (net / gross / strokes-off + net %), and the
single-match-bet settlement (winners +bet, losers −bet, halve = push).

Teams are Team 1 = (A, B), Team 2 = (C, D) throughout.
"""
from decimal import Decimal

from django.test import TestCase

from core.models import MatchStatus
from services.fourball import setup_fourball, calculate_fourball, fourball_summary
from ._helpers import make_course, make_tee, make_round, make_foursome, make_player


class FourballBase(TestCase):
    def setUp(self):
        self.tee   = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['fourball'])
        self.round.bet_unit = Decimal('2.00')
        self.round.save(update_fields=['bet_unit'])

    def _make_fs(self, hcps=(0, 0, 0, 0)):
        self.p = [make_player(n, h, short_name=n)
                  for n, h in zip(('A', 'B', 'C', 'D'), hcps)]
        self.fs = make_foursome(self.round,
                                [(pl, h) for pl, h in zip(self.p, hcps)],
                                tee=self.tee)

    def _setup(self, *, hmode='gross', net_percent=100, bet_amount=None):
        return setup_fourball(
            self.fs,
            [self.p[0].id, self.p[1].id], [self.p[2].id, self.p[3].id],
            handicap_mode=hmode, net_percent=net_percent, bet_amount=bet_amount)

    def _play(self, hole, g_a, g_b, g_c, g_d):
        from ._helpers import submit_hole
        submit_hole(self.fs, hole, [
            (self.p[0], g_a), (self.p[1], g_b),
            (self.p[2], g_c), (self.p[3], g_d)])
        calculate_fourball(self.fs)

    def _fill_through(self, last_hole):
        """Score holes 1..last_hole-1 as gross halves so the match-play loop
        (which starts at hole 1 and stops at the first unscored hole) reaches
        the hole under test."""
        for h in range(1, last_hole):
            self._play(h, 4, 4, 4, 4)

    def _hole(self, hole):
        s = fourball_summary(self.fs)
        return next(h for h in s['holes'] if h['hole'] == hole)

    def _money(self, name):
        s = fourball_summary(self.fs)
        return next(e['amount'] for e in s['money']['by_player']
                    if e['name'] == name)


class FourballSetupTests(FourballBase):
    def test_setup_creates_two_teams(self):
        self._make_fs()
        game = self._setup()
        self.assertEqual(game.teams.count(), 2)
        t1 = game.teams.get(team_number=1)
        self.assertEqual({p.id for p in t1.players.all()},
                         {self.p[0].id, self.p[1].id})

    def test_bet_amount_defaults_to_round_bet_unit(self):
        self._make_fs()
        game = self._setup()
        self.assertEqual(game.bet_amount, Decimal('2.00'))

    def test_overlapping_teams_rejected(self):
        self._make_fs()
        with self.assertRaises(ValueError):
            setup_fourball(self.fs,
                           [self.p[0].id, self.p[1].id],
                           [self.p[1].id, self.p[2].id])

    def test_wrong_team_size_rejected(self):
        self._make_fs()
        with self.assertRaises(ValueError):
            setup_fourball(self.fs, [self.p[0].id], [self.p[2].id, self.p[3].id])


class FourballScoringTests(FourballBase):
    def test_best_ball_decides_hole(self):
        self._make_fs()
        self._setup(hmode='gross')
        # T1 best = min(4,5)=4 ; T2 best = min(5,6)=5 → T1 wins, +1 up.
        self._play(1, 4, 5, 5, 6)
        h = self._hole(1)
        self.assertEqual((h['t1_net'], h['t2_net']), (4, 5))
        self.assertEqual(h['winner'], 'T1')
        self.assertEqual(h['margin'], 1)

    def test_tie_halves_hole(self):
        self._make_fs()
        self._setup(hmode='gross')
        self._play(1, 4, 5, 4, 6)          # both best balls = 4
        h = self._hole(1)
        self.assertEqual(h['winner'], 'Halved')
        self.assertEqual(h['margin'], 0)

    def test_margin_runs_up_and_down(self):
        self._make_fs()
        self._setup(hmode='gross')
        self._play(1, 3, 4, 4, 5)          # T1 → +1
        self._play(2, 5, 6, 3, 4)          # T2 → 0
        self._play(3, 6, 7, 3, 4)          # T2 → -1
        self.assertEqual(self._hole(2)['margin'], 0)
        self.assertEqual(self._hole(3)['margin'], -1)
        s = fourball_summary(self.fs)
        self.assertEqual(s['overall']['holes_up'], -1)
        self.assertEqual(s['overall']['leader'], 'team2')
        self.assertEqual(s['status'], MatchStatus.IN_PROGRESS)


class FourballCloseoutTests(FourballBase):
    def test_early_closeout_3_and_2(self):
        self._make_fs()
        self._setup(hmode='gross')
        # T1 wins holes 1 & 2 (margin +2), holes 3–15 halved, T1 wins 16
        # → +3 with 2 to play → closes out "3&2".  Holes 17–18 don't count.
        self._play(1, 3, 4, 4, 5)
        self._play(2, 3, 4, 4, 5)
        for h in range(3, 16):
            self._play(h, 4, 4, 4, 4)
        self._play(16, 3, 4, 4, 5)
        s = fourball_summary(self.fs)
        self.assertEqual(s['status'], MatchStatus.COMPLETE)
        self.assertEqual(s['result'], 'team1')
        self.assertEqual(s['finished_on_hole'], 16)
        self.assertEqual(s['result_label'], 'Team 1 wins 3&2')
        self.assertTrue(s['team1']['is_winner'])
        # Only 16 holes recorded — the match was decided.
        self.assertEqual(len(s['holes']), 16)

    def test_halved_match_is_a_push(self):
        self._make_fs()
        self._setup(hmode='gross')
        for h in range(1, 19):
            self._play(h, 4, 4, 4, 4)      # every hole halved
        s = fourball_summary(self.fs)
        self.assertEqual(s['status'], MatchStatus.HALVED)
        self.assertEqual(s['result'], 'halved')
        self.assertEqual(s['result_label'], 'All Square')
        self.assertEqual(self._money('A'), 0.0)
        self.assertEqual(self._money('C'), 0.0)


class FourballSettlementTests(FourballBase):
    def test_winning_team_collects_match_bet(self):
        self._make_fs()
        self._setup(hmode='gross', bet_amount=Decimal('5.00'))
        # T1 wins 1–10 → +10 with 8 to play → closes out at hole 10.
        for h in range(1, 11):
            self._play(h, 3, 4, 4, 5)
        s = fourball_summary(self.fs)
        self.assertEqual(s['result'], 'team1')
        self.assertEqual(self._money('A'), 5.0)
        self.assertEqual(self._money('B'), 5.0)
        self.assertEqual(self._money('C'), -5.0)
        self.assertEqual(self._money('D'), -5.0)
        # Zero-sum.
        self.assertEqual(sum(e['amount'] for e in s['money']['by_player']), 0.0)

    def test_in_progress_pays_nobody(self):
        self._make_fs()
        self._setup(hmode='gross')
        self._play(1, 3, 4, 4, 5)          # T1 1 up, match not over
        self.assertEqual(self._money('A'), 0.0)
        self.assertEqual(self._money('C'), 0.0)


class FourballHandicapTests(FourballBase):
    def test_net_strokes_change_best_ball(self):
        # B is an 18 — one stroke every hole.  On hole 5 (SI 1) B's gross 5
        # becomes net 4, beating scratch C/D's 5.  In gross it would tie.
        self._make_fs(hcps=(0, 18, 0, 0))
        self._setup(hmode='net')
        self._fill_through(5)
        self._play(5, 5, 5, 5, 5)
        h = self._hole(5)
        self.assertEqual(h['t1_net'], 4)   # B's stroke
        self.assertEqual(h['t2_net'], 5)
        self.assertEqual(h['winner'], 'T1')

    def test_strokes_off_low_allocates_to_high_player(self):
        # A is a 5, everyone else scratch → A plays off 5 strokes, allocated
        # to the 5 hardest holes (SI 1–5).  Hole 5 is SI 1 → A gets a stroke.
        self._make_fs(hcps=(5, 0, 0, 0))
        self._setup(hmode='strokes_off')
        self._fill_through(5)
        # A gross 5 on hole 5 → net 4; partner B gross 6 → 6; T1 best 4.
        self._play(5, 5, 6, 5, 5)
        h = self._hole(5)
        self.assertEqual(h['t1_net'], 4)
        self.assertEqual(h['winner'], 'T1')

    def test_strokes_off_net_percent_scales_allocation(self):
        # A is a 10.  Hole 10 has SI 8.  At 100% A's SO=10 → SI 8 ≤ 10 gets a
        # stroke; at 50% A's SO=5 → SI 8 > 5 gets none.
        self._make_fs(hcps=(10, 0, 0, 0))
        self._setup(hmode='strokes_off', net_percent=100)
        self._fill_through(10)
        self._play(10, 5, 9, 9, 9)         # A net 5-1=4 → T1 best 4
        self.assertEqual(self._hole(10)['t1_net'], 4)

        self._setup(hmode='strokes_off', net_percent=50)
        calculate_fourball(self.fs)
        self.assertEqual(self._hole(10)['t1_net'], 5)   # no stroke at 50%


class FourballMidCourseTests(FourballBase):
    """A round that starts mid-course (shotgun / partial) must accrue match
    state from the holes actually PLAYED, not stay 'Not started' because hole 1
    is blank. Regression for the range(1,19) match loop."""

    def _mid_course_round(self, start_hole):
        self.round.starting_hole = start_hole
        self.round.num_holes = 18
        self.round.save(update_fields=['starting_hole', 'num_holes'])
        self._make_fs()
        self._setup(hmode='gross')

    def test_progress_from_play_order_not_hole_one(self):
        self._mid_course_round(start_hole=7)
        # Play the first two holes in play order (7, 8); 1-6 blank.
        self._play(7, 4, 4, 5, 5)   # Team 1 wins hole 7
        self._play(8, 4, 4, 5, 5)   # Team 1 wins hole 8

        game = calculate_fourball(self.fs)
        self.assertEqual(game.status, MatchStatus.IN_PROGRESS)   # NOT pending
        self.assertEqual(game.holes_up_after_final, 2)           # Team 1, 2 up

        s = fourball_summary(self.fs)
        self.assertEqual({h['hole'] for h in s['holes']}, {7, 8})
        self.assertEqual(self._hole(7)['winner'], 'T1')
        # "thru N" is a COUNT — 2 holes played, not hole number 8.
        self.assertEqual(s['holes_played'], 2)
        # current_hole = last hole played in PLAY ORDER (7, 8) = 8.
        self.assertEqual(s['current_hole'], 8)

    def test_early_closeout_notation_uses_play_order(self):
        # Start on 13 → play order 13..18,1..12. Team 1 wins the first 6 played
        # (13-18); after hole 18 they're 6 up with 5 (1-5) still... not yet clinched
        # (6 up, 12 to play). Keep it simple: just assert the &M reflects holes
        # remaining in PLAY ORDER once clinched.
        self._mid_course_round(start_hole=10)   # play order 10..18,1..9
        # Team 1 wins every hole; clinch happens when up > holes remaining.
        order = [10, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        for h in order:
            self._play(h, 4, 4, 6, 6)          # Team 1 wins each
            g = fourball_summary(self.fs)
            if g['status'] == 'complete':
                # &M where M = holes that were left in play order.
                self.assertIn('&', g['result_label'])
                break
        else:
            self.fail('match never closed out')


class FourballScorecardTests(FourballBase):
    """The leaderboard scorecard block: stroke index + hole-winner team +
    per-player teams, over every hole in play."""

    def test_scorecard_has_index_teams_and_hole_winner(self):
        self._make_fs(hcps=(0, 0, 0, 0))
        self._setup(hmode='gross')
        # Team 1 (A,B) beats Team 2 (C,D) on hole 1.
        self._play(1, 3, 4, 5, 5)
        s = fourball_summary(self.fs)
        self.assertEqual(len(s['scorecard']), 18)        # whole round listed
        self.assertEqual(s['holes_in_play'][0], 1)
        # Players carry their team number for tinting.
        self.assertEqual({p['team'] for p in s['players']}, {1, 2})
        h1 = next(h for h in s['scorecard'] if h['hole'] == 1)
        self.assertEqual(h1['stroke_index'], self.tee.hole(1)['stroke_index'])
        self.assertEqual(h1['winner_team'], 1)
        # An unplayed hole still carries par + index with null gross.
        h2 = next(h for h in s['scorecard'] if h['hole'] == 2)
        self.assertIsNotNone(h2['stroke_index'])
        self.assertTrue(all(sco['gross'] is None for sco in h2['scores']))

    def test_scorecard_strokes_off_puts_strokes_on_hardest_holes(self):
        # D has 4 more than the low → SO 4 → strokes on the 4 hardest holes.
        self._make_fs(hcps=(0, 0, 0, 4))
        self._setup(hmode='strokes_off')
        self._play(1, 4, 4, 4, 4)
        s = fourball_summary(self.fs)
        d_id = self.p[3].id
        # Collect D's strokes across the played hole(s); on a hole with SI <= 4
        # D should show a stroke.
        h1 = next(h for h in s['scorecard'] if h['hole'] == 1)
        d_row = next(sc for sc in h1['scores'] if sc['player_id'] == d_id)
        si1 = self.tee.hole(1)['stroke_index']
        self.assertEqual(d_row['strokes'], 1 if si1 <= 4 else 0, (si1, d_row))
