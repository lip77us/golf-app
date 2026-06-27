"""
api/test_course_quality.py
--------------------------
Tests for the course import quality gate (services/course_quality.py) and the
adapter fix that no longer fabricates per-hole data (services/golf_api_client).

The headline defect this guards against: an upstream course with no per-hole
handicap data, which the adapter used to collapse to stroke_index 18 for every
hole — silently breaking net scoring for every account that copied it.
"""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import CatalogCourse, Course
from services.course_quality import (
    CourseQualityError, assert_course_quality, validate_tee_holes,
)
from services.golf_api_client import _adapt_hole


User = get_user_model()


def _good_holes(si=None):
    si = si or list(range(1, 19))
    return [
        {'number': n, 'par': 4, 'stroke_index': si[n - 1], 'yards': 400}
        for n in range(1, 19)
    ]


def _course(tees):
    return {'id': 99, 'course_name': 'Test GC', 'tees': tees}


# ---------------------------------------------------------------------------
# Validator units (no DB)
# ---------------------------------------------------------------------------

class ValidateTeeHolesTests(TestCase):
    def test_valid_permutation_passes(self):
        self.assertEqual(validate_tee_holes(_good_holes()), [])

    def test_all_18_stroke_index_rejected(self):
        holes = [{'number': n, 'par': 4, 'stroke_index': 18, 'yards': 400}
                 for n in range(1, 19)]
        errors = validate_tee_holes(holes, label='Blue')
        self.assertTrue(any('stroke index' in e.lower() for e in errors))

    def test_duplicate_stroke_index_rejected(self):
        si = list(range(1, 19))
        si[0] = 2  # now two 2s, no 1
        self.assertTrue(validate_tee_holes(_good_holes(si)))

    def test_missing_stroke_index_rejected(self):
        holes = _good_holes()
        holes[5]['stroke_index'] = 0  # adapter sentinel for "missing"
        self.assertTrue(validate_tee_holes(holes))

    def test_bad_par_rejected(self):
        holes = _good_holes()
        holes[0]['par'] = 9
        errors = validate_tee_holes(holes)
        self.assertTrue(any('par' in e.lower() for e in errors))

    def test_wrong_hole_count_rejected(self):
        self.assertTrue(validate_tee_holes(_good_holes()[:17]))

    def test_empty_holes_is_not_an_error(self):
        # Slope/rating-only tee — gross usable, handled as a warning upstream.
        self.assertEqual(validate_tee_holes([]), [])


class AssertCourseQualityTests(TestCase):
    def test_good_course_passes_and_returns_warnings_list(self):
        warnings = assert_course_quality(_course([
            {'name': 'Blue', 'holes': _good_holes()},
        ]))
        self.assertEqual(warnings, [])

    def test_gross_only_tee_warns_not_raises(self):
        warnings = assert_course_quality(_course([
            {'name': 'Blue', 'holes': _good_holes()},
            {'name': 'Red', 'holes': []},
        ]))
        self.assertTrue(any('gross' in w.lower() for w in warnings))

    def test_no_tees_raises(self):
        with self.assertRaises(CourseQualityError):
            assert_course_quality(_course([]))

    def test_bad_si_raises_with_problems(self):
        bad = [{'number': n, 'par': 4, 'stroke_index': 18, 'yards': 400}
               for n in range(1, 19)]
        with self.assertRaises(CourseQualityError) as ctx:
            assert_course_quality(_course([{'name': 'Blue', 'holes': bad}]))
        self.assertTrue(ctx.exception.problems)


# ---------------------------------------------------------------------------
# Adapter: missing upstream data becomes a sentinel, not a fabricated value
# ---------------------------------------------------------------------------

class AdaptHoleTests(TestCase):
    def test_missing_handicap_yields_zero_sentinel_not_18(self):
        h = _adapt_hole({'par': 4}, number=3)  # no 'handicap' key
        self.assertEqual(h['stroke_index'], 0)

    def test_missing_par_yields_zero_sentinel_not_4(self):
        h = _adapt_hole({'handicap': 7}, number=3)  # no 'par' key
        self.assertEqual(h['par'], 0)

    def test_present_values_pass_through(self):
        h = _adapt_hole({'par': '5', 'handicap': '11', 'yardage': '540'}, number=3)
        self.assertEqual((h['par'], h['stroke_index'], h['yards']), (5, 11, 540))


# ---------------------------------------------------------------------------
# View: a bad import is rejected with 422 and writes nothing
# ---------------------------------------------------------------------------

class CourseImportQualityGateTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Acct A')
        self.user = User.objects.create_user(username='a', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _adapted(self, holes):
        return {
            'id': 99, 'club_name': 'Bad GC', 'course_name': 'Bad GC',
            'city': 'X', 'state': 'CA', 'country': 'US',
            'latitude': Decimal('1.0'), 'longitude': Decimal('2.0'),
            'tees': [{'name': 'Blue', 'slope': 130,
                      'course_rating': Decimal('72.1'), 'par': 72, 'sex': 'M',
                      'holes': holes}],
        }

    @patch('services.golf_api_client.fetch_course')
    def test_all_18_import_rejected_422_no_writes(self, mock_fetch):
        bad = [{'number': n, 'par': 4, 'stroke_index': 18, 'yards': 400}
               for n in range(1, 19)]
        mock_fetch.return_value = self._adapted(bad)

        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 422, resp.data)
        self.assertIn('problems', resp.data)
        # Nothing leaked into the catalog or the account.
        self.assertFalse(CatalogCourse.objects.filter(golf_api_id='99').exists())
        self.assertFalse(Course.objects.filter(account=self.account).exists())

    @patch('services.golf_api_client.fetch_course')
    def test_good_import_still_succeeds(self, mock_fetch):
        mock_fetch.return_value = self._adapted(_good_holes())
        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertTrue(CatalogCourse.objects.filter(golf_api_id='99').exists())
