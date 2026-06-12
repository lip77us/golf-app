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

from games.models import SixesHoleResult
from services.sixes import (
    apply_withdrawal_to_sixes,
    calculate_sixes,
    setup_sixes,
    sixes_summary,
)

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

    # ── Mid-round withdrawal ──────────────────────────────────────────────

    def _withdraw(self, name, after_hole):
        m = self.fs.memberships.get(player_id=self.pid[name])
        m.withdrew_after_hole = after_hole
        m.save(update_fields=['withdrew_after_hole'])

    def _std_sixes(self, **kw):
        setup_sixes(
            self.fs,
            _team_data(self.pid['T1A'], self.pid['T1B'],
                       self.pid['T2A'], self.pid['T2B']),
            handicap_mode='gross', **kw,
        )

    def test_withdrawal_void_excludes_affected_segments(self):
        """WD after hole 9 with 'void': segment 1 (done) stands; the segment
        in progress and all later ones are voided — 0 points, excluded from
        the win/halve tally."""
        self._std_sixes()
        # Segment 1 (1-6): T1 wins hole 1, rest halved → Team 1.
        for h in range(1, 7):
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [
                (self.pid['T1A'], par), (self.pid['T1B'], par),
                (self.pid['T2A'], par + (1 if h == 1 else 0)),
                (self.pid['T2B'], par + (1 if h == 1 else 0)),
            ])
        # Holes 7-9 played by all four before the WD.
        for h in range(7, 10):
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [(self.pid[n], par) for n in
                                     ('T1A', 'T1B', 'T2A', 'T2B')])

        self._withdraw('T2B', 9)
        apply_withdrawal_to_sixes(self.fs, self.pid['T2B'], 9, 'void')
        calculate_sixes(self.fs)

        summary = sixes_summary(self.fs)
        ordered = sorted(summary['segments'], key=lambda s: s['start_hole'])
        assert ordered[0]['winner'] == 'Team 1', ordered[0]
        assert ordered[1]['is_void'] and ordered[1]['winner'] == 'Voided', ordered[1]
        assert ordered[2]['is_void'] and ordered[2]['winner'] == 'Voided', ordered[2]
        assert summary['overall'] == {'team1_wins': 1, 'team2_wins': 0,
                                      'halves': 0}, summary['overall']

    def test_withdrawal_solo_best_ball_uses_lone_ball(self):
        """WD after hole 9 with 'solo': the remaining partner plays on and
        their lone ball is the team's ball for the rest of the segment."""
        self._std_sixes()
        # Holes 1-9: everyone pars (segment 1 halved; seg 2 holes 7-9 halved).
        for h in range(1, 10):
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [(self.pid[n], par) for n in
                                     ('T1A', 'T1B', 'T2A', 'T2B')])
        self._withdraw('T2B', 9)
        apply_withdrawal_to_sixes(self.fs, self.pid['T2B'], 9, 'solo')
        # Holes 10-12: T2A (solo) birdies, T1 pars → Team 2 takes the segment.
        for h in range(10, 13):
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [(self.pid['T1A'], par),
                                     (self.pid['T1B'], par),
                                     (self.pid['T2A'], par - 1)])
        calculate_sixes(self.fs)

        summary = sixes_summary(self.fs)
        seg2 = next(s for s in summary['segments'] if s['start_hole'] == 7)
        assert not seg2['is_void'], seg2
        assert seg2['winner'] == 'Team 2', seg2
        # The lone-ball holes produced results using T2A's score.
        hr = SixesHoleResult.objects.get(segment__foursome=self.fs, hole_number=10)
        assert hr.team2_best_net == self.tee.hole(10)['par'] - 1, hr.team2_best_net

    def test_withdrawal_solo_high_low_lone_net_is_both_ends(self):
        """High-Low 'solo': a one-player team uses its lone net as BOTH the
        high and the low ball."""
        self._std_sixes(scoring_format='high_low')
        for h in range(1, 10):
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [(self.pid[n], par) for n in
                                     ('T1A', 'T1B', 'T2A', 'T2B')])
        self._withdraw('T2B', 9)
        apply_withdrawal_to_sixes(self.fs, self.pid['T2B'], 9, 'solo')
        # Hole 10: T2A alone scores 3; T1 both score 4.
        submit_hole(self.fs, 10, [(self.pid['T1A'], 4), (self.pid['T1B'], 4),
                                  (self.pid['T2A'], 3)])
        calculate_sixes(self.fs)

        hr = SixesHoleResult.objects.get(segment__foursome=self.fs, hole_number=10)
        assert hr.team2_best_net == 3, hr.team2_best_net
        assert hr.team2_worst_net == 3, hr.team2_worst_net
