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

from services.edit_window import (EDIT_CEILING_HOLES, ceiling_for,
                                  edits_open, scored_holes)
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

    def test_the_ceiling_is_three(self):
        """Written down once. A 3 repeated in each service is how eleven games
        end up with eleven rules again.

        Three, not four, and the reason pins it rather than a feel for it:
        three scored holes is exactly one complete Sequoya match, and match 2
        has not been set. A window reaching hole 4 would redraw a pairing the
        second match was already being played under."""
        self.assertEqual(EDIT_CEILING_HOLES, 3)

    def test_it_counts_holes_not_rows(self):
        """A group is through 3 when three holes are in, whether that is three
        golfers on them or four."""
        self._score_through(3)
        self.assertEqual(scored_holes(self.fs), 3)

    def test_open_through_the_third_and_closed_on_the_fourth(self):
        self.assertTrue(edits_open(self.fs))
        self._score_through(3)
        self.assertTrue(edits_open(self.fs), 'the third hole is inside')
        self._score_through(4)
        self.assertFalse(edits_open(self.fs))

    def test_the_bound_is_the_rewrite_it_permits(self):
        """Three scored holes is three holes per golfer to rewrite, never
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

    def test_and_through_the_whole_first_match(self):
        """Three holes IS match 1. This is the boundary the number was chosen
        for: at three, match 2 has not been set, so redrawing the pairing
        cannot change a match already being played."""
        self._score_through(3)
        self._redraw()
        self.fs.refresh_from_db()
        self.assertEqual(set(self.fs.sequoya_threes_game.match1_side1),
                         {self.A, self.C})

    def test_the_first_hole_of_match_two_closes_it(self):
        """Hole 4 is match 2's first, and scoring it is what shuts the
        window — the two facts are the same fact."""
        self._score_through(4)
        with self.assertRaises(SequoyaLocked) as ctx:
            self._redraw()
        self.assertIn('after the first 3 holes', str(ctx.exception))

    def test_the_refused_save_leaves_the_pairing_alone(self):
        self._score_through(4)
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


class BankerZeroWindowTests(TestCase):
    """Banker gets no window at all.

    A game may lock EARLIER than the ceiling and never later, and one game
    does. Every Banker hole is a separately negotiated bet, priced against the
    strokes in play at the moment it is struck — so a bet made on the 1st
    cannot survive its inputs changing on the 2nd. There is no interval in
    which a correction is free, because the first hole has already been bought.
    Paul, 12 Sep: before any holes are scored, and not after.

    Distinct from `BankerLocked`, which is a hole's BETTING window closing.
    """

    def setUp(self):
        from services.banker import setup_banker
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['banker'])
        self.round.primary_game = 'banker'
        self.round.save(update_fields=['primary_game'])
        self.fs = make_foursome(
            self.round, [('Paul', 8), ('Dave', 14), ('Sam', 2), ('Lee', 8)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     min_bet=5, max_bet=50)

    def _score_one(self):
        submit_hole(self.fs, 1, [(self.pid['Paul'], 4), (self.pid['Dave'], 5),
                                 (self.pid['Sam'], 4), (self.pid['Lee'], 6)])

    def test_the_window_is_zero_not_the_shared_three(self):
        self.assertEqual(ceiling_for(self.fs), 0)
        self.assertNotEqual(ceiling_for(self.fs), EDIT_CEILING_HOLES)

    def test_open_before_a_hole_is_scored(self):
        self.assertTrue(edits_open(self.fs))

    def test_shut_by_the_first_scored_hole(self):
        """Where every other game would still have two holes of room."""
        self._score_one()
        self.assertEqual(scored_holes(self.fs), 1)
        self.assertFalse(edits_open(self.fs))

    def test_the_banker_can_still_be_changed_before_anybody_plays(self):
        from services.banker import setup_banker
        setup_banker(self.fs, first_banker_id=self.pid['Dave'],
                     min_bet=5, max_bet=50)
        self.fs.refresh_from_db()
        self.assertEqual(self.fs.banker_game.first_banker_id, self.pid['Dave'])

    def test_changing_who_banks_is_refused_once_a_hole_is_scored(self):
        from services.banker import BankerSetupLocked, setup_banker
        self._score_one()
        with self.assertRaises(BankerSetupLocked) as ctx:
            setup_banker(self.fs, first_banker_id=self.pid['Dave'],
                         min_bet=5, max_bet=50)
        self.assertIn('once a hole is scored', str(ctx.exception))
        self.fs.refresh_from_db()
        self.assertEqual(self.fs.banker_game.first_banker_id, self.pid['Paul'])

    def test_changing_the_strokes_is_refused_too(self):
        """The bet was priced against them."""
        from services.banker import BankerSetupLocked, setup_banker
        self._score_one()
        with self.assertRaises(BankerSetupLocked):
            setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                         min_bet=5, max_bet=50, handicap_mode='gross')

    def test_the_wager_band_still_moves(self):
        """It governs bets not yet struck, so raising the ceiling mid-round
        re-prices nothing. Locking it would be strictness for its own sake."""
        from services.banker import setup_banker
        self._score_one()
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     min_bet=10, max_bet=100)
        self.fs.refresh_from_db()
        self.assertEqual(int(self.fs.banker_game.max_bet), 100)

    def test_an_idempotent_re_post_is_not_a_change(self):
        """The setup screen saving the same values back must not 400."""
        from services.banker import setup_banker
        self._score_one()
        setup_banker(self.fs, first_banker_id=self.pid['Paul'],
                     min_bet=5, max_bet=50)

    def test_a_round_without_banker_keeps_the_shared_ceiling(self):
        other = make_foursome(make_round(self.tee.course),
                              [('Ann', 0), ('Ben', 0)], tee=self.tee)
        self.assertEqual(ceiling_for(other), EDIT_CEILING_HOLES)
