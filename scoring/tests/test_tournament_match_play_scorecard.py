"""
scoring/tests/test_tournament_match_play_scorecard.py
-----------------------------------------------------
The per-match scoring-detail block on tournament_match_play_summary (the data
that feeds the leaderboard's Mini Singles Bracket detail): prospective per-hole
handicap strokes that follow the bracket's handicap mode — Strokes-Off-Low is
PER-PAIR (the lower handicap of each match plays scratch), matching how
calculate_tournament_match_play actually scores and what the score-entry "gets"
bubble shows. Final/consolation stay hidden until both semis resolve.
"""
from django.test import TestCase

from services.tournament_match_play import (
    setup_tournament_match_play,
    calculate_tournament_match_play,
    tournament_match_play_summary,
)

from ._helpers import make_tee, make_round, make_foursome


class TournamentMatchPlayScorecardTests(TestCase):
    def setUp(self):
        self.tee = make_tee()  # front-9 SIs: 7,3,15,9,1,13,17,11,5
        self.round = make_round(self.tee.course, active_games=['match_play'])
        # Seeds by handicap → semi1: A(0) vs D(15); semi2: B(5) vs C(10).
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 5), ('C', 10), ('D', 15)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_tournament_match_play(self.fs)   # defaults to Strokes-Off-Low
        calculate_tournament_match_play(self.fs)   # no scores → prospective

    def _cell(self, sc, hole, name):
        h = next(x for x in sc['holes'] if x['hole'] == hole)
        return next(s for s in h['scores'] if s['player_id'] == self.pid[name])

    def test_semis_have_prospective_scorecard(self):
        s = tournament_match_play_summary(self.fs)
        self.assertEqual(s['handicap']['mode'], 'strokes_off')
        semis = [m for m in s['matches'] if m['round'] == 1]
        self.assertEqual(len(semis), 2)
        for m in semis:
            self.assertIsNotNone(m['scorecard'])
            self.assertEqual([h['hole'] for h in m['scorecard']['holes']],
                             list(range(1, 10)))
            self.assertTrue(all(h['par'] is not None
                                for h in m['scorecard']['holes']))
            self.assertTrue(all(h['stroke_index'] is not None
                                for h in m['scorecard']['holes']))

    def test_so_low_strokes_are_per_pair(self):
        s = tournament_match_play_summary(self.fs)
        semi = next(m for m in s['matches'] if m['round'] == 1
                    and {m['player1_id'], m['player2_id']}
                        == {self.pid['B'], self.pid['C']})
        sc = semi['scorecard']
        # C(10) vs B(5): pair low = 5, so C gets (10−5)=5 strokes and B plays
        # scratch. Front-9 SI ≤ 5 → holes 2 (SI 3), 5 (SI 1), 9 (SI 5).
        self.assertEqual(self._cell(sc, 5, 'C')['strokes'], 1)   # SI 1
        self.assertEqual(self._cell(sc, 1, 'C')['strokes'], 0)   # SI 7 > 5
        self.assertIsNone(self._cell(sc, 5, 'C')['gross'])       # prospective
        self.assertEqual(self._cell(sc, 5, 'B')['strokes'], 0)   # pair low
        # NOT the full-handicap allocation: C hcp 10 alone would also stroke
        # hole 4 (SI 9); per-pair it does not.
        self.assertEqual(self._cell(sc, 4, 'C')['strokes'], 0)   # SI 9 > 5

    def test_final_hidden_until_semis_complete(self):
        s = tournament_match_play_summary(self.fs)   # semis unscored
        r2 = [m for m in s['matches'] if m['round'] == 2]
        self.assertTrue(r2)
        for m in r2:
            self.assertIsNone(m['scorecard'])


class TournamentMatchPlaySuddenDeathGateTests(TestCase):
    """A semi tied after 9 goes to sudden death on holes 10+, which overlap the
    back-9 holes the Final/3rd-Place use. The Final must NOT start (assign
    players, score, or show a scorecard) until BOTH semis are decided — even
    while one semi is still tied deep into sudden death."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['match_play'])
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 5), ('C', 10), ('D', 15)], tee=self.tee)

    def _score(self, s1, s2, hole, s1p1, s1p2, s2p1, s2p2):
        from ._helpers import submit_hole
        submit_hole(self.fs, hole, [
            (s1.player1_id, s1p1), (s1.player2_id, s1p2),
            (s2.player1_id, s2p1), (s2.player2_id, s2p2)])
        calculate_tournament_match_play(self.fs)

    def _final(self):
        s = tournament_match_play_summary(self.fs)
        return next(m for m in s['matches'] if m['round'] == 2)

    def test_final_waits_through_sudden_death(self):
        bracket = setup_tournament_match_play(self.fs, handicap_mode='gross')
        r1 = [m for m in bracket.matches.order_by('round_number', 'id')
              if m.round_number == 1]
        s1, s2 = r1[0], r1[1]

        # Holes 1-9: semi1 halved every hole (tied → sudden death); semi2's
        # player1 wins every hole (closes out → complete).
        for h in range(1, 10):
            self._score(s1, s2, h, 4, 4, 3, 5)

        # One semi decided, the other tied and about to enter SD.
        final = self._final()
        self.assertTrue(final['players_tbd'])
        self.assertIsNone(final['scorecard'])
        self.assertEqual(final['status'], 'pending')
        self.assertEqual(final['player1'], 'Semi 1 Winner')

        # Hole 10 — SD, still tied. The Final must STILL be pending (the bug:
        # it used to start here because both semis were "past the front 9").
        self._score(s1, s2, 10, 4, 4, 4, 4)
        final = self._final()
        self.assertTrue(final['players_tbd'], 'Final started during sudden death')
        self.assertIsNone(final['scorecard'])
        self.assertEqual(final['status'], 'pending')

        # Hole 11 — semi1's player1 wins the SD → both semis decided. NOW the
        # Final resolves: real players + scorecard appear.
        self._score(s1, s2, 11, 3, 4, 4, 4)
        s = tournament_match_play_summary(self.fs)
        self.assertTrue(all(m['status'] == 'complete'
                            for m in s['matches'] if m['round'] == 1))
        final = next(m for m in s['matches'] if m['round'] == 2)
        self.assertFalse(final['players_tbd'])
        self.assertIsNotNone(final['scorecard'])
