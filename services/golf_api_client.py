"""
services/golf_api_client.py
---------------------------
Thin HTTP client for GolfCourseAPI (https://api.golfcourseapi.com).

Endpoints used
~~~~~~~~~~~~~~
    GET /v1/search?search_query={query}   Search courses by club/course name
    GET /v1/courses/{id}                  Full course data (tees + holes)

Authentication
~~~~~~~~~~~~~~
    Authorization: Key {GOLF_API_KEY}

IMPORTANT — Field name adapters
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The functions _adapt_course_summary(), _adapt_course_detail(), _adapt_tee(),
and _adapt_hole() are the single place to fix if the API returns field names
that differ from the ones assumed here.  Check a real API response and update
only those functions — the rest of the codebase stays unchanged.

API response shapes
~~~~~~~~~~~~~~~~~~~
Search  → { "courses": [ { "id", "club_name", "course_name",
                            "location": { "city", "state", "country" } } ] }

Detail  → { "id", "club_name", "course_name",
             "location": { "address", "city", "state", "country",
                            "latitude", "longitude" },
             "tees": {
               "male":   [ TeeBox, ... ],
               "female": [ TeeBox, ... ]
             } }

TeeBox  → { "tee_name", "course_rating", "slope_rating", "par_total",
             "total_yards", "number_of_holes",
             "holes": [ { "par", "yardage", "handicap" } ] }
            (holes array is ordered 1..18; no explicit hole-number field)
"""

import json
import urllib.parse
import urllib.request
from urllib.error import HTTPError

from django.conf import settings


# ---------------------------------------------------------------------------
# Low-level HTTP helper
# ---------------------------------------------------------------------------

#: Query parameters whose VALUES may be written to a log.
#:
#: An ALLOWLIST rather than a denylist, which is the whole point: a denylist
#: fails open, so the next endpoint's parameter would be logged in full until
#: somebody remembered to add it. Here a new parameter is secret by default
#: and shows as ``REDACTED`` until it is named safe.
#:
#: What this exists for is ``/v1/proximity``'s ``latitude``/``longitude``. A
#: position is the one thing this client sends that describes a PERSON rather
#: than a golf course, and the App Privacy and Play Data-safety answers for
#: "near me" both claim it is not retained — a log line is retention.
_LOGGABLE_PARAMS = frozenset({'search_query', 'radius', 'limit'})


def _safe_url(path: str, params: dict | None = None) -> str:
    """The request line, rebuilt for a LOG with unlisted values redacted.

    Keeps `search_query` readable — a search that found the wrong course is
    diagnosed from the term that was sent, which is how "The Bridges" filed
    upstream as "Bridges (The)" was found — while `latitude`/`longitude`
    become `REDACTED`.
    """
    base = getattr(settings, 'GOLF_API_BASE_URL', 'https://api.golfcourseapi.com')
    out  = f'{base.rstrip("/")}{path}'
    if params:
        # `REDACTED`, not `[redacted]`: urlencode percent-escapes the
        # brackets into `%5Bredacted%5D`, which reads like a value in a log.
        shown = {
            k: (v if k in _LOGGABLE_PARAMS else 'REDACTED')
            for k, v in params.items() if v is not None
        }
        if shown:
            out += '?' + urllib.parse.urlencode(shown)
    return out


def _get(path: str, params: dict | None = None) -> dict:
    """
    Execute a GET request against GolfCourseAPI.
    Raises ValueError if GOLF_API_KEY is not set.
    Raises RuntimeError on HTTP errors or network failures.

    **Nothing here may log or raise the real query string.** `_safe_url` is
    what goes into a message, including the two `RuntimeError`s — a caller
    that logs `traceback.format_exc()` (`CourseFindView` does) would
    otherwise print whatever the exception carries, so redacting only at the
    `logger` call would have left the leak open one frame up.
    """
    key = getattr(settings, 'GOLF_API_KEY', '')
    if not key:
        raise ValueError(
            'GOLF_API_KEY is not configured.  '
            'Set it in your environment or in settings.py.'
        )

    base = getattr(settings, 'GOLF_API_BASE_URL', 'https://api.golfcourseapi.com')
    url  = f'{base.rstrip("/")}{path}'
    if params:
        url += '?' + urllib.parse.urlencode(
            {k: v for k, v in params.items() if v is not None}
        )

    req = urllib.request.Request(url, headers={
        'Authorization': f'Key {key}',
        'Accept'       : 'application/json',
    })

    import logging
    logger = logging.getLogger(__name__)
    # Drop the per-request trace to DEBUG — it logged the full response
    # body (up to 3000 chars) on every course load, which spammed the
    # server log.  INFO-level callers still see the higher-level
    # "CourseImportView" summary; flip the level to DEBUG via
    # DJANGO_LOG_LEVEL=DEBUG if you need the raw API payload again.
    safe = _safe_url(path, params)
    logger.debug('GolfCourseAPI request: %s', safe)

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode('utf-8')
            data = json.loads(body)
            logger.debug('GolfCourseAPI response (%s): %s', safe, body[:3000])
            return data
    except HTTPError as exc:
        body = exc.read().decode('utf-8', errors='replace')
        msg  = f'GolfCourseAPI HTTP {exc.code} for {safe} — {body[:400]}'
        logger.error(msg)
        raise RuntimeError(msg) from exc
    except Exception as exc:
        msg = f'GolfCourseAPI request failed for {safe} — {type(exc).__name__}: {exc}'
        logger.error(msg)
        raise RuntimeError(msg) from exc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#: Leading words a club name is filed under elsewhere. Upstream stores "The
#: Bridges" as "Bridges (The)", so the article has to come off the query or
#: the course cannot be found by its own name.
_LEADING_ARTICLES = ('the ', 'a ', 'an ')


def search_terms(query: str) -> str:
    """The query to actually send upstream.

    **Strips a leading article.** Reported from San Ramon, 18 Oct 2026: The
    Bridges Golf Club did not come up. GolfCourseAPI files it as
    `Bridges (The)`, so "The Bridges" returns eleven courses and none of them
    is the one you played, while "Bridges" finds it immediately.

    Strictly better for recall and it loses nothing: searching "Bridges"
    returns every "The Bridges" as well as every "Bridges (The)". The cost is
    a wider result set, which the merge already caps.

    Only a LEADING article, and only when something follows it -- "The" alone
    is somebody still typing.
    """
    q = (query or '').strip()
    low = q.lower()
    for art in _LEADING_ARTICLES:
        if low.startswith(art) and len(q) > len(art):
            return q[len(art):].strip()
    return q


def search_courses(query: str) -> list:
    """
    Search for golf courses by club name or course name.

    Returns a list of course summary dicts:
        [{
            'id'         : int,
            'club_name'  : str,
            'course_name': str,
            'city'       : str,
            'state'      : str,
            'country'    : str,
        }]
    """
    data    = _get('/v1/search', params={'search_query': search_terms(query)})
    courses = data.get('courses') or []
    return [_adapt_course_summary(c) for c in courses]


#: GolfCourseAPI caps the proximity radius. Sending more is a 4xx, so the
#: view clamps rather than letting a typo in a query string fail the request.
PROXIMITY_MAX_RADIUS_MILES = 50
#: ...and the page size. 25 is the server's ceiling, not a preference.
PROXIMITY_MAX_LIMIT = 25


def courses_near(latitude, longitude, radius=10, limit=25) -> list:
    """
    Courses within `radius` miles of a point, nearest first.

    Returns `_adapt_course_summary` rows with one extra key, **`distance`** in
    miles, which is the whole reason this endpoint exists rather than being a
    search with a clever query.

    `radius` and `limit` are CLAMPED to what the API accepts rather than
    passed through: both have hard ceilings upstream, and a request that 4xxs
    costs the same daily quota as one that works.

    Quota: this is a new line against the 10k/day Pro allowance, so callers
    fire it on a tap, never on every screen open.
    """
    radius = max(1, min(int(radius or 10), PROXIMITY_MAX_RADIUS_MILES))
    limit  = max(1, min(int(limit or 25), PROXIMITY_MAX_LIMIT))

    data = _get('/v1/proximity', params={
        'latitude' : latitude,
        'longitude': longitude,
        'radius'   : radius,
        'limit'    : limit,
    })
    # The search endpoint returns {"courses": [...]}; proximity is documented
    # the same way. Fall back to a bare list so a shape change degrades to
    # "no nearby courses" instead of raising inside a best-effort caller.
    raw = data.get('courses') if isinstance(data, dict) else data
    out = []
    for c in (raw or []):
        row = _adapt_course_summary(c)
        # Distance rides on the summary rather than being recomputed: the API
        # knows where it measured from, and re-deriving it here would be a
        # second answer to the same question.
        d = c.get('distance')
        try:
            row['distance'] = round(float(d), 1) if d is not None else None
        except (TypeError, ValueError):
            row['distance'] = None
        out.append(row)
    return out


def fetch_course(course_id) -> dict:
    """
    Fetch full course data including all tee sets and hole-by-hole scorecard.

    Returns a canonical dict:
        {
            'id'         : int,
            'club_name'  : str,
            'course_name': str,
            'city'       : str,
            'state'      : str,
            'country'    : str,
            'tees'       : [
                {
                    'name'         : str,
                    'slope'        : int,
                    'course_rating': float,
                    'par'          : int,
                    'sex'          : 'M' | 'W',
                    'holes'        : [
                        { 'number': int, 'par': int,
                          'stroke_index': int, 'yards': int | None }
                    ],
                }
            ],
        }
    """
    data = _get(f'/v1/courses/{course_id}')
    # API wraps the result in a top-level "course" key.
    raw  = data.get('course') or data
    return _adapt_course_detail(raw)


# ---------------------------------------------------------------------------
# Adapters — update here if the API uses different field names
# ---------------------------------------------------------------------------

def _opt_int(value):
    """int(value), or None when the value is missing/blank/non-numeric.

    Used so the adapter doesn't FABRICATE per-hole data the upstream omitted —
    a missing handicap/par becomes a sentinel the quality gate can reject,
    rather than a plausible-looking default that silently corrupts scoring.
    """
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _adapt_course_summary(raw: dict) -> dict:
    loc = raw.get('location') or {}
    return {
        'id'         : raw.get('id'),
        'club_name'  : raw.get('club_name', ''),
        'course_name': raw.get('course_name', ''),
        'city'       : loc.get('city', ''),
        'state'      : loc.get('state', ''),
        'country'    : loc.get('country', ''),
        # Kept for ONE job: `course_quality.country_contradiction`. The
        # address is what the coordinates were geocoded FROM, so when it and
        # `country` disagree the row cannot be trusted to be where it claims.
        # Never displayed — the app shows city/state.
        'address'    : loc.get('address', ''),
    }


def _adapt_course_detail(raw: dict) -> dict:
    loc      = raw.get('location') or {}
    tees_raw = raw.get('tees') or {}

    male_tees   = tees_raw.get('male')   or []
    female_tees = tees_raw.get('female') or []

    all_tees = (
        [_adapt_tee(t, sex='M') for t in male_tees] +
        [_adapt_tee(t, sex='W') for t in female_tees]
    )

    return {
        'id'         : raw.get('id'),
        'club_name'  : raw.get('club_name', ''),
        'course_name': raw.get('course_name', ''),
        'city'       : loc.get('city', ''),
        'state'      : loc.get('state', ''),
        'country'    : loc.get('country', ''),
        'latitude'   : loc.get('latitude'),
        'longitude'  : loc.get('longitude'),
        'tees'       : all_tees,
    }


def _adapt_tee(raw: dict, sex: str) -> dict:
    """One tee set, with **nothing invented**.

    This used to default a missing slope to 113, a missing course rating to
    72.0 and a missing par to 72 — three plausible-looking numbers that are
    silently wrong. `_adapt_hole` was fixed for exactly this and `_adapt_tee`,
    ten lines below it in the same file, was left behind.

    **Found while chasing a different bug, and NOT demonstrated by it.** The
    Bridges in San Ramon has a full rating on every tee (White is 70.5/129,
    par 72); I reported otherwise after probing `tee['rating']` when this
    function emits `course_rating`, so every tee read as None. The
    fabrication below is real and worth removing on its own merit — no course
    yet found has triggered it.

    Why a fabricated rating is worse than a missing one: course handicap is
    `index x slope/113 + (CR - par)`, so a CR invented as 72.0 against a real
    par of 72 makes that term ZERO and quietly moves every handicap at the
    course. Nothing on screen says so. The handicap BASIS reads
    `tee.course_rating` directly too, so one fabricated figure would become
    the reference for a whole field.

    Missing values come through as None / 0 so `services.course_quality` can
    see them and refuse the import, which is the same call the stroke-index
    permutation check already makes.
    """
    holes = raw.get('holes') or []
    return {
        'name'         : raw.get('tee_name', ''),
        'slope'        : _opt_int(raw.get('slope_rating')) or None,
        'course_rating': (float(raw['course_rating'])
                          if raw.get('course_rating') not in (None, '')
                          else None),
        'par'          : _opt_int(raw.get('par_total')),
        'sex'          : sex,           # 'M' or 'W' — derived from tees.male / tees.female
        'holes'        : [_adapt_hole(h, number=i + 1) for i, h in enumerate(holes)],
    }


def _adapt_hole(raw: dict, number: int) -> dict:
    yards_raw = raw.get('yardage')
    # Do NOT invent a stroke index / par when the API omits it.  A sentinel 0
    # makes the import quality gate (services/course_quality.py) reject the
    # course instead of silently collapsing every hole to SI 18 (which breaks
    # per-hole handicap allocation) or par 4.
    si  = _opt_int(raw.get('handicap'))           # API uses 'handicap' for SI
    par = _opt_int(raw.get('par'))
    return {
        'number'      : number,                   # inferred from position
        'par'         : par if par is not None else 0,
        'stroke_index': si if si is not None else 0,
        'yards'       : int(yards_raw) if yards_raw else None,
    }
