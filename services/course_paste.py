"""
services/course_paste.py
------------------------
Parser + persistence helper for the "paste a scorecard" course
importer (see CoursePasteView in api/views.py).

Why this exists
~~~~~~~~~~~~~~~
The GolfCourseAPI search/import flow only handles courses already in
that catalog.  For:
  * niche / private courses not in the catalog,
  * USGA re-ratings of an existing course
admins want to paste data straight off a scorecard PDF or a club
website.  This module turns one big blob of human-pasted text into
a structured (tees, holes) payload that CoursePasteView can either
preview or commit.

Format expected from the user
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A single multi-line string with two implicit sections:

  Tee specs    (one tee per line, in any order):
      <name>, <slope>, <rating> [, <sex>]
      Black, 144, 75.5, M
      Blue,  138, 72.7, M
      White, 130, 70.1, M
      Red,   124, 70.7, W

  Holes        (header row + 18 data rows):
      Hole Par SI Black Blue White Red
      1    4   7  412   395  365   315
      2    5   3  540   520  490   440
      ...
      18   5   5  540   520  500   460

The parser detects the holes section by finding the first row whose
first token (case-insensitively) is "Hole".  Anything before it is
tee specs.  Anything after is 18 hole rows.

Separators are auto-detected per line:
  * tab-delimited (HTML table copies)
  * comma-delimited
  * whitespace-delimited (typing into a textarea)
"""

from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

from django.db import models
from rest_framework import serializers


# Hole counts a pasted course may have: a full 18 or a short 9-hole course.
# Odd counts are deferred — see docs/hole-flexibility.md.
ALLOWED_HOLE_COUNTS = (9, 18)


# ---------------------------------------------------------------------------
# Token splitting
# ---------------------------------------------------------------------------

def _split_tokens(line: str) -> list[str]:
    """
    Split one line into tokens.  Picks tabs first, then commas, then
    runs of whitespace — whichever is present wins, so a single line
    is parsed consistently.  Empty tokens (e.g. trailing comma) are
    dropped.
    """
    if '\t' in line:
        raw = line.split('\t')
    elif ',' in line:
        raw = line.split(',')
    else:
        raw = re.split(r'\s+', line)
    return [t.strip() for t in raw if t.strip()]


# ---------------------------------------------------------------------------
# Main parser
# ---------------------------------------------------------------------------

class CoursePasteError(serializers.ValidationError):
    """Raised by parse_paste on malformed input.  Subclass of DRF's
    ValidationError so views can let it propagate to a 400."""


def parse_paste(text: str) -> dict[str, Any]:
    """
    Parse a paste blob.  Returns:
        {
          'tees': [
            {'name': str, 'slope': int, 'course_rating': Decimal,
             'par': int, 'sex': str|None},
            ...
          ],
          'holes': [
            {'number': int, 'par': int, 'stroke_index': int,
             'yards_by_tee': {tee_name: int, ...}},
            ...18 items, ordered 1-18...
          ],
        }

    `par` on each tee is computed from the sum of hole pars (we
    don't bother asking the user — every tee on a course plays the
    same per-hole pars in practice).
    """
    lines = [ln for ln in (raw.rstrip() for raw in text.splitlines())
             if ln.strip()]
    if not lines:
        raise CoursePasteError('The paste is empty.')

    holes_header_idx = _find_holes_header(lines)
    if holes_header_idx is None:
        raise CoursePasteError(
            'Could not find the holes header.  It should be a row '
            'starting with "Hole" — e.g. "Hole Par SI Black Blue White".'
        )

    tee_spec_lines = lines[:holes_header_idx]
    holes_header   = lines[holes_header_idx]
    holes_lines    = lines[holes_header_idx + 1:]

    tees = _parse_tee_specs(tee_spec_lines)
    if not tees:
        raise CoursePasteError(
            'Need at least one tee spec line before the "Hole" header.'
        )

    tee_columns = _parse_holes_header(holes_header)
    if len(tee_columns) == 0:
        raise CoursePasteError(
            'Holes header must list at least one tee column after '
            '"Hole Par SI".'
        )

    # Cross-check: every tee column must correspond to a tee spec,
    # though the reverse is allowed (specs can list extras that
    # don't appear in the holes table — we'll drop those with a
    # warning later).
    tee_specs_by_name = {t['name'].casefold(): t for t in tees}
    unknown = [c for c in tee_columns
               if c.casefold() not in tee_specs_by_name]
    if unknown:
        raise CoursePasteError(
            f'Holes header has tee column(s) {unknown!r} that have '
            f'no matching tee spec.  Add a spec line like '
            f'"{unknown[0]}, 130, 70.1, M" before the Hole row.'
        )

    holes = _parse_hole_rows(holes_lines, tee_columns)

    # Tee.par = sum of hole pars, applied to every tee.  Tees that
    # weren't in the holes header but were in the tee specs get
    # dropped — we can't store their hole data.
    par_total  = sum(h['par'] for h in holes)
    used_tees: list[dict] = []
    for col in tee_columns:
        spec = tee_specs_by_name[col.casefold()]
        # Preserve the holes-header capitalisation as the canonical
        # spelling, in case the user typed "white" in the spec but
        # "White" in the header.
        used_tees.append({
            **spec,
            'name': col,
            'par':  par_total,
        })

    return {'tees': used_tees, 'holes': holes}


# ---------------------------------------------------------------------------
# Section helpers
# ---------------------------------------------------------------------------

def _find_holes_header(lines: list[str]) -> int | None:
    """Index of the first line whose first token is "Hole" (CI)."""
    for i, line in enumerate(lines):
        toks = _split_tokens(line)
        if toks and toks[0].casefold() == 'hole':
            return i
    return None


def _parse_tee_specs(lines: list[str]) -> list[dict]:
    out = []
    for raw in lines:
        toks = _split_tokens(raw)
        if len(toks) < 3:
            raise CoursePasteError(
                f'Tee spec "{raw}" needs at least name, slope, rating.'
            )
        name = toks[0]
        try:
            slope  = int(toks[1])
            rating = Decimal(toks[2])
        except (ValueError, ArithmeticError):
            raise CoursePasteError(
                f'Tee spec "{raw}": slope must be an integer and '
                'rating a number.'
            )
        if not (55 <= slope <= 155):
            raise CoursePasteError(
                f'Tee spec "{raw}": slope {slope} must be 55-155.'
            )
        if not (Decimal('60') <= rating <= Decimal('80')):
            raise CoursePasteError(
                f'Tee spec "{raw}": rating {rating} must be 60-80.'
            )

        sex: str | None
        if len(toks) >= 4:
            s = toks[3].strip().upper()
            if s in ('M', 'MEN', "MEN'S"):
                sex = 'M'
            elif s in ('W', 'WOMEN', "WOMEN'S", 'L', 'LADIES'):
                sex = 'W'
            elif s in ('U', 'UNISEX', '-'):
                sex = None
            else:
                raise CoursePasteError(
                    f'Tee spec "{raw}": sex must be M, W, or U/Unisex.'
                )
        else:
            sex = 'M'

        out.append({
            'name':          name,
            'slope':         slope,
            'course_rating': rating,
            'sex':           sex,
        })
    return out


def _parse_holes_header(line: str) -> list[str]:
    toks = _split_tokens(line)
    # Expected: "Hole", "Par", "SI" (or "HCP"/"Handicap"), then tee names.
    if len(toks) < 3:
        raise CoursePasteError(
            f'Holes header "{line}" is too short — need at least '
            '"Hole Par SI <tee names>".'
        )
    if toks[1].casefold() != 'par':
        raise CoursePasteError(
            f'Holes header "{line}" — second column must be "Par".'
        )
    if toks[2].casefold() not in ('si', 'hcp', 'handicap', 'sh', 'index'):
        raise CoursePasteError(
            f'Holes header "{line}" — third column must be the '
            'stroke index ("SI", "HCP", "Handicap", "Index").'
        )
    return toks[3:]


def _parse_hole_rows(lines: list[str],
                     tee_columns: list[str]) -> list[dict]:
    n = len(lines)
    if n not in ALLOWED_HOLE_COUNTS:
        raise CoursePasteError(
            f'Expected 9 or 18 hole rows, got {n}.'
        )
    expected_cols = 3 + len(tee_columns)
    holes = []
    for idx, raw in enumerate(lines, start=1):
        toks = _split_tokens(raw)
        if len(toks) != expected_cols:
            raise CoursePasteError(
                f'Hole {idx} row "{raw}" has {len(toks)} tokens but '
                f'header has {expected_cols}.'
            )
        try:
            hole_num = int(toks[0])
            par      = int(toks[1])
            si       = int(toks[2])
            yards = {tee: int(toks[3 + i])
                     for i, tee in enumerate(tee_columns)}
        except ValueError:
            raise CoursePasteError(
                f'Hole {idx} row "{raw}" — every value must be a '
                'whole number.'
            )
        if hole_num != idx:
            raise CoursePasteError(
                f'Hole rows must be ordered 1..{n}.  Row {idx} starts '
                f'with hole number {hole_num}.'
            )
        if not (3 <= par <= 6):
            raise CoursePasteError(
                f'Hole {idx}: par {par} must be 3-6.'
            )
        if not (1 <= si <= n):
            raise CoursePasteError(
                f'Hole {idx}: stroke index {si} must be 1-{n}.'
            )
        for tee, y in yards.items():
            if not (50 <= y <= 800):
                raise CoursePasteError(
                    f'Hole {idx} tee {tee}: yards {y} must be 50-800.'
                )
        holes.append({
            'number':       hole_num,
            'par':          par,
            'stroke_index': si,
            'yards_by_tee': yards,
        })

    # SI uniqueness check — every stroke index 1-n should appear once.
    si_seen = sorted(h['stroke_index'] for h in holes)
    if si_seen != list(range(1, n + 1)):
        raise CoursePasteError(
            f'Stroke indexes must be 1..{n} with each value appearing '
            f'exactly once.  Got: {si_seen}.'
        )

    return holes


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Single-tee paste — for combo tees, men's vs women's stroke indexes,
# or adding one extra tee that the catalogue doesn't have yet.
# ---------------------------------------------------------------------------

def parse_single_tee_holes(text: str) -> list[dict]:
    """
    Parse 18 lines of "<hole> <par> <si> <yards>" into the same
    per-hole dict shape that parse_paste produces (minus the
    multi-tee yards_by_tee map — a single-tee paste only has one
    yards value per hole).

    Returns:
        [
          {'number': 1, 'par': 4, 'stroke_index': 7, 'yards': 412},
          ...18 items in order...
        ]
    """
    lines = [ln for ln in (raw.rstrip() for raw in text.splitlines())
             if ln.strip()]

    # Skip an optional header row whose first token is "Hole".
    if lines and _split_tokens(lines[0])[:1] == ['Hole'] \
            or (lines and _split_tokens(lines[0])
                and _split_tokens(lines[0])[0].casefold() == 'hole'):
        lines = lines[1:]

    n = len(lines)
    if n not in ALLOWED_HOLE_COUNTS:
        raise CoursePasteError(
            f'Expected 9 or 18 hole rows (one per line), got {n}.'
        )

    holes = []
    for idx, raw in enumerate(lines, start=1):
        toks = _split_tokens(raw)
        if len(toks) != 4:
            raise CoursePasteError(
                f'Hole {idx} row "{raw}" — need 4 numbers '
                '(hole, par, stroke index, yards).'
            )
        try:
            hole_num = int(toks[0])
            par      = int(toks[1])
            si       = int(toks[2])
            yards    = int(toks[3])
        except ValueError:
            raise CoursePasteError(
                f'Hole {idx} row "{raw}" — every value must be a '
                'whole number.'
            )
        if hole_num != idx:
            raise CoursePasteError(
                f'Hole rows must be ordered 1..{n}.  Row {idx} starts '
                f'with hole number {hole_num}.'
            )
        if not (3 <= par <= 6):
            raise CoursePasteError(
                f'Hole {idx}: par {par} must be 3-6.'
            )
        if not (1 <= si <= n):
            raise CoursePasteError(
                f'Hole {idx}: stroke index {si} must be 1-{n}.'
            )
        if not (50 <= yards <= 800):
            raise CoursePasteError(
                f'Hole {idx}: yards {yards} must be 50-800.'
            )
        holes.append({
            'number':       hole_num,
            'par':          par,
            'stroke_index': si,
            'yards':        yards,
        })

    si_seen = sorted(h['stroke_index'] for h in holes)
    if si_seen != list(range(1, n + 1)):
        raise CoursePasteError(
            f'Stroke indexes must be 1..{n} with each value appearing '
            f'exactly once.  Got: {si_seen}.'
        )
    return holes


def apply_single_tee(course, *, tee_name: str, slope: int,
                     course_rating, sex: str | None,
                     holes: list[dict]):
    """
    Persist a single-tee paste against an existing course.  Matches
    an existing tee by tee_name (CI); UPDATE if found, CREATE if
    not.  Preserves the tee pk on update so FoursomeMembership FKs
    (PROTECT) keep pointing at the same row across re-rates.

    Returns the Tee instance.
    """
    from django.db import transaction
    from core.models import Tee
    from services.tee_revisions import update_tee_geometry

    tee_name = tee_name.strip()
    if not tee_name:
        raise serializers.ValidationError(
            {'name': 'Tee name is required.'},
        )

    par_total = sum(h['par'] for h in holes)

    with transaction.atomic():
        # Match among CURRENT tees only — a retired (superseded) revision must
        # not be re-rated or re-matched.
        existing = next(
            (t for t in course.tees.all()
             if t.is_current and t.tee_name.casefold() == tee_name.casefold()),
            None,
        )
        attrs = dict(
            tee_name      = tee_name,
            slope         = slope,
            course_rating = course_rating,
            par           = par_total,
            sex           = sex,
            holes         = holes,
        )
        if existing is None:
            # New tee — assign a sort_priority just past the highest current
            # one so it lands at the bottom of the list.
            max_priority = course.tees.filter(
                superseded_by__isnull=True,
            ).aggregate(m=models.Max('sort_priority'))['m'] or 0
            tee = Tee.objects.create(
                course=course,
                sort_priority=max_priority + 10,
                **attrs,
            )
        else:
            # Copy-on-write: supersedes the row (preserving played rounds) when
            # the holes changed and it's been used; otherwise updates in place.
            tee = update_tee_geometry(existing, attrs)

    return tee


def apply_parse(account, parsed: dict[str, Any], *,
                course_name: str | None = None,
                replace_course=None):
    """
    Commit a parse_paste() result to the database.

    Exactly one of (course_name, replace_course) must be supplied:
      * course_name=str  → create a NEW Course in `account`.  Name
                           collisions (case-insensitive) raise
                           ValidationError to give the API a clean
                           400.
      * replace_course=Course → update the existing course's tees
                           in place.  Tees are matched by name (CI).
                           A tee in the paste that exists on the
                           course is UPDATED (slope, rating, sex,
                           par, holes); a tee that doesn't exist is
                           CREATED; a tee that exists on the course
                           but is NOT in the paste is LEFT ALONE
                           (we never delete here, to preserve any
                           FoursomeMembership FKs that point at it).

    Returns the Course instance.
    """
    from django.db import transaction
    from core.models import Course, Tee
    from services.tee_revisions import update_tee_geometry

    if bool(course_name) == bool(replace_course):
        raise ValueError(
            'apply_parse needs exactly one of course_name or '
            'replace_course.'
        )

    with transaction.atomic():
        if course_name is not None:
            name = course_name.strip()
            if not name:
                raise serializers.ValidationError(
                    {'name': 'Course name is required.'},
                )
            if Course.objects.for_account(account).filter(
                name__iexact=name,
            ).exists():
                raise serializers.ValidationError({
                    'name': f'A course called "{name}" already exists '
                            'in this account.',
                })
            course = Course.objects.create(account=account, name=name)
        else:
            course = replace_course

        existing_by_name = {
            t.tee_name.casefold(): t
            for t in course.tees.all() if t.is_current
        }

        for priority, spec in enumerate(parsed['tees'], start=10):
            holes_json = [
                {
                    'number':       h['number'],
                    'par':          h['par'],
                    'stroke_index': h['stroke_index'],
                    'yards':        h['yards_by_tee'][spec['name']],
                }
                for h in parsed['holes']
            ]
            attrs = dict(
                tee_name      = spec['name'],
                slope         = spec['slope'],
                course_rating = spec['course_rating'],
                par           = spec['par'],
                sex           = spec['sex'],
                sort_priority = priority,
                holes         = holes_json,
            )
            existing = existing_by_name.get(spec['name'].casefold())
            if existing is None:
                Tee.objects.create(course=course, **attrs)
            else:
                # Copy-on-write: preserves any round already played on this tee.
                update_tee_geometry(existing, attrs)

        return course
