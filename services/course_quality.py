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


# ---------------------------------------------------------------------------
# Yardage cross-check — OPERATOR ONLY
# ---------------------------------------------------------------------------

def yardage_notes(api_course) -> list:
    """Notes where a tee's STATED total disagrees with the sum of its holes.

    **These are for us, never for the golfer.**  Paul, 27 Oct 2026: *"as long
    as it is only a warning to us and not to the user.  They never care about
    the accuracy of total yards."*  He is right, and the mechanics agree: yards
    feed the display and the combo-tee indicator, while scoring reads par and
    stroke index — so a four-yard typo must not colour a snackbar at a golfer
    who is trying to add his home course.

    That is why this is a separate function with its own return value rather
    than more entries in `assert_course_quality`'s warnings list: THAT list
    reaches the user through `result['warning']`.  Two audiences, two channels,
    kept apart by construction — the same split `detail` and `problems` needed
    one commit earlier, after the technical reason was shown to a member in a
    red snackbar.

    Never raises and never blocks an import: a mismatch is a HINT that some
    per-hole number is wrong, not proof, and refusing a course over it would
    block real courses for something cosmetic.

    Why it earns its keep: at Annandale three stated totals disagreed with
    their holes, and all three were real errors — Green's 1st and 18th (which
    also broke a combo), a combo blended from the wrong column on two holes,
    and one genuine typo in the total itself.  None of it was visible to the
    app, because the adapter used to drop `total_yards` entirely.
    """
    tees = api_course.get('tees') or []
    # Only grumble about a MISSING total when the card carries them elsewhere.
    # Plenty of courses simply have no such field, and reporting every tee of
    # every one of those is noise that would get the whole check ignored.
    any_stated = any(t.get('total_yards') for t in tees)

    notes = []
    for i, tee in enumerate(tees):
        label = _tee_label(tee, i)
        sex = tee.get('sex') or '?'
        holes = tee.get('holes') or []
        total = sum((h.get('yards') or 0) for h in holes)
        if not total:
            # No per-hole yardages at all — there is nothing to compare, and
            # a rating-only tee is a legitimate shape (see the 0-hole rule).
            continue

        stated = tee.get('total_yards')
        if not stated:
            if any_stated:
                notes.append(
                    f'{label} ({sex}): no stated total; the holes add to {total}.'
                )
            continue

        if int(stated) != total:
            notes.append(
                f'{label} ({sex}): stated total {stated} but the holes add to '
                f'{total} (off by {int(stated) - total:+d}).'
            )
    return notes
