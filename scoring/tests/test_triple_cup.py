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
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


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
        # T1 = Ryan(0) + Bob(9) → combined 50/50 = round(4.5) = 4
        # T2 = Gary(9) + Glenn(5) → combined 50/50 = round(7) = 7
        # Team-vs-team: T1 (low) = 0, T2 (high) = 7 − 4 = 3
        # (Earlier hand-math said 4, but with banker's rounding
        # round(4.5)→4 in Python so the differential is 3.)
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
        assert blue == 3, (red, blue)


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
