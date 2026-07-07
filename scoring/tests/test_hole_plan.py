"""
scoring/tests/test_hole_plan.py
-------------------------------
services/hole_plan.py — the derived play order / holes-in-play / segment math
for partial rounds, shotgun starts, and short courses.

Defaults (18 holes from hole 1) must reproduce the classic 1..18 behavior; the
interesting cases are back-9, a shotgun start with wraparound, per-foursome
overrides, and a 9-hole course.
"""
from django.test import TestCase

from services import hole_plan as hp
from ._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
)


class HolePlanTests(TestCase):
    def _round(self, *, holes=None, num_holes=18, starting_hole=1):
        """A saved round whose course carries a tee with the given holes."""
        course = make_course()
        make_tee(course=course, holes=holes or DEFAULT_HOLES)
        r = make_round(course=course)
        r.num_holes = num_holes
        r.starting_hole = starting_hole
        r.save()
        return r

    # -- universe -----------------------------------------------------------

    def test_course_hole_count_18_and_9(self):
        self.assertEqual(hp.course_hole_count(self._round()), 18)
        short = self._round(holes=DEFAULT_HOLES[:9], num_holes=9)
        self.assertEqual(hp.course_hole_count(short), 9)

    # -- default (no-op) reproduces classic behavior ------------------------

    def test_default_round_is_1_to_18(self):
        r = self._round()
        self.assertEqual(hp.play_order(r), list(range(1, 19)))
        self.assertEqual(hp.holes_in_play(r), set(range(1, 19)))

    # -- partial rounds -----------------------------------------------------

    def test_back_nine(self):
        r = self._round(starting_hole=10, num_holes=9)
        self.assertEqual(hp.play_order(r), list(range(10, 19)))
        self.assertEqual(hp.holes_in_play(r), set(range(10, 19)))

    def test_partial_wraps_around(self):
        # Start on 17, play 9 → 17,18,1,2,3,4,5,6,7
        r = self._round(starting_hole=17, num_holes=9)
        self.assertEqual(hp.play_order(r), [17, 18, 1, 2, 3, 4, 5, 6, 7])

    def test_nine_hole_course_played_once(self):
        r = self._round(holes=DEFAULT_HOLES[:9], num_holes=9)
        self.assertEqual(hp.play_order(r), list(range(1, 10)))

    def test_num_holes_capped_at_course_size(self):
        # A 9-hole course with a stale num_holes=18 never invents holes 10-18.
        r = self._round(holes=DEFAULT_HOLES[:9], num_holes=18)
        self.assertEqual(hp.play_order(r), list(range(1, 10)))

    # -- shotgun (round-level start) ----------------------------------------

    def test_shotgun_start_wraps_full_18(self):
        r = self._round(starting_hole=8, num_holes=18)
        self.assertEqual(
            hp.play_order(r),
            [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 6, 7],
        )
        # Everyone still plays all 18 — the SET is unchanged, only the order.
        self.assertEqual(hp.holes_in_play(r), set(range(1, 19)))

    # -- per-foursome override (the shotgun field) --------------------------

    def test_foursome_starting_hole_overrides_round(self):
        r = self._round(starting_hole=1, num_holes=18)
        fs = make_foursome(r, [('Amy', 10), ('Bob', 12)])
        fs.starting_hole = 8
        fs.save()
        self.assertEqual(hp.effective_start(r, fs), 8)
        self.assertEqual(hp.play_order(r, fs)[0], 8)
        # A foursome with no override inherits the round's start.
        fs2 = make_foursome(r, [('Cyd', 8), ('Dan', 6)], group_number=2)
        self.assertEqual(hp.effective_start(r, fs2), 1)

    # -- segments follow PLAY ORDER, not hole number ------------------------

    def test_segment_halves_default(self):
        r = self._round()
        front, back = hp.segment(r, None, 2)
        self.assertEqual(front, list(range(1, 10)))
        self.assertEqual(back, list(range(10, 19)))

    def test_segment_thirds_shotgun_start_8(self):
        # Paul's confirmed example: start on 8, Sixes segments are 8-13/14-1/2-7.
        r = self._round(starting_hole=8, num_holes=18)
        s1, s2, s3 = hp.segment(r, None, 3)
        self.assertEqual(s1, [8, 9, 10, 11, 12, 13])
        self.assertEqual(s2, [14, 15, 16, 17, 18, 1])
        self.assertEqual(s3, [2, 3, 4, 5, 6, 7])

    def test_segment_halves_shotgun_start_8(self):
        # OUT = first nine played (8-16), IN = last nine played (17-7).
        r = self._round(starting_hole=8, num_holes=18)
        out, inn = hp.segment(r, None, 2)
        self.assertEqual(out, [8, 9, 10, 11, 12, 13, 14, 15, 16])
        self.assertEqual(inn, [17, 18, 1, 2, 3, 4, 5, 6, 7])
