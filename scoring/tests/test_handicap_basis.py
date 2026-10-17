"""
scoring/tests/test_handicap_basis.py
------------------------------------
The handicap basis tee — every handicap in an event measured from one
reference instead of from whoever the golfer was drawn with.

**The defect it fixes**, found comparing Halved to Golf Genius before a
46-golfer cup: the reference was `min(tee.par)` across the FOURSOME, so the
same golfer, on the same tee, with the same index, played off a different
number depending on the draw.

Numbers below are Tilden Park's real tees.
"""
from decimal import Decimal

from django.test import TestCase

from scoring.handicap import basis_rating_for, par_adjusted_playing_handicap

#: Tilden Park, account 53's rows.
W_WHITE = dict(par=71, cr=Decimal('73.5'), slope=129)   # women's
M_WHITE = dict(par=70, cr=Decimal('69.0'), slope=122)   # men's -- the basis
M_BLUE  = dict(par=70, cr=Decimal('71.2'), slope=125)
M_RED   = dict(par=70, cr=Decimal('67.3'), slope=116)


def ch(index, tee):
    """Course handicap, WHS 2020: Index x Slope/113 + (CR - par)."""
    from core.handicap_math import round_half_up
    return round_half_up(float(index) * tee['slope'] / 113.0
                         + float(tee['cr']) - tee['par'])


class TheDrawUsedToMoveTheHandicap(TestCase):
    """The bug, stated as a test so it cannot come back."""

    def test_same_golfer_same_tee_different_group_different_handicap(self):
        c = ch(22.3, W_WHITE)
        self.assertEqual(c, 28)
        with_men   = par_adjusted_playing_handicap(c, 71, 70)   # group low par 70
        with_women = par_adjusted_playing_handicap(c, 71, 71)   # group low par 71
        self.assertEqual((with_men, with_women), (29, 28),
                         'the shipped behaviour -- one stroke on the draw alone')

    def test_a_basis_makes_it_the_same_number_either_way(self):
        c = ch(22.3, W_WHITE)
        basis = float(M_WHITE['cr'])
        self.assertEqual(
            par_adjusted_playing_handicap(c, 71, 70, basis_rating=basis),
            par_adjusted_playing_handicap(c, 71, 71, basis_rating=basis),
            'the group is no longer an input')


class MatchesGolfGenius(TestCase):
    """The worked example that started this, basis = men's White."""

    def test_the_woman_comes_out_at_30(self):
        c = ch(22.3, W_WHITE)
        self.assertEqual(
            par_adjusted_playing_handicap(c, 71, 70,
                                          basis_rating=float(M_WHITE['cr'])),
            30)

    def test_every_mens_tee_shifts_by_exactly_one(self):
        """Tilden's men's tees are all par 70, so each man moves by the same
        `70 - 69.0` whatever tee he is on -- no match between men changes."""
        basis = float(M_WHITE['cr'])
        for tee in (M_WHITE, M_BLUE, M_RED):
            for index in (4.1, 10.0, 18.6):
                c = ch(index, tee)
                before = par_adjusted_playing_handicap(c, tee['par'], 70)
                after  = par_adjusted_playing_handicap(c, tee['par'], 70,
                                                       basis_rating=basis)
                self.assertEqual(after - before, 1,
                                 f'index {index} on par {tee["par"]} CR {tee["cr"]}')

    def test_the_woman_moves_two_from_a_womens_group(self):
        c = ch(22.3, W_WHITE)
        before = par_adjusted_playing_handicap(c, 71, 71)        # women only
        after  = par_adjusted_playing_handicap(c, 71, 71,
                                               basis_rating=float(M_WHITE['cr']))
        self.assertEqual(after - before, 2)


class UnsetIsExactlyTodaysBehaviour(TestCase):
    """The change has to be additive: a casual round has no tournament to
    carry the setting, and the per-group rule is RIGHT for it."""

    def test_none_takes_the_original_path(self):
        for c in range(0, 37, 3):
            for par, low in ((70, 70), (71, 70), (72, 70), (71, 71)):
                self.assertEqual(
                    par_adjusted_playing_handicap(c, par, low),
                    par_adjusted_playing_handicap(c, par, low, basis_rating=None))

    def test_an_allowance_still_applies(self):
        # 90% of 25 = 22.5 -> 23 (round half UP, not banker's).
        self.assertEqual(par_adjusted_playing_handicap(25, 70, 70, 0.9), 23)

    def test_the_allowance_applies_under_a_basis_too(self):
        self.assertEqual(
            par_adjusted_playing_handicap(25, 70, 70, 0.9, basis_rating=69.0),
            round(22.5 + 1.0))


class ARatingIsNotAWholeNumber(TestCase):
    def test_a_fractional_basis_rounds_the_whole_sum(self):
        """69.5 as a basis must not be truncated to an int difference before
        the handicap is rounded."""
        # CH 28, par 71, basis 69.5 -> 28 + 1.5 = 29.5 -> 30 (half up)
        self.assertEqual(
            par_adjusted_playing_handicap(28, 71, 70, basis_rating=69.5), 30)
        # CH 28, par 70, basis 69.5 -> 28.5 -> 29
        self.assertEqual(
            par_adjusted_playing_handicap(28, 70, 70, basis_rating=69.5), 29)


class ResolutionOrder(TestCase):
    """round override -> tournament default -> None."""

    class _Tee:
        def __init__(self, cr): self.course_rating = Decimal(str(cr))

    class _Tour:
        def __init__(self, tee=None): self.handicap_basis_tee = tee

    class _Course:
        def __init__(self, tee=None): self.default_basis_tee = tee

    class _Round:
        def __init__(self, tee=None, tour=None, course=None):
            self.handicap_basis_tee = tee
            self.tournament = tour
            self.course = course or ResolutionOrder._Course()

    def test_no_round_is_none(self):
        self.assertIsNone(basis_rating_for(None))

    def test_nothing_set_anywhere_is_none(self):
        self.assertIsNone(basis_rating_for(self._Round()))

    def test_the_course_supplies_it_when_nothing_else_does(self):
        """The whole point of keeping it on the course: a CASUAL round has no
        tournament, but it always has a course."""
        r = self._Round(course=self._Course(self._Tee('69.0')))
        self.assertEqual(basis_rating_for(r), 69.0)

    def test_the_tournament_beats_the_course(self):
        r = self._Round(tour=self._Tour(self._Tee('71.2')),
                        course=self._Course(self._Tee('69.0')))
        self.assertEqual(basis_rating_for(r), 71.2)

    def test_the_round_beats_both(self):
        """A cup plays several rounds, possibly on different courses."""
        r = self._Round(tee=self._Tee('67.3'),
                        tour=self._Tour(self._Tee('71.2')),
                        course=self._Course(self._Tee('69.0')))
        self.assertEqual(basis_rating_for(r), 67.3)

    def test_a_casual_round_at_tilden_gets_the_same_number_as_the_cup(self):
        """Paul, 17 Oct: same rule for casual rounds. With the default on the
        course they agree by construction rather than by being kept in step."""
        tilden = self._Course(self._Tee('69.0'))
        casual = self._Round(course=tilden)
        cup    = self._Round(course=tilden, tour=self._Tour())
        self.assertEqual(basis_rating_for(casual), basis_rating_for(cup))
