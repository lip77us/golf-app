"""
scoring/tests/test_edit_window.py
---------------------------------
The 4-hole edit ceiling, and the two games that now sit under it.

One rule for every game (`services/edit_window`): setup stays correctable
through four scored holes, and a game's own rule may lock EARLIER but never
later. The Sixes half is exercised in `test_sixes.SixesTeamLockTests`; this
module pins the ceiling itself and Sequoya, which had no lock at all before.
"""
from django.test import TestCase

from services.edit_window import (EDIT_CEILING_HOLES, edits_open, scored_holes)
from services.sequoya_threes import SequoyaLocked, setup_sequoya_threes
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0), ('Dee', 0)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.A, self.B = self.pid['Ann'], self.pid['Ben']
        self.C, self.D = self.pid['Cal'], self.pid['Dee']

    def _score_through(self, n):
        for h in range(1, n + 1):
            submit_hole(self.fs, h, [(self.A, 4), (self.B, 5),
                                     (self.C, 5), (self.D, 6)])


class CeilingTests(_Base):

    def test_the_ceiling_is_four(self):
        """Written down once. A 4 repeated in each service is how eleven games
        end up with eleven rules again."""
        self.assertEqual(EDIT_CEILING_HOLES, 4)

    def test_it_counts_holes_not_rows(self):
        """A group is through 3 when three holes are in, whether that is three
        golfers on them or four."""
        self._score_through(3)
        self.assertEqual(scored_holes(self.fs), 3)

    def test_open_through_the_fourth_and_closed_on_the_fifth(self):
        self.assertTrue(edits_open(self.fs))
        self._score_through(4)
        self.assertTrue(edits_open(self.fs), 'four is inside, not past')
        self._score_through(5)
        self.assertFalse(edits_open(self.fs))

    def test_the_bound_is_the_rewrite_it_permits(self):
        """Four scored holes is four holes per golfer to rewrite, never
        eighteen — which is what makes accepting a retroactive edit tractable
        when `handicap_strokes` and `net_score` are stored rather than
        computed."""
        self._score_through(EDIT_CEILING_HOLES)
        self.assertTrue(edits_open(self.fs))
        self.assertLessEqual(scored_holes(self.fs), EDIT_CEILING_HOLES)

    def test_a_phantom_score_does_not_spend_the_window(self):
        """A phantom padding a three-ball is not somebody playing — the same
        rule the tee-box editor has always used."""
        from core.models import Player
        from scoring.models import HoleScore
        ghost = Player.objects.create(
            account=self.round.account, name='Ghost', short_name='Gho',
            handicap_index=0, is_phantom=True)
        self.fs.memberships.create(player=ghost, tee=self.tee,
                                   course_handicap=0, playing_handicap=0)
        for h in range(1, 10):
            HoleScore.objects.create(foursome=self.fs, player=ghost,
                                     hole_number=h, gross_score=5)
        self.assertEqual(scored_holes(self.fs), 0)
        self.assertTrue(edits_open(self.fs))


class SequoyaPairingLockTests(_Base):
    """Sequoya had NO lock: `setup_sequoya_threes` was a bare
    `update_or_create`, so match 1's pairing could be rewritten on the 17th.

    That is worse here than in Sixes rather than better. Sequoya stores no hole
    results — all six matches are DERIVED from `match1_side1` — so a redraw
    silently re-decides the matches already settled. Nothing would look wrong;
    the money would just be different.

    Four holes suits this game particularly well: a match is three holes, so
    the window covers a complete first match and one hole of the second.
    """

    def setUp(self):
        super().setUp()
        setup_sequoya_threes(self.fs, [self.A, self.B], bet_amount=5)

    def _redraw(self):
        setup_sequoya_threes(self.fs, [self.A, self.C], bet_amount=5)

    def test_the_pairing_can_be_redrawn_before_anybody_plays(self):
        self._redraw()
        self.assertEqual(set(self.fs.sequoya_threes_game.match1_side1),
                         {self.A, self.C})

    def test_and_through_the_first_match_and_one_more(self):
        """Three holes is a whole match; the fourth is the one after it."""
        self._score_through(4)
        self._redraw()
        self.fs.refresh_from_db()
        self.assertEqual(set(self.fs.sequoya_threes_game.match1_side1),
                         {self.A, self.C})

    def test_the_fifth_scored_hole_closes_it(self):
        self._score_through(5)
        with self.assertRaises(SequoyaLocked) as ctx:
            self._redraw()
        self.assertIn('after 4 holes are scored', str(ctx.exception))

    def test_the_refused_save_leaves_the_pairing_alone(self):
        self._score_through(5)
        with self.assertRaises(SequoyaLocked):
            self._redraw()
        self.fs.refresh_from_db()
        self.assertEqual(set(self.fs.sequoya_threes_game.match1_side1),
                         {self.A, self.B})

    def test_settings_still_move_at_any_hole(self):
        """Only the pairing is locked. A TD correcting the stake, the allowance
        or the press mode is legitimate on the 17th — the same carve-out Sixes
        has, and for the same reason: no played hole changes meaning."""
        self._score_through(12)
        setup_sequoya_threes(self.fs, [self.A, self.B], bet_amount=20,
                             net_percent=90)
        self.fs.refresh_from_db()
        game = self.fs.sequoya_threes_game
        self.assertEqual(int(game.bet_amount), 20)
        self.assertEqual(game.net_percent, 90)

    def test_the_same_pairing_sent_the_other_way_round_is_not_a_change(self):
        """`[B, A]` is `[A, B]`. A side is a set of two golfers, so an
        idempotent save from a client that reordered the list must not be
        refused as a redraw."""
        self._score_through(9)
        setup_sequoya_threes(self.fs, [self.B, self.A], bet_amount=5)
        self.fs.refresh_from_db()
        self.assertEqual(set(self.fs.sequoya_threes_game.match1_side1),
                         {self.A, self.B})
