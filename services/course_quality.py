"""
services/course_quality.py
--------------------------
Quality gate run BEFORE a course enters the shared catalog.

The GolfCourseAPI sometimes returns courses with missing or garbage per-hole
handicap (stroke index) data — e.g. every hole's `handicap` absent, which the
adapter used to collapse to stroke_index 18 for ALL 18 holes.  An all-18 stroke
index silently breaks net scoring (every hole allocates handicap strokes
identically), so we reject such courses at import time instead of poisoning the
catalog — and every account that later copies from it.

Operates on the ADAPTED course dict (the shape `fetch_course()` returns and that
`upsert_catalog_course()` consumes):

    {'tees': [{'name': str, ..., 'holes': [
        {'number': int, 'par': int, 'stroke_index': int, 'yards': int|None}, ...
    ]}]}

The same SI-permutation rule already guards the manual paste path
(services/course_paste.py); this brings the API import path up to parity.
"""

# Hole counts we accept into the catalog: full 18 or a short 9-hole course.
# Odd counts (e.g. Bandon Preserve 13, Shorty's 19) are deferred — see
# docs/hole-flexibility.md.
ALLOWED_HOLE_COUNTS = (9, 18)
MIN_PAR, MAX_PAR = 3, 6
# Plausible total-par band for an 18-hole course; scaled by hole count so a
# 9-hole course is checked against ~half (28–39).  The floor is 55, not ~72:
# legitimately short forward tees exist (e.g. Tilden's yellow tee is par 61),
# and the corrupt "all holes wrong" cases are caught by the per-hole par (3-6)
# and stroke-index permutation rules below.  55 still rejects an all-par-3
# course (54) — executive/par-3 layouts remain out of scope (hole-flexibility).
_TOTAL_PAR_18 = (55, 78)


def _total_par_band(n):
    lo, hi = _TOTAL_PAR_18
    return round(lo * n / 18), round(hi * n / 18)


class CourseQualityError(Exception):
    """Raised when a course fails the import quality gate.

    `problems` is a list of human-readable reasons (one per defect), suitable
    for returning straight to the client.
    """

    def __init__(self, problems):
        self.problems = list(problems)
        super().__init__('; '.join(self.problems))


def _tee_label(tee, index):
    return tee.get('name') or tee.get('tee_name') or f'tee #{index + 1}'


def validate_tee_holes(holes, *, label='tee'):
    """Return a list of hard-error strings for one tee's holes (empty == OK).

    A tee with NO holes is NOT an error here — it's a slope/rating-only tee
    still usable for gross games (the caller surfaces that as a soft warning).
    We only hard-fail a tee that CLAIMS per-hole data but gets it wrong, which
    is exactly what corrupts handicap allocation.
    """
    errors = []
    if not holes:
        return errors  # gross-only tee; handled as a soft warning upstream

    n = len(holes)
    if n not in ALLOWED_HOLE_COUNTS:
        errors.append(
            f'{label}: expected 9 or 18 holes, got {n}.'
        )

    nums = [h.get('number') for h in holes]
    if not all(isinstance(x, int) for x in nums) or sorted(nums) != list(range(1, n + 1)):
        errors.append(
            f'{label}: hole numbers must be 1..{n} with no gaps or duplicates.'
        )

    bad_par = [h.get('number') for h in holes
               if not isinstance(h.get('par'), int)
               or not (MIN_PAR <= h['par'] <= MAX_PAR)]
    if bad_par:
        errors.append(
            f'{label}: every hole par must be {MIN_PAR}-{MAX_PAR}; '
            f'invalid on hole(s) {bad_par}.'
        )
    else:
        total_par = sum(h['par'] for h in holes)
        min_total, max_total = _total_par_band(n)
        if not (min_total <= total_par <= max_total):
            errors.append(
                f'{label}: total par {total_par} is outside the plausible '
                f'{min_total}-{max_total} range.'
            )

    # The headline check: stroke index must be a permutation of 1..n.  This is
    # what catches the all-18 (and any duplicate/gap/out-of-range) defect.
    sis = [h.get('stroke_index') for h in holes]
    if not all(isinstance(s, int) for s in sis):
        errors.append(
            f'{label}: every hole needs an integer stroke index (handicap).'
        )
    elif sorted(sis) != list(range(1, n + 1)):
        errors.append(
            f'{label}: stroke indexes must be 1..{n} with each value appearing '
            f'exactly once (this allocates handicap strokes per hole).  '
            f'Got: {sorted(sis)}.'
        )
    return errors


def assert_course_quality(api_course):
    """Raise CourseQualityError if `api_course` is unfit for the catalog.

    Returns a list of soft warnings (e.g. gross-only tees) when it passes, so
    the caller can surface them without blocking the import.
    """
    tees = api_course.get('tees') or []
    problems = []
    warnings = []

    if not tees:
        problems.append('Course has no tees.')

    for i, tee in enumerate(tees):
        label = _tee_label(tee, i)

        # **A tee with no course rating cannot be played net**, and importing
        # one is worse than refusing it: course handicap is
        # `index x slope/113 + (CR - par)`, so a missing CR either crashes or
        # gets defaulted into a plausible number that silently moves every
        # handicap at the course. The adapter used to default it to 72.0;
        # it now reports None and this is where that lands.
        #
        # Same rule as the stroke index: reject rather than import a
        # gross-only approximation, and let the TD paste a corrected card.
        if tee.get('course_rating') in (None, ''):
            problems.append(
                f'{label}: no course rating. Net scoring needs one, and a '
                f'guessed rating would change every handicap here without '
                f'saying so.'
            )
        if not tee.get('slope'):
            problems.append(f'{label}: no slope rating.')
        if not tee.get('par'):
            problems.append(f'{label}: no par for the tee.')

        holes = tee.get('holes') or []
        if not holes:
            warnings.append(
                f'{label}: no per-hole data — usable for gross games only.'
            )
            continue
        problems.extend(validate_tee_holes(holes, label=label))

    if problems:
        raise CourseQualityError(problems)
    return warnings


# ---------------------------------------------------------------------------
# A record that disagrees with itself about where it is
# ---------------------------------------------------------------------------

#: Country names that mean the same place. Only the cases that actually
#: collide: a geocoded address says `USA` where a record says
#: `United States`, and the UK's constituent countries are routinely given
#: where the address says `UK`. Everything else is compared literally.
_SAME_COUNTRY = {
    'usa': 'us', 'u.s.a.': 'us', 'us': 'us', 'u.s.': 'us',
    'united states': 'us', 'united states of america': 'us',

    'uk': 'uk', 'u.k.': 'uk', 'gb': 'uk', 'great britain': 'uk',
    'united kingdom': 'uk', 'england': 'uk', 'scotland': 'uk',
    'wales': 'uk', 'northern ireland': 'uk',

    'uae': 'ae', 'united arab emirates': 'ae',
    'republic of ireland': 'ie', 'ireland': 'ie', 'eire': 'ie',
    'south korea': 'kr', 'korea': 'kr', 'republic of korea': 'kr',
    'czechia': 'cz', 'czech republic': 'cz',
}


def _canonical_country(name: str) -> str:
    key = (name or '').strip().lower().rstrip('.')
    if not key:
        return ''
    return _SAME_COUNTRY.get(key) or _SAME_COUNTRY.get(key + '.') or key


def country_contradiction(row: dict) -> str | None:
    """Does this proximity row disagree with ITSELF about which country it is in?

    Returns a one-line description, or None when the row is consistent or
    cannot be judged.

    **The case this exists for**, seen in production on 20 Oct 2026, four
    miles from Oakland::

        club_name : Royal Golf Residence
        city      : Londrina      state: PR      country: Brazil
        address   : "Alameda, CA, USA"
        latitude  : 37.7798721    longitude: -122.2821855

    `Alameda` is Portuguese for avenue. A Brazilian street line beginning
    "Alameda …" was handed to a geocoder, which matched the city of Alameda,
    California and returned its coordinates — so a club in Paraná has sat in
    the Bay Area in the upstream database ever since. Every genuine neighbour
    in that same response carried a real street address; this one's was the
    bare string above.

    **Why dropping is right, and only here.** The row's distance is perfectly
    correct *for the coordinates it carries* — our maths was never wrong. But
    a proximity list exists for one reason, position, and a record whose own
    fields disagree about which continent it is on has nothing trustworthy to
    offer it. The same record is still perfectly findable by NAME, where the
    golfer is the one judging whether it is the course he meant.

    **It fails open on purpose.** Hiding a real course from a picker is worse
    than showing a strange one, so a row is dropped only when both countries
    are present AND normalise to something different. An unknown name, a
    missing address, an address with no country — all keep the row.
    """
    stated = (row.get('country') or '').strip()
    address = (row.get('address') or '').strip()
    if not stated or not address or ',' not in address:
        return None

    tail = address.rsplit(',', 1)[-1].strip()
    if not tail:
        return None

    a, b = _canonical_country(stated), _canonical_country(tail)
    if not a or not b or a == b:
        return None
    return (f'says country={stated!r} but its address ends {tail!r} '
            f'({address!r})')
