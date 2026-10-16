"""Distance between two points on the earth.

Exists because **courses near a golfer come from three sources and only one
of them reports a distance.** GolfCourseAPI's ``/v1/proximity`` returns one
per row; the account's own courses and the shared catalog carry
``latitude``/``longitude`` and nothing else, so their distance has to be
computed here or they cannot be ranked against the API's.

Haversine on a spherical earth. Good to a few tenths of a percent, which is
far better than this needs: the figure is shown to the nearest mile and the
radius it filters against is a round number a golfer chose.
"""

from __future__ import annotations

import math

#: Mean earth radius. Miles because the UI says miles; GolfCourseAPI's own
#: radius parameter accepts either and we send miles explicitly.
EARTH_RADIUS_MILES = 3958.7613


def haversine_miles(lat1, lon1, lat2, lon2) -> float | None:
    """Great-circle distance in miles, or **None if any value is missing**.

    None rather than 0.0 on missing input, and the distinction matters: a
    course with no coordinates is one we cannot place, not one in the car
    park. Callers drop those rows instead of ranking them first.

    Takes anything float() accepts, because `Course.latitude` is a Decimal
    and the API hands back floats.
    """
    if lat1 is None or lon1 is None or lat2 is None or lon2 is None:
        return None
    try:
        lat1, lon1, lat2, lon2 = (float(lat1), float(lon1), float(lat2), float(lon2))
    except (TypeError, ValueError):
        return None

    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp     = math.radians(lat2 - lat1)
    dl     = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return EARTH_RADIUS_MILES * 2 * math.asin(math.sqrt(a))
