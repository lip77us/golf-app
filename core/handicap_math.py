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
