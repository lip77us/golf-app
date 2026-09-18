"""
scoring/tests/test_cup_singles_shotgun.py
-----------------------------------------
Cup singles on a shotgun start.

**A cup day is very often a shotgun**, which is where this matters most — and
the scorer walked 1..18 by hole number and stopped at the first unscored hole.
A group starting on 13 with six holes in stopped at the 1st: the match reported
as not started, and as holes 1..5 came in it scored THOSE while ignoring the
six already played.

There was no test file for this service at all.
"""
from django.test import TestCase

from services.cup_singles import (setup_cup_singles, calculate_cup_singles,
                                  cup_singles_summary)
from ._helpers import make_tee, make_round, make_foursome, submit_hole


class CupSinglesShotgunTests(TestCase):

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.round.starting_hole = 13
        self.round.num_holes = 18
        self.round.save(update_fields=['starting_hole', 'num_holes'])
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 0), ('C', 0), ('D', 0)], tee=self.tee)
        self.fs.starting_hole = 13
        self.fs.save(update_fields=['starting_hole'])
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_cup_singles(
            self.fs, None, None,
            singles_matchups=[
                {'player1_id': self.pid['A'], 'player2_id': self.pid['C']},
                {'player1_id': self.pid['B'], 'player2_id': self.pid['D']},
            ])

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [(self.pid['A'], a), (self.pid['B'], b),
                                    (self.pid['C'], c), (self.pid['D'], d)])
        calculate_cup_singles(self.fs)

    def _match_a_v_c(self):
        s = cup_singles_summary(self.fs)
        return next(m for m in s['matches']
                    if {m['player1'], m['player2']} == {'A', 'C'})

    def test_the_first_six_holes_of_a_shotgun_count(self):
        """They were silently ignored: the walk began at hole 1, found no
        score, and stopped — so a match six holes old read as not started."""
        for h in (13, 14, 15, 16, 17, 18):
            self._play(h, 4, 4, 5, 5)        # A and B win every hole
        m = self._match_a_v_c()
        self.assertEqual(m['holes_played'], 6,
                         'six holes were played and six must be scored')
        self.assertEqual(m['overall_holes_up'], 6)

    def test_a_shotgun_match_can_close_out_early(self):
        """Dormie counts holes left in the GROUP's order. Ten straight wins
        from the 13th leaves eight to play, which is 10 up with 8 to go."""
        order = [13, 14, 15, 16, 17, 18, 1, 2, 3, 4]
        for h in order:
            self._play(h, 4, 4, 5, 5)
        m = self._match_a_v_c()
        self.assertEqual(m['result'], 'player1')
        self.assertEqual(m['status'], 'complete')
        self.assertEqual(m['finished_on_hole'], 4,
                         'the 10th hole PLAYED is hole 4, not hole 10')

    def test_it_does_not_close_out_while_holes_remain(self):
        """Six up with twelve to play is not over, however it looks by
        number: an 18-minus-hole-number count would call this 6 up with 12
        left on hole 6 and be right by accident, and wrong the moment the
        order wraps."""
        for h in (13, 14, 15, 16, 17, 18):
            self._play(h, 4, 4, 5, 5)
        m = self._match_a_v_c()
        self.assertNotEqual(m['status'], 'complete')

    def test_a_round_from_the_first_is_unchanged(self):
        """The shipped behaviour is the degenerate case."""
        self.round.starting_hole = 1
        self.round.save(update_fields=['starting_hole'])
        self.fs.starting_hole = 1
        self.fs.save(update_fields=['starting_hole'])
        for h in range(1, 7):
            self._play(h, 4, 4, 5, 5)
        m = self._match_a_v_c()
        self.assertEqual(m['holes_played'], 6)
        self.assertEqual(m['overall_holes_up'], 6)

    def test_the_closeout_margin_comes_from_the_server(self):
        """`3&2` is holes left in the group's own order. A client doing
        `18 - finished_on_hole` is right on a round from the 1st and wrong on
        every shotgun — so the count is computed where the order is known."""
        order = [13, 14, 15, 16, 17, 18, 1, 2, 3, 4]
        for h in order:
            self._play(h, 4, 4, 5, 5)
        m = self._match_a_v_c()
        self.assertEqual(m['finished_on_hole'], 4)
        self.assertEqual(m['holes_to_play'], 8,
                         'ten of eighteen played leaves eight, whatever the '
                         'hole is numbered')
