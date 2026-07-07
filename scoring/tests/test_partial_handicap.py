"""
scoring/tests/test_partial_handicap.py
--------------------------------------
Phase 2c — handicap allocation on a PARTIAL round (scoring.handicap.make_strokes_fn):
scale the handicap to the holes played and re-rank by SI within them (WHS 9-hole
style). A full round reduces to the standard 18-hole allocation.
"""
from django.test import TestCase

from scoring.handicap import _strokes_on_hole, make_strokes_fn
from ._helpers import DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee


class PartialHandicapTests(TestCase):
    def _round(self, *, num_holes, starting_hole, hcp):
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)   # 18-hole course
        r = make_round(course=course)
        r.num_holes = num_holes
        r.starting_hole = starting_hole
        r.save()
        fs = make_foursome(r, [('Amy', hcp)], tee=tee)       # playing_handicap = hcp
        return fs, fs.memberships.first()

    def test_full_round_matches_standard_allocation(self):
        fs, m = self._round(num_holes=18, starting_hole=1, hcp=7)
        fn = make_strokes_fn(fs)
        for h in range(1, 19):
            si = m.tee.hole(h)['stroke_index']
            self.assertEqual(fn(7, m.tee, h), _strokes_on_hole(7, si))

    def test_back_nine_scales_and_reranks(self):
        # Back 9 (holes 10–18) of an 18-hole course, playing handicap 7.
        # Scaled: round(7 * 9/18) = 4 strokes, allocated to the 4 HARDEST holes
        # played by SI (SI 2,4,6,8 = holes 14,11,18,10). The unscaled 18-hole
        # allocation would put only 3 on the back nine (SI ≤ 7 that are even).
        fs, m = self._round(num_holes=9, starting_hole=10, hcp=7)
        fn = make_strokes_fn(fs)
        strokes = {h: fn(7, m.tee, h) for h in range(1, 19)}

        self.assertEqual(sum(strokes.values()), 4)                    # scaled total
        self.assertEqual(sum(strokes[h] for h in range(1, 10)), 0)    # front 9 not in play
        self.assertEqual({h for h, s in strokes.items() if s > 0},
                         {10, 11, 14, 18})                            # hardest 4 played

    def test_membership_method_is_partial_aware_with_hole_number(self):
        # The stored per-hole strokes (submit + scorecard) go through
        # FoursomeMembership.handicap_strokes_on_hole — passing hole_number makes
        # it partial-aware; omitting it keeps the legacy full-18 formula.
        fs, m = self._round(num_holes=9, starting_hole=10, hcp=7)
        si10 = m.tee.hole(10)['stroke_index']            # SI 8
        # Partial: hole 10 is among the hardest 4 played → 1 stroke.
        self.assertEqual(m.handicap_strokes_on_hole(si10, 10), 1)
        # Legacy (no hole_number): full-18 formula → SI 8 > 7 → 0.
        self.assertEqual(m.handicap_strokes_on_hole(si10), 0)

    def test_high_handicap_gets_multiple_strokes_per_hole(self):
        # Playing handicap 30 on the back 9 → round(30*9/18)=15 over 9 holes:
        # one each + an extra on the six hardest → totals 15.
        fs, m = self._round(num_holes=9, starting_hole=10, hcp=30)
        fn = make_strokes_fn(fs)
        strokes = {h: fn(30, m.tee, h) for h in range(1, 19)}
        self.assertEqual(sum(strokes.values()), 15)
        self.assertEqual(strokes[14], 2)   # SI 2 (hardest played) gets 2
        self.assertEqual(strokes[16], 1)   # SI 18 (easiest played) gets 1
