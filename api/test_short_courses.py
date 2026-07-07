"""
api/test_short_courses.py
-------------------------
Short-course (9-hole) storage — Phase 1 of docs/hole-flexibility.md.

The import quality gate (services/course_quality.py) and the manual paste parser
(services/course_paste.py) must accept a 9-hole course (SI a permutation of 1..9,
total par scaled to ~half) while still rejecting odd counts (13/19 — deferred).
"""
from django.test import TestCase

from services.course_quality import (
    assert_course_quality, validate_tee_holes,
)
from services.course_paste import CoursePasteError, parse_single_tee_holes


def _holes(n, si=None):
    si = si or list(range(1, n + 1))
    return [{'number': i, 'par': 4, 'stroke_index': si[i - 1], 'yards': 400}
            for i in range(1, n + 1)]


class ShortCourseQualityGateTests(TestCase):
    def test_valid_9_hole_passes(self):
        self.assertEqual(validate_tee_holes(_holes(9)), [])

    def test_18_hole_still_passes(self):
        self.assertEqual(validate_tee_holes(_holes(18)), [])

    def test_9_hole_duplicate_si_rejected(self):
        si = list(range(1, 10))
        si[0] = 2  # two 2s, no 1
        self.assertTrue(validate_tee_holes(_holes(9, si)))

    def test_odd_hole_count_rejected(self):
        # 13-hole course (Bandon Preserve) — deferred, so rejected for now.
        errors = validate_tee_holes(_holes(13))
        self.assertTrue(any('9 or 18' in e for e in errors))

    def test_assert_quality_accepts_9_hole_course(self):
        warnings = assert_course_quality(
            {'id': 1, 'course_name': 'Short GC',
             'tees': [{'name': 'White', 'holes': _holes(9)}]})
        self.assertEqual(warnings, [])

    def test_9_hole_par_band_is_scaled(self):
        # 9 par-3s = total 27, below the scaled ~31 floor for 9 holes -> rejected
        # (consistent with the 18-hole band rejecting a par-3 course; executive
        # courses are out of scope).
        holes = [{'number': i, 'par': 3, 'stroke_index': i, 'yards': 150}
                 for i in range(1, 10)]
        self.assertTrue(
            any('total par' in e.lower() for e in validate_tee_holes(holes)))


class ShortCoursePasteTests(TestCase):
    def _card(self, n):
        return '\n'.join(f'{i} 4 {i} 400' for i in range(1, n + 1))

    def test_9_hole_paste_parses(self):
        holes = parse_single_tee_holes(self._card(9))
        self.assertEqual(len(holes), 9)
        self.assertEqual(sorted(h['stroke_index'] for h in holes),
                         list(range(1, 10)))

    def test_18_hole_paste_still_parses(self):
        self.assertEqual(len(parse_single_tee_holes(self._card(18))), 18)

    def test_odd_count_paste_rejected(self):
        with self.assertRaises(CoursePasteError):
            parse_single_tee_holes(self._card(13))
