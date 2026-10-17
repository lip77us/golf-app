"""
api/test_roster_last_import.py
------------------------------
`GET /api/roster/last-import/` — when the roster last came from Golf Genius.

Paul, 17 Oct: "It would be nice to know in the app when the app database was
last synched with Golf Genius." The data already existed in `ImportRun`;
this is the read.
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Account
from console.models import ImportRun

User = get_user_model()


def _run(account, *, status, number=None, created=0, updated=0,
         applied_at=None, user=None, filename='roster.xlsx'):
    run = ImportRun.objects.create(
        account=account, user=user, status=status, number=number,
        filename=filename,
        result={'log': {'created': [{'id': i} for i in range(created)],
                        'updated': [{'id': i} for i in range(updated)]}},
    )
    if applied_at is not None:
        ImportRun.objects.filter(pk=run.pk).update(applied_at=applied_at)
        run.refresh_from_db()
    return run


class RosterLastImportTests(TestCase):

    def setUp(self):
        self.account = Account.objects.create(name='TPSGC')
        self.user = User.objects.create_user(username='td', account=self.account,
                                             first_name='Paul', last_name='Lipkin')
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-roster-last-import')

    def test_never_imported_is_an_answer_not_a_404(self):
        """The screen draws nothing; a 404 would read as a fault."""
        r = self.client.get(self.url)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data['synced'])

    def test_it_reports_the_latest_applied_run(self):
        now = timezone.now()
        _run(self.account, status=ImportRun.STATUS_APPLIED, number=5,
             created=1, updated=42, applied_at=now - timedelta(days=10))
        _run(self.account, status=ImportRun.STATUS_APPLIED, number=6,
             created=2, updated=72, applied_at=now, user=self.user)
        r = self.client.get(self.url)
        self.assertTrue(r.data['synced'])
        self.assertEqual(r.data['run_number'], 6)
        self.assertEqual((r.data['created'], r.data['updated']), (2, 72))
        self.assertEqual(r.data['by'], 'Paul Lipkin')

    def test_a_preview_never_applied_does_not_count(self):
        """A run the TD walked away from changed no golfer, so it is not a
        sync. `console/models.py` makes the same distinction."""
        _run(self.account, status=ImportRun.STATUS_PREVIEW, created=9, updated=9)
        self.assertFalse(self.client.get(self.url).data['synced'])

    def test_a_discarded_run_does_not_count_either(self):
        _run(self.account, status=ImportRun.STATUS_DISCARDED, number=None)
        self.assertFalse(self.client.get(self.url).data['synced'])

    def test_it_dates_from_when_the_roster_CHANGED(self):
        """A file dropped one evening and applied the next morning must not
        report the evening -- `created_at` is the upload, `applied_at` is the
        moment golfers moved."""
        now = timezone.now()
        run = _run(self.account, status=ImportRun.STATUS_APPLIED, number=1,
                   applied_at=now)
        ImportRun.objects.filter(pk=run.pk).update(
            created_at=now - timedelta(days=1))
        r = self.client.get(self.url)
        self.assertEqual(r.data['when'].date(), now.date())

    def test_a_run_with_no_applied_at_falls_back_to_created_at(self):
        """Older rows predate the column being filled; reporting nothing
        would hide a sync that really happened."""
        _run(self.account, status=ImportRun.STATUS_APPLIED, number=2)
        r = self.client.get(self.url)
        self.assertTrue(r.data['synced'])
        self.assertIsNotNone(r.data['when'])

    def test_another_account_s_import_is_not_mine(self):
        other = Account.objects.create(name='Someone Else')
        _run(other, status=ImportRun.STATUS_APPLIED, number=1,
             created=50, updated=50, applied_at=timezone.now())
        self.assertFalse(self.client.get(self.url).data['synced'])

    def test_a_run_with_no_log_reports_zeroes_rather_than_breaking(self):
        run = _run(self.account, status=ImportRun.STATUS_APPLIED, number=3,
                   applied_at=timezone.now())
        ImportRun.objects.filter(pk=run.pk).update(result={})
        r = self.client.get(self.url)
        self.assertEqual((r.data['created'], r.data['updated']), (0, 0))

    def test_an_anonymous_caller_gets_nothing(self):
        c = APIClient()
        self.assertIn(c.get(self.url).status_code, (401, 403))
