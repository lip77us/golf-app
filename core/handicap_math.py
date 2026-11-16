"""
core/handicap_math.py
---------------------
Rounding primitive shared by every handicap calculation.

Lives in `core` with no imports of its own so `core.models`,
`scoring.handicap` and every `services/*.py` game calculator can all pull it
in without a circular import.
"""

import math


def round_half_up(value) -> int:
    """Round to the nearest whole number with .5 going UP, per WHS Rule 6.1.

    Python's built-in ``round()`` is banker's rounding (round-half-to-even),
    so ``round(28.5) == 28`` and ``round(4.5) == 4`` — each a stroke short of
    what the Rules of Handicapping call for ("0.5 or above is rounded
    upward").  Exact .5 is rare for a course handicap but routine once a
    Net % lands on it: 90% of a 5-stroke strokes-off differential is 4.5.

    ``floor(x + 0.5)`` implements the rule as literally written, including
    for plus handicaps (-3.5 rounds UP to -3, not away from zero to -4), and
    is the exact counterpart of ``roundHalfUp()`` in
    ``mobile/lib/utils/handicap_rounding.dart`` so the two platforms cannot
    drift.
    """
    return math.floor(float(value) + 0.5)


def course_handicap_exact(index, slope, rating, par, holes: int = 18) -> float:
    """The WHS course handicap BEFORE rounding.

    ``index × slope/113 + (rating − par)`` for an 18-hole rating. A tee whose
    rating is a **9-hole** one (a nine-hole course: ``holes == 9``) halves the
    index first — WHS: ``index/2 × slope/113 + (9-hole rating − 9-hole par)`` —
    because the rating and the par describe nine holes, and a whole-round index
    against them gives roughly three times the strokes (a 10.0 on a 31.2/105,
    par 34 nine reads 7 instead of 2).

    One writer, because the formula had been copied into four places
    (``Player.course_handicap``, ``road_trip``, ``triple_cup`` and the Dart
    client) and a 9-hole rule fixed in one would be wrong in the other three.
    """
    idx = float(index)
    if holes and holes <= 9:
        idx = idx / 2.0
    return idx * (float(slope) / 113.0) + (float(rating) - float(par))


def tee_hole_count(tee) -> int:
    """How many holes a tee's data covers (18 when it has none to count)."""
    holes = getattr(tee, 'holes', None)
    return len(holes) if holes else 18
