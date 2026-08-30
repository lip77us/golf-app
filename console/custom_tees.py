"""
console/custom_tees.py
----------------------
A private re-index of a tee set.

The case: a course sets its stroke index off the tips, and off the whites it
makes no sense — the 4th plays 478 from the back and 318 from the front and is
still index 1.  The printed card is not wrong; it is written for a tee nobody in
this event is playing.  So a TD builds their own ranking.

**Index only, and the lock is the feature.**  Par, yards, rating and slope are
carried over and cannot be touched.  A re-index changes nothing about the golf
course, so the rating still describes it and every handicap already computed
stays valid.  Let a TD change a yardage and it does not: the rating would be
describing a course that does not exist, and every net score in the field would
be quietly wrong.  That is a course correction, and it belongs in the editor
next door.

**Eighteen unique indexes, enforced.**  An index set is a RANKING — 1..n, each
used exactly once.  Anything else is not a looser version of the same thing, it
is a set that allocates strokes wrongly, silently, for everyone in the field.
So Save is refused until the set is whole, and the refusal says which number is
doubled and which is missing — because a duplicate is only half the error, and
the missing number is the one the TD actually has to find.
"""

from __future__ import annotations

from core.models import Tee


def default_name(source: Tee) -> str:
    """`White` -> `White — club index`.

    Naming is part of the job: this sits in a picker beside four other tees, so
    a set called "Custom" is one nobody can identify a season later.
    """
    return f'{source.tee_name} — club index'


def blank_set(source: Tee) -> list[dict]:
    """A starting point: the source's own ranking, to be edited."""
    return [dict(h) for h in source.holes]


# ---------------------------------------------------------------------------
# The ranking
# ---------------------------------------------------------------------------

def strip(indexes: list[int | None], n: int) -> list[dict]:
    """The 1..n strip: every number, and how many times it is used.

    Shown whole rather than only flagging the offending cells, because using 12
    twice means something else is MISSING, and that is the number the TD has to
    hunt for.  Two conflicts and one gap, read at a glance.
    """
    counts = {v: 0 for v in range(1, n + 1)}
    for v in indexes:
        if v in counts:
            counts[v] += 1
    return [{'value': v,
             'state': 'used' if c == 1 else ('twice' if c > 1 else 'missing')}
            for v, c in counts.items()]


def problems(indexes: list[int | None], n: int) -> list[str]:
    """Human sentences for what is wrong with the ranking, or []."""
    out = []
    missing = [s['value'] for s in strip(indexes, n) if s['state'] == 'missing']
    twice   = [s['value'] for s in strip(indexes, n) if s['state'] == 'twice']
    blank   = [i + 1 for i, v in enumerate(indexes) if v is None]
    bad     = [i + 1 for i, v in enumerate(indexes)
               if v is not None and not (1 <= v <= n)]
    if blank:
        out.append('Every hole needs an index — '
                   + _holes(blank) + ' ' + _is_are(blank) + ' empty.')
    if bad:
        out.append(f'An index must be 1–{n} — check ' + _holes(bad) + '.')
    if twice:
        out.append(_numbers(twice) + ' ' + _is_are(twice) + ' used twice.')
    if missing:
        out.append(_numbers(missing) + ' ' + _is_are(missing) + ' not used.')
    return out


def blocker(indexes: list[int | None], n: int) -> str:
    """What to put ON the disabled Save button.

    A disabled button that does not say why is a mystery; this one carries the
    count, so the TD knows what is left without hunting for a message.
    """
    twice   = sum(1 for s in strip(indexes, n) if s['state'] == 'twice')
    missing = sum(1 for s in strip(indexes, n) if s['state'] == 'missing')
    parts = []
    if twice:
        parts.append(f'{twice} duplicate' + ('' if twice == 1 else 's'))
    if missing:
        parts.append(f'{missing} gap' + ('' if missing == 1 else 's'))
    return ', '.join(parts)


def suggestion(indexes: list[int | None], n: int, changed_hole: int | None):
    """The one case worth offering outright: exactly one doubled, one missing.

    A swap cannot fix a duplicate — something has to become the missing number —
    and the cell the TD just edited is almost always the one that used to hold
    it.  Returns ``(hole, value)`` or None.
    """
    twice   = [s['value'] for s in strip(indexes, n) if s['state'] == 'twice']
    missing = [s['value'] for s in strip(indexes, n) if s['state'] == 'missing']
    if len(twice) != 1 or len(missing) != 1:
        return None
    holes_with = [i + 1 for i, v in enumerate(indexes) if v == twice[0]]
    if changed_hole in holes_with:
        return changed_hole, missing[0]
    # No edit to go on — offer the later of the two, which is the one a TD
    # typing left-to-right has just arrived at.
    return (holes_with[-1], missing[0]) if holes_with else None


def _numbers(vals):
    vals = [str(v) for v in sorted(vals)]
    return vals[0] if len(vals) == 1 else ', '.join(vals[:-1]) + ' and ' + vals[-1]


def _holes(vals):
    return ('hole ' if len(vals) == 1 else 'holes ') + _numbers(vals)


def _is_are(vals):
    return 'is' if len(vals) == 1 else 'are'


# ---------------------------------------------------------------------------
# Reading the form
# ---------------------------------------------------------------------------

def read_form(post, source: Tee) -> tuple[str, list[int | None], int | None]:
    """(name, indexes-in-hole-order, hole the TD last changed)."""
    name = (post.get('name') or '').strip()
    indexes: list[int | None] = []
    for hole in source.holes:
        raw = (post.get(f'index_{hole["number"]}') or '').strip()
        try:
            indexes.append(int(raw))
        except ValueError:
            indexes.append(None)
    try:
        changed = int(post.get('changed_hole') or '')
    except ValueError:
        changed = None
    return name, indexes, changed


def build_holes(source: Tee, indexes: list[int | None]) -> list[dict]:
    """Source geometry + the TD's ranking.

    Everything except ``stroke_index`` is copied straight off the source, which
    is the lock: there is no path through this function that changes par or a
    yardage, whatever the form said.
    """
    out = []
    for hole, si in zip(source.holes, indexes):
        new = dict(hole)
        new['stroke_index'] = si
        out.append(new)
    return out


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

def create(source: Tee, name: str, indexes: list[int | None]) -> Tee:
    """A new tee on the same course, carrying the source's geometry.

    A real ``Tee`` row on purpose — the picker, round setup and every scoring
    service then need no change at all.  ``curated`` + ``origin='manual'`` is
    what keeps a catalog re-sync away from it: services/catalog.py skips a
    curated tee and never deletes one.

    Sort priority MATCHES the source rather than beating it, so the set appears
    beside the tee it forked from without silently becoming the default pick
    for everyone of that sex.
    """
    return Tee.objects.create(
        course=source.course,
        tee_name=name,
        slope=source.slope,
        course_rating=source.course_rating,
        par=source.par,
        sex=source.sex,
        sort_priority=source.sort_priority,
        holes=build_holes(source, indexes),
        origin=Tee.ORIGIN_MANUAL,
        curated=True,
        custom_index_of=source,
    )


def rounds_using(tee: Tee) -> int:
    from tournament.models import FoursomeMembership
    return FoursomeMembership.objects.filter(tee=tee).count()


def diff_from_source(tee: Tee) -> set[int]:
    """Hole numbers where this set differs from the tee it forked from.

    The source row stays on screen and the changed cells are marked, because a
    diff of eighteen numbers is not something anyone holds in their head.
    """
    source = tee.custom_index_of
    if source is None:
        return set()
    by_number = {h['number']: h.get('stroke_index') for h in source.holes}
    return {h['number'] for h in tee.holes
            if by_number.get(h['number']) != h.get('stroke_index')}
