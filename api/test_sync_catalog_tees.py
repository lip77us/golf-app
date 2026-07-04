"""
api/test_sync_catalog_tees.py
-----------------------------
The `sync_catalog_tees` command must reconcile a tee's RATING (slope / course
rating / total par), not just its hole geometry — the common drift is a
corrected slope with identical holes (e.g. Metro women's Gold 114 → 116). The
dry-run must REPORT it (so the operator knows to --apply), and --apply must
push it onto the account copies in place.
"""
from decimal import Decimal
from io import StringIO

from django.core.management import call_command
from django.test import TestCase

from accounts.models import Account
from core.models import CatalogCourse, CatalogTee, Course, Tee


def _holes():
    # A valid 18-hole card (stroke index a permutation of 1..18).
    pars = [4, 4, 5, 4, 3, 5, 3, 4, 4, 5, 4, 3, 4, 4, 3, 4, 5, 4]
    return [{'number': i + 1, 'par': pars[i], 'stroke_index': i + 1,
             'yards': 350 + i} for i in range(18)]


class SyncCatalogTeesRatingTests(TestCase):
    def setUp(self):
        self.holes = _holes()
        self.cc = CatalogCourse.objects.create(
            name='Metropolitan', golf_api_id='SYNC-TEST')
        # Master: women's Gold at the CORRECTED slope 116.
        self.ct = CatalogTee.objects.create(
            catalog_course=self.cc, tee_name='GOLD', sex='W',
            slope=116, course_rating=Decimal('69.4'), par=72,
            holes=self.holes, default_sort_priority=30)

        # An account copy that drifted to slope 114 — SAME holes.
        self.account = Account.objects.create(name='Paul')
        self.course = Course.objects.create(
            account=self.account, name='Metropolitan', golf_api_id='SYNC-TEST')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='GOLD', sex='W',
            slope=114, course_rating=Decimal('69.4'), par=72,
            holes=self.holes, sort_priority=30)

    def _run(self, *args):
        out = StringIO()
        call_command('sync_catalog_tees', '--golf-api-id', 'SYNC-TEST',
                     *args, stdout=out)
        return out.getvalue()

    def test_dry_run_reports_rating_change_not_unchanged(self):
        output = self._run()
        self.assertIn('re-rate', output)
        self.assertIn('slope 114→116', output)
        self.assertIn('slope/rating-corrected', output)
        # Dry-run writes nothing.
        self.tee.refresh_from_db()
        self.assertEqual(self.tee.slope, 114)

    def test_apply_pushes_rating_to_account_copy(self):
        self._run('--apply')
        self.tee.refresh_from_db()
        self.assertEqual(self.tee.slope, 116)
        self.assertEqual(self.tee.course_rating, Decimal('69.4'))
        # Still the same (current) row — no needless revision for a rating-only
        # change with identical holes.
        self.assertIsNone(self.tee.superseded_by_id)

    def test_no_change_when_identical(self):
        self.tee.slope = 116
        self.tee.save(update_fields=['slope'])
        output = self._run()
        self.assertIn('1 unchanged', output)
        self.assertIn('0 slope/rating-corrected', output)
        self.assertNotIn('→', output)  # no rating-change arrows anywhere
