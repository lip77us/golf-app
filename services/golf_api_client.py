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

def _get(path: str, params: dict | None = None) -> dict:
    """
    Execute a GET request against GolfCourseAPI.
    Raises ValueError if GOLF_API_KEY is not set.
    Raises RuntimeError on HTTP errors or network failures.
    """
    key = getattr(settings, 'GOLF_API_KEY', '')
    import logging as _logging
    _logging.getLogger(__name__).warning(
        'GOLF_API_KEY in use: %r (first 6 chars: %s)',
        key[:6] + '...' if len(key) > 6 else key,
        key[:6],
    )
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
    logger.info('GolfCourseAPI request: %s', url)

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode('utf-8')
            data = json.loads(body)
            logger.info('GolfCourseAPI response (%s): %s', url, body[:3000])
            return data
    except HTTPError as exc:
        body = exc.read().decode('utf-8', errors='replace')
        msg  = f'GolfCourseAPI HTTP {exc.code} for {url} — {body[:400]}'
        logger.error(msg)
        raise RuntimeError(msg) from exc
    except Exception as exc:
        msg = f'GolfCourseAPI request failed for {url} — {type(exc).__name__}: {exc}'
        logger.error(msg)
        raise RuntimeError(msg) from exc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

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
    data    = _get('/v1/search', params={'search_query': query})
    courses = data.get('courses') or []
    return [_adapt_course_summary(c) for c in courses]


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

def _adapt_course_summary(raw: dict) -> dict:
    loc = raw.get('location') or {}
    return {
        'id'         : raw.get('id'),
        'club_name'  : raw.get('club_name', ''),
        'course_name': raw.get('course_name', ''),
        'city'       : loc.get('city', ''),
        'state'      : loc.get('state', ''),
        'country'    : loc.get('country', ''),
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
        'tees'       : all_tees,
    }


def _adapt_tee(raw: dict, sex: str) -> dict:
    holes = raw.get('holes') or []
    return {
        'name'         : raw.get('tee_name', ''),
        'slope'        : int(raw.get('slope_rating') or 113),
        'course_rating': float(raw.get('course_rating') or 72.0),
        'par'          : int(raw.get('par_total') or 72),
        'sex'          : sex,           # 'M' or 'W' — derived from tees.male / tees.female
        'holes'        : [_adapt_hole(h, number=i + 1) for i, h in enumerate(holes)],
    }


def _adapt_hole(raw: dict, number: int) -> dict:
    yards_raw = raw.get('yardage')
    return {
        'number'      : number,                                    # inferred from position
        'par'         : int(raw.get('par', 4)),
        'stroke_index': int(raw.get('handicap') or 18),           # API uses 'handicap'
        'yards'       : int(yards_raw) if yards_raw else None,
    }
