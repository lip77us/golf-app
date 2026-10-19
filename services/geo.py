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


#: Decimal places a device position is cut to before the server uses it.
#:
#: Two, which is about 1.1 km of latitude, and the number is a PRIVACY
#: decision rather than a precision one. Apple defines its App Privacy label
#: by the resolution of what an app transmits — three or more decimal places
#: is *Precise Location* — so a position carrying more than this would
#: contradict the Coarse Location declaration whatever accuracy CoreLocation
#: was asked for. `docs/location-permission.md` has the whole argument.
#:
#: It is also why the distance is shown in WHOLE miles: at this resolution the
#: anchor can move by most of a mile, so a tenth would be a digit we do not
#: have.
COARSE_DECIMALS = 2


def coarse_position(latitude, longitude):
    """A requested position, validated and cut to `COARSE_DECIMALS`.

    Returns `(lat, lng)` as floats, or **`(None, None)`** for anything that is
    not a place. Callers answer 400 on that — unlike a missing home course,
    which is a state the golfer is in, a malformed coordinate is a client
    fault and saying so is more use than an empty list.

    **The app rounds before sending and this rounds again.** Not redundant:
    rounding only on the phone means the server's correctness depends on the
    client's, and an older build, a replayed URL or a hand-typed request would
    hand us a precise position that we would then measure from, log around and
    forward upstream. Rounding here is what makes "the server never holds a
    precise position" a property of the server.

    Ranges are checked PER COORDINATE — a single range covering both accepts a
    latitude of 150, which is not a place — and `0, 0` is rejected as a pair:
    it is in the Atlantic, no golfer is there, and it is what a value
    defaulted rather than supplied looks like. Either alone is fine, since the
    equator and the Greenwich meridian both cross dry land.
    """
    def one(value, limit):
        if value is None or value == '':
            return None
        try:
            d = round(float(value), COARSE_DECIMALS)
        except (TypeError, ValueError):
            return None
        if d != d or d in (float('inf'), float('-inf')):   # NaN / infinity
            return None
        return d if -limit <= d <= limit else None

    lat, lng = one(latitude, 90), one(longitude, 180)
    if lat is None or lng is None or (lat == 0 and lng == 0):
        return None, None
    return lat, lng
