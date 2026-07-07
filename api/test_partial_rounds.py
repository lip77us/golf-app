"""
api/test_partial_rounds.py
--------------------------
End-to-end backend behavior for partial rounds (Phase 2 of
docs/hole-flexibility.md): a 9-hole round completes on its 9 holes, not 18.
Grows as later sub-slices (per-hole scoring, handicap, segment games) land.
"""
from django.test import TestCase

from api.views import RoundCompleteView
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)


class PartialRoundCompletionTests(TestCase):
    def _nine_hole_round(self):
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES[:9])
        r = make_round(course=course)
        r.num_holes = 9
        r.starting_hole = 1
        r.save()
        fs = make_foursome(r, [('Amy', 10), ('Bob', 12)])
        return r, fs

    def test_nine_hole_round_completes_on_nine(self):
        r, fs = self._nine_hole_round()
        # 8 of 9 holes scored -> not done.
        for h in range(1, 9):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertFalse(RoundCompleteView._all_foursomes_done(r))
        # Score the 9th -> done (never needs holes 10-18).
        submit_hole(fs, 9, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertTrue(RoundCompleteView._all_foursomes_done(r))

    def test_expected_holes_is_the_nine_played(self):
        r, fs = self._nine_hole_round()
        self.assertEqual(RoundCompleteView._expected_holes(fs), set(range(1, 10)))


class BackNineCompletionTests(TestCase):
    def test_back_nine_completes_on_10_to_18(self):
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES)   # full 18-hole course
        r = make_round(course=course)
        r.num_holes = 9
        r.starting_hole = 10
        r.save()
        fs = make_foursome(r, [('Amy', 10), ('Bob', 12)])
        self.assertEqual(RoundCompleteView._expected_holes(fs), set(range(10, 19)))
        for h in range(10, 19):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertTrue(RoundCompleteView._all_foursomes_done(r))
