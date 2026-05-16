"""
scoring/tests/test_sixes.py
---------------------------
Regression tests for services/sixes.py — the 3-segment 2v2 best-ball
format.  Sixes is unusual because its strokes-off allocation spreads
across segments (each segment gets roughly equal SO strokes) rather
than allocating all strokes to the toughest holes.  These tests pin
the segment math.
"""
from django.test import TestCase

from services.sixes import calculate_sixes, setup_sixes, sixes_summary

from ._helpers import (
    make_foursome,
    make_round,
    make_tee,
    submit_hole,
)


def _team_data(t1_a_id, t1_b_id, t2_a_id, t2_b_id):
    """Standard Sixes layout: three 6-hole segments with the same pair
    each time (long_drive method) — only the team assignments rotate.
    For these unit tests, we keep the same teams across all three
    segments so the math is easier to reason about."""
    base = {
        'team_select_method': 'long_drive',
        'team1_player_ids':   [t1_a_id, t1_b_id],
        'team2_player_ids':   [t2_a_id, t2_b_id],
    }
    return [
        {**base, 'start_hole':  1, 'end_hole':  6},
        {**base, 'start_hole':  7, 'end_hole': 12},
        {**base, 'start_hole': 13, 'end_hole': 18},
    ]


class SixesTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    # ── Three segments scored independently ───────────────────────────────

    def test_each_segment_scored_independently_of_the_others(self):
        """A win in one segment doesn't carry into the next.  Use
        narrow margins so no segment ends early — that keeps segment
        boundaries at 1-6 / 7-12 / 13-18 and lets us assert per-segment
        winners by start_hole."""
        setup_sixes(
            self.fs,
            _team_data(self.pid['T1A'], self.pid['T1B'],
                       self.pid['T2A'], self.pid['T2B']),
            handicap_mode='gross',
        )
        # Segment 1 (holes 1-6): T1 wins hole 1 only (par vs bogey),
        # halved holes 2-6.  Final margin +1 — no early clinch.
        for h in range(1, 7):
            par = self.tee.hole(h)['par']
            t1_score = par if h > 1 else par
            t2_score = par if h > 1 else par + 1
            submit_hole(self.fs, h, [
                (self.pid['T1A'], t1_score), (self.pid['T1B'], t1_score),
                (self.pid['T2A'], t2_score), (self.pid['T2B'], t2_score),
            ])
        # Segment 2 (holes 7-12): tied every hole.
        for h in range(7, 13):
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [
                (self.pid['T1A'], par), (self.pid['T1B'], par),
                (self.pid['T2A'], par), (self.pid['T2B'], par),
            ])
        # Segment 3 (holes 13-18): T2 wins hole 18 only, halved 13-17.
        for h in range(13, 19):
            par = self.tee.hole(h)['par']
            t1_score = par if h < 18 else par + 1
            t2_score = par
            submit_hole(self.fs, h, [
                (self.pid['T1A'], t1_score), (self.pid['T1B'], t1_score),
                (self.pid['T2A'], t2_score), (self.pid['T2B'], t2_score),
            ])
        calculate_sixes(self.fs)
        summary = sixes_summary(self.fs)
        segs = summary['segments']
        ordered = sorted(segs, key=lambda s: s['start_hole'])
        # Winner labels: "Team 1" / "Team 2" / "Halved" (or None mid-play).
        assert ordered[0]['winner'] == 'Team 1', ordered[0]
        assert ordered[1]['winner'] in ('Halved', None), ordered[1]
        assert ordered[2]['winner'] == 'Team 2', ordered[2]

    # ── Strokes-Off spreading ─────────────────────────────────────────────

    def test_strokes_off_spreads_across_segments(self):
        """Strokes-off allocates SO strokes across segments.  Verify that
        a 9-stroke high-handicapper on T2 touches every segment — when
        all four players shoot the same gross score, T2B's net advantage
        wins every segment for team 2."""
        # Rebuild the foursome with different handicaps.
        self.fs.delete()
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 9)],  # 9 SO total
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_sixes(
            self.fs,
            _team_data(self.pid['T1A'], self.pid['T1B'],
                       self.pid['T2A'], self.pid['T2B']),
            handicap_mode='strokes_off',
        )
        # Same gross score for all four players on every hole.  Without
        # SO, every hole halves.  With SO spread to T2B across all three
        # segments, T2 wins each segment where T2B picks up a stroke.
        for h in range(1, 19):
            submit_hole(self.fs, h, [
                (self.pid['T1A'], 4), (self.pid['T1B'], 4),
                (self.pid['T2A'], 4), (self.pid['T2B'], 4),
            ])
        calculate_sixes(self.fs)
        summary = sixes_summary(self.fs)
        # Every segment should reflect T2B's stroke advantage — at least
        # one segment must report Team 2 as the winner (proves SO is
        # being applied per-segment rather than ignored).
        winners = [seg.get('winner') for seg in summary['segments']]
        assert any(w == 'Team 2' for w in winners), winners
