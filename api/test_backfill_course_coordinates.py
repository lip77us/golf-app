"""backfill_course_coordinates: fills only NULLs, one lookup per distinct id."""
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.test import TestCase

from accounts.models import Account
from core.models import CatalogCourse, Course


def _run(fetch, *args):
    out = StringIO()
    with mock.patch('services.golf_api_client.fetch_course', side_effect=fetch):
        call_command('backfill_course_coordinates', *args, stdout=out, stderr=StringIO())
    return out.getvalue()


class BackfillTests(TestCase):
    def setUp(self):
        self.a = Account.objects.create(name='A')
        self.b = Account.objects.create(name='B')

    def _course(self, acct, name, api, lat=None, lon=None):
        return Course.objects.create(account=acct, name=name, golf_api_id=api,
                                     latitude=lat, longitude=lon)

    def test_dry_run_writes_nothing(self):
        c = self._course(self.a, 'Tilden', 'tq1')
        out = _run(lambda i: {'latitude': 37.9, 'longitude': -122.2})
        c.refresh_from_db()
        self.assertIsNone(c.latitude)
        self.assertIn('dry run', out)

    def test_apply_fills_every_copy_and_the_catalog_with_one_lookup(self):
        c1 = self._course(self.a, 'Tilden', 'tq1')
        c2 = self._course(self.b, 'Tilden', 'tq1')
        cat = CatalogCourse.objects.create(golf_api_id='tq1', name='Tilden')
        calls = []
        _run(lambda i: calls.append(i) or {'latitude': 37.9, 'longitude': -122.2},
             '--apply')
        self.assertEqual(calls, ['tq1'])           # ONE call for three rows
        for o in (c1, c2, cat):
            o.refresh_from_db()
            self.assertEqual(float(o.latitude), 37.9)

    def test_a_point_already_there_is_never_touched(self):
        c = self._course(self.a, 'Hand', 'h1', lat=1.5, lon=2.5)
        calls = []
        _run(lambda i: calls.append(i) or {'latitude': 9, 'longitude': 9}, '--apply')
        c.refresh_from_db()
        self.assertEqual(float(c.latitude), 1.5)
        self.assertEqual(calls, [])                # not even looked up

    def test_a_course_with_no_api_id_has_nothing_to_look_up(self):
        Course.objects.create(account=self.a, name='Pasted')
        calls = []
        _run(lambda i: calls.append(i) or {}, '--apply')
        self.assertEqual(calls, [])

    def test_zero_zero_is_a_missing_geocode_not_a_place(self):
        c = self._course(self.a, 'Nowhere', 'z1')
        _run(lambda i: {'latitude': 0, 'longitude': 0}, '--apply')
        c.refresh_from_db()
        self.assertIsNone(c.latitude)

    def test_one_failed_lookup_does_not_stop_the_rest(self):
        bad = self._course(self.a, 'Bad', 'bad')
        ok = self._course(self.a, 'Good', 'good')

        def fetch(i):
            if i == 'bad':
                raise RuntimeError('boom')
            return {'latitude': 10.0, 'longitude': 20.0}
        out = _run(fetch, '--apply')
        bad.refresh_from_db(); ok.refresh_from_db()
        self.assertIsNone(bad.latitude)
        self.assertEqual(float(ok.latitude), 10.0)
        self.assertIn('1 lookups failed', out)

    def test_limit_caps_the_lookups(self):
        for n in range(4):
            self._course(self.a, f'C{n}', f'id{n}')
        calls = []
        _run(lambda i: calls.append(i) or {'latitude': 1, 'longitude': 1},
             '--apply', '--limit', '2')
        self.assertEqual(len(calls), 2)
