"""
scoring/tests/test_tournament_match_play_scorecard.py
-----------------------------------------------------
The per-match scoring-detail block on tournament_match_play_summary (the data
that feeds the leaderboard's Mini Singles Bracket detail): prospective per-hole
handicap strokes that follow the bracket's handicap mode — Strokes-Off-Low is
PER-PAIR (the lower handicap of each match plays scratch), matching how
calculate_tournament_match_play actually scores and what the score-entry "gets"
bubble shows.

The Final / 3rd-Place carry a card from the first tee shot on 10 even while a
semi is still level — a halved semi PLAYS ON and nobody waits — with only the
unnamed side's cells left blank. See
docs/design-review/handoff-individual-play/SPEC.md §4.
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

    def test_final_shows_a_card_with_the_unnamed_side_blank(self):
        s = tournament_match_play_summary(self.fs)   # semis unscored
        r2 = [m for m in s['matches'] if m['round'] == 2]
        self.assertTrue(r2)
        for m in r2:
            # A card, not an empty frame — the back-9 matches are real.
            self.assertIsNotNone(m['scorecard'])
            self.assertEqual([h['hole'] for h in m['scorecard']['holes']],
                             list(range(10, 19)))
            # Both sides are fed by unresolved semis, so both read TBD.
            self.assertEqual([p['name'] for p in m['scorecard']['players']],
                             ['TBD', 'TBD'])
            self.assertTrue(all(c['tbd'] for h in m['scorecard']['holes']
                                for c in h['scores']))


class HalvedSemiPlaysOnTests(TestCase):
    """
    A halved semi PLAYS ON into the back nine — it never splits and never goes
    to a card-off — and nobody waits for it. The pair whose semi resolved tee
    off on 10 on schedule and their back-9 match is scored live against an
    opponent the bracket cannot name yet: `1 UP thru 11`, never "Pending".

    This is unambiguous rather than a guess, because the pair still level can
    only HALVE the holes they play in overtime: the first hole either takes
    outright is the hole that ends the semi.
    """

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['match_play'])
        self.fs = make_foursome(
            self.round, [('Alan Petersen', 0), ('Alex Gunst', 5),
                         ('Aldo Detomasi', 10), ('Anna Maiolini', 15)],
            tee=self.tee)

    def _score(self, s1, s2, hole, s1p1, s1p2, s2p1, s2p2):
        from ._helpers import submit_hole
        submit_hole(self.fs, hole, [
            (s1.player1_id, s1p1), (s1.player2_id, s1p2),
            (s2.player1_id, s2p1), (s2.player2_id, s2p2)])
        calculate_tournament_match_play(self.fs)

    def _matches(self):
        return tournament_match_play_summary(self.fs)['matches']

    def _final(self):
        return next(m for m in self._matches() if m['round'] == 2)

    def _setup(self):
        bracket = setup_tournament_match_play(self.fs, handicap_mode='gross')
        r1 = [m for m in bracket.matches.order_by('round_number', 'id')
              if m.round_number == 1]
        return r1[0], r1[1]

    def test_the_final_does_not_wait_for_a_semi_still_level(self):
        s1, s2 = self._setup()

        # Holes 1–9: semi 1 halved every hole (level → plays on); semi 2's
        # player1 wins every hole (closes out).
        for h in range(1, 10):
            self._score(s1, s2, h, 4, 4, 3, 5)

        final = self._final()
        self.assertTrue(final['players_tbd'])
        # One side is named — the semi that resolved — and the other is TBD.
        self.assertEqual(
            sorted([final['player1'] == 'TBD', final['player2'] == 'TBD']),
            [False, True])

        # Hole 10: the level pair halve again (they can only halve), and the
        # resolved golfer wins the hole. His FINAL is now 1 up on whoever
        # emerges — a real, scored result against an unnamed opponent.
        self._score(s1, s2, 10, 4, 4, 3, 5)
        final = self._final()
        self.assertTrue(final['players_tbd'])
        self.assertEqual(final['status'], 'in_progress')
        self.assertEqual(final['line'], '1 UP thru 10')
        self.assertIn('TBD', final['pairing'])

        # Hole 11 ends the semi. The opponent is named and the earlier holes
        # re-score to exactly the same standing — they were halved.
        self._score(s1, s2, 11, 3, 4, 3, 5)
        final = self._final()
        self.assertFalse(final['players_tbd'])
        self.assertNotIn('TBD', final['pairing'])
        self.assertEqual(final['line'], 'Gunst 1 UP thru 11')

    def test_the_semi_reports_playing_on_not_sudden_death(self):
        s1, s2 = self._setup()
        for h in range(1, 10):
            self._score(s1, s2, h, 4, 4, 3, 5)
        self._score(s1, s2, 10, 4, 4, 4, 4)
        self._score(s1, s2, 11, 3, 4, 4, 4)

        semi = next(m for m in self._matches() if m['round'] == 1
                    and m['label'] == 'Semi 1')
        self.assertEqual(semi['status'], 'complete')
        self.assertEqual(semi['tie_break'], 'played_on')
        self.assertEqual(semi['finished_hole'], 11)
        self.assertTrue(any(h['is_overtime'] for h in semi['holes']))

    def test_match_summaries_use_the_surname_alone(self):
        s1, _s2 = self._setup()
        self.assertEqual(
            next(m for m in self._matches() if m['label'] == 'Semi 1')['pairing'],
            'Petersen vs Maiolini')


class HalvedFinalSplitsTheMoneyTests(TestCase):
    """
    A halved FINAL splits 1st and 2nd — nobody is played off for cash. Only the
    trophy and the next-stage seat need one name, and they go to the last hole
    won. A halved 3rd-place match simply splits: nothing depends on the order.
    """

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['match_play'])
        self.fs = make_foursome(
            self.round, [('Alan Petersen', 0), ('Alex Gunst', 0),
                         ('Aldo Detomasi', 0), ('Anna Maiolini', 0)],
            tee=self.tee)
        self.bracket = setup_tournament_match_play(
            self.fs, entry_fee=10,
            payout_config={'1st': 24.0, '2nd': 10.0, '3rd': 6.0, '4th': 0.0},
            handicap_mode='gross')
        r1 = [m for m in self.bracket.matches.order_by('round_number', 'id')
              if m.round_number == 1]
        self.s1, self.s2 = r1[0], r1[1]

    def _score(self, hole, s1p1, s1p2, s2p1, s2p2):
        from ._helpers import submit_hole
        submit_hole(self.fs, hole, [
            (self.s1.player1_id, s1p1), (self.s1.player2_id, s1p2),
            (self.s2.player1_id, s2p1), (self.s2.player2_id, s2p2)])
        calculate_tournament_match_play(self.fs)

    def _play_out(self, back9):
        # Semis: both player1s win outright on hole 1, halve the rest.
        self._score(1, 3, 5, 3, 5)
        for h in range(2, 10):
            self._score(h, 4, 4, 4, 4)
        for hole, scores in back9.items():
            self._score(hole, *scores)

    def test_a_halved_final_splits_first_and_second(self):
        # Back 9: the final (s1 winner vs s2 winner — both are the player1s)
        # is level after 18 with one hole each; the 3rd-place match is level
        # with every hole halved.
        back9 = {10: (3, 4, 4, 4)}                      # final p1 wins 10
        back9.update({h: (4, 4, 4, 4) for h in range(11, 18)})
        back9[18] = (4, 4, 3, 4)                        # Gunst wins 18
        self._play_out(back9)

        s = tournament_match_play_summary(self.fs)
        final = next(m for m in s['matches'] if m['label'] == 'Final')
        self.assertEqual(final['result'], 'halved')
        self.assertEqual(final['tie_break'], 'last_hole_won')
        # The trophy goes to whoever won the LAST hole taken outright — 18.
        self.assertIsNotNone(final['trophy_player_id'])

        # 1st + 2nd are pooled and shared: $24 + $10 = $17 each.
        split = next(sp for sp in s['money']['splits'] if sp['places'] == ['1st', '2nd'])
        self.assertEqual(split['each'], 17.0)
        self.assertEqual(len(split['players']), 2)

    def test_the_trophy_takes_the_seat_but_not_extra_money(self):
        back9 = {10: (3, 4, 4, 4)}
        back9.update({h: (4, 4, 4, 4) for h in range(11, 18)})
        back9[18] = (4, 4, 3, 4)
        self._play_out(back9)

        s = tournament_match_play_summary(self.fs)
        final = next(m for m in s['matches'] if m['label'] == 'Final')
        self.assertEqual(s['winner'], final['trophy_player'])
        # Both finalists collect the same amount.
        split = next(sp for sp in s['money']['splits'] if sp['places'] == ['1st', '2nd'])
        self.assertEqual(split['each'], 17.0)

    def test_every_hole_halved_is_a_dead_heat_with_no_trophy(self):
        back9 = {h: (4, 4, 4, 4) for h in range(10, 19)}
        self._play_out(back9)

        s = tournament_match_play_summary(self.fs)
        final = next(m for m in s['matches'] if m['label'] == 'Final')
        self.assertEqual(final['result'], 'halved')
        self.assertEqual(final['tie_break'], 'dead_heat')
        self.assertIsNone(final['trophy_player_id'])
