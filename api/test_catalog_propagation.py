"""
api/test_catalog_propagation.py
-------------------------------
Lazy catalog -> account tee propagation (services.catalog.sync_course_from_catalog
+ the TeeListView trigger).  Covers:
  * data_version bumps only when tee geometry actually moves;
  * the sync refreshes uncurated catalog-origin tees, adds missing ones, and
    NEVER touches a curated local variant (a re-rated 'White-Sixes' extra) or
    deletes anything;
  * a slope/rating re-rate updates IN PLACE (completed rounds keep their
    snapshotted course_handicap); a stroke-index/par change supersedes so played
    scorecards stay frozen;
  * version gating (idempotent no-op once current) + cross-account convergence;
  * the /api/tees/ picker triggers the sync.
"""
from copy import deepcopy
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import CatalogCourse, Course, Tee
from tournament.models import FoursomeMembership
from services.catalog import (
    upsert_catalog_course, clone_catalog_to_account,
    sync_course_from_catalog, sync_account_courses_from_catalog,
)
from scoring.tests._helpers import make_round, make_foursome

User = get_user_model()

GID = 'peb-1'


def _holes(si_by_hole=None, par_by_hole=None):
    return [
        {
            'number': n,
            'par': (par_by_hole or {}).get(n, 4),
            'stroke_index': (si_by_hole or {}).get(n, n),
            'yards': 400,
        }
        for n in range(1, 19)
    ]


def _api_course(white_slope=122, white_rating='70.4', white_holes=None, extra_tees=None):
    """Adapted GolfCourseAPI course dict (shape upsert_catalog_course consumes)."""
    tees = [
        {'name': 'Blue', 'slope': 130, 'course_rating': Decimal('72.1'),
         'par': 72, 'sex': 'M', 'holes': _holes()},
        {'name': 'White', 'slope': white_slope, 'course_rating': Decimal(white_rating),
         'par': 72, 'sex': 'M', 'holes': white_holes or _holes()},
    ]
    tees += extra_tees or []
    return {
        'id': GID, 'club_name': 'Pebble Beach', 'course_name': 'Pebble Beach',
        'city': 'Pebble Beach', 'state': 'CA', 'country': 'United States',
        'latitude': Decimal('36.5'), 'longitude': Decimal('-121.9'),
        'tees': tees,
    }


def _account(name):
    return Account.objects.create(name=name)


class DataVersionBumpTests(TestCase):
    def test_new_course_starts_at_v1_then_bumps_only_on_geometry_change(self):
        cc = upsert_catalog_course(_api_course(), GID, 'Pebble Beach')
        self.assertEqual(cc.data_version, 1)  # brand new -> no bump beyond 1

        # Re-import identical payload -> no change -> no bump.
        cc = upsert_catalog_course(_api_course(), GID, 'Pebble Beach')
        self.assertEqual(cc.data_version, 1)

        # Name/location-only edit -> still no geometry change -> no bump.
        payload = _api_course()
        payload['city'] = 'Monterey'
        cc = upsert_catalog_course(payload, GID, 'Pebble Beach Golf Links')
        self.assertEqual(cc.data_version, 1)

        # USGA slope re-rate -> bump.
        cc = upsert_catalog_course(_api_course(white_slope=128), GID, 'Pebble Beach')
        self.assertEqual(cc.data_version, 2)

        # Adding a tee -> bump.
        gold = {'name': 'Gold', 'slope': 118, 'course_rating': Decimal('68.0'),
                'par': 72, 'sex': 'M', 'holes': _holes()}
        cc = upsert_catalog_course(
            _api_course(white_slope=128, extra_tees=[gold]), GID, 'Pebble Beach')
        self.assertEqual(cc.data_version, 3)


class SyncScopeTests(TestCase):
    def setUp(self):
        self.cc = upsert_catalog_course(_api_course(), GID, 'Pebble Beach')
        self.acct = _account('Group A')
        self.course, _ = clone_catalog_to_account(self.cc, self.acct)
        # A deliberate local variant: a re-rated 'White-Sixes' extra tee that
        # exists in no catalog. Backfill/clone would mark this curated.
        self.white_sixes = Tee.objects.create(
            course=self.course, tee_name='White-Sixes', slope=122,
            course_rating=Decimal('70.4'), par=72, sex='M',
            holes=_holes(si_by_hole={1: 5, 5: 1}),
            origin=Tee.ORIGIN_MANUAL, curated=True,
        )

    def test_clone_is_born_current_and_catalog_origin(self):
        self.assertEqual(self.course.catalog_synced_version, self.cc.data_version)
        white = self.course.tees.get(tee_name='White')
        self.assertEqual(white.origin, Tee.ORIGIN_API)
        self.assertFalse(white.curated)
        # Nothing to sync yet.
        self.assertFalse(sync_course_from_catalog(self.course))

    def test_slope_rerate_updates_uncurated_in_place_spares_white_sixes(self):
        white = self.course.tees.get(tee_name='White')
        white_pk, sixes_pk = white.pk, self.white_sixes.pk

        upsert_catalog_course(_api_course(white_slope=128), GID, 'Pebble Beach')
        self.assertTrue(sync_course_from_catalog(self.course))

        white.refresh_from_db()
        self.assertEqual(white.pk, white_pk)      # in place (holes unchanged)
        self.assertEqual(white.slope, 128)        # picked up the re-rate
        self.assertTrue(white.is_current)

        self.white_sixes.refresh_from_db()
        self.assertEqual(self.white_sixes.pk, sixes_pk)
        self.assertEqual(self.white_sixes.slope, 122)   # untouched
        self.assertTrue(self.white_sixes.curated)

        self.course.refresh_from_db()
        self.assertEqual(self.course.catalog_synced_version, 2)
        # Idempotent: no work the second time.
        self.assertFalse(sync_course_from_catalog(self.course))

    def test_new_catalog_tee_is_added_to_account(self):
        gold = {'name': 'Gold', 'slope': 118, 'course_rating': Decimal('68.0'),
                'par': 72, 'sex': 'M', 'holes': _holes()}
        upsert_catalog_course(_api_course(extra_tees=[gold]), GID, 'Pebble Beach')
        self.assertTrue(sync_course_from_catalog(self.course))
        self.assertTrue(self.course.tees.filter(tee_name='Gold', origin=Tee.ORIGIN_API).exists())

    def test_sync_never_deletes_account_tees(self):
        # Catalog drops 'Blue'; the account keeps it (just stops updating).
        payload = _api_course()
        payload['tees'] = [t for t in payload['tees'] if t['name'] != 'Blue']
        # Force a bump so the sync actually runs.
        payload['tees'][0]['slope'] = 125
        upsert_catalog_course(payload, GID, 'Pebble Beach')
        sync_course_from_catalog(self.course)
        self.assertTrue(self.course.tees.filter(tee_name='Blue').exists())
        self.assertTrue(self.white_sixes.__class__.objects.filter(pk=self.white_sixes.pk).exists())


class FreezeInteractionTests(TestCase):
    """Propagation routes through update_tee_geometry, so played rounds stay
    correct: slope/rating in place, stroke-index/par supersedes."""

    def setUp(self):
        self.cc = upsert_catalog_course(_api_course(), GID, 'Pebble Beach')
        self.acct = _account('Group B')
        self.course, _ = clone_catalog_to_account(self.cc, self.acct)
        self.white = self.course.tees.get(tee_name='White')
        # A completed round played on the White tee, handicap snapshotted.
        self.fs = make_foursome(make_round(self.course),
                                [('Ann', 10), ('Bob', 4)], tee=self.white)

    def test_slope_rerate_preserves_completed_course_handicap(self):
        before = {m.player_id: m.course_handicap for m in self.fs.memberships.all()}
        upsert_catalog_course(_api_course(white_slope=128), GID, 'Pebble Beach')
        sync_course_from_catalog(self.course)

        self.white.refresh_from_db()
        self.assertEqual(self.white.slope, 128)          # updated in place
        self.assertTrue(self.white.is_current)
        after = {m.player_id: m.course_handicap for m in self.fs.memberships.all()}
        self.assertEqual(after, before)                  # frozen handicaps

    def test_stroke_index_rerate_supersedes_and_freezes_holes(self):
        original_holes = deepcopy(self.white.holes)
        new_holes = _holes(par_by_hole={1: 5}, si_by_hole={1: 1, 5: 7})
        upsert_catalog_course(_api_course(white_holes=new_holes), GID, 'Pebble Beach')
        sync_course_from_catalog(self.course)

        m = self.fs.memberships.first()
        m.refresh_from_db()
        # Played membership still points at the retired row with ORIGINAL holes.
        self.assertFalse(m.tee.is_current)
        self.assertEqual(m.tee.holes, original_holes)
        # The course's CURRENT White tee carries the re-rate.
        current_white = self.course.tees.get(tee_name='White', superseded_by__isnull=True)
        self.assertEqual(current_white.holes[0]['par'], 5)


class CrossAccountAndTriggerTests(TestCase):
    def setUp(self):
        self.cc = upsert_catalog_course(_api_course(), GID, 'Pebble Beach')

    def test_two_accounts_converge_independently(self):
        a1, a2 = _account('A1'), _account('A2')
        c1, _ = clone_catalog_to_account(self.cc, a1)
        c2, _ = clone_catalog_to_account(self.cc, a2)
        upsert_catalog_course(_api_course(white_slope=131), GID, 'Pebble Beach')

        self.assertEqual(sync_account_courses_from_catalog(a1), 1)
        self.assertEqual(c1.tees.get(tee_name='White').slope, 131)
        # a2 is still behind until it syncs.
        self.assertEqual(c2.tees.get(tee_name='White').slope, 122)
        self.assertEqual(sync_account_courses_from_catalog(a2), 1)
        self.assertEqual(c2.tees.get(tee_name='White').slope, 131)

    def test_tee_picker_endpoint_triggers_sync(self):
        acct = _account('Pickers')
        course, _ = clone_catalog_to_account(self.cc, acct)
        user = User.objects.create_user(username='picker', account=acct)
        upsert_catalog_course(_api_course(white_slope=126), GID, 'Pebble Beach')

        client = APIClient()
        client.force_authenticate(user=user)
        resp = client.get('/api/tees/')
        self.assertEqual(resp.status_code, 200)

        course.refresh_from_db()
        self.assertEqual(course.catalog_synced_version, 2)
        self.assertEqual(course.tees.get(tee_name='White').slope, 126)
