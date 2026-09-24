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


class _FieldBase(TestCase):
    """Two groups of two, so the field is bigger than any one card."""

    method = 'stroke'
    games  = ['low_net']

    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.tourn = Tournament.objects.create(
            account=course.account, name='Tilden Stroke',
            start_date=date(2026, 9, 23), total_rounds=1,
            active_games=list(self.games), scoring_method=self.method,
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


class FieldStandingTests(_FieldBase):
    """Stroke scoring — a place and a score against par."""

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

class StablefordFieldStandingTests(_FieldBase):
    """The same row on an individual-play STABLEFORD tournament.

    It quotes the CHAMPIONSHIP rather than this round, because that is the
    board its pill opens: a Stableford tournament round has no round-level
    points board — the game is the tournament's — and the round leaderboard
    would show a stroke-play tab that is not the competition being played.
    """

    method = 'stableford'
    games  = ['stableford_championship']

    def test_the_metric_is_points_not_strokes(self):
        """One payload key must never mean two shapes.

        A client casting blind would read a points total as a score against
        par, which on a Stableford round is roughly its opposite.
        """
        self._play(self.fs1, 1, [('Ann', self.par[1] - 1), ('Bea', self.par[1])])
        st = _build_scorecard(self.fs1)['field_standing']
        ann = st[str(self._pid(self.fs1, 'Ann'))]
        self.assertEqual(ann['metric'], 'points')
        self.assertIn('points', ann)
        self.assertNotIn('net_to_par', ann)

    def test_more_points_is_a_better_place(self):
        """Stableford ranks the other way up — and the row must follow the
        game rather than the shape of the stroke one it was copied from."""
        self._play(self.fs1, 1, [('Ann', self.par[1] - 1), ('Bea', self.par[1])])
        self._play(self.fs2, 1, [('Cal', self.par[1] + 2), ('Dee', self.par[1] + 2)])
        st = _build_scorecard(self.fs1)['field_standing']
        ann = st[str(self._pid(self.fs1, 'Ann'))]
        bea = st[str(self._pid(self.fs1, 'Bea'))]
        self.assertGreater(ann['points'], bea['points'])
        self.assertLess(ann['rank'], bea['rank'])

    def test_thru_is_TODAY_not_the_event(self):
        """The total is cumulative; how far in you are is a fact about today."""
        self._play(self.fs1, 1, [('Ann', self.par[1]), ('Bea', self.par[1])])
        self._play(self.fs1, 2, [('Ann', self.par[2]), ('Bea', self.par[2])])
        ann = _build_scorecard(self.fs1)['field_standing'][
            str(self._pid(self.fs1, 'Ann'))]
        self.assertEqual(ann['thru'], 2)

    def test_the_row_draws_from_the_FIRST_TEE(self):
        """**The championship standings hold only golfers who have scored.**

        Before the first putt they are empty, so the block would be empty, so
        there would be no row — and no named way to the leaderboard on the one
        screen a first-time player is looking at. That is the problem D2
        exists to solve, so the whole roster is seeded and the row says
        `Tee off`.
        """
        st = _build_scorecard(self.fs1)['field_standing']
        self.assertEqual(len(st), 4)
        ann = st[str(self._pid(self.fs1, 'Ann'))]
        self.assertIsNone(ann['rank'])
        self.assertIsNone(ann['points'])
        self.assertEqual(ann['thru'], 0)
        self.assertEqual(ann['field'], 4)

    def test_a_golfer_who_has_not_teed_off_is_unranked(self):
        self._play(self.fs1, 1, [('Ann', self.par[1]), ('Bea', self.par[1])])
        st = _build_scorecard(self.fs1)['field_standing']
        cal = st[str(self._pid(self.fs2, 'Cal'))]
        self.assertIsNone(cal['rank'])
        self.assertEqual(cal['field'], 4)

class GoverningHandicapTests(_FieldBase):
    """Which handicap a tournament round's card is drawn off.

    `Round.handicap_mode` / `net_percent` are the ROUND's own defaults and are
    never written from the tournament, so they read net/100 on an event the TD
    set to gross or to 90% — and the card's stroke dots would be drawn off a
    handicap nobody is playing.
    """

    def test_the_tournaments_handicap_is_sent_not_the_rounds(self):
        self.tourn.handicap_mode = 'gross'
        self.tourn.net_percent = 90
        self.tourn.save(update_fields=['handicap_mode', 'net_percent'])
        # The round still says its own thing...
        self.assertEqual(self.round.handicap_mode, 'net')
        self.assertEqual(self.round.net_percent, 100)
        # ...and the card is told the tournament's.
        scoring = _build_scorecard(self.fs1)['scoring']
        self.assertEqual(scoring['handicap_mode'], 'gross')
        self.assertEqual(scoring['net_percent'], 90)
        self.assertEqual(scoring['method'], 'stroke')

    def test_a_casual_round_is_told_nothing(self):
        """Its own values ARE the answer, so there is nothing to override."""
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        rnd = make_round(course=course, active_games=['low_net_round'])
        fs = make_foursome(rnd, [('Eve', 0)], tee=tee)
        self.assertNotIn('scoring', _build_scorecard(fs))


class StablefordGoverningHandicapTests(_FieldBase):
    method = 'stableford'
    games  = ['stableford_championship']

    def test_the_championship_config_governs_when_there_is_one(self):
        """The same resolver the points come from.

        A board scored on one handicap and a card drawn off another is the
        kind of disagreement nobody can debug from the tee.
        """
        from games.models import StablefordChampionshipConfig
        StablefordChampionshipConfig.objects.create(
            tournament=self.tourn, handicap_mode='gross', net_percent=80)
        scoring = _build_scorecard(self.fs1)['scoring']
        self.assertEqual(scoring['handicap_mode'], 'gross')
        self.assertEqual(scoring['net_percent'], 80)

    def test_it_falls_back_to_the_tournament_with_no_config(self):
        # The wizard only writes a championship config when the TD sets money,
        # so a no-stakes event legitimately has none.
        self.tourn.handicap_mode = 'gross'
        self.tourn.save(update_fields=['handicap_mode'])
        self.assertEqual(
            _build_scorecard(self.fs1)['scoring']['handicap_mode'], 'gross')

