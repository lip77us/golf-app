"""
scoring/tests/test_live_activity_shotgun.py
-------------------------------------------
`holes_played` is a COUNT, and every lock-screen card depends on it.

It returned `max(hole_number)` — the same integer on a round starting at the
1st and wrong on every other shape. `hole_in_play()` consumes it as an INDEX
into play order, so the two disagreed silently and the card drew the wrong
hole, or decided the round was over.
"""
from django.test import TestCase

from services.live_activity_registry import holes_played, hole_in_play
from ._helpers import make_tee, make_round, make_foursome, submit_hole


class HolesPlayedTests(TestCase):

    def _round(self, *, start=1, num_holes=18):
        tee = make_tee()
        rnd = make_round(tee.course)
        rnd.starting_hole = start
        rnd.num_holes = num_holes
        rnd.save(update_fields=['starting_hole', 'num_holes'])
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)],
                           tee=tee)
        fs.starting_hole = start
        fs.save(update_fields=['starting_hole'])
        pids = [m.player_id for m in fs.memberships.all()]
        return tee, rnd, fs, pids

    def _play(self, fs, pids, holes):
        for h in holes:
            submit_hole(fs, h, [(p, 4) for p in pids])

    def test_a_shotgun_counts_holes_not_numbers(self):
        """Fifteen holes from the 13th returned 18 — and `order[18]` is past
        the end, so every card decided the round had finished with three holes
        still to play."""
        from services.hole_plan import play_order
        _tee, rnd, fs, pids = self._round(start=13)
        order = play_order(rnd, fs)
        self._play(fs, pids, order[:15])
        self.assertEqual(holes_played(fs), 15)
        self.assertEqual(hole_in_play(fs, holes_played(fs)), 10,
                         'the group is standing on the 10th')

    def test_a_back_nine_round_breaks_sooner(self):
        """Three holes in returned 12, and a nine-hole order has nine entries,
        so the card gave up after three holes."""
        from services.hole_plan import play_order
        _tee, rnd, fs, pids = self._round(start=10, num_holes=9)
        order = play_order(rnd, fs)
        self.assertEqual(order, [10, 11, 12, 13, 14, 15, 16, 17, 18])
        self._play(fs, pids, order[:3])
        self.assertEqual(holes_played(fs), 3)
        self.assertEqual(hole_in_play(fs, holes_played(fs)), 13)

    def test_a_round_from_the_first_is_unchanged(self):
        """The shipped behaviour is the degenerate case — the count and the
        hole number are the same integer there, which is why this survived."""
        _tee, _rnd, fs, pids = self._round()
        self._play(fs, pids, range(1, 8))
        self.assertEqual(holes_played(fs), 7)
        self.assertEqual(hole_in_play(fs, holes_played(fs)), 8)

    def test_one_golfer_running_ahead_does_not_move_it(self):
        """A card reads 'thru 7' when the GROUP is through 7."""
        _tee, _rnd, fs, pids = self._round()
        self._play(fs, pids, range(1, 5))
        submit_hole(fs, 5, [(pids[0], 4)])          # one player only
        self.assertEqual(holes_played(fs), 4)

    def test_nothing_played_is_the_first_hole_of_the_order(self):
        _tee, _rnd, fs, _pids = self._round(start=13)
        self.assertEqual(holes_played(fs), 0)
        self.assertEqual(hole_in_play(fs, 0), 13)

    def test_the_whole_round_played_has_no_hole_in_play(self):
        from services.hole_plan import play_order
        _tee, rnd, fs, pids = self._round(start=13)
        self._play(fs, pids, play_order(rnd, fs))
        self.assertEqual(holes_played(fs), 18)
        self.assertIsNone(hole_in_play(fs, 18))
