"""
api/test_courses_near.py
------------------------
`GET /api/courses/find/?near=home` — courses ranked by distance from the
golfer's own home course.

**Slice 1 of "courses near me".** The anchor is a COURSE, never the device:
the app asks for no location permission and declares none, and a `?near=me`
taking coordinates would carry an App Privacy declaration, a privacy-policy
rewrite and a Play Data-safety update with it. The tests below pin that the
only way in is `near=home`.
"""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import CatalogCourse, Course, Player
from services.geo import haversine_miles

User = get_user_model()

#: Pebble Beach, and three real neighbours at known distances.
PEBBLE   = (Decimal('36.568300'), Decimal('-121.950000'))
SPYGLASS = (Decimal('36.580600'), Decimal('-121.964600'))   # ~1.2 mi
POPPY    = (Decimal('36.573000'), Decimal('-121.936000'))   # ~0.8 mi
SFO      = (Decimal('37.621300'), Decimal('-122.379000'))   # ~85 mi, out of range


def _api_row(cid, name, distance, city='Pebble Beach'):
    """A `courses_near` row — an adapted summary plus `distance`."""
    return {'id': cid, 'club_name': name, 'course_name': '',
            'city': city, 'state': 'CA', 'country': 'USA',
            'distance': distance}


class CoursesNearHomeTests(TestCase):

    def setUp(self):
        self.account = Account.objects.create(name='Near Acct')
        self.user = User.objects.create_user(username='nearby', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        self.home = Course.objects.create(
            account=self.account, name='Pebble Beach', golf_api_id='99',
            city='Pebble Beach', state='CA',
            latitude=PEBBLE[0], longitude=PEBBLE[1],
        )
        self.player = Player.objects.create(
            account=self.account, name='Paul Avery', short_name='PA',
            handicap_index=Decimal('9.4'), user=self.user,
            home_course=self.home,
        )
        self.url = reverse('api-course-find')

    # ---------------------------------------------------------------- anchor

    def test_no_home_course_explains_itself_instead_of_erroring(self):
        """A picker that throws is worse than one that is empty."""
        self.player.home_course = None
        self.player.save(update_fields=['home_course'])
        r = self.client.get(self.url, {'near': 'home'})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['courses'], [])
        self.assertIsNone(r.data['anchor'])
        self.assertIn('home course', r.data['detail'].lower())

    def test_a_home_course_with_no_coordinates_says_so(self):
        """A pasted course has no lat/lng, which is a different problem from
        having no home course and needs a different sentence."""
        self.home.latitude = self.home.longitude = None
        self.home.save(update_fields=['latitude', 'longitude'])
        r = self.client.get(self.url, {'near': 'home'})
        self.assertEqual(r.status_code, 200)
        self.assertIsNone(r.data['anchor'])
        self.assertIn('no map position', r.data['detail'])

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_the_anchor_names_the_course_and_the_radius(self, _m):
        r = self.client.get(self.url, {'near': 'home', 'radius': '12'})
        self.assertEqual(r.data['anchor'],
                         {'course_id': self.home.id, 'name': 'Pebble Beach',
                          'radius_miles': 12, 'coarse': False})

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_the_radius_is_clamped_to_what_the_api_accepts(self, _m):
        """50 is the API's ceiling, so a bigger number is a 4xx that costs
        the same quota as a request that works."""
        r = self.client.get(self.url, {'near': 'home', 'radius': '999'})
        self.assertEqual(r.data['anchor']['radius_miles'], 50)
        r = self.client.get(self.url, {'near': 'home', 'radius': 'banana'})
        self.assertEqual(r.data['anchor']['radius_miles'], 25)

    # ----------------------------------------------------------------- merge

    @patch('services.golf_api_client.courses_near')
    def test_all_three_sources_merge_and_sort_by_distance(self, mock_near):
        Course.objects.create(
            account=self.account, name='Poppy Hills', golf_api_id='101',
            city='Pebble Beach', state='CA',
            latitude=POPPY[0], longitude=POPPY[1])
        CatalogCourse.objects.create(
            golf_api_id='200', name='Spyglass Hill', city='Pebble Beach',
            state='CA', latitude=SPYGLASS[0], longitude=SPYGLASS[1])
        mock_near.return_value = [_api_row('300', 'Cypress Point', 2.4)]

        rows = self.client.get(self.url, {'near': 'home'}).data['courses']
        by = {r['name']: r for r in rows}

        self.assertEqual(by['Pebble Beach']['source'], 'account')
        self.assertEqual(by['Poppy Hills']['source'], 'account')
        self.assertEqual(by['Spyglass Hill']['source'], 'catalog')
        self.assertEqual(by['Cypress Point']['source'], 'api')
        # Nearest first, and the home course is 0.0 from itself.
        distances = [r['distance'] for r in rows]
        self.assertEqual(distances, sorted(distances), rows)
        self.assertEqual(rows[0]['name'], 'Pebble Beach')
        self.assertEqual(by['Pebble Beach']['distance'], 0.0)
        self.assertLess(by['Poppy Hills']['distance'], by['Spyglass Hill']['distance'])

    @patch('services.golf_api_client.courses_near')
    def test_a_course_outside_the_radius_is_dropped(self, mock_near):
        mock_near.return_value = []
        CatalogCourse.objects.create(
            golf_api_id='400', name='Far Away GC', city='San Francisco',
            state='CA', latitude=SFO[0], longitude=SFO[1])
        rows = self.client.get(self.url, {'near': 'home', 'radius': '25'}).data['courses']
        self.assertNotIn('Far Away GC', [r['name'] for r in rows])
        # Still out at the 50mi ceiling, which is the point: the clamp is a
        # real limit, not a formality -- SFO is ~85mi from Pebble Beach and
        # no radius this endpoint accepts will reach it.
        rows = self.client.get(self.url, {'near': 'home', 'radius': '50'}).data['courses']
        self.assertNotIn('Far Away GC', [r['name'] for r in rows])

    @patch('services.golf_api_client.courses_near')
    def test_a_course_with_no_coordinates_is_dropped_not_ranked_first(self, mock_near):
        """None is not zero. A course we cannot place is not in the car park."""
        mock_near.return_value = []
        CatalogCourse.objects.create(
            golf_api_id='500', name='Placeless GC', city='Nowhere', state='CA')
        rows = self.client.get(self.url, {'near': 'home'}).data['courses']
        self.assertNotIn('Placeless GC', [r['name'] for r in rows])

    @patch('services.golf_api_client.courses_near')
    def test_the_api_never_duplicates_a_course_already_owned(self, mock_near):
        mock_near.return_value = [_api_row('99', 'Pebble Beach', 0.0)]
        rows = self.client.get(self.url, {'near': 'home'}).data['courses']
        self.assertEqual([r['name'] for r in rows], ['Pebble Beach'])
        self.assertEqual(rows[0]['source'], 'account')

    @patch('services.golf_api_client.courses_near',
           side_effect=RuntimeError('upstream down'))
    def test_an_upstream_failure_still_returns_local_courses(self, _m):
        """Same promise the text search makes: the picker never breaks on a
        slow or broken upstream."""
        r = self.client.get(self.url, {'near': 'home'})
        self.assertEqual(r.status_code, 200)
        self.assertEqual([x['name'] for x in r.data['courses']], ['Pebble Beach'])

    @patch('services.golf_api_client.courses_near')
    def test_a_row_with_no_distance_sorts_last_not_first(self, mock_near):
        mock_near.return_value = [_api_row('301', 'Unknown Distance GC', None),
                                  _api_row('302', 'Known GC', 3.0)]
        rows = self.client.get(self.url, {'near': 'home'}).data['courses']
        self.assertEqual(rows[-1]['name'], 'Unknown Distance GC')

    # ------------------------------------------------------- the deferral

    @patch('services.golf_api_client.courses_near')
    def test_coordinates_cannot_be_passed_in(self, mock_near):
        """Slice 2 is a deliberate decision with privacy paperwork attached.
        Until it is taken, lat/lng in the query string must do NOTHING --
        otherwise a client could ship device GPS without any of it."""
        mock_near.return_value = []
        r = self.client.get(self.url, {'near': 'home',
                                       'lat': str(SFO[0]), 'lng': str(SFO[1])})
        # Still anchored on the home course, not on what was passed.
        self.assertEqual(r.data['anchor']['course_id'], self.home.id)
        args, kwargs = mock_near.call_args
        self.assertAlmostEqual(args[0], float(PEBBLE[0]), places=4)
        self.assertAlmostEqual(args[1], float(PEBBLE[1]), places=4)

    def test_near_anything_else_falls_through_to_the_text_search(self):
        """An unrecognised `near` is a text search, not a silent proximity one.

        `near=me` IS implemented now (see `CoursesNearMeTests`); this pins
        that a typo or a future value nobody has built does not quietly
        behave like one of the two that exist.
        """
        r = self.client.get(self.url, {'near': 'somewhere'})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['courses'], [])      # no q, so the search is empty
        self.assertNotIn('anchor', r.data)


class CoursesNearMeTests(TestCase):
    """`GET /api/courses/find/?near=me&lat=&lng=` — anchored on the device.

    What is pinned here is mostly the PRIVACY shape, because that is the part
    a refactor can quietly undo: the position never reaches anything at full
    precision, and the distance is never reported finer than the anchor
    justifies. `docs/location-permission.md` is the argument.
    """

    def setUp(self):
        self.account = Account.objects.create(name='Near Me')
        self.user = User.objects.create_user(
            username='nm', password='x', account=self.account,
            is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-course-find')

        # Spyglass is ~1.2 mi from Pebble, Poppy ~0.8 mi.
        self.spy = Course.objects.create(
            account=self.account, name='Spyglass', city='Pebble Beach',
            state='CA', latitude=SPYGLASS[0], longitude=SPYGLASS[1])
        self.poppy = Course.objects.create(
            account=self.account, name='Poppy Hills', city='Pebble Beach',
            state='CA', latitude=POPPY[0], longitude=POPPY[1])

    def _get(self, **params):
        return self.client.get(self.url, {'near': 'me', **params})

    # --- the coarsening -----------------------------------------------

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_the_position_is_cut_to_two_decimals_before_it_is_used(self, mock_near):
        """The app rounds and the server rounds again.

        Rounding only on the phone would make the server's correctness depend
        on the client's — an older build or a replayed URL would hand us a
        precise position that we would measure from and forward upstream.
        """
        self._get(lat='36.5683219', lng='-121.9500777')
        args, _ = mock_near.call_args
        self.assertEqual(args[0], 36.57)
        self.assertEqual(args[1], -121.95)

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_the_upstream_never_sees_more_than_two_decimals(self, mock_near):
        """The third party is the one that matters most: it is outside our
        logs and our retention promise."""
        self._get(lat='36.568321', lng='-121.950077')
        for value in mock_near.call_args[0][:2]:
            places = len(str(abs(value)).partition('.')[2])
            self.assertLessEqual(places, 2, f'{value} carries {places} places')

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_the_anchor_says_it_is_coarse_and_names_no_course(self, _m):
        r = self._get(lat='36.57', lng='-121.95', radius='12')
        self.assertEqual(r.data['anchor'],
                         {'course_id': None, 'name': None,
                          'radius_miles': 12, 'coarse': True})

    # --- whole miles --------------------------------------------------

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_the_distance_is_a_whole_number_of_miles(self, _m):
        """A tenth would be a digit the anchor does not have."""
        rows = self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1])).data['courses']
        self.assertTrue(rows)
        for row in rows:
            self.assertIsInstance(row['distance'], int)

    @patch('services.golf_api_client.courses_near')
    def test_an_api_row_is_rounded_too(self, mock_near):
        """Upstream reports a tenth; it must not survive into our answer
        while the local rows next to it are whole."""
        mock_near.return_value = [_api_row('99', 'Bayonet', 7.4)]
        rows = self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1])).data['courses']
        api = [r for r in rows if r['source'] == 'api'][0]
        self.assertEqual(api['distance'], 7)

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_rounding_does_not_reorder_the_list(self, _m):
        """Poppy (~0.8 mi) and Spyglass (~1.2 mi) both round to 1.

        Sorting on the rounded figure would make their order arbitrary, so
        the sort runs on the real distance and the quantise happens after.
        """
        rows = self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1])).data['courses']
        names = [r['name'] for r in rows]
        self.assertEqual(names[:2], ['Poppy Hills', 'Spyglass'])
        self.assertEqual([r['distance'] for r in rows[:2]], [1, 1])

    # --- a bad request is a 400, not an empty list --------------------

    def test_a_missing_position_is_a_400(self):
        """Unlike a missing home course, which is a state the golfer is in,
        this is a client fault and an empty list would hide it."""
        self.assertEqual(self._get().status_code, 400)

    def test_an_impossible_latitude_is_a_400(self):
        """Per-coordinate ranges: a single range covering both would accept
        150, which is not a place."""
        self.assertEqual(self._get(lat='150', lng='-121.95').status_code, 400)

    def test_an_impossible_longitude_is_a_400(self):
        self.assertEqual(self._get(lat='36.57', lng='200').status_code, 400)

    def test_junk_is_a_400(self):
        self.assertEqual(self._get(lat='somewhere', lng='else').status_code, 400)

    def test_the_null_island_pair_is_a_400(self):
        """0,0 is in the Atlantic and is what a defaulted value looks like."""
        self.assertEqual(self._get(lat='0', lng='0').status_code, 400)

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_a_single_zero_is_fine(self, _m):
        """The equator and the Greenwich meridian both cross dry land."""
        self.assertEqual(self._get(lat='0', lng='-121.95').status_code, 200)

    # --- the cap ------------------------------------------------------

    @patch('services.golf_api_client.courses_near')
    def test_it_returns_at_most_ten_rows(self, mock_near):
        """The design's "top 10", trimmed from the MERGED list.

        Capping the upstream call alone would not do it: local and catalog
        rows are in the same ranking, so the real list at 25 miles runs to
        twenty-odd.
        """
        mock_near.return_value = [
            _api_row(str(900 + i), f'Course {i}', 1.0 + i * 0.3)
            for i in range(25)
        ]
        rows = self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1])).data['courses']
        self.assertEqual(len(rows), 10)

    @patch('services.golf_api_client.courses_near')
    def test_the_ten_it_keeps_are_the_NEAREST_ten(self, mock_near):
        """Trimmed after the sort, so the cap cannot drop a closer course."""
        mock_near.return_value = [
            _api_row(str(900 + i), f'Course {i}', 40.0 - i)   # farthest first
            for i in range(20)
        ]
        rows = self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1]),
                         radius='50').data['courses']
        names = [r['name'] for r in rows]
        distances = [r['distance'] for r in rows]

        self.assertEqual(distances, sorted(distances), 'not nearest-first')
        # The two local courses (~1 mi) take the first slots, so the API rows
        # that survive are its nearest — Course 19 at 21 mi in, Course 0 at
        # 40 mi out. Asserted by name rather than by a hard-coded ceiling,
        # which would move with the fixture.
        self.assertIn('Course 19', names)
        self.assertNotIn('Course 0', names)
        self.assertEqual(names[:2], ['Poppy Hills', 'Spyglass'])

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_the_upstream_is_still_asked_for_its_full_page(self, mock_near):
        """Quota is charged per REQUEST, not per row, so asking for fewer
        saves nothing and costs dedup headroom."""
        self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1]))
        _, kwargs = mock_near.call_args
        self.assertNotIn('limit', kwargs)   # the client's own default, 25

    # --- it degrades, like the search branch --------------------------

    @patch('services.golf_api_client.courses_near',
           side_effect=RuntimeError('upstream down'))
    def test_a_dead_upstream_still_returns_the_local_rows(self, _m):
        """The picker never breaks on a slow upstream — the same promise the
        text search makes."""
        r = self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1]))
        self.assertEqual(r.status_code, 200)
        self.assertEqual({row['name'] for row in r.data['courses']},
                         {'Spyglass', 'Poppy Hills'})

    @patch('services.golf_api_client.courses_near', return_value=[])
    def test_a_course_out_of_range_is_dropped(self, _m):
        Course.objects.create(account=self.account, name='Harding Park',
                              city='San Francisco', state='CA',
                              latitude=SFO[0], longitude=SFO[1])
        rows = self._get(lat=str(PEBBLE[0]), lng=str(PEBBLE[1])).data['courses']
        self.assertNotIn('Harding Park', [r['name'] for r in rows])


class CoarsePositionTests(TestCase):
    """`services.geo.coarse_position` on its own."""

    def test_it_rounds_rather_than_truncating(self):
        from services.geo import coarse_position
        self.assertEqual(coarse_position('36.5689', '-121.9499'),
                         (36.57, -121.95))

    def test_it_refuses_nan_and_infinity(self):
        from services.geo import coarse_position
        for bad in ('nan', 'inf', '-inf'):
            self.assertEqual(coarse_position(bad, '0.5'), (None, None), bad)

    def test_it_accepts_the_extremes(self):
        from services.geo import coarse_position
        self.assertEqual(coarse_position('90', '180'), (90.0, 180.0))
        self.assertEqual(coarse_position('-90', '-180'), (-90.0, -180.0))

    def test_an_empty_string_is_not_zero(self):
        from services.geo import coarse_position
        self.assertEqual(coarse_position('', '-121.95'), (None, None))


class HaversineTests(TestCase):
    """The helper the ranking rests on."""

    def test_a_known_distance(self):
        # SFO -> LAX is about 337 statute miles.
        d = haversine_miles(37.6213, -122.3790, 33.9416, -118.4085)
        self.assertAlmostEqual(d, 337.8, delta=1.0)

    def test_the_same_point_is_zero(self):
        self.assertEqual(haversine_miles(36.5683, -121.95, 36.5683, -121.95), 0.0)

    def test_missing_input_is_none_not_zero(self):
        self.assertIsNone(haversine_miles(None, -121.95, 36.57, -121.96))
        self.assertIsNone(haversine_miles(36.57, -121.95, 36.57, None))

    def test_it_takes_decimals_because_course_latitude_is_one(self):
        d = haversine_miles(Decimal('36.5683'), Decimal('-121.9500'),
                            Decimal('36.5806'), Decimal('-121.9646'))
        self.assertAlmostEqual(d, 1.17, delta=0.1)


class CoordinatesNeverReachALogTests(TestCase):
    """`_safe_url` — a position must not survive into a log or a traceback.

    The leak this closes is LATENT rather than live: the only caller today is
    `?near=home`, whose coordinates belong to a golf COURSE and are public.
    It becomes a real one the moment `?near=me` passes the device's position,
    which is why it is fixed before that ships rather than with it — the App
    Privacy and Play Data-safety answers both claim the position is not
    retained, and a log line is retention.
    """

    def test_coordinates_are_redacted(self):
        from services.golf_api_client import _safe_url
        out = _safe_url('/v1/proximity', {
            'latitude': 37.874290, 'longitude': -122.245850,
            'radius': 25, 'limit': 25,
        })
        self.assertNotIn('37.87', out)
        self.assertNotIn('122.24', out)
        self.assertIn('latitude=REDACTED', out)
        self.assertIn('longitude=REDACTED', out)

    def test_the_radius_and_limit_still_read(self):
        """Redacting the whole query string would cost the diagnostics the
        allowlist exists to keep."""
        from services.golf_api_client import _safe_url
        out = _safe_url('/v1/proximity', {'latitude': 1.5, 'longitude': 2.5,
                                          'radius': 25, 'limit': 10})
        self.assertIn('radius=25', out)
        self.assertIn('limit=10', out)

    def test_a_search_term_still_reads(self):
        """`Bridges (The)` was diagnosed from the term that was sent."""
        from services.golf_api_client import _safe_url
        out = _safe_url('/v1/search', {'search_query': 'Bridges'})
        self.assertIn('search_query=Bridges', out)

    def test_an_unknown_parameter_is_secret_by_default(self):
        """The allowlist's whole point: a denylist fails open."""
        from services.golf_api_client import _safe_url
        out = _safe_url('/v1/proximity', {'geo_hash': 'ezs42', 'radius': 5})
        self.assertNotIn('ezs42', out)
        self.assertIn('radius=5', out)

    def test_the_path_survives(self):
        from services.golf_api_client import _safe_url
        self.assertIn('/v1/courses/1234', _safe_url('/v1/courses/1234'))

    def test_the_error_message_carries_no_coordinates(self):
        """The message, not just the logger call.

        `CourseFindView` logs `traceback.format_exc()` on a proximity
        failure, so a `RuntimeError` carrying the real query string would
        print it one frame up however carefully `_get` logged.
        """
        from services import golf_api_client as gac

        def boom(*a, **kw):
            raise OSError('connection refused')

        with self.settings(GOLF_API_KEY='k'):
            with patch.object(gac.urllib.request, 'urlopen', boom):
                with self.assertRaises(RuntimeError) as caught:
                    gac.courses_near(37.874290, -122.245850, radius=25)

        import traceback
        text = ''.join(traceback.format_exception(caught.exception))
        for leak in ('37.87', '122.24', '37.8742', '122.2458'):
            self.assertNotIn(leak, text, f'{leak!r} reached the traceback')
        self.assertIn('REDACTED', str(caught.exception))

    def test_an_http_error_message_carries_no_coordinates(self):
        from urllib.error import HTTPError
        from services import golf_api_client as gac

        def boom(*a, **kw):
            raise HTTPError('https://api.golfcourseapi.com/v1/proximity'
                            '?latitude=37.874290&longitude=-122.245850',
                            400, 'Bad Request', {}, None)

        with self.settings(GOLF_API_KEY='k'):
            with patch.object(gac.urllib.request, 'urlopen', boom):
                with self.assertRaises(RuntimeError) as caught:
                    gac.courses_near(37.874290, -122.245850)

        self.assertNotIn('37.87', str(caught.exception))
        self.assertNotIn('122.24', str(caught.exception))
