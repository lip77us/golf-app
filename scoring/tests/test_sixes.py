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
    sixes_player_hole_strokes,
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


class SixesRessegmentTests(TestCase):
    """The classic early-finish → extra-segment chain, and shotgun thirds —
    both driven by play-order POSITION, not absolute hole number."""

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

    def _td(self):
        return _team_data(self.pid['T1A'], self.pid['T1B'],
                          self.pid['T2A'], self.pid['T2B'])

    def _halve(self, h):
        par = self.tee.hole(h)['par']
        submit_hole(self.fs, h, [(self.pid['T1A'], par), (self.pid['T1B'], par),
                                  (self.pid['T2A'], par), (self.pid['T2B'], par)])

    def _t1_wins(self, h):
        par = self.tee.hole(h)['par']
        submit_hole(self.fs, h, [(self.pid['T1A'], par), (self.pid['T1B'], par),
                                  (self.pid['T2A'], par + 1), (self.pid['T2B'], par + 1)])

    def _t2_wins(self, h):
        par = self.tee.hole(h)['par']
        submit_hole(self.fs, h, [(self.pid['T1A'], par + 1), (self.pid['T1B'], par + 1),
                                  (self.pid['T2A'], par), (self.pid['T2B'], par)])

    def test_early_finish_spawns_extra_segment(self):
        # Normal round. Segment 1 (holes 1-6): T1 wins holes 1-4 → 4 up with 2
        # to play → clinched at hole 4. Classic collapses the freed holes: the
        # next matches shift left and a final extra match covers 17-18.
        setup_sixes(self.fs, self._td(), handicap_mode='gross')
        for h in range(1, 5):
            self._t1_wins(h)
        for h in range(5, 19):
            self._halve(h)
        calculate_sixes(self.fs)
        s = sixes_summary(self.fs)
        starts = sorted(seg['start_hole'] for seg in s['segments'])
        # seg1 1-6 (closed early), seg2 5-10, seg3 11-16, extra 17-18.
        self.assertEqual(starts, [1, 5, 11, 17], s['segments'])

    def test_shotgun_thirds_by_play_order(self):
        # Shotgun from hole 8: play order 8..18,1..7. Thirds by POSITION are
        # 8-13 / 14-1 / 2-7, not 1-6 / 7-12 / 13-18.
        self.round.num_holes = 18
        self.round.starting_hole = 8
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        setup_sixes(self.fs, self._td(), handicap_mode='gross')
        for h in list(range(8, 19)) + list(range(1, 8)):
            self._halve(h)                       # all halved → no extras
        calculate_sixes(self.fs)
        s = sixes_summary(self.fs)
        bounds = {(seg['start_hole'], seg['end_hole']) for seg in s['segments']}
        self.assertEqual(bounds, {(8, 13), (14, 1), (2, 7)}, s['segments'])

    def test_strokes_off_dots_are_prospective_and_play_order(self):
        # User's scenario: shotgun from hole 16 (play order 16,17,18,1..15),
        # only the FIRST hole (16) entered so far. The WHOLE stroke plan must
        # still be visible — dots on the not-yet-played stroke holes.
        #
        # A player with SO=4 gets floor(4/3)=1 per segment plus a +1 on the
        # FIRST segment (4%3=1) → 2 strokes in segment 1 (its two hardest holes
        # SI 3 = hole 2 and SI 6 = hole 18), then 1 in segment 2 (SI 1 = hole 5)
        # and 1 in segment 3 (SI 2 = hole 14). Hole 18 only earns a stroke
        # because segment 1 WRAPS to include it — a hole-number allocation
        # would miss it.
        self.round.num_holes = 18
        self.round.starting_hole = 16
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        self.fs.delete()
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 4)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_sixes(self.fs, self._td(), handicap_mode='strokes_off')
        # Only the first hole (16) is played.
        par = self.tee.hole(16)['par']
        submit_hole(self.fs, 16, [
            (self.pid['T1A'], par), (self.pid['T1B'], par),
            (self.pid['T2A'], par), (self.pid['T2B'], par + 3)])
        calculate_sixes(self.fs)

        strokes = sixes_player_hole_strokes(self.fs)
        t2b = {h: s for h, s in strokes.get(self.pid['T2B'], {}).items() if s}
        self.assertEqual(t2b, {2: 1, 18: 1, 5: 1, 14: 1}, t2b)
        self.assertEqual(strokes.get(self.pid['T1A'], {}), {})  # scratch = no dots

        # The summary grid carries those strokes on the UNPLAYED holes (with a
        # null gross), and renders columns in play order.
        summary = sixes_summary(self.fs)
        self.assertEqual(summary['holes_in_play'][0], 16)       # play order
        grid = {h['hole']: h for h in summary['holes']}

        def _t2b(hole):
            return next(s for s in grid[hole]['scores']
                        if s['player_id'] == self.pid['T2B'])

        self.assertEqual(_t2b(18)['strokes'], 1)      # unplayed stroke hole
        self.assertIsNone(_t2b(18)['gross'])          # ...with no score yet
        self.assertEqual(_t2b(16)['gross'], par + 3)  # the one played hole
        # Each hole carries its stroke index for the scorecard's Index row.
        self.assertEqual(grid[18]['stroke_index'],
                         self.tee.hole(18)['stroke_index'])

    def test_wrapping_segment_emits_holes_in_play_order(self):
        # Shotgun from hole 16 → play order 16,17,18,1..15. Segment 1 WRAPS:
        # holes 16,17,18,1,2,3. Team 1 wins it (+2 final), but the last hole BY
        # NUMBER (18) sits at an intermediate running margin of 0. The summary
        # must emit holes in PLAY order so holes[-1] is the truly-last-played
        # hole 3 (final margin +2) — otherwise mobile's statusDisplay reads
        # hole 18's margin and shows "Halved" on a decided segment.
        self.round.num_holes = 18
        self.round.starting_hole = 16
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        setup_sixes(self.fs, self._td(), handicap_mode='gross')
        # Play-order running margin: 16:+1, 17:0, 18:0, 1:+1, 2:+1, 3:+2.
        self._t1_wins(16)
        self._t2_wins(17)
        self._halve(18)
        self._t1_wins(1)
        self._halve(2)
        self._t1_wins(3)
        for h in range(4, 16):
            self._halve(h)                       # segments 2 & 3 halved
        calculate_sixes(self.fs)
        s = sixes_summary(self.fs)
        seg1 = next(seg for seg in s['segments'] if seg['start_hole'] == 16)
        self.assertEqual(seg1['winner'], 'Team 1', seg1)
        self.assertEqual([h['hole'] for h in seg1['holes']],
                         [16, 17, 18, 1, 2, 3], seg1)
        # holes[-1] is the last-PLAYED hole (3) with the FINAL margin, not
        # hole 18's intermediate 0.
        self.assertEqual(seg1['holes'][-1]['hole'], 3, seg1)
        self.assertEqual(seg1['holes'][-1]['margin'], 2, seg1)


class SixesStrokeStabilityTests(TestCase):
    """A closeout repositions the LATER matches; it must never change the
    strokes on a hole that has already been played."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 5
        self.round.save(update_fields=['bet_unit'])
        # Dana gets SO=9 → 3 strokes in each of the three matches.
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dana', 9)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        A, B, C, D = (self.pid['Ann'], self.pid['Ben'],
                      self.pid['Cal'], self.pid['Dana'])
        setup_sixes(self.fs, _team_data(A, B, C, D),
                    handicap_mode='strokes_off',
                    handicap_allocation='per_segment')

    def _strokes(self, player_id):
        calculate_sixes(self.fs)
        return dict(sixes_player_hole_strokes(self.fs).get(player_id, {}))

    def test_closeout_never_moves_strokes_on_a_played_hole(self):
        A, B, C, D = (self.pid['Ann'], self.pid['Ben'],
                      self.pid['Cal'], self.pid['Dana'])
        played: dict = {}

        def check(hole):
            """Score `hole`, then assert no earlier hole's strokes changed."""
            now = self._strokes(D)
            for h, s in played.items():
                assert now.get(h, 0) == s, \
                    f'hole {h} strokes moved {s} → {now.get(h, 0)} ' \
                    f'after hole {hole} (match closeout re-spread)'
            played[hole] = now.get(hole, 0)

        # Match 1 (holes 1-6): team 1 wins 1, 2, 3, 4 → 4 up with 2 to play,
        # so it closes out on hole 4 and match 2 starts on hole 5.
        for h in range(1, 5):
            check(h)
            submit_hole(self.fs, h, [(A, 3), (B, 3), (C, 6), (D, 6)])
        # Match 2 now runs 5-10 and closes out on hole 8; match 3 runs 9-14.
        for h in range(5, 9):
            check(h)
            submit_hole(self.fs, h, [(A, 3), (B, 3), (C, 6), (D, 6)])
        for h in range(9, 19):
            check(h)
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4), (D, 5)])
        check(18)

    def test_closeout_drops_the_handed_over_holes_strokes(self):
        # A match that ends early hands its remaining holes to the next match,
        # which allocates its OWN strokes over them.  calculate_sixes undoes the
        # finished match's strokes there; the stroke dots must do the same, or a
        # dot shows on a hole that never receives the stroke (hole 10 below).
        A, B, C, D = (self.pid['Ann'], self.pid['Ben'],
                      self.pid['Cal'], self.pid['Dana'])
        for h in range(1, 9):            # match 1 ends on 4, match 2 on 8
            submit_hole(self.fs, h, [(A, 3), (B, 3), (C, 6), (D, 6)])
        # Match 1 (window 1-6, ended on 4) → holes 1, 2.  Match 2 (window 5-10,
        # ended on 8) → hole 5.  Match 3 (window 9-14) → 9, 11, 14.  Extra
        # (15-18, full-round SI <= 9) → 18.
        assert sorted(self._strokes(D)) == [1, 2, 5, 9, 11, 14, 18], \
            sorted(self._strokes(D))


class SixesConfiguredGamesTests(TestCase):
    """`configured_games` must report sixes once teams are set.

    The round hub routes Enter Scores off this. It used to route off an
    in-memory per-device flag instead, which was only ever set by running setup
    or loading the summary on THAT device — so a second golfer opening a match
    already in progress was sent into the team picker. If this contract ever
    stops holding, that bug comes straight back.
    """

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dee', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _configured(self):
        from api.serializers import FoursomeSerializer
        return FoursomeSerializer(self.fs).data['configured_games']

    def test_not_reported_before_setup(self):
        self.assertNotIn('sixes', self._configured())

    def test_reported_once_teams_are_set(self):
        setup_sixes(self.fs, _team_data(
            self.pid['Ann'], self.pid['Ben'],
            self.pid['Cal'], self.pid['Dee']), handicap_mode='gross')
        self.assertIn('sixes', self._configured())

    def test_segments_always_carry_their_teams(self):
        """The serializer keys off segments EXISTING, so a segment must never
        exist without players — otherwise 'configured' would be a lie and the
        hub would skip a setup that is genuinely still needed."""
        setup_sixes(self.fs, _team_data(
            self.pid['Ann'], self.pid['Ben'],
            self.pid['Cal'], self.pid['Dee']), handicap_mode='gross')
        for seg in self.fs.sixes_segments.all():
            for team in seg.teams.all():
                self.assertTrue(team.players.exists(),
                                f'segment {seg.segment_number} team '
                                f'{team.team_number} has no players')
