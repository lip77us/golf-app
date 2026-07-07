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
# 9-hole course is checked against ~half (31–39).
_TOTAL_PAR_18 = (62, 78)


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
