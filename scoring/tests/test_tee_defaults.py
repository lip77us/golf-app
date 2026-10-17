"""
scoring/tests/test_tee_defaults.py
----------------------------------
`default_tee_for` — the basis tee for its own sex, one step SHORTER for the
other.

Numbers are Tilden Park's real rows, including the `White - sixes` variant,
because that variant is precisely what breaks the obvious implementations.
"""
from decimal import Decimal

from django.test import TestCase

from services.tee_defaults import default_tee_for, tee_yards


class _Tee:
    """Enough of a Tee to order by length. One hole carrying the whole
    yardage -- `tee_yards` sums the list, so the split does not matter."""

    def __init__(self, name, sex, yards, par=70):
        self.tee_name, self.sex, self.par = name, sex, par
        self.holes = [{'number': 1, 'yards': yards}] if yards else []

    def __repr__(self):
        return f'<{self.tee_name} {self.sex or "-"}>'


_tee = _Tee


# Tilden Park, both sexes on the same physical boxes.
M_BLUE   = _tee('Blue',          'M', 6258)
M_WHITE  = _tee('White',         'M', 5764)
M_SIXES  = _tee('White - sixes', 'M', 5778)   # the variant between White and Blue
M_RED    = _tee('Red',           'M', 5395)
M_YELLOW = _tee('Yellow',        'M', 3113, par=61)
W_BLUE   = _tee('BLUE',          'W', 6258, par=71)
W_WHITE  = _tee('WHITE',         'W', 5764, par=71)
W_RED    = _tee('RED',           'W', 5395, par=71)
W_YELLOW = _tee('Yellow',        'W', 3113, par=66)

TILDEN = [M_BLUE, M_WHITE, M_SIXES, M_RED, M_YELLOW,
          W_BLUE, W_WHITE, W_RED, W_YELLOW]


class TildenIsTheCase(TestCase):

    def test_a_man_gets_the_basis_itself(self):
        self.assertIs(default_tee_for('M', M_WHITE, TILDEN), M_WHITE)

    def test_a_woman_gets_RED_not_WHITE(self):
        """The whole point. sort_priority offers her WHITE (12 vs RED's 15);
        most women here play Red."""
        self.assertIs(default_tee_for('W', M_WHITE, TILDEN), W_RED)

    def test_one_down_from_Blue_is_WHITE(self):
        self.assertIs(default_tee_for('W', M_BLUE, TILDEN), W_WHITE)

    def test_the_sixes_variant_still_lands_on_RED(self):
        """`White - sixes` is a 5778-yard men's variant that exists for one
        game. No women's tee is named that, so it matches WHITE by length
        and steps on to RED like its parent."""
        self.assertIs(default_tee_for('W', M_SIXES, TILDEN), W_RED)

    def test_nine_yards_does_not_change_the_answer(self):
        """Our two Tilden rows disagree by nine yards -- production has
        men's White and women's WHITE both at 5764, the other has 5778 and
        5769. 'The longest women's tee shorter than the basis' gives RED on
        one and WHITE on the other. One position down gives RED on both."""
        m_white = _tee('White', 'M', 5778)
        w_white = _tee('WHITE', 'W', 5769, par=71)
        w_red   = _tee('RED',   'W', 5395, par=71)
        tees    = [_tee('Blue', 'M', 6260), m_white, w_white, w_red]
        self.assertIs(default_tee_for('W', m_white, tees), w_red)


class TheEdges(TestCase):

    def test_no_basis_means_leave_todays_rule_alone(self):
        self.assertIsNone(default_tee_for('W', None, TILDEN))

    def test_a_unisex_basis_serves_everyone(self):
        uni = _tee('Combo', None, 5764)
        self.assertIs(default_tee_for('M', uni, TILDEN + [uni]), uni)
        self.assertIs(default_tee_for('W', uni, TILDEN + [uni]), uni)

    def test_nothing_shorter_falls_to_the_front_tees(self):
        """'One down' past the end of the list still means the front tees."""
        self.assertIs(default_tee_for('W', M_YELLOW, TILDEN), W_YELLOW)

    def test_a_tee_with_no_yardage_cannot_be_measured(self):
        """Rating-and-slope-only tees are legal. They must not rank as the
        shortest on the course just because they total zero."""
        ghost = _tee('Ghost', 'W', 0, par=71)
        self.assertIs(
            default_tee_for('W', M_WHITE, [M_WHITE, W_WHITE, W_RED, ghost]),
            W_RED)

    def test_no_yardages_at_all_returns_none(self):
        a, b = _tee('A', 'M', 0), _tee('B', 'W', 0)
        self.assertIsNone(default_tee_for('W', a, [a, b]))

    def test_no_eligible_tee_returns_none(self):
        self.assertIsNone(default_tee_for('W', M_WHITE, [M_WHITE, M_RED]))

    def test_tee_yards_survives_junk_hole_data(self):
        t = _tee('X', 'M', 0)
        t.holes = [{'yards': '400'}, {'yards': None}, {}, None, {'yards': 'x'}]
        self.assertEqual(tee_yards(t), 400)
