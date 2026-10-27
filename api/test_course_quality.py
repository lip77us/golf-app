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
    yardage_notes,
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
    def test_detail_is_written_for_the_golfer_not_the_operator(
            self, mock_fetch):
        """`detail` names the COURSE and what happens next, not the defect.

        friendlyError() hands `detail` straight to a red snackbar.  A version
        of this led with the gate's own first problem, which is accurate and
        unreadable: an Annandale member was shown a sentence about handicap
        allocation and an 18-integer stroke-index array.  The technical reason
        belongs in `problems`, which the operator alert renders.
        """
        empty = self._adapted(_good_holes())
        empty['tees'] = []
        mock_fetch.return_value = empty

        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 422, resp.data)
        detail = resp.data['detail']
        self.assertIn('Bad GC', detail)                  # names the course
        self.assertIn("can't be added", detail)          # says what happened
        self.assertIn('told about it', detail)           # and what happens next
        # None of the gate's vocabulary reaches him.
        for jargon in ('stroke index', 'hole data', 'permutation', 'Got:'):
            self.assertNotIn(jargon, detail)
        # ...but it is still there in full for the alert.
        self.assertEqual(resp.data['problems'], ['Course has no tees.'])

    @patch('services.golf_api_client.fetch_course')
    def test_a_stroke_index_array_never_reaches_the_golfer(self, mock_fetch):
        """The exact message a member was shown, in red, for four seconds."""
        bad = self._adapted(
            [{'number': n, 'par': 4,
              'stroke_index': 17 if n == 4 else n, 'yards': 400}
             for n in range(1, 19)]
        )
        mock_fetch.return_value = bad

        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 422, resp.data)
        self.assertNotIn('[', resp.data['detail'])       # no array
        self.assertTrue(any('stroke index' in p for p in resp.data['problems']))

    @patch('services.golf_api_client.fetch_course')
    def test_every_problem_still_travels_in_problems(self, mock_fetch):
        # A tee missing its rating, slope and par gives three problems.  The
        # golfer sees one sentence; the alert sees all three.
        bare = self._adapted(_good_holes())
        bare['tees'][0].update(course_rating=None, slope=None, par=None)
        mock_fetch.return_value = bare

        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 422, resp.data)
        self.assertEqual(len(resp.data['problems']), 3)
        for prob in resp.data['problems']:
            self.assertNotIn(prob, resp.data['detail'])

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
        self.assertIn("can't be added", resp.data['detail'])
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


# ---------------------------------------------------------------------------
# A copy we already hold beats an upstream regression
# ---------------------------------------------------------------------------

@override_settings(COURSE_IMPORT_ALERT_EMAIL='ops@halved.golf')
class HeldCopyBeatsUpstreamTests(TestCase):
    """Annandale's women's tees were edited upstream and broke, three weeks
    after we had already imported a clean copy into the shared catalog.  The
    gate then refused the whole course -- so a member was blocked from a
    course we demonstrably had, by somebody else's bad edit.

    The picker's `catalog` branch clones that copy without re-running this
    gate, so serving it from the import path is the same trust decision, not
    a new one.
    """

    API_ID = '3vzs9mg0'

    def setUp(self):
        cache.clear()
        mail.outbox = []
        self.account = Account.objects.create(name='Member Acct')
        self.user = User.objects.create_user(
            username='+18185175766', account=self.account,
            phone='+18185175766',
        )
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _upstream(self, tees):
        return {
            'id': self.API_ID, 'club_name': 'Annandale Golf Club',
            'course_name': 'Annandale Golf Club', 'city': 'Pasadena',
            'state': 'CA', 'country': 'US',
            'latitude': Decimal('34.1'), 'longitude': Decimal('-118.1'),
            'tees': tees,
        }

    def _good_tee(self, name='Orange', sex='M'):
        return {'name': name, 'slope': 134, 'course_rating': Decimal('73.0'),
                'par': 70, 'sex': sex, 'holes': _good_holes()}

    def _broken_tee(self, name='Orange', sex='W'):
        holes = [dict(h) for h in _good_holes()]
        holes[3]['stroke_index'] = holes[8]['stroke_index']   # duplicate
        return {'name': name, 'slope': 141, 'course_rating': Decimal('79.2'),
                'par': 70, 'sex': sex, 'holes': holes}

    def _seed_catalog(self):
        """Import a clean course first — this is how the good copy got there."""
        with patch('services.golf_api_client.fetch_course') as mf:
            mf.return_value = self._upstream([self._good_tee()])
            resp = self.client.post(reverse('api-course-import'),
                                    {'course_id': self.API_ID}, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        Course.objects.filter(account=self.account).delete()   # he loses his copy
        mail.outbox = []
        cache.clear()
        return CatalogCourse.objects.get(golf_api_id=self.API_ID)

    @patch('services.golf_api_client.fetch_course')
    def test_the_member_gets_the_course_instead_of_a_refusal(self, mock_fetch):
        held = self._seed_catalog()
        mock_fetch.return_value = self._upstream(
            [self._good_tee(), self._broken_tee()])

        resp = self.client.post(reverse('api-course-import'),
                                {'course_id': self.API_ID}, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertIn('course', resp.data)
        self.assertIn('our own copy', resp.data['warning'])
        # He actually has it, with the tees the catalog holds.
        mine = Course.objects.get(account=self.account, golf_api_id=self.API_ID)
        self.assertEqual(mine.tees.count(), held.tees.count())

    @patch('services.golf_api_client.fetch_course')
    def test_the_operator_is_still_told_and_is_not_told_he_was_blocked(
            self, mock_fetch):
        """The alert must not claim a golfer could not add a course he added."""
        self._seed_catalog()
        mock_fetch.return_value = self._upstream(
            [self._good_tee(), self._broken_tee()])

        with self.assertLogs('services.course_import_report', 'WARNING') as cm:
            self.client.post(reverse('api-course-import'),
                             {'course_id': self.API_ID}, format='json')
        self.assertIn('SERVED-FROM-CATALOG', '\n'.join(cm.output))

        self.assertEqual(len(mail.outbox), 1)
        body = mail.outbox[0].body
        self.assertIn('OUR OWN catalog copy', body)
        self.assertIn('was not blocked', body)
        self.assertNotIn('could not add', body)
        self.assertIn('stroke index', body)        # the real reason is there

    @patch('services.golf_api_client.fetch_course')
    def test_a_course_we_do_not_hold_is_still_refused(self, mock_fetch):
        """No held copy, no fallback — the gate still protects the catalog."""
        mock_fetch.return_value = self._upstream([self._broken_tee()])
        resp = self.client.post(reverse('api-course-import'),
                                {'course_id': 'neverseen'}, format='json')
        self.assertEqual(resp.status_code, 422, resp.data)
        self.assertFalse(
            CatalogCourse.objects.filter(golf_api_id='neverseen').exists())
        self.assertFalse(Course.objects.filter(account=self.account).exists())

    @patch('services.golf_api_client.fetch_course')
    def test_a_catalog_row_with_no_tees_is_no_fallback_at_all(self, mock_fetch):
        """An empty held row would "succeed" into a course nobody can score."""
        CatalogCourse.objects.create(golf_api_id='emptyrow',
                                     name='Empty GC', city='X', state='CA')
        mock_fetch.return_value = self._upstream([self._broken_tee()])
        resp = self.client.post(reverse('api-course-import'),
                                {'course_id': 'emptyrow'}, format='json')
        self.assertEqual(resp.status_code, 422, resp.data)

    @patch('services.golf_api_client.fetch_course')
    def test_already_having_it_still_reads_as_already_having_it(
            self, mock_fetch):
        """409, not a 201 that claims a fresh import which did nothing."""
        self._seed_catalog()
        # Give him the copy back.
        mock_fetch.return_value = self._upstream([self._good_tee()])
        self.client.post(reverse('api-course-import'),
                         {'course_id': self.API_ID}, format='json')
        cache.clear()

        mock_fetch.return_value = self._upstream(
            [self._good_tee(), self._broken_tee()])
        resp = self.client.post(reverse('api-course-import'),
                                {'course_id': self.API_ID}, format='json')
        self.assertEqual(resp.status_code, 409, resp.data)
        self.assertTrue(resp.data['already_exists'])


# ---------------------------------------------------------------------------
# The yardage cross-check — ours, never the golfer's
# ---------------------------------------------------------------------------

def _yd_tee(name, stated, yards, sex='M'):
    return {'name': name, 'sex': sex, 'slope': 130,
            'course_rating': Decimal('70.0'), 'par': 70,
            'total_yards': stated,
            'holes': [{'number': i + 1, 'par': 4, 'stroke_index': i + 1,
                       'yards': y} for i, y in enumerate(yards)]}


class YardageNotesUnitTests(TestCase):
    """Pure units.  Every shape here came off the real Annandale card."""

    def test_a_matching_total_says_nothing(self):
        self.assertEqual(
            yardage_notes({'tees': [_yd_tee('Blue', 180, [10] * 18)]}), [])

    def test_a_mismatch_names_the_tee_the_sex_and_the_gap(self):
        # Green: stated 5003 against holes that add to 5049.
        yards = [322] + [269] * 16 + [458]
        note, = yardage_notes({'tees': [_yd_tee('Green', 5003, yards)]})
        self.assertIn('Green', note)
        self.assertIn('(M)', note)
        self.assertIn('5003', note)
        self.assertIn(str(sum(yards)), note)
        self.assertIn('off by', note)

    def test_the_gap_is_signed_so_the_direction_reads(self):
        over = yardage_notes({'tees': [_yd_tee('A', 200, [10] * 18)]})[0]
        under = yardage_notes({'tees': [_yd_tee('B', 160, [10] * 18)]})[0]
        self.assertIn('+20', over)
        self.assertIn('-20', under)

    def test_a_missing_total_is_flagged_when_the_card_has_others(self):
        """Women's Orange carried none while every other tee did."""
        note, = yardage_notes({'tees': [
            _yd_tee('Blue', 180, [10] * 18),
            _yd_tee('Orange', None, [10] * 18, sex='W'),
        ]})
        self.assertIn('Orange', note)
        self.assertIn('(W)', note)
        self.assertIn('no stated total', note)

    def test_a_card_stating_no_totals_at_all_is_silent(self):
        """Many courses have no such field; grumbling about every tee of every
        one of those is how a check earns being ignored."""
        self.assertEqual(yardage_notes({'tees': [
            _yd_tee('Blue', None, [10] * 18),
            _yd_tee('White', None, [10] * 18),
        ]}), [])

    def test_a_tee_with_no_per_hole_yardage_is_skipped(self):
        """A rating-only tee is legitimate — there is nothing to compare."""
        self.assertEqual(
            yardage_notes({'tees': [_yd_tee('Rating only', 6000,
                                            [None] * 18)]}), [])

    def test_it_never_raises_on_a_junk_payload(self):
        for junk in ({}, {'tees': None}, {'tees': [{}]},
                     {'tees': [{'holes': None, 'total_yards': None}]}):
            yardage_notes(junk)


@override_settings(COURSE_IMPORT_ALERT_EMAIL='ops@halved.golf')
class YardageIsOperatorOnlyTests(TestCase):
    """Paul, 27 Oct 2026: "only a warning to us and not to the user.  They
    never care about the accuracy of total yards."
    """

    def setUp(self):
        cache.clear()
        mail.outbox = []
        self.account = Account.objects.create(name='Acct Y')
        self.user = User.objects.create_user(
            username='+15105550000', account=self.account,
            phone='+15105550000',
        )
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.hole_sum = sum((h.get('yards') or 0) for h in _good_holes())

    def _payload(self, stated):
        return {
            'id': 'yard0001', 'club_name': 'Yardage GC',
            'course_name': 'Yardage GC', 'city': 'X', 'state': 'CA',
            'country': 'US', 'latitude': Decimal('1.0'),
            'longitude': Decimal('2.0'),
            'tees': [{'name': 'Blue', 'slope': 130,
                      'course_rating': Decimal('72.1'), 'par': 72, 'sex': 'M',
                      'total_yards': stated, 'holes': _good_holes()}],
        }

    def _import(self, stated):
        with patch('services.golf_api_client.fetch_course') as mf:
            mf.return_value = self._payload(stated)
            return self.client.post(reverse('api-course-import'),
                                    {'course_id': 'yard0001'}, format='json')

    def test_the_import_still_succeeds(self):
        resp = self._import(self.hole_sum + 58)
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertTrue(Course.objects.filter(account=self.account).exists())

    def test_the_response_says_nothing_about_yardage(self):
        """`result['warning']` is the USER's channel and must stay clean."""
        resp = self._import(self.hole_sum + 58)
        blob = str(resp.data).replace('Yardage GC', '')
        for leak in ('off by', 'add to', 'stated total', '+58'):
            self.assertNotIn(leak, blob)
        self.assertNotIn('warning', resp.data)

    def test_we_are_told_in_the_log_and_by_email(self):
        with self.assertLogs('services.course_import_report', 'WARNING') as cm:
            self._import(self.hole_sum + 58)
        line = '\n'.join(cm.output)
        self.assertIn('YARDAGE', line)
        self.assertIn(f'user={self.user.id}', line)
        self.assertNotIn('5105550000', line)     # phone stays out of the log

        self.assertEqual(len(mail.outbox), 1)
        body = mail.outbox[0].body
        self.assertIn('does not match', body)
        self.assertIn('+15105550000', body)      # ...and is in the email
        self.assertIn('Nobody was blocked', body)

    def test_a_course_that_adds_up_says_nothing_at_all(self):
        resp = self._import(self.hole_sum)
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(mail.outbox, [])

    def test_the_yardage_throttle_is_its_own(self):
        """A refusal and a yardage note for the same course must not silence
        each other: different findings, and the first of each is worth having.
        """
        from services.course_import_report import (
            report_import_refusal, report_yardage_notes,
        )
        self.assertTrue(report_import_refusal(
            self.user, 'samecourse', 'Same GC', ['Course has no tees.']))
        self.assertTrue(report_yardage_notes(
            self.user, 'samecourse', 'Same GC', ['Blue (M): off by +4.']))
        self.assertEqual(len(mail.outbox), 2)

    def test_no_notes_means_no_email_even_when_called_directly(self):
        from services.course_import_report import report_yardage_notes
        self.assertFalse(report_yardage_notes(self.user, 'x', 'X GC', []))
        self.assertEqual(mail.outbox, [])
