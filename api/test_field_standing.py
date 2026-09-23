"""
api/test_field_standing.py
--------------------------
The place the score-entry standing row reports on an individual-play STROKE
tournament.

A card holds ONE foursome and a place is a fact about everybody, so it comes
down with the card. The thing that matters is that it says the same as the
board the row's own pill opens.
"""
from datetime import date

from django.test import TestCase

from api.views import _build_scorecard
from services.low_net_round import field_standing, low_net_round_standings
from tournament.models import Tournament
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)


class FieldStandingTests(TestCase):
    """Two groups of two, so the field is bigger than any one card."""

    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.tourn = Tournament.objects.create(
            account=course.account, name='Tilden Stroke',
            start_date=date(2026, 9, 23), total_rounds=1,
            active_games=['low_net'], scoring_method='stroke',
            handicap_mode='net', net_percent=100)
        self.round = make_round(course=course, handicap_mode='net',
                                net_percent=100, active_games=[])
        self.round.tournament = self.tourn
        self.round.save(update_fields=['tournament'])
        self.fs1 = make_foursome(self.round, [('Ann', 0), ('Bea', 0)],
                                 tee=self.tee)
        self.fs2 = make_foursome(self.round, [('Cal', 0), ('Dee', 0)],
                                 tee=self.tee, group_number=2)
        self.par = {h['number']: h['par'] for h in DEFAULT_HOLES}

    def _pid(self, fs, name):
        return next(m.player_id for m in fs.memberships.all()
                    if m.player.name == name)

    def _play(self, fs, hole, scores):
        submit_hole(fs, hole, [(self._pid(fs, n), s) for n, s in scores])

    # ── the shape ────────────────────────────────────────────────────────────

    def test_the_card_carries_every_golfers_place(self):
        self._play(self.fs1, 1, [('Ann', self.par[1] - 1), ('Bea', self.par[1])])
        self._play(self.fs2, 1, [('Cal', self.par[1]), ('Dee', self.par[1] + 1)])
        st = _build_scorecard(self.fs1)['field_standing']
        # Keyed by player id as a STRING — jsonb keys are strings, and the
        # client parses them back.
        self.assertEqual(len(st), 4)
        ann = st[str(self._pid(self.fs1, 'Ann'))]
        self.assertEqual(ann['rank'], 1)
        self.assertEqual(ann['field'], 4)
        self.assertEqual(ann['net_to_par'], -1)
        self.assertEqual(ann['thru'], 1)

    def test_the_field_is_bigger_than_the_card(self):
        """The whole point: a rank off four golfers is not a place in a field."""
        self._play(self.fs1, 1, [('Ann', self.par[1]), ('Bea', self.par[1])])
        st = _build_scorecard(self.fs1)['field_standing']
        self.assertEqual({v['field'] for v in st.values()}, {4})
        self.assertEqual(len(_build_scorecard(self.fs1)['totals']), 2)

    def test_the_card_and_the_board_never_disagree(self):
        """**The one thing this row must never do.**

        Two implementations of a rank would eventually put a golfer 2nd on the
        row and 3rd on the board he taps through to.
        """
        self._play(self.fs1, 1, [('Ann', self.par[1] - 1), ('Bea', self.par[1])])
        self._play(self.fs2, 1, [('Cal', self.par[1]), ('Dee', self.par[1] + 1)])
        board = {r['player_id']: r for r in low_net_round_standings(self.round)}
        for pid, row in field_standing(self.round).items():
            if row['rank'] is not None:
                self.assertEqual(row['rank'], board[pid]['rank'])
            self.assertEqual(row['net_to_par'], board[pid]['net_to_par'])

    # ── what it will not claim ───────────────────────────────────────────────

    def test_a_golfer_who_has_not_teed_off_is_unranked(self):
        """Not level par — not on the board.

        The board's own rows hand him the last rank it issued, which on a
        field where everybody is level reads as a share of FIRST. The row says
        `Tee off` for him instead, and nothing it displays contradicts the
        board, because unstarted golfers sort last and cannot change the rank
        of anybody who has a score.
        """
        self._play(self.fs1, 1, [('Ann', self.par[1]), ('Bea', self.par[1])])
        st = field_standing(self.round)
        self.assertIsNone(st[self._pid(self.fs2, 'Cal')]['rank'])
        self.assertEqual(st[self._pid(self.fs2, 'Cal')]['thru'], 0)
        self.assertFalse(st[self._pid(self.fs2, 'Cal')]['tied'])
        # ...and the denominator still counts him.
        self.assertEqual(st[self._pid(self.fs2, 'Cal')]['field'], 4)

    def test_a_tie_is_marked_and_skips_the_places_it_occupies(self):
        # Three level, one behind: the three share 1st and the fourth is 4th.
        self._play(self.fs1, 1, [('Ann', self.par[1]), ('Bea', self.par[1])])
        self._play(self.fs2, 1, [('Cal', self.par[1]), ('Dee', self.par[1] + 1)])
        st = field_standing(self.round)
        ann = st[self._pid(self.fs1, 'Ann')]
        dee = st[self._pid(self.fs2, 'Dee')]
        self.assertTrue(ann['tied'])
        self.assertEqual(ann['rank'], 1)
        self.assertEqual(dee['rank'], 4)
        self.assertFalse(dee['tied'])

    # ── where it is NOT sent ─────────────────────────────────────────────────

    def test_a_casual_round_carries_none(self):
        """A casual round's field IS the foursome, so the row works it out on
        the card it already holds and the server says nothing."""
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        rnd = make_round(course=course, active_games=['low_net_round'])
        fs = make_foursome(rnd, [('Eve', 0), ('Fay', 0)], tee=tee)
        self.assertNotIn('field_standing', _build_scorecard(fs))

    def test_a_team_play_tournament_carries_none(self):
        """It scores a TEAM, not a golfer, and has its own row."""
        self.tourn.active_games = ['team_play']
        self.tourn.save(update_fields=['active_games'])
        self.assertNotIn('field_standing', _build_scorecard(self.fs1))

    def test_a_cup_carries_none(self):
        """A cup keeps its own per-round, per-format scoring."""
        self.tourn.active_games = ['team_cup']
        self.tourn.save(update_fields=['active_games'])
        self.assertNotIn('field_standing', _build_scorecard(self.fs1))

    def test_a_stableford_tournament_carries_none(self):
        """Stableford has its own round-level summary and its own row; a
        stroke place beside a points total would be two answers to one
        question."""
        self.tourn.scoring_method = 'stableford'
        self.tourn.save(update_fields=['scoring_method'])
        self.assertNotIn('field_standing', _build_scorecard(self.fs1))
