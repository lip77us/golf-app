"""
scoring/tests/test_triple_cup.py
--------------------------------
Regression tests for services/triple_cup.py — the One-Round Ryder Cup
per-foursome game.  Pins:
  * 2v2 produces 4 matches (1 fourball + 1 foursomes + 2 singles)
  * 2v1 produces 4 matches and uses a phantom in fourball
  * 1v1 produces 3 singles matches
  * Per-match scoring totals add up to 4 cup points (or 3 for 1v1)
  * Halved matches split (0.5 each)
"""
from django.test import TestCase

from services.triple_cup import (
    setup_triple_cup, calculate_triple_cup, triple_cup_summary,
    _alt_shot_team_combined, _build_match_plan, segment_percent,
)

from ._helpers import (
    make_foursome, make_round, make_tee, make_player, submit_hole,
)


def _score_hole(fs, pid, hole, par, scores):
    """Submit one hole with explicit per-player gross.
    `scores` is a list of (player_name, gross) tuples; only those
    players record a score (others leave the hole blank, mirroring
    what alt-shot would look like)."""
    submit_hole(fs, hole, [(pid[name], gross) for name, gross in scores])


class TripleCup2v2Tests(TestCase):
    """Canonical 4-player Triple Cup."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self):
        return setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['T1A'], self.pid['T1B']],
            team2_ids=[self.pid['T2A'], self.pid['T2B']],
            handicap_mode='gross',
        )

    def test_setup_creates_four_matches(self):
        game = self._setup()
        matches = list(game.matches.order_by('match_number'))
        assert [m.segment for m in matches] == [
            'fourball', 'foursomes', 'singles', 'singles',
        ]
        assert [(m.start_hole, m.end_hole) for m in matches] == [
            (1, 6), (7, 12), (13, 18), (13, 18),
        ]

    def test_summary_exposes_team_ids(self):
        """The summary reports the ordered per-side player ids so the setup
        screen can restore the team picks on re-edit."""
        self._setup()
        summary = triple_cup_summary(self.fs)
        assert summary['team1_ids'] == [self.pid['T1A'], self.pid['T1B']], \
            summary['team1_ids']
        assert summary['team2_ids'] == [self.pid['T2A'], self.pid['T2B']], \
            summary['team2_ids']

    def test_fourball_best_ball(self):
        """T1A scores par every hole, T1B scores bogey; T2A/T2B both par.
        Team1's best ball each hole = par; Team2's best = par.  Should
        halve every hole → match halved."""
        self._setup()
        for h in range(1, 7):
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par), ('T1B', par + 1),
                ('T2A', par), ('T2B', par),
            ])
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        fourball = next(m for m in s['matches'] if m['segment'] == 'fourball')
        assert fourball['winner_label'] == 'Halved', fourball
        assert fourball['result'] == 'halved'

    def test_singles_two_matches_independent(self):
        """13–18: T1A beats T2A (T1 wins singles 1), T1B loses to T2B
        (T2 wins singles 2).  Net cup result for the singles segment
        is one point each side."""
        self._setup()
        # First score holes 1–12 as halves so we can isolate singles.
        for h in range(1, 13):
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par), ('T1B', par),
                ('T2A', par), ('T2B', par),
            ])
        # Holes 13–17: T1A par, T2A bogey; T1B bogey, T2B par.
        # Hole 18: same again.  Each match decided 6&5? No — same delta
        # every hole, so T1A is 6 up after 6 holes (won all 6) and
        # T2B is 6 up.  Both decided early.
        for h in range(13, 19):
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par),       ('T1B', par + 1),
                ('T2A', par + 1),   ('T2B', par),
            ])
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        singles = [m for m in s['matches'] if m['segment'] == 'singles']
        assert len(singles) == 2
        results = sorted(m['result'] for m in singles)
        assert results == ['team1', 'team2'], results
        # Cup points: 1 each for singles.  Fourball + foursomes halved
        # (all pars).
        assert s['overall']['team1_points'] == 2.0   # 0.5+0.5+1+0
        assert s['overall']['team2_points'] == 2.0
        assert s['overall']['points_available'] == 4

    def test_match_clinches_early(self):
        """T1A wins holes 13 by a stroke; halve 14–17; T1A wins 18 too.
        The 1-up margin means the match runs all 6 holes (doesn't
        clinch).  Then test a clinch scenario separately."""
        self._setup()
        # Halve 1–12.
        for h in range(1, 13):
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par), ('T1B', par),
                ('T2A', par), ('T2B', par),
            ])
        # Singles 1: T1A wins 13, 14, 15, 16 → 4 up with 2 to play, clinched.
        # Singles 2: halved every hole.
        for h in range(13, 19):
            par = self.tee.hole(h)['par']
            if h <= 16:
                _score_hole(self.fs, self.pid, h, par, [
                    ('T1A', par - 1), ('T1B', par),
                    ('T2A', par),     ('T2B', par),
                ])
            else:
                _score_hole(self.fs, self.pid, h, par, [
                    ('T1A', par), ('T1B', par),
                    ('T2A', par), ('T2B', par),
                ])
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        singles = [m for m in s['matches'] if m['segment'] == 'singles']
        # Singles 1 (match_number=3) was T1A vs T2A; Singles 2 was T1B vs T2B.
        m1 = next(m for m in singles if m['match_number'] == 3)
        assert m1['result'] == 'team1'
        assert m1['finished_on_hole'] == 16   # clinched at 4&2
        assert m1['display_end_hole'] == 16
        m2 = next(m for m in singles if m['match_number'] == 4)
        assert m2['result'] == 'halved'


class TripleCup2v1CasualRejectedTests(TestCase):
    """Casual 2v1 Triple Cup is rejected at setup — there are no
    cross-foursome teammates to donate phantom scores from.  Cup-mode
    2v1 (donor + Shadow logic) is exercised in test_triple_cup_cup.py."""

    def test_casual_2v1_setup_raises(self):
        tee = make_tee()
        round_ = make_round(tee.course, handicap_mode='gross')
        fs = make_foursome(
            round_, [('T1A', 0), ('T1B', 0), ('SOLO', 0)], tee=tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        with self.assertRaises(ValueError) as cm:
            setup_triple_cup(
                fs,
                team1_ids=[pid['T1A'], pid['T1B']],
                team2_ids=[pid['SOLO']],
                handicap_mode='gross',
            )
        assert '2v1' in str(cm.exception)


class TripleCup1v1Tests(TestCase):
    """2-player Triple Cup: 3 singles segments, 3 cup points total."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.fs = make_foursome(
            self.round,
            [('A', 0), ('B', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def test_setup_creates_nassau_f9_b9_overall(self):
        """2-player TC is a Nassau: F9 (1-9) + B9 (10-18) + Overall (1-18)."""
        game = setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['A']],
            team2_ids=[self.pid['B']],
            handicap_mode='gross',
        )
        matches = list(game.matches.order_by('match_number'))
        assert [m.segment for m in matches] == ['singles', 'singles', 'singles']
        assert [(m.start_hole, m.end_hole) for m in matches] == [
            (1, 9), (10, 18), (1, 18),
        ]
        assert [m.label for m in matches] == ['Front 9', 'Back 9', 'Overall']

    def test_nassau_f9_b9_overall_points(self):
        """Nassau weighting 1+1+2 = 4 pts total.  A wins hole 1, B
        wins hole 13, everything else halved → A wins F9, B wins B9,
        Overall halved.  Final: A = 1 + 0 + 1 = 2; B = 0 + 1 + 1 = 2."""
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['A']],
            team2_ids=[self.pid['B']],
            handicap_mode='gross',
        )
        # F9 (1-9): A wins hole 1, halved rest → A wins F9.
        for h in range(1, 10):
            par = self.tee.hole(h)['par']
            if h == 1:
                _score_hole(self.fs, self.pid, h, par,
                            [('A', par), ('B', par + 1)])
            else:
                _score_hole(self.fs, self.pid, h, par,
                            [('A', par), ('B', par)])
        # B9 (10-18): B wins hole 13, halved rest → B wins B9.
        for h in range(10, 19):
            par = self.tee.hole(h)['par']
            if h == 13:
                _score_hole(self.fs, self.pid, h, par,
                            [('A', par + 1), ('B', par)])
            else:
                _score_hole(self.fs, self.pid, h, par,
                            [('A', par), ('B', par)])
        # Overall (1-18) sees both wins → 1 hole each → halved.
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        assert s['overall']['points_available'] == 4   # 1 + 1 + 2
        # A = F9 (1) + 0 + Overall halve (1) = 2
        # B = 0 + B9 (1) + Overall halve (1) = 2
        assert s['overall']['team1_points'] == 2.0
        assert s['overall']['team2_points'] == 2.0
        assert s['overall']['team1_wins'] == 1   # F9
        assert s['overall']['team2_wins'] == 1   # B9
        assert s['overall']['halves']     == 1   # Overall


class TripleCupWHSSOAllocationTests(TestCase):
    """SO mode allocates strokes via plain WHS course-wide threshold:
    any hole whose SI ≤ player's SO gets a stroke, regardless of
    segment.  No Sixes-style per-segment spreading.

    Regression: an SO=9 player in fourball picks up strokes on every
    hole in 1–6 whose SI ≤ 9 (hole 4 at SI 9 included), not just
    the segment's "top N hardest"."""

    def test_so_9_player_strokes_match_whs_threshold_in_fourball(self):
        tee = make_tee()  # DEFAULT_HOLES: holes 1-6 SIs = 7,3,15,9,1,13
        round_ = make_round(tee.course, handicap_mode='strokes_off')
        fs = make_foursome(
            round_,
            [('Low', 0), ('Hi9A', 9), ('Hi9B', 9), ('Hi5', 5)],
            tee=tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_triple_cup(
            fs,
            team1_ids=[pid['Low'], pid['Hi9A']],
            team2_ids=[pid['Hi9B'], pid['Hi5']],
            handicap_mode='strokes_off',
        )
        s = triple_cup_summary(fs)
        fourball = next(m for m in s['matches'] if m['segment'] == 'fourball')

        # SO=9 → strokes on every hole in 1–6 with SI ≤ 9: holes 1
        # (SI 7), 2 (SI 3), 4 (SI 9), 5 (SI 1) — total 4.  Hole 3
        # (SI 15) and hole 6 (SI 13) do NOT get strokes.
        hi9a = next(p for p in fourball['players']
                    if p['player_id'] == pid['Hi9A'])
        sbh9 = hi9a['strokes_by_hole']
        assert sbh9.get(1) == 1, sbh9
        assert sbh9.get(2) == 1, sbh9
        assert sbh9.get(3) == 0, sbh9
        assert sbh9.get(4) == 1, sbh9
        assert sbh9.get(5) == 1, sbh9
        assert sbh9.get(6) == 0, sbh9
        assert sum(sbh9.values()) == 4, sbh9

        # SO=5 → strokes on SI ≤ 5 in 1–6: hole 2 (SI 3), hole 5
        # (SI 1).  Hole 1 (SI 7), hole 4 (SI 9) do NOT.
        hi5 = next(p for p in fourball['players']
                   if p['player_id'] == pid['Hi5'])
        sbh5 = hi5['strokes_by_hole']
        assert sbh5.get(2) == 1, sbh5
        assert sbh5.get(5) == 1, sbh5
        assert sbh5.get(1) == 0, sbh5
        assert sbh5.get(4) == 0, sbh5
        assert sum(sbh5.values()) == 2, sbh5


class TripleCupFoursomesTeamSODisplayTests(TestCase):
    """In foursomes SO mode the per-player `strokes_off` field should
    carry the TEAM's alt-shot SO (same value for both partners), not
    each player's individual differential."""

    def test_foursomes_so_field_reflects_team_alt_shot_differential(self):
        tee = make_tee()
        round_ = make_round(tee.course, handicap_mode='strokes_off')
        # Combined = weighted-average of the UNROUNDED course handicaps
        # (here CH == index since slope 113 / CR == par), rounded ONCE, 0.5 up.
        # T1 = Ryan(0) + Bob(9) → 50/50 = 4.5 → round-half-up → 5
        # T2 = Gary(9) + Glenn(5) → 50/50 = 7.0 → 7
        # Team-vs-team: T1 (low) = 0, T2 (high) = 7 − 5 = 2
        fs = make_foursome(
            round_,
            [('Ryan', 0), ('Bob', 9), ('Gary', 9), ('Glenn', 5)],
            tee=tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_triple_cup(
            fs,
            team1_ids=[pid['Ryan'], pid['Bob']],
            team2_ids=[pid['Gary'], pid['Glenn']],
            handicap_mode='strokes_off',
            alt_shot_low_pct=50,
            alt_shot_high_pct=50,
        )
        s = triple_cup_summary(fs)
        foursomes = next(m for m in s['matches'] if m['segment'] == 'foursomes')
        so_by_pid = {p['player_id']: p['strokes_off']
                     for p in foursomes['players']}
        # Both Red partners share the team SO.
        assert so_by_pid[pid['Ryan']] == so_by_pid[pid['Bob']], so_by_pid
        # Both Blue partners share the team SO.
        assert so_by_pid[pid['Gary']] == so_by_pid[pid['Glenn']], so_by_pid
        # The lower-combined team plays to scratch.
        red, blue = so_by_pid[pid['Ryan']], so_by_pid[pid['Gary']]
        assert red == 0 and blue > 0, (red, blue)
        # And the differential equals high_combined − low_combined.
        assert blue == 2, (red, blue)

    def test_alt_shot_averages_indexes_not_course_handicaps(self):
        # Real course (slope 130 / CR 71.6 / par 70) → course handicap != index,
        # so averaging the INDEXES then deriving the CH differs from averaging
        # the two already-rounded integer course handicaps.
        tee = make_tee(slope=130, course_rating=71.6, par=70)
        round_ = make_round(tee.course, handicap_mode='strokes_off')
        pa = make_player('A', 21)   # CH 26
        pb = make_player('B', 15)   # CH 19
        ps = make_player('S', 20)   # CH 25
        pf = make_player('F', 5)
        fs = make_foursome(
            round_, [(pa, 26), (pb, 19), (ps, 25), (pf, 8)], tee=tee,
        )
        setup_triple_cup(
            fs, team1_ids=[pa.id, pb.id], team2_ids=[ps.id, pf.id],
            handicap_mode='strokes_off',
            alt_shot_low_pct=50, alt_shot_high_pct=50,
        )
        from games.models import TripleCupGame
        g = TripleCupGame.objects.get(foursome=fs)
        mbp = {m.player_id: m
               for m in fs.memberships.select_related('player', 'tee')}

        # Pair: index avg (21+15)/2 = 18 → 18*130/113 + 1.6 = 22.31 → 22.
        # (Course-hcp average would be (26+19)/2 = 22.5 → 23.)
        self.assertEqual(_alt_shot_team_combined(g, [pa.id, pb.id], mbp)[0], 22)

        # **The weights are the allowance, and nothing else scales them.**
        # This asserted the opposite until 30 Sep: `net_percent` multiplied
        # the alt-shot figure as well, so the four-ball allowance silently
        # moved the alt-shot one and "40% of combined with the four-ball at
        # 90%" could not be expressed — it came out 36%.
        g.net_percent = 90
        g.fourball_percent = 90
        self.assertEqual(
            _alt_shot_team_combined(g, [pa.id, pb.id], mbp)[0], 22,
            'the four-ball allowance must not move the alt-shot figure')

        # 90% of the pair's combined is written as the weights: 22.31 * .9
        # = 20.08 → 20.
        g.alt_shot_low_pct = g.alt_shot_high_pct = 45
        self.assertEqual(_alt_shot_team_combined(g, [pa.id, pb.id], mbp)[0], 20)

        # Solo at 50 + 50 is his own figure once: 24.61 → 25.
        g.alt_shot_low_pct = g.alt_shot_high_pct = 50
        self.assertEqual(_alt_shot_team_combined(g, [ps.id], mbp)[0], 25)


class AltShotAllowanceTests(TestCase):
    """The allowance a side plays the alt-shot segment off.

    `low + high` is a share of the pair's COMBINED handicap, so 50 + 50 is
    the USGA half-of-combined and 40 + 40 is 40% of combined — which is the
    same number as 80% of half, and is what the match's stroke difference is
    then taken from.
    """

    def _game(self, low, high):
        tee = make_tee(slope=113, course_rating=72.0, par=72)   # CH == index
        round_ = make_round(tee.course)
        a = make_player('A', 20)
        b = make_player('B', 10)
        s = make_player('S', 14)
        f = make_player('F', 6)
        fs = make_foursome(round_, [(a, 20), (b, 10), (s, 14), (f, 6)], tee=tee)
        setup_triple_cup(fs, team1_ids=[a.id, b.id], team2_ids=[s.id, f.id],
                         alt_shot_low_pct=low, alt_shot_high_pct=high)
        from games.models import TripleCupGame
        g = TripleCupGame.objects.get(foursome=fs)
        mbp = {m.player_id: m
               for m in fs.memberships.select_related('player', 'tee')}
        return g, mbp, (a, b, s, f)

    def test_forty_and_forty_is_forty_percent_of_combined(self):
        g, mbp, (a, b, s, f) = self._game(40, 40)
        # 20 + 10 = 30 combined; 40% of 30 = 12.
        self.assertEqual(_alt_shot_team_combined(g, [a.id, b.id], mbp)[0], 12)
        # 14 + 6 = 20 combined; 40% of 20 = 8.
        self.assertEqual(_alt_shot_team_combined(g, [s.id, f.id], mbp)[0], 8)

    def test_it_is_the_same_as_eighty_percent_of_half(self):
        """The two ways of saying it have to produce one number."""
        g, mbp, (a, b, _s, _f) = self._game(40, 40)
        combined = 20 + 10
        self.assertEqual(_alt_shot_team_combined(g, [a.id, b.id], mbp)[0],
                         round(0.40 * combined))
        self.assertEqual(round(0.40 * combined), round(0.80 * combined / 2))

    def test_the_match_plays_off_the_DIFFERENCE(self):
        g, mbp, (a, b, s, f) = self._game(40, 40)
        t1 = _alt_shot_team_combined(g, [a.id, b.id], mbp)[0]
        t2 = _alt_shot_team_combined(g, [s.id, f.id], mbp)[0]
        # 40% of (30 − 20) = 4 — the strokes the higher side receives.
        self.assertEqual(t1 - t2, 4)

    def test_a_SOLO_side_plays_off_his_own_handicap_TWICE(self):
        """Alt-shot is a two-ball format; a side of one still plays a
        combined figure, so the lone player counts twice.

        Reading his handicap ONCE made his side cheaper than a pair's for any
        weighting that did not happen to sum to 100 — at 40 + 40 he would
        have carried 40% of one handicap against a pair's 40% of two.
        """
        g, mbp, (a, _b, _s, _f) = self._game(40, 40)
        # A is off 20. Twice is 40 combined; 40% of that is 16.
        self.assertEqual(_alt_shot_team_combined(g, [a.id], mbp)[0], 16)

    def test_fifty_fifty_leaves_a_solo_on_his_own_figure(self):
        """The historic default has to be unchanged: 50 + 50 of a doubled
        handicap is the handicap."""
        g, mbp, (a, _b, _s, _f) = self._game(50, 50)
        self.assertEqual(_alt_shot_team_combined(g, [a.id], mbp)[0], 20)


class TripleCupStrokesOffTests(TestCase):
    """Strokes-Off mode must spread each player's SO across the 3
    segments (Sixes-style) — previously fell back to net@100 because
    the service didn't pass segments to build_score_index."""

    def test_strokes_off_helps_high_handicapper_win_a_segment(self):
        tee = make_tee()
        round_ = make_round(tee.course, handicap_mode='strokes_off')
        # T2B has 9 SO strokes vs the field's low (=0).  Even gross
        # ties become net wins for team2 on any hole T2B receives a
        # stroke.
        fs = make_foursome(
            round_,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 9)],
            tee=tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_triple_cup(
            fs,
            team1_ids=[pid['T1A'], pid['T1B']],
            team2_ids=[pid['T2A'], pid['T2B']],
            handicap_mode='strokes_off',
        )
        for h in range(1, 19):
            par = tee.hole(h)['par']
            _score_hole(fs, pid, h, par, [
                ('T1A', par), ('T1B', par),
                ('T2A', par), ('T2B', par),
            ])
        calculate_triple_cup(fs)
        summary = triple_cup_summary(fs)
        winners = [m['winner_label'] for m in summary['matches']]
        # With proper SO spreading, T2B's strokes touch every segment.
        # If the bug regressed (full net = 0 for everyone), no segment
        # would have a winner.
        assert any(w == 'Team 2' for w in winners), winners


class TripleCupSinglesPairSOTests(TestCase):
    """In SO mode the singles match that doesn't include the foursome's
    low resets SO to per-pair (lower of the pair plays to scratch).
    Strokes-off uses plain WHS allocation against the relevant
    baseline — so a match WITHOUT the foursome low can produce a
    different result than one WITH it, even with identical pars."""

    def test_singles_pair_so_baseline_differs_from_foursome_wide(self):
        tee = make_tee()
        round_ = make_round(tee.course, handicap_mode='strokes_off')
        # T1A is the foursome low (hcp 0), the rest are higher.
        # Handicap-sort within team: Red = [T1A(0), T1B(8)],
        # Blue   = [T2B(2), T2A(4)].  Singles pair low-of-Red vs
        # low-of-Blue: Singles 1 = T1A vs T2B (contains foursome
        # low); Singles 2 = T1B vs T2A (does NOT).
        fs = make_foursome(
            round_,
            [('T1A', 0), ('T1B', 8), ('T2A', 4), ('T2B', 2)],
            tee=tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_triple_cup(
            fs,
            team1_ids=[pid['T1A'], pid['T1B']],
            team2_ids=[pid['T2A'], pid['T2B']],
            handicap_mode='strokes_off',
        )
        s = triple_cup_summary(fs)
        singles = [m for m in s['matches'] if m['segment'] == 'singles']

        m_with_low = next(m for m in singles
                          if any(p['player_id'] == pid['T1A']
                                 for p in m['players']))
        m_without_low = next(m for m in singles
                             if not any(p['player_id'] == pid['T1A']
                                        for p in m['players']))

        # m_with_low baseline = foursome low (0) → T2B's SO = 2.
        t2b = next(p for p in m_with_low['players']
                   if p['player_id'] == pid['T2B'])
        assert t2b['strokes_off'] == 2, t2b

        # m_without_low baseline = per-pair low = min(8, 4) = 4 → T1B's SO = 4.
        # (Foursome-wide would have given T1B 8.)
        t1b = next(p for p in m_without_low['players']
                   if p['player_id'] == pid['T1B'])
        assert t1b['strokes_off'] == 4, t1b
        t2a = next(p for p in m_without_low['players']
                   if p['player_id'] == pid['T2A'])
        assert t2a['strokes_off'] == 0, t2a


class TripleCupFoursomesAltShotTests(TestCase):
    """Pin the alt-shot foursomes scoring path."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course)
        # T1: 0 + 10 handicaps → combined (50/50) = 5 strokes.
        # T2: 4 + 6 handicaps → combined (50/50) = 5 strokes.
        # Both teams get the same 5 strokes spread by stroke index,
        # so an identical hole gross from each team should halve.
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 10), ('T2A', 4), ('T2B', 6)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def test_summary_exposes_team_strokes_for_foursomes(self):
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['T1A'], self.pid['T1B']],
            team2_ids=[self.pid['T2A'], self.pid['T2B']],
            handicap_mode='net',
            alt_shot_low_pct=50,
            alt_shot_high_pct=50,
        )
        for h in range(7, 13):
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par), ('T2A', par),
            ])
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        foursomes = next(m for m in s['matches'] if m['segment'] == 'foursomes')
        # At least one hole in the segment should carry a non-zero
        # alt-shot team stroke (combined 50/50 of 0+10 = 5, holes with
        # SI ≤ 5 in 7-12 get a stroke).
        t1_total = sum((h.get('t1_team_strokes') or 0)
                       for h in foursomes['holes'])
        assert t1_total > 0, foursomes['holes']
        # And the field must appear on every foursomes hole entry.
        for h in foursomes['holes']:
            assert 't1_team_strokes' in h
            assert 't2_team_strokes' in h
            assert 't1_team_gross'  in h
            assert 't2_team_gross'  in h

    def test_alt_shot_combined_handicap_halves_when_team_gross_matches(self):
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['T1A'], self.pid['T1B']],
            team2_ids=[self.pid['T2A'], self.pid['T2B']],
            handicap_mode='net',
            alt_shot_low_pct=50,
            alt_shot_high_pct=50,
        )
        # Holes 7–12: each team's single recorded gross is par.  With
        # equal combined handicaps both team nets match, every hole
        # halves.
        for h in range(7, 13):
            par = self.tee.hole(h)['par']
            # In alt-shot only one player records per hole; we put it on
            # whichever player makes sense.  Alternate so both
            # team-members contribute.
            t1_recorder = 'T1A' if h % 2 == 1 else 'T1B'
            t2_recorder = 'T2A' if h % 2 == 1 else 'T2B'
            _score_hole(self.fs, self.pid, h, par, [
                (t1_recorder, par), (t2_recorder, par),
            ])
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        foursomes = next(m for m in s['matches'] if m['segment'] == 'foursomes')
        assert foursomes['result'] == 'halved', foursomes


class TripleCupSegmentOrderPoCTests(TestCase):
    """PoC for configurable Fourball/Foursomes order (foursomes_first flag).

    _build_match_plan is a pure function, so we can verify the slot swap
    without a DB.  Scoring on the swapped holes is covered by the
    hole-agnostic test in scoring/tests/test_phantom.py.
    """

    def test_foursomes_first_swaps_segment_holes(self):
        # 2v1: pair = [1, 2], solo = [99], phantom = 500.
        plan = _build_match_plan([1, 2], [99], phantom_pid=500,
                                 foursomes_first=True)
        seg = {m['segment']: m for m in plan if m['segment'] != 'singles'}
        fo, fb = seg['foursomes'], seg['fourball']
        # Foursomes now FIRST (holes 1-6, match 1).
        self.assertEqual(
            (fo['start_hole'], fo['end_hole'], fo['match_number']), (1, 6, 1))
        # Fourball SECOND (holes 7-12, match 2) — still carries the phantom.
        self.assertEqual(
            (fb['start_hole'], fb['end_hole'], fb['match_number']), (7, 12, 2))
        self.assertIn(500, fb['team1_ids'] + fb['team2_ids'])
        # Singles unchanged at 13-18.
        singles = [m for m in plan if m['segment'] == 'singles']
        self.assertTrue(all(m['start_hole'] == 13 and m['end_hole'] == 18
                            for m in singles))

    def test_default_is_fourball_first_unchanged(self):
        plan = _build_match_plan([1, 2], [99], phantom_pid=500)
        fb = next(m for m in plan if m['segment'] == 'fourball')
        fo = next(m for m in plan if m['segment'] == 'foursomes')
        self.assertEqual(
            (fb['start_hole'], fb['end_hole'], fb['match_number']), (1, 6, 1))
        self.assertEqual(
            (fo['start_hole'], fo['end_hole'], fo['match_number']), (7, 12, 2))

    def test_setup_2v2_foursomes_first_persists_and_swaps_holes(self):
        # Full path: model field + setup_triple_cup + summary (2v2, no cup).
        tee = make_tee()
        round_ = make_round(tee.course, handicap_mode='gross')
        fs = make_foursome(
            round_, [('A', 0), ('B', 0), ('C', 0), ('D', 0)], tee=tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        game = setup_triple_cup(
            fs, team1_ids=[pid['A'], pid['B']], team2_ids=[pid['C'], pid['D']],
            handicap_mode='gross', foursomes_first=True,
        )
        self.assertTrue(game.foursomes_first)
        seg = {m.segment: m for m in game.matches.all()
               if m.segment != 'singles'}
        self.assertEqual(
            (seg['foursomes'].start_hole, seg['foursomes'].end_hole), (1, 6))
        self.assertEqual(
            (seg['fourball'].start_hole, seg['fourball'].end_hole), (7, 12))
        self.assertTrue(triple_cup_summary(fs)['foursomes_first'])


class TripleCupShotgunTests(TestCase):
    """Segments follow the group's play order (thirds by POSITION), so a shotgun
    start puts the right holes in fourball / foursomes / singles."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.round.num_holes = 18
        self.round.starting_hole = 8          # play order 8..18,1..7
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def test_shotgun_segments_are_play_order_thirds(self):
        game = setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['T1A'], self.pid['T1B']],
            team2_ids=[self.pid['T2A'], self.pid['T2B']],
            handicap_mode='gross',
        )
        by_seg = {}
        for m in game.matches.all():
            by_seg.setdefault(m.segment, []).append((m.start_hole, m.end_hole))
        # Thirds by play position: 8-13 / 14-1 / 2-7 (not 1-6 / 7-12 / 13-18).
        self.assertEqual(by_seg['fourball'], [(8, 13)], by_seg)
        self.assertEqual(by_seg['foursomes'], [(14, 1)], by_seg)
        self.assertEqual(sorted(by_seg['singles']), [(2, 7), (2, 7)], by_seg)

    def test_shotgun_fourball_scores_over_its_played_holes(self):
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['T1A'], self.pid['T1B']],
            team2_ids=[self.pid['T2A'], self.pid['T2B']],
            handicap_mode='gross',
        )
        # Fourball is holes 8-13. T1 wins 8,9,10,11 outright → 4 up with 2 to
        # play → clinched (a 4&2 close-out) within the shotgun third.
        for h in [8, 9, 10, 11]:
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par), ('T1B', par),
                ('T2A', par + 1), ('T2B', par + 1),
            ])
        for h in [12, 13]:
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par), ('T1B', par), ('T2A', par), ('T2B', par),
            ])
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        fourball = next(m for m in s['matches'] if m['segment'] == 'fourball')
        self.assertEqual(fourball['result'], 'team1', fourball)

    def test_a_wrapping_segment_closes_out_in_play_order(self):
        """The foursomes third here is holes 14..1 — it crosses the turn, so
        its last hole has the SMALLEST number. Every "did it finish early"
        test that compared hole numbers ("17 < 1") answered no, which dropped
        the `&M` from the label and left the card claiming the match ran to
        its scheduled end."""
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['T1A'], self.pid['T1B']],
            team2_ids=[self.pid['T2A'], self.pid['T2B']],
            handicap_mode='gross',
        )
        # Foursomes = 14,15,16,17,18,1 in play order. Team 1 wins the first
        # four → 4 up with 2 left → clinched ON HOLE 17, a "4&2".
        for h in [14, 15, 16, 17]:
            par = self.tee.hole(h)['par']
            _score_hole(self.fs, self.pid, h, par, [
                ('T1A', par), ('T2A', par + 1),
            ])
        calculate_triple_cup(self.fs)
        s = triple_cup_summary(self.fs)
        foursomes = next(m for m in s['matches'] if m['segment'] == 'foursomes')

        self.assertEqual(foursomes['result'], 'team1', foursomes)
        self.assertEqual(foursomes['finished_on_hole'], 17)
        # Two holes of the SEGMENT were left: 18 and 1.
        self.assertEqual(foursomes['holes_to_play'], 2)
        # The card's last column is the hole it actually ended on.
        self.assertEqual(foursomes['display_end_hole'], 17)
        # Both arithmetics the clients used to do, for the record: one goes
        # negative, the other counts the whole round.
        self.assertNotEqual(foursomes['end_hole'] - 17,
                            foursomes['holes_to_play'])
        self.assertNotEqual(18 - 17, foursomes['holes_to_play'])


class TripleCupDetailProspectiveStrokesTests(TestCase):
    """The leaderboard detail grid (`match['holes']`) lists EVERY hole in a
    match's 6-hole range up front — with par, stroke index, and each player's
    prospective handicap strokes — so a strokes-off player can see where their
    strokes fall over the whole round before any hole is played."""

    def test_detail_holes_are_prospective(self):
        tee = make_tee()  # DEFAULT_HOLES holes 1-6 SIs = 7,3,15,9,1,13
        round_ = make_round(tee.course, handicap_mode='strokes_off')
        fs = make_foursome(
            round_,
            [('Low', 0), ('Hi9A', 9), ('Hi9B', 9), ('Hi5', 5)],
            tee=tee,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_triple_cup(
            fs,
            team1_ids=[pid['Low'], pid['Hi9A']],
            team2_ids=[pid['Hi9B'], pid['Hi5']],
            handicap_mode='strokes_off',
        )
        # No scores submitted — everything is prospective.
        s = triple_cup_summary(fs)
        fourball = next(m for m in s['matches'] if m['segment'] == 'fourball')
        holes = fourball['holes']

        # All 6 holes present, with par + stroke index for the Par/SI rows.
        self.assertEqual([h['hole'] for h in holes], [1, 2, 3, 4, 5, 6])
        self.assertTrue(all(h['par'] is not None for h in holes))
        self.assertTrue(all(h['stroke_index'] is not None for h in holes))
        # Nothing played yet → null winner and null gross everywhere.
        self.assertTrue(all(h['winner'] is None for h in holes))

        def cell(hole, who):
            h = next(x for x in holes if x['hole'] == hole)
            return next(sc for sc in h['scores'] if sc['player_id'] == pid[who])

        self.assertIsNone(cell(1, 'Hi9A')['gross'])
        # Hi9A SO=9 → a stroke on holes 1,2,4,5 (SI 7,3,9,1); none on 3,6.
        self.assertEqual(cell(1, 'Hi9A')['strokes'], 1)
        self.assertEqual(cell(4, 'Hi9A')['strokes'], 1)
        self.assertEqual(cell(3, 'Hi9A')['strokes'], 0)
        self.assertEqual(cell(6, 'Hi9A')['strokes'], 0)
        # Low is the scratch baseline → no strokes anywhere.
        self.assertEqual(cell(1, 'Low')['strokes'], 0)


class SegmentAllowanceTests(TestCase):
    """One allowance per segment.

    A Triple Cup plays three different formats in one round, and WHS gives
    them different allowances — 90% four-ball, 100% singles. Until these were
    separate fields a single `net_percent` drove both, so asking for 90%
    four-ball and full-index singles set them to the same number.
    """

    def _game(self, **kw):
        tee = make_tee(slope=113, course_rating=72.0, par=72)   # CH == index
        round_ = make_round(tee.course)
        a = make_player('A', 20)
        b = make_player('B', 10)
        s = make_player('S', 14)
        f = make_player('F', 6)
        fs = make_foursome(round_, [(a, 20), (b, 10), (s, 14), (f, 6)], tee=tee)
        setup_triple_cup(fs, team1_ids=[a.id, b.id], team2_ids=[s.id, f.id],
                         **kw)
        from games.models import TripleCupGame
        return TripleCupGame.objects.get(foursome=fs), fs

    def test_the_two_segments_are_set_independently(self):
        g, _fs = self._game(fourball_percent=90, singles_percent=100)
        self.assertEqual(segment_percent(g, 'fourball'), 90)
        self.assertEqual(segment_percent(g, 'singles'), 100)

    def test_four_ball_at_ninety_does_not_move_the_singles(self):
        """The defect these fields exist to fix."""
        g, _fs = self._game(fourball_percent=90, singles_percent=100)
        self.assertNotEqual(segment_percent(g, 'fourball'),
                            segment_percent(g, 'singles'))

    def test_a_caller_that_knows_only_net_percent_is_unchanged(self):
        """What the cup round does: it passes the round's one allowance and
        knows nothing about segments, so both must land on it."""
        g, _fs = self._game(net_percent=90)
        self.assertEqual(segment_percent(g, 'fourball'), 90)
        self.assertEqual(segment_percent(g, 'singles'), 90)

    def test_the_defaults_are_the_WHS_numbers(self):
        g, _fs = self._game()
        self.assertEqual(segment_percent(g, 'fourball'), 100)
        self.assertEqual(segment_percent(g, 'singles'), 100)
        # …and an explicit pair survives the round-trip.
        g2, _ = self._game(fourball_percent=90, singles_percent=100)
        self.assertEqual((g2.fourball_percent, g2.singles_percent), (90, 100))

    def test_alt_shot_is_NOT_one_of_them(self):
        """Its allowance is the low/high weighting of two handicaps, not a
        percentage of one — `segment_percent` must never be asked for it."""
        g, _fs = self._game(fourball_percent=90, singles_percent=100)
        # 'foursomes' falls back rather than raising, but the weights are what
        # the alt-shot engine reads; this pins that they are independent.
        self.assertEqual(g.alt_shot_low_pct, 50)
        self.assertEqual(g.alt_shot_high_pct, 50)

    def test_the_singles_strokes_follow_the_singles_allowance(self):
        """End to end: the strokes a singles match allocates move when the
        singles allowance moves, and do NOT move when the four-ball's does.
        """
        from services.triple_cup import _expected_strokes_per_match
        strokes = {}
        for label, kw in (('full',  dict(fourball_percent=100, singles_percent=100)),
                          ('half',  dict(fourball_percent=100, singles_percent=50)),
                          ('fb50',  dict(fourball_percent=50,  singles_percent=100))):
            g, fs = self._game(**kw)
            mbp = {m.player_id: m
                   for m in fs.memberships.select_related('player', 'tee')}
            match = next(m for m in g.matches.all() if m.segment == 'singles')
            t1 = list(match.teams.get(team_number=1).players
                      .values_list('id', flat=True))
            t2 = list(match.teams.get(team_number=2).players
                      .values_list('id', flat=True))
            got = _expected_strokes_per_match(match, list(g.matches.all()),
                                              t1, t2, g, mbp, None)
            strokes[label] = sum(sum(h.values()) for h in got.values())

        self.assertGreater(strokes['full'], strokes['half'],
                           'the singles allowance must change singles strokes')
        self.assertEqual(strokes['full'], strokes['fb50'],
                         'the four-ball allowance must not touch the singles')


class CupAllowanceTests(TestCase):
    """**The cup's allowances reach the game.**

    The cup path called `setup_triple_cup` with the round's single
    `net_percent` and nothing else — no segment split and no alt-shot weights
    — so a cup Triple Cup was stuck on one allowance and the USGA 50/50 while
    the casual setup screen had both.

    They live on the **TeamTournament**, not the round config: a multi-day cup
    plays the same allowances every day, so one answer for the event. Asking
    per round would let day 2 disagree with day 1 with nothing saying so.
    """

    def test_an_unset_cup_asks_for_nothing(self):
        """Null means "as before": no kwargs, so the engine's own fallback
        applies and an existing cup does not move."""
        from tournament.models import TeamTournament
        self.assertEqual(TeamTournament().triple_cup_allowances(), {})

    def test_what_the_TD_sets_is_what_the_engine_is_asked_for(self):
        from tournament.models import TeamTournament
        tt = TeamTournament(
            tc_fourball_percent=90, tc_singles_percent=100,
            tc_alt_shot_low_pct=40, tc_alt_shot_high_pct=40)
        self.assertEqual(tt.triple_cup_allowances(), {
            'fourball_percent': 90,
            'singles_percent': 100,
            'alt_shot_low_pct': 40,
            'alt_shot_high_pct': 40,
        })

    def test_a_partly_set_cup_passes_only_what_was_set(self):
        """A key that is absent must stay absent, not arrive as None — the
        engine reads `is None` to mean "fall back to net_percent"."""
        from tournament.models import TeamTournament
        self.assertEqual(
            TeamTournament(tc_singles_percent=100).triple_cup_allowances(),
            {'singles_percent': 100})

    def test_the_round_config_no_longer_owns_them(self):
        """One fact, one owner. They were briefly on the round too, which
        would have let the second round of a cup carry a different four-ball
        allowance from the first."""
        from tournament.models import RyderCupRoundConfig
        for f in ('tc_fourball_percent', 'tc_singles_percent',
                  'tc_alt_shot_low_pct', 'tc_alt_shot_high_pct'):
            self.assertFalse(
                hasattr(RyderCupRoundConfig(), f),
                f'{f} should live on the cup, not the round')

    def test_those_kwargs_land_on_the_game(self):
        """End to end: the dict the cup produces is accepted by setup and
        stored, so the two halves cannot drift."""
        from tournament.models import TeamTournament
        from games.models import TripleCupGame
        tee = make_tee(slope=113, course_rating=72.0, par=72)
        round_ = make_round(tee.course)
        a = make_player('A', 20)
        b = make_player('B', 10)
        c = make_player('C', 14)
        d = make_player('D', 6)
        fs = make_foursome(round_, [(a, 20), (b, 10), (c, 14), (d, 6)], tee=tee)
        kwargs = TeamTournament(
            tc_fourball_percent=90, tc_singles_percent=100,
            tc_alt_shot_low_pct=40, tc_alt_shot_high_pct=40,
        ).triple_cup_allowances()
        setup_triple_cup(fs, team1_ids=[a.id, b.id], team2_ids=[c.id, d.id],
                         net_percent=75, **kwargs)
        g = TripleCupGame.objects.get(foursome=fs)
        self.assertEqual(segment_percent(g, 'fourball'), 90)
        self.assertEqual(segment_percent(g, 'singles'), 100)
        self.assertEqual((g.alt_shot_low_pct, g.alt_shot_high_pct), (40, 40))
        # The round's own net% is stored but no longer drives a segment.
        self.assertEqual(g.net_percent, 75)

    def test_every_round_of_a_multi_day_cup_gets_the_SAME_ones(self):
        """The reason they are on the event: two rounds, one answer."""
        from tournament.models import TeamTournament
        from games.models import TripleCupGame
        tt = TeamTournament(tc_fourball_percent=90, tc_singles_percent=100,
                            tc_alt_shot_low_pct=40, tc_alt_shot_high_pct=40)
        kwargs = tt.triple_cup_allowances()
        seen = set()
        for day in range(2):
            tee = make_tee(slope=113, course_rating=72.0, par=72)
            round_ = make_round(tee.course)
            ps = [make_player(f'D{day}{i}', h)
                  for i, h in enumerate((20, 10, 14, 6))]
            fs = make_foursome(
                round_, [(p, int(p.handicap_index)) for p in ps], tee=tee)
            setup_triple_cup(fs,
                             team1_ids=[ps[0].id, ps[1].id],
                             team2_ids=[ps[2].id, ps[3].id], **kwargs)
            g = TripleCupGame.objects.get(foursome=fs)
            seen.add((g.fourball_percent, g.singles_percent,
                      g.alt_shot_low_pct, g.alt_shot_high_pct))
        self.assertEqual(seen, {(90, 100, 40, 40)},
                         'every round of one cup must play off the same '
                         'allowances')


class PhantomOnTheCardTests(TestCase):
    """**The phantom is a four-ball row and nothing else.**

    In a 2v1 the phantom is the solo side's four-ball partner, scored from a
    cross-foursome donor — the one ball on the card a reader is genuinely
    waiting for, and until now the only way to see what it got was to walk
    back to the hole it was posted on.

    The score-entry card draws a row per player in each match, so THIS is what
    makes that row populate across the four-ball holes and stay blank on the
    rest — with no hole filtering on the client. A phantom that leaked into
    the foursomes or singles match would draw scores on holes it does not
    play, and nothing on the client would catch it.

    Asserted on `_build_match_plan`, which is pure: a 2v1 needs a cup round
    with a second foursome to donate from, and the plan is where the fact
    actually lives.
    """

    PHANTOM = 500

    def _plan(self, **kw):
        return _build_match_plan([1, 2], [99], phantom_pid=self.PHANTOM, **kw)

    def _segments_with_phantom(self, plan):
        return {e['segment'] for e in plan
                if self.PHANTOM in e['team1_ids'] + e['team2_ids']}

    def test_only_the_four_ball_carries_it(self):
        self.assertEqual(self._segments_with_phantom(self._plan()),
                         {'fourball'})

    def test_it_partners_the_SOLO_side(self):
        plan = self._plan()
        fb = next(e for e in plan if e['segment'] == 'fourball')
        solo_side = (fb['team1_ids'] if 99 in fb['team1_ids']
                     else fb['team2_ids'])
        self.assertIn(self.PHANTOM, solo_side,
                      'the phantom is the solo player\u2019s second ball')
        self.assertEqual(sorted(solo_side), sorted([99, self.PHANTOM]))

    def test_it_holds_when_the_segments_are_swapped(self):
        """Foursomes-first moves the four-ball to 7-12; the phantom follows
        the SEGMENT, not the hole numbers."""
        self.assertEqual(
            self._segments_with_phantom(self._plan(foursomes_first=True)),
            {'fourball'})

    def test_no_phantom_means_no_phantom_anywhere(self):
        plan = _build_match_plan([1, 2], [3, 4])
        everyone = {p for e in plan for p in e['team1_ids'] + e['team2_ids']}
        self.assertEqual(everyone, {1, 2, 3, 4})
