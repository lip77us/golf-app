"""
api/test_backfill_coordinates.py
--------------------------------
`backfill_course_coords` — fills in lat/lon on courses imported before
`_adapt_course_detail` kept them.

The command shipped as `9ea32fc wip: backfill command` with **no tests**,
which is why these exist. The invariants worth pinning are the ones that
fail SILENTLY: writing a column it should not, paying for the same lookup
twice, and accepting a coordinate that is not a place.
"""

from decimal import Decimal
from io import StringIO
from unittest.mock import patch

from django.core.management import call_command
from django.test import TestCase

from accounts.models import Account
from core.models import CatalogCourse, Course, Tee


def _detail(cid, lat, lng):
    """What fetch_course returns — note it carries TEES, which is exactly
    what this command must not write."""
    return {
        'id': cid, 'club_name': 'Pebble Beach', 'course_name': '',
        'city': 'Pebble Beach', 'state': 'CA', 'country': 'USA',
        'latitude': lat, 'longitude': lng,
        'tees': [{'name': 'Blue', 'sex': 'M', 'rating': 72.1, 'slope': 135,
                  'par': 72, 'holes': [{'number': n, 'par': 4,
                                        'stroke_index': n, 'yards': 400}
                                       for n in range(1, 19)]}],
    }


class BackfillCoordinatesTests(TestCase):

    def setUp(self):
        self.account = Account.objects.create(name='Backfill Acct')
        self.course = Course.objects.create(
            account=self.account, name='Pebble Beach', golf_api_id='99',
            city='Pebble Beach', state='CA')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='Blue', sex='M',
            course_rating=Decimal('72.1'), slope=135, par=72,
            holes=[{'number': n, 'par': 3, 'stroke_index': n, 'yards': 150}
                   for n in range(1, 19)])

    def _run(self, *args):
        out = StringIO()
        call_command('backfill_course_coords', *args, stdout=out, stderr=out)
        return out.getvalue()

    @patch('services.golf_api_client.fetch_course')
    def test_a_dry_run_calls_the_api_and_writes_nothing(self, mock_fetch):
        mock_fetch.return_value = _detail('99', 36.5683, -121.95)
        out = self._run()
        self.course.refresh_from_db()
        self.assertIsNone(self.course.latitude)
        self.assertIn('Dry run', out)
        self.assertIn('Re-run with --apply', out)

    @patch('services.golf_api_client.fetch_course')
    def test_apply_writes_the_position(self, mock_fetch):
        mock_fetch.return_value = _detail('99', 36.5683, -121.95)
        self._run('--apply')
        self.course.refresh_from_db()
        self.assertEqual(self.course.latitude, Decimal('36.568300'))
        self.assertEqual(self.course.longitude, Decimal('-121.950000'))

    @patch('services.golf_api_client.fetch_course')
    def test_it_never_touches_the_tees(self, mock_fetch):
        """fetch_course returns the whole course. Writing any of the rest
        would run into the copy-on-write tee rules and could supersede a tee
        that rounds have already been scored against."""
        mock_fetch.return_value = _detail('99', 36.5683, -121.95)
        before = self.tee.holes
        self._run('--apply')
        self.tee.refresh_from_db()
        self.assertEqual(self.tee.holes, before)
        self.assertEqual(Tee.objects.filter(course=self.course).count(), 1)
        # ...and no revision was spawned.
        self.assertIsNone(self.tee.superseded_by)

    @patch('services.golf_api_client.fetch_course')
    def test_one_lookup_serves_every_clone_of_the_same_course(self, mock_fetch):
        """Copy-on-add means several accounts own the same course under one
        golf_api_id. Paying per ROW would buy the same answer repeatedly."""
        other = Account.objects.create(name='Other Acct')
        Course.objects.create(account=other, name='Pebble Beach',
                              golf_api_id='99', city='Pebble Beach')
        CatalogCourse.objects.create(golf_api_id='99', name='Pebble Beach',
                                     city='Pebble Beach')
        mock_fetch.return_value = _detail('99', 36.5683, -121.95)

        out = self._run('--apply')
        self.assertEqual(mock_fetch.call_count, 1, 'should be one lookup')
        self.assertEqual(
            Course.objects.filter(golf_api_id='99')
                          .exclude(latitude=None).count(), 2)
        self.assertEqual(
            CatalogCourse.objects.filter(golf_api_id='99')
                                 .exclude(latitude=None).count(), 1)
        self.assertIn('1 distinct course', out)

    @patch('services.golf_api_client.fetch_course')
    def test_a_course_upstream_cannot_place_is_reported_not_written(self, mock_fetch):
        mock_fetch.return_value = _detail('99', None, None)
        out = self._run('--apply')
        self.course.refresh_from_db()
        self.assertIsNone(self.course.latitude)
        self.assertIn('NO COORDS', out)

    @patch('services.golf_api_client.fetch_course')
    def test_zero_zero_is_a_defaulted_value_not_a_golf_course(self, mock_fetch):
        mock_fetch.return_value = _detail('99', 0, 0)
        self._run('--apply')
        self.course.refresh_from_db()
        self.assertIsNone(self.course.latitude)

    @patch('services.golf_api_client.fetch_course')
    def test_an_impossible_latitude_is_refused(self, mock_fetch):
        mock_fetch.return_value = _detail('99', 150.0, -121.95)
        self._run('--apply')
        self.course.refresh_from_db()
        self.assertIsNone(self.course.latitude)

    @patch('services.golf_api_client.fetch_course',
           side_effect=RuntimeError('upstream down'))
    def test_one_failed_lookup_does_not_stop_the_rest(self, mock_fetch):
        Course.objects.create(account=self.account, name='Spyglass',
                              golf_api_id='200', city='Pebble Beach')
        out = self._run('--apply')
        self.assertEqual(mock_fetch.call_count, 2, 'kept going after the first')
        self.assertIn('2 could not be', out)

    @patch('services.golf_api_client.fetch_course')
    def test_limit_bounds_what_a_run_spends(self, mock_fetch):
        for i in range(5):
            Course.objects.create(account=self.account, name=f'C{i}',
                                  golf_api_id=str(300 + i))
        mock_fetch.return_value = _detail('x', 36.5, -121.9)
        self._run('--apply', '--limit', '2')
        self.assertEqual(mock_fetch.call_count, 2)

    @patch('services.golf_api_client.fetch_course')
    def test_a_course_that_already_has_a_position_is_never_looked_up(self, mock_fetch):
        self.course.latitude = Decimal('36.568300')
        self.course.longitude = Decimal('-121.950000')
        self.course.save(update_fields=['latitude', 'longitude'])
        out = self._run()
        mock_fetch.assert_not_called()
        self.assertIn('Nothing to backfill', out)

    @patch('services.golf_api_client.fetch_course')
    def test_blank_text_fields_are_FILLED_but_never_overwritten(self, mock_fetch):
        """A club may have corrected its own city; a coordinate backfill has
        no business undoing that. Blanks get filled, values are left."""
        self.course.city = 'Carmel'          # already set, must survive
        self.course.state = ''               # blank, should fill
        self.course.save(update_fields=['city', 'state'])
        mock_fetch.return_value = _detail('99', 36.5683, -121.95)
        self._run('--apply')
        self.course.refresh_from_db()
        self.assertEqual(self.course.city, 'Carmel')
        self.assertEqual(self.course.state, 'CA')

    @patch('services.golf_api_client.fetch_course')
    def test_the_catalog_gets_the_position_too(self, mock_fetch):
        """So the next account to clone this course starts with it and never
        needs this command at all."""
        cat = CatalogCourse.objects.create(golf_api_id='99', name='Pebble Beach')
        mock_fetch.return_value = _detail('99', 36.5683, -121.95)
        self._run('--apply')
        cat.refresh_from_db()
        self.assertEqual(cat.latitude, Decimal('36.568300'))

    @patch('services.golf_api_client.fetch_course')
    def test_a_hand_pasted_course_is_left_alone(self, mock_fetch):
        """No golf_api_id means no upstream to ask. It is not a failure and
        must not be counted as one."""
        self.course.delete()
        Course.objects.create(account=self.account, name='Muni', golf_api_id='')
        out = self._run()
        mock_fetch.assert_not_called()
        self.assertIn('Nothing to backfill', out)
