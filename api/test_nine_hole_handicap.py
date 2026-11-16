"""
api/test_nine_hole_handicap.py
------------------------------
A NINE-hole course's rating and par describe nine holes, so the course
handicap halves the index first (WHS). Without it a 10.0 on The Ridge 9's White
tees (31.2 / 105, par 34) got 6 strokes instead of 2.
"""
from decimal import Decimal

from django.test import SimpleTestCase, TestCase

from accounts.models import Account
from core.handicap_math import course_handicap_exact, round_half_up
from core.models import Course, Player, Tee
from services.road_trip import course_handicap as trip_course_handicap


def _holes(n, par=4):
    return [{'number': i, 'par': par, 'stroke_index': i, 'yards': 300}
            for i in range(1, n + 1)]


class TheFormulaTests(SimpleTestCase):
    def test_a_nine_hole_rating_halves_the_index_first(self):
        # The Ridge 9, White: 10.0 index, 31.2 / 105, par 34.
        exact = course_handicap_exact(10.0, 105, 31.2, 34, holes=9)
        self.assertAlmostEqual(exact, 5.0 * 105 / 113 + (31.2 - 34), places=6)
        self.assertEqual(round_half_up(exact), 2)

    def test_the_same_numbers_as_eighteen_would_give_six(self):
        # What the app did before: the whole index against a nine-hole rating.
        self.assertEqual(round_half_up(
            course_handicap_exact(10.0, 105, 31.2, 34, holes=18)), 6)

    def test_an_eighteen_hole_tee_is_unchanged(self):
        self.assertAlmostEqual(
            course_handicap_exact(12.4, 130, 72.1, 72, holes=18),
            12.4 * 130 / 113 + 0.1, places=6)


class TheCallersTests(TestCase):
    def setUp(self):
        acct = Account.objects.create(name='Nine')
        course = Course.objects.create(account=acct, name='The Ridge 9')
        self.nine = Tee.objects.create(
            course=course, tee_name='White', slope=105,
            course_rating=Decimal('31.2'), par=34, holes=_holes(9))
        self.eighteen = Tee.objects.create(
            course=course, tee_name='Full', slope=130,
            course_rating=Decimal('72.1'), par=72, holes=_holes(18))
        self.player = Player.objects.create(
            account=acct, name='Paul', handicap_index=Decimal('10.0'))

    def test_the_player_method_halves_for_a_nine_hole_tee(self):
        self.assertEqual(self.player.course_handicap(self.nine), 2)

    def test_the_player_method_is_unchanged_for_eighteen(self):
        self.assertEqual(self.player.course_handicap(self.eighteen),
                         round_half_up(10.0 * 130 / 113 + 0.1))

    def test_the_road_trip_copy_agrees(self):
        self.assertEqual(trip_course_handicap(10.0, self.nine), 2)
        self.assertEqual(trip_course_handicap(10.0, self.eighteen),
                         self.player.course_handicap(self.eighteen))
