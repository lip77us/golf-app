"""
console/courses.py
------------------
The course library, the editor, and the push upstream.

Three things this file is careful about, in order of how badly they bite:

1. **A played tee is immutable.**  Every scoring service reads par and stroke
   index LIVE from ``membership.tee.holes``, so editing a tee in place would
   retroactively rewrite the net scores of every round played on it.  All
   geometry goes through ``services/tee_revisions.update_tee_geometry``, which
   retires the old row and creates a new revision when the tee has been used.
   Nothing here writes ``Tee.holes`` directly.

2. **A stroke-index set is a ranking.**  1..18, each exactly once.  Anything
   else allocates handicap strokes wrongly, silently, for everyone who plays
   it — so it is rejected rather than warned about, reusing the same
   ``services/course_quality.validate_tee_holes`` the API import gate uses.

3. **The account's copy and the shared catalog are different things.**  Editing
   here changes the account's own clone and nobody else's.  Pushing upstream
   changes ``CatalogCourse``, which every other account clones from — a much
   bigger act, and one that also marks the tees ``curated`` so a later
   GolfCourseAPI re-import cannot undo it.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from django.db.models import Count, Max

from core.models import Course, Tee
from services.course_quality import validate_tee_holes
from services.tee_revisions import update_tee_geometry

from .models import CourseCheck


# Tee-level fields the console may change, and how to read each off a form.
TEE_FIELDS = ('tee_name', 'course_rating', 'slope', 'par')
# Per-hole fields, in the order the grid draws them.
HOLE_FIELDS = ('par', 'yards', 'stroke_index')


# ---------------------------------------------------------------------------
# The library
# ---------------------------------------------------------------------------

def library(account) -> list[dict]:
    """Every course this account owns, most-played first.

    Sorted by rounds played rather than alphabetically on purpose: the course
    you are about to run a tournament on is the one worth ten minutes with the
    printed card, and that ordering is the only nudge the page needs.
    """
    courses = (Course.objects.filter(account=account)
               .annotate(round_count=Count('rounds', distinct=True))
               .prefetch_related('tees'))

    # One query for the whole library rather than one per course.
    latest = {}
    for check in CourseCheck.objects.filter(account=account).order_by('created_at'):
        latest[check.course_id] = check          # last write wins == most recent

    rows = []
    for course in courses:
        check = latest.get(course.id)
        rows.append({
            'course':   course,
            'tees':     sum(1 for t in course.tees.all() if t.is_current),
            'rounds':   course.round_count,
            'updated':  check.created_at if check else course.created_at,
            'state':    _state(check),
            'check':    check,
        })
    rows.sort(key=lambda r: (-r['rounds'], r['course'].name.lower()))
    return rows


def _state(check) -> dict:
    """What the library says about a course record's confidence.

    A course nobody has ever checked is not the same as one somebody checked
    and found correct, and the library is the only place that difference can
    show up.
    """
    if check is None:
        return {'label': 'NEVER CHECKED', 'tone': 'old',
                'action': 'Check the card'}
    if check.kind == CourseCheck.KIND_VERIFIED:
        return {'label': 'VERIFIED BY YOU', 'tone': 'ok', 'action': 'Open'}
    if check.kind == CourseCheck.KIND_EDITED:
        return {'label': 'CORRECTED BY YOU', 'tone': 'upd', 'action': 'Open'}
    if check.status == CourseCheck.STATUS_APPLIED:
        return {'label': 'SENT TO HALVED', 'tone': 'upd', 'action': 'Open'}
    return {'label': 'REPORTED · IN REVIEW', 'tone': 'rev', 'action': 'Open'}


def current_tees(course) -> list[Tee]:
    """Only the live revisions, each carrying its totals.

    A retired tee still exists so old scorecards render, but it is not
    something anyone should be editing.
    """
    tees = sorted((t for t in course.tees.all() if t.is_current),
                  key=lambda t: (t.sort_priority, t.tee_name))
    for tee in tees:
        add_totals(tee)
    return tees


def add_totals(tee) -> None:
    """Hang par and yardage totals off the tee for the grid's last column.

    Derived, never stored: `Tee.par` is the field of record, but a card that
    shows eighteen numbers and no total makes the reader add them up to check
    the one number that is stored — so the grid does the addition.  Yardage has
    no stored total at all, which is the other half of the reason.
    """
    tee.par_total = sum(h.get('par') or 0 for h in tee.holes) or None
    yards = [h.get('yards') or 0 for h in tee.holes]
    # A tee with no yardage at all shows a dash rather than a confident 0.
    tee.yards_total = sum(yards) or None


def custom_sets(account) -> list[dict]:
    """Every re-index this account owns, across every course.

    Worth its own page rather than only living under the course that hosts it:
    a set is built for an event, and the question a TD asks later is "what have
    I got, and is anything using it" — not "which course was that on".
    """
    from tournament.models import FoursomeMembership

    tees = (Tee.objects
            .filter(course__account=account, custom_index_of__isnull=False,
                    superseded_by__isnull=True)
            .select_related('course', 'custom_index_of'))
    rows = []
    for tee in tees:
        source = tee.custom_index_of
        moved = []
        if source:
            by_number = {h['number']: h.get('stroke_index') for h in source.holes}
            moved = [h['number'] for h in tee.holes
                     if by_number.get(h['number']) != h.get('stroke_index')]
        rows.append({
            'tee':     tee,
            'source':  source,
            'course':  tee.course,
            'moved':   len(moved),
            'rounds':  FoursomeMembership.objects.filter(tee=tee).count(),
        })
    rows.sort(key=lambda r: (r['course'].name.lower(), r['tee'].tee_name.lower()))
    return rows


# ---------------------------------------------------------------------------
# Reading an edit off the form
# ---------------------------------------------------------------------------

class EditError(Exception):
    """A rejected edit, carrying the messages to put on the page."""

    def __init__(self, problems):
        self.problems = problems if isinstance(problems, list) else [problems]
        super().__init__('; '.join(self.problems))


def _int(raw, label, problems, *, lo=None, hi=None):
    try:
        val = int(str(raw).strip())
    except (TypeError, ValueError):
        problems.append(f'{label}: "{raw}" is not a whole number.')
        return None
    if lo is not None and val < lo or hi is not None and val > hi:
        problems.append(f'{label}: {val} is outside {lo}–{hi}.')
        return None
    return val


def read_tee_form(post, tee) -> tuple[dict, list[dict]]:
    """Form POST -> (attrs for update_tee_geometry, human-readable diff).

    Returns only what actually CHANGED, so an edit that touched nothing is
    visibly a no-op rather than a new tee revision.
    """
    problems: list[str] = []
    attrs: dict = {}
    diff: list[dict] = []

    name = (post.get('tee_name') or '').strip()
    if not name:
        problems.append('The tee needs a name.')
    elif name != tee.tee_name:
        attrs['tee_name'] = name
        diff.append({'label': 'tee name', 'before': tee.tee_name, 'after': name})

    slope = _int(post.get('slope'), 'Slope', problems, lo=55, hi=155)
    if slope is not None and slope != tee.slope:
        attrs['slope'] = slope
        diff.append({'label': 'slope', 'before': str(tee.slope), 'after': str(slope)})

    try:
        rating = Decimal((post.get('course_rating') or '').strip())
    except (InvalidOperation, TypeError):
        problems.append(f'Rating: "{post.get("course_rating")}" is not a number.')
        rating = None
    if rating is not None:
        if not (Decimal('50') <= rating <= Decimal('90')):
            problems.append(f'Rating: {rating} is outside 50–90.')
        elif rating != tee.course_rating:
            attrs['course_rating'] = rating
            diff.append({'label': 'rating', 'before': str(tee.course_rating),
                         'after': str(rating)})

    # Holes.  Read every one, then validate the SET — a duplicate index is only
    # half the error, and the missing number is the one the TD has to find.
    holes, changed_holes = [], []
    for hole in tee.holes:
        n = hole['number']
        new = dict(hole)
        for field in HOLE_FIELDS:
            raw = post.get(f'{field}_{n}')
            if raw is None or str(raw).strip() == '':
                continue
            bounds = {'par': (3, 6), 'stroke_index': (1, len(tee.holes)),
                      'yards': (30, 800)}[field]
            val = _int(raw, f'Hole {n} {field.replace("_", " ")}', problems,
                       lo=bounds[0], hi=bounds[1])
            if val is None:
                continue
            if val != hole.get(field):
                new[field] = val
                changed_holes.append({
                    'label': f'hole {n} {field.replace("_", " ")}',
                    'before': str(hole.get(field, '')), 'after': str(val)})
        holes.append(new)

    if problems:
        raise EditError(problems)

    # The same permutation check the API import gate runs.  Enforced, not
    # warned about: a set that isn't 1..18 allocates strokes wrongly for
    # everyone who plays it.
    errors = validate_tee_holes(holes, label=name or tee.tee_name)
    if errors:
        raise EditError(errors)

    if changed_holes:
        attrs['holes'] = holes
        diff.extend(changed_holes)

    total_par = sum(h['par'] for h in holes) if holes else None
    if total_par is not None and total_par != tee.par:
        attrs['par'] = total_par
        diff.append({'label': 'par', 'before': str(tee.par), 'after': str(total_par)})

    return attrs, diff


def rating_at_risk(diff) -> bool:
    """True when the edit changed the shape of the golf course rather than just
    where the strokes fall.

    A re-index leaves the rating describing the same course.  Changing par or
    yardage does not — the rating now describes a course that does not exist,
    and every net score computed from it is quietly wrong until someone
    re-rates.  Worth saying out loud; not worth blocking, because the record
    may be catching up with a real re-measure.
    """
    return any(d['label'].endswith(' par') or d['label'].endswith(' yards')
               or d['label'] == 'par' for d in diff)


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

def apply_edit(course, tee, attrs, diff, user) -> CourseCheck:
    """Commit a tee edit and record that it happened.

    Geometry goes through ``update_tee_geometry``, which is what keeps a played
    round's scorecard frozen: if this tee has been used, the old row is retired
    and a new revision created rather than the holes changing underneath it.
    """
    update_tee_geometry(tee, attrs)
    return CourseCheck.objects.create(
        account=course.account, course=course, user=user,
        kind=CourseCheck.KIND_EDITED, tee_name=tee.tee_name, changes=diff)


def mark_verified(course, user, tee_name='') -> CourseCheck:
    """Record a check that found nothing wrong.

    Not a no-op: it is the only thing that separates a record somebody has
    stood over with the printed card from one nobody has ever looked at.
    """
    return CourseCheck.objects.create(
        account=course.account, course=course, user=user,
        kind=CourseCheck.KIND_VERIFIED, tee_name=tee_name)


def send_upstream(course, user, *, source, note, diff, is_staff) -> CourseCheck:
    """Push the corrected record at the SHARED catalog.

    Staff write straight through — there is no queue behind this, and pretending
    otherwise would just be a report nobody actions.  Everyone else files it,
    and the account's own copy is already correct either way, so nothing is
    blocked on the answer.

    Note what a catalog write means: ``catalog_from_course`` marks the tees
    ``curated``, which PROTECTS them from a later GolfCourseAPI re-import
    overwriting them.  That is the intent — a human looked at the card — but it
    does mean the API stops being able to correct that course automatically.
    """
    from django.db import transaction

    check = CourseCheck(
        account=course.account, course=course, user=user,
        kind=CourseCheck.KIND_REPORTED, changes=diff,
        source=source, note=note)

    with transaction.atomic():
        if is_staff:
            from services.catalog import catalog_from_course
            catalog_from_course(course, overwrite=True)
            check.upstream = True
            check.status = CourseCheck.STATUS_APPLIED
        else:
            check.status = CourseCheck.STATUS_SENT
        check.number = check.next_number()
        check.save()
    return check


def report_email(course, check, user) -> tuple[str, str]:
    """The message that leaves, as (subject, body).

    A diff, not prose — written to be actionable by someone who has never met
    this TD and is looking at a database row.  The TD sees it before it goes,
    because they are the one sending it.
    """
    lines = [
        f'Course   {course.name} · id {course.id}',
        f'Source   {check.get_source_display()}',
        f'From     {user.get_full_name() or user.username} · {course.account.name}',
        '',
    ]
    for d in check.changes:
        lines.append(f'{d["label"]:<22} {d["before"] or "—"} -> {d["after"]}')
    if check.note:
        lines += ['', 'Note:', check.note]
    subject = (f'Course correction — {course.name} '
               f'({len(check.changes)} field{"" if len(check.changes) == 1 else "s"})')
    return subject, '\n'.join(lines)
