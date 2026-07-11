"""
scoring/tests/test_match_play.py
--------------------------------
Regression test for scoring.handicap.build_match_play_score_index.

Match play decides each hole on the ACTUAL net score (the hole is played
out or conceded), so the stroke-play net-double-bogey cap must NOT apply —
and the helper must not crash on the cap branch (it once referenced an
undefined ``cap_enabled``).
"""
from django.test import TestCase

from scoring.handicap import build_match_play_score_index

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class MatchPlayHandicapTests(TestCase):
    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course)
        # Turn the round-level net-double-bogey cap ON so the test proves
        # match play ignores it.
        self.round.net_max_double_bogey = True
        self.round.save(update_fields=['net_max_double_bogey'])
        self.fs = make_foursome(self.round, [('P1', 0), ('P2', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def test_no_double_bogey_cap_in_match_play(self):
        # Hole 1 is par 4 → net double bogey would cap at 6.  Both players are
        # scratch (no strokes), so the index is the raw gross — uncapped.
        submit_hole(self.fs, 1, [(self.pid['P1'], 8), (self.pid['P2'], 4)])
        idx = build_match_play_score_index(
            self.fs, self.pid['P1'], self.pid['P2'])
        assert idx[self.pid['P1']][1] == 8, idx   # NOT clamped to 6
        assert idx[self.pid['P2']][1] == 4, idx


from services.match_play import (
    setup_match_play, calculate_match_play, match_play_summary,
)


class MatchPlayScorecardTests(TestCase):
    """The per-match scoring detail block: prospective per-hole handicap
    strokes (full-net, the basis the bracket scores on) so a player can see
    where strokes fall over the 9 holes; final/consolation stay hidden until
    both semis finish."""

    def setUp(self):
        self.tee = make_tee()  # holes 1-9 SIs: 7,3,15,9,1,13,17,11,5
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 4), ('C', 9), ('D', 2)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_match_play(self.fs)
        calculate_match_play(self.fs)   # no scores → everything prospective

    def _cell(self, sc, hole, name):
        h = next(x for x in sc['holes'] if x['hole'] == hole)
        return next(s for s in h['scores'] if s['player_id'] == self.pid[name])

    def test_semis_have_prospective_scorecard(self):
        s = match_play_summary(self.fs)
        semis = [m for m in s['matches'] if m['round'] == 1]
        self.assertEqual(len(semis), 2)
        for m in semis:
            self.assertFalse(m['players_tbd'])
            sc = m['scorecard']
            self.assertIsNotNone(sc)
            self.assertEqual([h['hole'] for h in sc['holes']], list(range(1, 10)))
            self.assertTrue(all(h['par'] is not None for h in sc['holes']))
            self.assertTrue(all(h['stroke_index'] is not None for h in sc['holes']))

    def test_prospective_strokes_are_full_net(self):
        s = match_play_summary(self.fs)
        # The semi containing A (scratch) vs C (hcp 9).
        semi = next(m for m in s['matches'] if m['round'] == 1
                    and {m['player1_id'], m['player2_id']}
                        == {self.pid['A'], self.pid['C']})
        sc = semi['scorecard']
        # C hcp 9 → a stroke on every front-9 hole with SI ≤ 9 (holes 1,2,4,5,9);
        # none on hole 3 (SI 15). Gross null before scoring.
        self.assertEqual(self._cell(sc, 5, 'C')['strokes'], 1)   # SI 1
        self.assertEqual(self._cell(sc, 3, 'C')['strokes'], 0)   # SI 15
        self.assertIsNone(self._cell(sc, 5, 'C')['gross'])
        # A is scratch → no strokes anywhere.
        self.assertEqual(self._cell(sc, 5, 'A')['strokes'], 0)

    def test_final_hidden_until_semis_complete(self):
        s = match_play_summary(self.fs)   # semis not scored yet
        r2 = [m for m in s['matches'] if m['round'] == 2]
        self.assertTrue(r2)
        for m in r2:
            self.assertTrue(m['players_tbd'])
            self.assertIsNone(m['scorecard'])


    def test_so_low_strokes_are_per_pair(self):
        # Flip the bracket to Strokes-Off-Low and recalculate.
        b = self.fs.match_play_brackets.first()
        b.handicap_mode = 'strokes_off'
        b.save(update_fields=['handicap_mode'])
        calculate_match_play(self.fs)
        s = match_play_summary(self.fs)
        self.assertEqual(s['handicap']['mode'], 'strokes_off')
        # Semi seeded D(2) vs B(4): the pair low is 2 (D), so B gets (4−2)=2
        # strokes and D plays scratch — NOT the full-handicap allocation.
        semi = next(
            m for m in s['matches'] if m['round'] == 1
            and {m['player1_id'], m['player2_id']} == {self.pid['D'], self.pid['B']})
        sc = semi['scorecard']
        # B so=2 → a stroke on the two hardest holes (SI 1,2); in the front 9
        # that's only hole 5 (SI 1). Hole 2 (SI 3) gets none. Under full net B
        # (hcp 4) would ALSO get hole 2 — this is what distinguishes SO.
        self.assertEqual(self._cell(sc, 5, 'B')['strokes'], 1)
        self.assertEqual(self._cell(sc, 2, 'B')['strokes'], 0)
        # D is the pair's low → scratch, no strokes anywhere.
        self.assertEqual(self._cell(sc, 5, 'D')['strokes'], 0)
