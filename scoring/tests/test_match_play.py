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
