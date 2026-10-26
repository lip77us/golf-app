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
from django.core import mail
from django.core.cache import cache
from django.test import TestCase, override_settings
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
    """A course as `fetch_course` returns it.

    Fills in rating / slope / par on any tee that does not state them: a real
    adapted tee ALWAYS carries those keys, and the gate refuses a tee with no
    course rating (a guessed one moves every handicap at the course). These
    fixtures are about the HOLE rules, so they should not trip that.
    """
    filled = []
    for t in tees:
        t = dict(t)
        t.setdefault('course_rating', 72.1)
        t.setdefault('slope', 125)
        t.setdefault('par', 72)
        filled.append(t)
    return {'id': 99, 'course_name': 'Test GC', 'tees': filled}


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
    def test_the_refusal_names_the_reason_not_just_bad_hole_data(
            self, mock_fetch):
        """A zero-tee course is reported as such.

        Annandale GC (Pasadena) comes back from GolfCourseAPI with no tees at
        all, and the old `detail` called that "invalid hole data" -- which
        sends the user looking for a data error that is not there.  The client
        shows `detail` and nothing else, so the reason has to be in it.
        """
        empty = self._adapted(_good_holes())
        empty['tees'] = []
        mock_fetch.return_value = empty

        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 422, resp.data)
        self.assertIn('no tees', resp.data['detail'])
        self.assertNotIn('invalid hole data', resp.data['detail'])
        self.assertEqual(resp.data['problems'], ['Course has no tees.'])

    @patch('services.golf_api_client.fetch_course')
    def test_several_problems_lead_with_one_and_count_the_rest(
            self, mock_fetch):
        # A tee missing its rating, slope and par gives three problems; the
        # snackbar is one line, so it leads with one and says how many more.
        bare = self._adapted(_good_holes())
        bare['tees'][0].update(course_rating=None, slope=None, par=None)
        mock_fetch.return_value = bare

        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 422, resp.data)
        self.assertEqual(len(resp.data['problems']), 3)
        self.assertIn('(+2 more)', resp.data['detail'])

    @patch('services.golf_api_client.fetch_course')
    def test_good_import_still_succeeds(self, mock_fetch):
        mock_fetch.return_value = self._adapted(_good_holes())
        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertTrue(CatalogCourse.objects.filter(golf_api_id='99').exists())


# ---------------------------------------------------------------------------
# A refusal is announced — it writes nothing, so without this it is invisible
# ---------------------------------------------------------------------------

@override_settings(COURSE_IMPORT_ALERT_EMAIL='ops@halved.golf')
class RefusalIsAnnouncedTests(TestCase):
    """The gap a golf club had to email us about.

    A member could not add their own course, and because the gate refuses
    before any DB write there was no row naming who had tried or which course
    it was — and the view's own log line sits below the gate, so it only ever
    described imports that succeeded.
    """

    def setUp(self):
        cache.clear()          # the throttle is a real cache key
        mail.outbox = []
        # Burn an Account id so account_id != user_id.  With the two equal a
        # log line printing the account in both slots would pass the assertions
        # below while naming the wrong thing.
        Account.objects.create(name='Filler')
        Account.objects.create(name='Filler 2')
        self.account = Account.objects.create(name='Acct A')
        self.user = User.objects.create_user(
            username='+16265551234', account=self.account,
            phone='+16265551234',
        )
        assert self.account.id != self.user.id, 'fixture must not coincide'
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _no_tees(self):
        return {
            'id': '3vzs9mg0', 'club_name': 'Annandale Golf Club',
            'course_name': 'Annandale Golf Club', 'city': 'Pasadena',
            'state': 'CA', 'country': 'US',
            'latitude': Decimal('34.1'), 'longitude': Decimal('-118.1'),
            'tees': [],
        }

    def _import(self):
        return self.client.post(
            reverse('api-course-import'), {'course_id': '3vzs9mg0'},
            format='json',
        )

    # -- the log -----------------------------------------------------------

    @patch('services.golf_api_client.fetch_course')
    def test_the_refusal_logs_the_user_and_the_course(self, mock_fetch):
        mock_fetch.return_value = self._no_tees()
        with self.assertLogs('services.course_import_report', 'WARNING') as cm:
            resp = self._import()
        self.assertEqual(resp.status_code, 422, resp.data)
        line = '\n'.join(cm.output)
        self.assertIn('REFUSED', line)
        self.assertIn(f'user={self.user.id}', line)
        self.assertIn(f'account={self.account.id}', line)
        self.assertIn('Annandale Golf Club', line)
        self.assertIn('Course has no tees.', line)

    @patch('services.golf_api_client.fetch_course')
    def test_the_log_does_not_carry_the_phone_number(self, mock_fetch):
        """A phone is this app's identity key; an id is enough to find the row.

        The log is a retained platform log read by anyone with Railway access.
        The EMAIL carries the phone, because that is a direct message about one
        person to help rather than a record that sits around.
        """
        mock_fetch.return_value = self._no_tees()
        with self.assertLogs('services.course_import_report', 'WARNING') as cm:
            self._import()
        self.assertNotIn('6265551234', '\n'.join(cm.output))

    # -- the email ---------------------------------------------------------

    @patch('services.golf_api_client.fetch_course')
    def test_the_operator_is_emailed_with_who_and_why(self, mock_fetch):
        mock_fetch.return_value = self._no_tees()
        self._import()
        self.assertEqual(len(mail.outbox), 1)
        msg = mail.outbox[0]
        self.assertEqual(msg.to, ['ops@halved.golf'])
        self.assertIn('Annandale Golf Club', msg.subject)
        self.assertIn('Course has no tees.', msg.body)
        self.assertIn('+16265551234', msg.body)        # the phone IS here
        self.assertIn(str(self.user.id), msg.body)
        self.assertIn('3vzs9mg0', msg.body)

    @patch('services.golf_api_client.fetch_course')
    def test_one_email_per_course_per_day(self, mock_fetch):
        """Three taps from one frustrated member is not three emails."""
        mock_fetch.return_value = self._no_tees()
        with self.assertLogs('services.course_import_report', 'WARNING') as cm:
            self._import()
            self._import()
            self._import()
        self.assertEqual(len(mail.outbox), 1)
        # ...but every attempt is still logged, which is what answers "who".
        self.assertEqual(sum('REFUSED' in o for o in cm.output), 3)

    @patch('services.golf_api_client.fetch_course')
    def test_a_different_course_is_its_own_report(self, mock_fetch):
        mock_fetch.return_value = self._no_tees()
        self._import()
        other = self._no_tees()
        other['id'] = 'zzzz1111'
        other['club_name'] = other['course_name'] = 'Somewhere Else GC'
        mock_fetch.return_value = other
        self.client.post(reverse('api-course-import'),
                         {'course_id': 'zzzz1111'}, format='json')
        self.assertEqual(len(mail.outbox), 2)

    @override_settings(COURSE_IMPORT_ALERT_EMAIL='')
    @patch('services.golf_api_client.fetch_course')
    def test_an_empty_address_turns_the_email_off_but_not_the_log(self, mock_fetch):
        mock_fetch.return_value = self._no_tees()
        with self.assertLogs('services.course_import_report', 'WARNING'):
            resp = self._import()
        self.assertEqual(resp.status_code, 422)
        self.assertEqual(mail.outbox, [])

    # -- it must never cost the golfer his error message -------------------

    @patch('services.course_import_report.send_mail',
           side_effect=RuntimeError('smtp down'))
    @patch('services.golf_api_client.fetch_course')
    def test_a_mail_outage_still_returns_the_422(self, mock_fetch, _mail):
        mock_fetch.return_value = self._no_tees()
        resp = self._import()
        self.assertEqual(resp.status_code, 422, resp.data)
        self.assertIn('no tees', resp.data['detail'])
        # And still nothing written.
        self.assertFalse(CatalogCourse.objects.exists())
        self.assertFalse(Course.objects.exists())

    @patch('services.golf_api_client.fetch_course')
    def test_a_good_import_announces_nothing(self, mock_fetch):
        mock_fetch.return_value = {
            'id': 'okok0001', 'club_name': 'Fine GC', 'course_name': 'Fine GC',
            'city': 'X', 'state': 'CA', 'country': 'US',
            'latitude': Decimal('1.0'), 'longitude': Decimal('2.0'),
            'tees': [{'name': 'Blue', 'slope': 130,
                      'course_rating': Decimal('72.1'), 'par': 72, 'sex': 'M',
                      'holes': _good_holes()}],
        }
        resp = self.client.post(reverse('api-course-import'),
                                {'course_id': 'okok0001'}, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(mail.outbox, [])
