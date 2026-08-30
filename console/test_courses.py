"""
console/test_courses.py
-----------------------
The course library and editor.

The tests that matter here are the ones protecting golf that has already been
played: a tee edit must never rewrite the par or stroke index a completed round
was scored against, and a stroke-index set must never leave the screen as
anything other than a ranking. Everything else is presentation.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core import mail
from django.test import TestCase, override_settings
from django.urls import reverse

from accounts.models import Account
from core.models import CatalogCourse, Course, Tee
from tournament.models import Foursome, FoursomeMembership, Round
from core.models import Player

from .models import CourseCheck
from .tests import plain_static


User = get_user_model()


def holes(si=None, par=4, yards=380):
    si = si or list(range(1, 19))
    return [{'number': n, 'par': par, 'stroke_index': si[n - 1], 'yards': yards}
            for n in range(1, 19)]


@plain_static
class CourseEditorTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Tilden')
        self.user = User.objects.create_user(
            username='paul', account=self.account, is_account_admin=True)
        self.client.force_login(self.user,
                                backend='accounts.backends.AccountBackend')
        self.course = Course.objects.create(account=self.account,
                                            name='Tilden Park GC')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=123,
            course_rating=Decimal('69.4'), par=72, holes=holes())

    def _edit(self, **over):
        """Post the grid back unchanged except for `over`."""
        data = {'tee_name': self.tee.tee_name,
                'course_rating': str(self.tee.course_rating),
                'slope': str(self.tee.slope)}
        for h in self.tee.holes:
            data[f'par_{h["number"]}'] = h['par']
            data[f'yards_{h["number"]}'] = h['yards']
            data[f'stroke_index_{h["number"]}'] = h['stroke_index']
        data.update(over)
        return self.client.post(
            reverse('console:tee-edit', args=[self.course.pk, self.tee.pk]), data)

    def _play_a_round(self):
        """Attach the tee to a real round, so it becomes immutable."""
        player = Player.objects.create(account=self.account, name='Dave',
                                       handicap_index=Decimal('8.4'))
        rnd = Round.objects.create(account=self.account, course=self.course)
        fs = Foursome.objects.create(round=rnd, group_number=1)
        FoursomeMembership.objects.create(foursome=fs, player=player,
                                          tee=self.tee, course_handicap=8,
                                          playing_handicap=8)
        return fs

    # -- the ranking is enforced, not warned about --------------------------

    def test_a_duplicate_stroke_index_is_rejected(self):
        resp = self._edit(stroke_index_4='5')      # 5 now used twice, 1 missing
        self.assertEqual(resp.status_code, 200)    # re-rendered, not redirected
        self.assertContains(resp, 'exactly once')
        self.tee.refresh_from_db()
        self.assertEqual([h['stroke_index'] for h in self.tee.holes],
                         list(range(1, 19)))       # untouched

    def test_a_valid_re_index_is_saved(self):
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]   # holes 5 and 12
        resp = self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])
        self.assertRedirects(resp, reverse('console:course', args=[self.course.pk]))
        self.tee.refresh_from_db()
        self.assertEqual(self.tee.holes[4]['stroke_index'], 12)
        self.assertEqual(self.tee.holes[11]['stroke_index'], 5)

    def test_an_out_of_range_value_is_rejected(self):
        self.assertContains(self._edit(par_3='9'), 'outside')

    # -- played golf is frozen ----------------------------------------------

    def test_editing_a_played_tee_supersedes_instead_of_mutating(self):
        """The whole point of the copy-on-write rule."""
        fs = self._play_a_round()
        original_id = self.tee.pk
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])

        old = Tee.objects.get(pk=original_id)
        self.assertIsNotNone(old.superseded_by_id)          # retired
        self.assertFalse(old.is_current)
        # The completed round still points at the geometry it was played on.
        played = FoursomeMembership.objects.get(foursome=fs).tee
        self.assertEqual(played.pk, original_id)
        self.assertEqual(played.holes[4]['stroke_index'], 5)
        # ...and the current revision carries the correction.
        current = Tee.objects.get(course=self.course, superseded_by__isnull=True)
        self.assertNotEqual(current.pk, original_id)
        self.assertEqual(current.holes[4]['stroke_index'], 12)

    def test_an_unplayed_tee_is_edited_in_place(self):
        """No revision churn for a course nobody has played."""
        original_id = self.tee.pk
        swapped = list(range(1, 19))
        swapped[0], swapped[1] = swapped[1], swapped[0]
        self._edit(stroke_index_1=swapped[0], stroke_index_2=swapped[1])
        self.assertEqual(
            Tee.objects.filter(course=self.course).count(), 1)
        self.assertEqual(Tee.objects.get(course=self.course).pk, original_id)

    # -- changing the shape of the course asks first ------------------------

    def test_changing_par_asks_before_saving(self):
        resp = self._edit(par_3='5')
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, 'may no longer describe it')
        self.tee.refresh_from_db()
        self.assertEqual(self.tee.holes[2]['par'], 4)      # not yet written

    def test_confirming_saves_the_shape_change(self):
        resp = self._edit(par_3='5', confirm='1')
        self.assertRedirects(resp, reverse('console:course', args=[self.course.pk]))
        self.tee.refresh_from_db()
        self.assertEqual(self.tee.holes[2]['par'], 5)
        self.assertEqual(self.tee.par, 73)                 # total re-derived

    def test_a_re_index_does_not_ask(self):
        """Moving strokes leaves the rating describing the same course."""
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        resp = self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])
        self.assertEqual(resp.status_code, 302)

    # -- the record of what happened ----------------------------------------

    def test_an_edit_is_recorded_with_a_field_level_diff(self):
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])
        check = CourseCheck.objects.get(course=self.course)
        self.assertEqual(check.kind, CourseCheck.KIND_EDITED)
        labels = {c['label'] for c in check.changes}
        self.assertEqual(labels, {'hole 5 stroke index', 'hole 12 stroke index'})

    def test_marking_verified_records_a_check_that_found_nothing(self):
        self.client.post(reverse('console:course', args=[self.course.pk]),
                         {'action': 'verify'})
        check = CourseCheck.objects.get(course=self.course)
        self.assertEqual(check.kind, CourseCheck.KIND_VERIFIED)
        # ...and the library can now tell it from a course nobody looked at.
        resp = self.client.get(reverse('console:courses'))
        self.assertContains(resp, 'VERIFIED BY YOU')

    def test_an_unchecked_course_says_so(self):
        self.assertContains(self.client.get(reverse('console:courses')),
                            'NEVER CHECKED')

    # -- upstream ------------------------------------------------------------

    def test_reporting_needs_a_local_correction_first(self):
        resp = self.client.post(reverse('console:course', args=[self.course.pk]),
                                {'action': 'report', 'source': 'scorecard'})
        self.assertContains(resp, 'Nothing to send')

    def test_staff_push_writes_the_shared_catalog(self):
        self.course.golf_api_id = 'gc-1'
        self.course.save()
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])

        self.user.is_staff = True
        self.user.save()
        self.client.post(reverse('console:course', args=[self.course.pk]),
                         {'action': 'report', 'source': 'scorecard',
                          'note': 'swapped for years'})

        report = CourseCheck.objects.get(kind=CourseCheck.KIND_REPORTED)
        self.assertTrue(report.upstream)
        self.assertEqual(report.status, CourseCheck.STATUS_APPLIED)
        catalog = CatalogCourse.objects.get(golf_api_id='gc-1')
        tee = catalog.tees.get(tee_name='White')
        self.assertEqual(tee.holes[4]['stroke_index'], 12)
        # Curated, so a later API re-import cannot undo the human's reading.
        self.assertTrue(tee.curated)

    def test_a_non_staff_push_files_a_report_and_writes_no_catalog(self):
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])
        self.client.post(reverse('console:course', args=[self.course.pk]),
                         {'action': 'report', 'source': 'ghin'})
        report = CourseCheck.objects.get(kind=CourseCheck.KIND_REPORTED)
        self.assertFalse(report.upstream)
        self.assertEqual(report.status, CourseCheck.STATUS_SENT)
        self.assertEqual(CatalogCourse.objects.count(), 0)

    @override_settings(COURSE_REPORT_EMAIL='info@halved.golf')
    def test_the_report_is_emailed_as_a_diff(self):
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])
        self.client.post(reverse('console:course', args=[self.course.pk]),
                         {'action': 'report', 'source': 'scorecard'})
        self.assertEqual(len(mail.outbox), 1)
        sent = mail.outbox[0]
        self.assertEqual(sent.to, ['info@halved.golf'])
        self.assertIn('Tilden Park GC', sent.subject)
        self.assertIn('hole 5 stroke index', sent.body)
        self.assertIn('-> 12', sent.body)

    def test_a_source_is_required(self):
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])
        resp = self.client.post(reverse('console:course', args=[self.course.pk]),
                                {'action': 'report'})
        self.assertContains(resp, 'Say where the correction came from')

    # -- scoping -------------------------------------------------------------

    def test_another_accounts_course_is_not_reachable(self):
        other = Account.objects.create(name='Somebody Else')
        intruder = User.objects.create_user(username='them', account=other,
                                            is_account_admin=True)
        self.client.force_login(intruder,
                                backend='accounts.backends.AccountBackend')
        self.assertEqual(
            self.client.get(reverse('console:course', args=[self.course.pk])
                            ).status_code, 404)
        self.assertEqual(
            self.client.get(reverse('console:tee-edit',
                                    args=[self.course.pk, self.tee.pk])
                            ).status_code, 404)

    def test_a_non_admin_cannot_open_the_editor(self):
        member = User.objects.create_user(username='member',
                                          account=self.account,
                                          is_account_admin=False)
        self.client.force_login(member,
                                backend='accounts.backends.AccountBackend')
        resp = self.client.get(reverse('console:tee-edit',
                                       args=[self.course.pk, self.tee.pk]))
        self.assertContains(resp, 'No roster to manage')

    def test_a_retired_tee_cannot_be_edited(self):
        self._play_a_round()
        swapped = list(range(1, 19))
        swapped[4], swapped[11] = swapped[11], swapped[4]
        self._edit(stroke_index_5=swapped[4], stroke_index_12=swapped[11])
        # self.tee is now the retired revision.
        resp = self.client.get(reverse('console:tee-edit',
                                       args=[self.course.pk, self.tee.pk]))
        self.assertEqual(resp.status_code, 404)


@plain_static
class GridTotalsTests(TestCase):
    """The total column is derived, so it has to be derived from the holes —
    not from `Tee.par`, which is the stored value it exists to let you check."""

    def setUp(self):
        self.account = Account.objects.create(name='Tilden')
        self.user = User.objects.create_user(
            username='paul', account=self.account, is_account_admin=True)
        self.client.force_login(self.user,
                                backend='accounts.backends.AccountBackend')
        self.course = Course.objects.create(account=self.account, name='Tilden')

    def test_totals_come_from_the_holes_not_the_stored_par(self):
        from console import courses as courselib
        tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('69.4'),
            par=99,                                   # deliberately wrong
            holes=holes(par=4, yards=350))
        courselib.add_totals(tee)
        self.assertEqual(tee.par_total, 72)           # 18 x 4, not the stored 99
        self.assertEqual(tee.yards_total, 6300)

    def test_a_tee_with_no_yardage_shows_a_dash_not_a_zero(self):
        from console import courses as courselib
        tee = Tee.objects.create(
            course=self.course, tee_name='Gross only', slope=113,
            course_rating=Decimal('69.4'), par=72, holes=holes(yards=0))
        courselib.add_totals(tee)
        self.assertEqual(tee.par_total, 72)
        self.assertIsNone(tee.yards_total)            # template renders "—"

    def test_the_grid_renders_a_total_column(self):
        Tee.objects.create(course=self.course, tee_name='White', slope=113,
                           course_rating=Decimal('69.4'), par=72,
                           holes=holes(par=4, yards=350))
        resp = self.client.get(reverse('console:course', args=[self.course.pk]))
        self.assertContains(resp, 'TOT')
        self.assertContains(resp, '6300')


@plain_static
class CustomTeeTests(TestCase):
    """A private re-index.

    The rule that matters: a stroke-index set is a RANKING, and a set that is
    not 1..n each exactly once allocates strokes wrongly, silently, for
    everyone in the field. So it is refused, not warned about. The other rule
    is the lock — nothing here may change par or a yardage, because that is
    what keeps the inherited rating honest.
    """

    def setUp(self):
        self.account = Account.objects.create(name='Tilden')
        self.user = User.objects.create_user(
            username='paul', account=self.account, is_account_admin=True)
        self.client.force_login(self.user,
                                backend='accounts.backends.AccountBackend')
        self.course = Course.objects.create(account=self.account, name='Tilden')
        self.source = Tee.objects.create(
            course=self.course, tee_name='White', slope=123,
            course_rating=Decimal('69.4'), par=70, sort_priority=30,
            holes=holes(par=4, yards=350))

    def _post(self, indexes, name='White — club index', tee=None, **extra):
        data = {'name': name}
        for i, v in enumerate(indexes, start=1):
            data[f'index_{i}'] = v
        data.update(extra)
        return self.client.post(
            reverse('console:custom-tee',
                    args=[self.course.pk, (tee or self.source).pk]), data)

    # -- the ranking is the whole point -------------------------------------

    def test_a_valid_re_index_creates_a_custom_set(self):
        swapped = list(range(1, 19))
        swapped[3], swapped[11] = swapped[11], swapped[3]     # holes 4 and 12
        resp = self._post(swapped)
        self.assertRedirects(resp,
                             reverse('console:course', args=[self.course.pk]))
        made = Tee.objects.get(custom_index_of=self.source)
        self.assertEqual(made.tee_name, 'White — club index')
        self.assertTrue(made.is_custom_index)
        self.assertEqual(made.holes[3]['stroke_index'], 12)
        self.assertEqual(made.holes[11]['stroke_index'], 4)

    def test_a_duplicate_is_refused_and_names_the_missing_number(self):
        bad = list(range(1, 19))
        bad[3] = 5                                   # 5 twice, 4 now missing
        resp = self._post(bad)
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, '5 is used twice')
        self.assertContains(resp, '4 is not used')
        self.assertFalse(Tee.objects.filter(custom_index_of=self.source).exists())

    def test_a_blank_index_is_refused(self):
        vals = list(range(1, 19))
        vals[6] = ''
        resp = self._post(vals)
        self.assertContains(resp, 'Every hole needs an index')
        self.assertFalse(Tee.objects.filter(custom_index_of=self.source).exists())

    def test_a_name_is_required(self):
        resp = self._post(list(range(1, 19)), name='  ')
        self.assertContains(resp, 'Give the set a name')

    # -- the lock ------------------------------------------------------------

    def test_par_and_yards_are_inherited_whatever_the_form_says(self):
        """The form has no par/yards inputs — but neither may a forged post
        change them, because the rating describes THAT geometry."""
        swapped = list(range(1, 19))
        swapped[0], swapped[1] = swapped[1], swapped[0]
        self._post(swapped, par_1='6', yards_1='999')
        made = Tee.objects.get(custom_index_of=self.source)
        self.assertEqual(made.holes[0]['par'], 4)
        self.assertEqual(made.holes[0]['yards'], 350)
        self.assertEqual(made.par, self.source.par)
        self.assertEqual(made.course_rating, self.source.course_rating)
        self.assertEqual(made.slope, self.source.slope)

    def test_the_set_is_protected_from_a_catalog_resync(self):
        """curated + manual is what keeps services/catalog.py away from it."""
        self._post(list(range(1, 19)))
        made = Tee.objects.get(custom_index_of=self.source)
        self.assertTrue(made.curated)
        self.assertEqual(made.origin, Tee.ORIGIN_MANUAL)

    def test_it_does_not_outrank_the_tee_it_forked_from(self):
        """Appearing beside the source is wanted; silently becoming everyone's
        default pick is not."""
        self._post(list(range(1, 19)))
        made = Tee.objects.get(custom_index_of=self.source)
        self.assertEqual(made.sort_priority, self.source.sort_priority)

    # -- the helpers the screen leans on ------------------------------------

    def test_the_strip_marks_doubled_and_missing(self):
        from console import custom_tees as custom
        vals = list(range(1, 19))
        vals[3] = 5
        states = {c['value']: c['state'] for c in custom.strip(vals, 18)}
        self.assertEqual(states[5], 'twice')
        self.assertEqual(states[4], 'missing')
        self.assertEqual(states[7], 'used')

    def test_the_blocker_counts_what_is_wrong(self):
        from console import custom_tees as custom
        vals = list(range(1, 19))
        vals[3] = 5
        self.assertEqual(custom.blocker(vals, 18), '1 duplicate, 1 gap')
        self.assertEqual(custom.blocker(list(range(1, 19)), 18), '')

    def test_one_doubled_and_one_missing_offers_the_assignment(self):
        """A swap cannot fix a duplicate — something must become the missing
        number, and the cell just edited is almost always the one."""
        from console import custom_tees as custom
        vals = list(range(1, 19))
        vals[3] = 5                                  # hole 4 now holds 5
        self.assertEqual(custom.suggestion(vals, 18, changed_hole=4), (4, 4))

    def test_no_suggestion_when_more_than_one_thing_is_wrong(self):
        from console import custom_tees as custom
        vals = list(range(1, 19))
        vals[3], vals[5] = 5, 7
        self.assertIsNone(custom.suggestion(vals, 18, changed_hole=4))

    # -- editing an existing set --------------------------------------------

    def test_editing_a_played_set_supersedes_it(self):
        self._post(list(range(1, 19)))
        made = Tee.objects.get(custom_index_of=self.source)
        player = Player.objects.create(account=self.account, name='Dave',
                                       handicap_index=Decimal('8.4'))
        rnd = Round.objects.create(account=self.account, course=self.course)
        fs = Foursome.objects.create(round=rnd, group_number=1)
        FoursomeMembership.objects.create(foursome=fs, player=player, tee=made,
                                          course_handicap=8, playing_handicap=8)

        swapped = list(range(1, 19))
        swapped[0], swapped[1] = swapped[1], swapped[0]
        self._post(swapped, tee=made)

        made.refresh_from_db()
        self.assertIsNotNone(made.superseded_by_id)
        self.assertEqual(
            FoursomeMembership.objects.get(foursome=fs).tee.holes[0]['stroke_index'], 1)

    def test_an_unplayed_set_can_be_deleted(self):
        self._post(list(range(1, 19)))
        made = Tee.objects.get(custom_index_of=self.source)
        self.client.post(reverse('console:custom-tee-delete',
                                 args=[self.course.pk, made.pk]))
        self.assertFalse(Tee.objects.filter(pk=made.pk).exists())

    def test_a_played_set_cannot_be_deleted(self):
        self._post(list(range(1, 19)))
        made = Tee.objects.get(custom_index_of=self.source)
        player = Player.objects.create(account=self.account, name='Dave',
                                       handicap_index=Decimal('8.4'))
        rnd = Round.objects.create(account=self.account, course=self.course)
        fs = Foursome.objects.create(round=rnd, group_number=1)
        FoursomeMembership.objects.create(foursome=fs, player=player, tee=made,
                                          course_handicap=8, playing_handicap=8)
        resp = self.client.post(reverse('console:custom-tee-delete',
                                        args=[self.course.pk, made.pk]))
        self.assertContains(resp, 'has been played and cannot be removed')
        self.assertTrue(Tee.objects.filter(pk=made.pk).exists())

    # -- it reaches the app --------------------------------------------------

    def test_the_api_marks_it_so_the_picker_can_label_it(self):
        self._post(list(range(1, 19)))
        made = Tee.objects.get(custom_index_of=self.source)
        from api.serializers import TeeSerializer
        data = TeeSerializer(made).data
        self.assertTrue(data['is_custom_index'])
        self.assertEqual(data['custom_index_of'], self.source.pk)
        self.assertFalse(TeeSerializer(self.source).data['is_custom_index'])
