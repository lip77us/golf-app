"""
api/test_tee_revisions.py
-------------------------
Copy-on-write tee revisioning (services/tee_revisions.py + catalog refresh):
a round's hole data stays frozen against the tee it was played on, even after
the course is re-rated / re-imported.
"""

from copy import deepcopy
from decimal import Decimal

from django.test import TestCase

from accounts.models import Account
from core.models import (
    CatalogCourse, CatalogTee, Course, Player, Tee,
)
from tournament.models import Foursome, FoursomeMembership, Round
from services.tee_revisions import update_tee_geometry
from api.serializers import CourseSerializer
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_tee, make_round, make_foursome,
)


def _changed_holes():
    """DEFAULT_HOLES with hole 1 re-rated (par + stroke index moved)."""
    holes = deepcopy(DEFAULT_HOLES)
    holes[0]['par'] = 5
    holes[0]['stroke_index'] = 1
    holes[4]['stroke_index'] = 7  # keep SI a valid permutation (swap 1<->7)
    return holes


class UpdateTeeGeometryTests(TestCase):
    def test_unreferenced_tee_updates_in_place(self):
        tee = make_tee(make_course('Unplayed'))
        before = Tee.objects.count()

        result = update_tee_geometry(tee, {'holes': _changed_holes()})

        self.assertEqual(result.id, tee.id)            # same row
        self.assertEqual(Tee.objects.count(), before)  # no new revision
        tee.refresh_from_db()
        self.assertTrue(tee.is_current)
        self.assertEqual(tee.holes[0]['par'], 5)

    def test_referenced_tee_with_changed_holes_supersedes(self):
        course = make_course('Played')
        tee = make_tee(course)
        rnd = make_round(course)
        fs = make_foursome(rnd, [('Ann', 10), ('Bob', 4)], tee=tee)

        new_holes = _changed_holes()
        result = update_tee_geometry(tee, {'holes': new_holes, 'par': 73})

        # Old row retired, new current revision created.
        self.assertNotEqual(result.id, tee.id)
        tee.refresh_from_db()
        self.assertFalse(tee.is_current)
        self.assertEqual(tee.superseded_by_id, result.id)
        self.assertTrue(result.is_current)
        self.assertEqual(result.holes, new_holes)

        # The played round still points at the OLD row with ORIGINAL holes.
        m = fs.memberships.first()
        self.assertEqual(m.tee_id, tee.id)
        self.assertEqual(m.tee.holes, DEFAULT_HOLES)

    def test_referenced_tee_unchanged_holes_updates_in_place(self):
        course = make_course('Played2')
        tee = make_tee(course)
        make_foursome(make_round(course), [('Ann', 10)], tee=tee)
        before = Tee.objects.count()

        # Slope re-rate but identical holes → no freeze needed, no new revision.
        result = update_tee_geometry(tee, {'slope': 130, 'holes': tee.holes})

        self.assertEqual(result.id, tee.id)
        self.assertEqual(Tee.objects.count(), before)
        tee.refresh_from_db()
        self.assertEqual(tee.slope, 130)

    def test_serializer_excludes_superseded_tees(self):
        course = make_course('Played3')
        tee = make_tee(course)
        make_foursome(make_round(course), [('Ann', 10)], tee=tee)
        new = update_tee_geometry(tee, {'holes': _changed_holes()})

        ids = [t['id'] for t in CourseSerializer(course).data['tees']]
        self.assertIn(new.id, ids)
        self.assertNotIn(tee.id, ids)


class CatalogRefreshSupersedesTests(TestCase):
    """The re-import / refresh path used to delete tees in place (ProtectedError
    once played).  It now supersedes, preserving local sort_priority."""

    def test_reimport_played_course_supersedes_and_preserves_priority(self):
        from services.catalog import clone_catalog_to_account

        acct = Account.objects.create(name='Acct')
        course = Course.objects.create(
            account=acct, name='Pebble', golf_api_id='gc-1',
        )
        tee = Tee.objects.create(
            course=course, tee_name='Blue', slope=120,
            course_rating=Decimal('70.0'), par=72, sex=None,
            holes=DEFAULT_HOLES, sort_priority=15,   # a LOCAL preference
        )
        # Reference the tee in a round.
        rnd = Round.objects.create(
            account=acct, course=course, status='in_progress', active_games=[],
            handicap_mode='net', net_percent=100, net_max_double_bogey=True,
        )
        fs = Foursome.objects.create(round=rnd, group_number=1)
        player = Player.objects.create(
            account=acct, name='Pat', handicap_index=Decimal('10'), sex='M',
        )
        FoursomeMembership.objects.create(
            foursome=fs, player=player, tee=tee,
            course_handicap=10, playing_handicap=10,
        )

        # Catalog has the same tee re-rated.
        cc = CatalogCourse.objects.create(golf_api_id='gc-1', name='Pebble')
        CatalogTee.objects.create(
            catalog_course=cc, tee_name='Blue', slope=121,
            course_rating=Decimal('70.1'), par=73, sex=None,
            default_sort_priority=99, holes=_changed_holes(),
        )

        # Re-import — must NOT raise ProtectedError.
        course_out, created = clone_catalog_to_account(
            cc, acct, replace_tees=True,
        )
        self.assertFalse(created)

        tee.refresh_from_db()
        self.assertFalse(tee.is_current)                       # retired
        self.assertEqual(fs.memberships.first().tee.holes, DEFAULT_HOLES)  # frozen

        new = course.tees.get(superseded_by__isnull=True, tee_name='Blue')
        self.assertEqual(new.holes, _changed_holes())
        self.assertEqual(new.sort_priority, 15)  # LOCAL priority preserved, not 99
