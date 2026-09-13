"""
services/combo_tees.py
----------------------
Which tee a golfer on a COMBO set should play on a given hole.

A combo is one row in the tee dropdown with one rating and one slope, so the
data never says which parent set a hole comes from — the indicator has to be
DERIVED. Spec: `~/Downloads/handoff-app-fixes 2/COMBO-TEES.md` (12 Sep 2026).

**Two steps, and the first runs once per round rather than once per hole.**

1. **Fix the parents at setup.** Find the smallest set of the course's ordinary
   tees whose yardages account for all eighteen holes. All eighteen check out →
   the set is fixed and the indicator is then guaranteed to name one of those
   tees on every hole. A hole matching none → the combo is UNSUPPORTED and the
   indicator is off for the whole round. One decision up front with one clear
   failure, instead of eighteen chances to quietly come back empty.
2. **Match the yardage per hole**, against the fixed set only.

Restricting step 2 to the fixed set is the point of step 1: without it a hole
could resolve to `Black` on a Blue/White combo merely because Black happens to
share that yardage.

**Ties take the LONGER parent.** Both parents often play a short par 3 at the
same yardage, and where the yardage is identical the shot is identical, so
there is nothing to get wrong. Longer rather than first-named because name
order carries no meaning — "Blue/White" and "White/Blue" are the same tees —
while total yardage is a property of the tees themselves. It is also
deterministic, which matters more than the choice: the same hole has to resolve
the same way on the lock screen, in score entry, and when the round is
reopened.

## Two departures from the spec, both from the real data

**The parents are NOT parsed from the name.** The spec proposes parsing
("Blue/White combo" → Blue and White) with yardage matching as the fallback for
names that do not parse. Against all 56 combo tees in the database, yardage
matching alone resolves 54 — including `B/W Combo`, which is initials, and
Pacific Grove's bare `Combo`, which carries no names at all. Neither would
parse. Matching is also what would have to verify a parse anyway, so the parse
step only adds a way to disagree with the check that follows it.

**The parent set is not always a PAIR.** Three real combos need three sets —
Corica's `Team Match Combo` (Black + Blue + White), California GC's
`Back/Middle Combo` (Back + Middle + Venturi) and Richmond's `Senior Combo`.
The spec's guarantee is unchanged by this: a fixed SET of size N either
accounts for every hole or the feature turns off.
"""
import logging
from itertools import combinations

logger = logging.getLogger(__name__)

# Tees already reported this process. A course-data problem is worth saying
# ONCE — the serializer runs on every round fetch, and a line per fetch buries
# the thing it is trying to surface.
_REPORTED: set = set()

# How many parent sets a combo may blend. Three is what the data needs; four is
# headroom, and the search is over a handful of tees so the cost is nothing.
MAX_PARENTS = 4


def is_combo(tee) -> bool:
    """Detection is the name, case-insensitively — there is no flag for it."""
    return 'combo' in (getattr(tee, 'tee_name', '') or '').lower()


def _yards(tee) -> dict:
    """{hole_number: yards} for the holes that carry one."""
    out = {}
    for h in (getattr(tee, 'holes', None) or []):
        n, y = h.get('number'), h.get('yards')
        if n and y:
            out[int(n)] = int(y)
    return out


def _total(tee) -> int:
    return sum((h.get('yards') or 0) for h in (getattr(tee, 'holes', None) or []))


def candidate_parents(tee) -> list:
    """The course's ordinary tees for the same sex — a combo's possible parents.

    Same sex because a set only ever blends within its own card, and CURRENT
    revisions only: a superseded tee is a previous version of one of these, not
    a different set.
    """
    from core.models import Tee
    return [
        t for t in Tee.objects.filter(course_id=tee.course_id, sex=tee.sex,
                                      superseded_by__isnull=True)
                             .order_by('sort_priority', 'tee_name', 'id')
        if t.pk != tee.pk and not is_combo(t) and t.holes
    ]


def resolve_parents(tee):
    """The fixed parent set, or None when the combo is unsupported.

    Smallest set first, so a two-tee combo is never described as a three-tee
    one. Among sets of the same size the one whose totals sit closest to the
    combo's wins, which picks the tees it was actually built from rather than
    any set that happens to cover the yardages; name order breaks what is left.
    Deterministic by construction — the same tee always resolves the same way.
    """
    if not is_combo(tee):
        return None
    mine = _yards(tee)
    if not mine:
        return None
    pool = candidate_parents(tee)
    if len(pool) < 2:
        return None

    target = _total(tee)
    by_tee = {t.pk: _yards(t) for t in pool}

    for size in range(2, min(MAX_PARENTS, len(pool)) + 1):
        best = None
        for group in combinations(pool, size):
            ys = [by_tee[t.pk] for t in group]
            if not all(any(y.get(n) == v for y in ys) for n, v in mine.items()):
                continue
            # Every member has to EARN its place: a set that covers the card
            # with one tee spare is really the smaller set, and naming the
            # spare would put a tee on the chip that the combo does not use.
            if not _all_needed(mine, group, by_tee):
                continue
            key = (sum(abs(_total(t) - target) for t in group),
                   tuple(sorted(t.tee_name or '' for t in group)))
            if best is None or key < best[0]:
                best = (key, list(group))
        if best:
            return best[1]
    return None


def _all_needed(mine: dict, group, by_tee: dict) -> bool:
    """False when the group still covers every hole with one member removed."""
    if len(group) <= 2:
        return True
    for drop in group:
        rest = [by_tee[t.pk] for t in group if t.pk != drop.pk]
        if all(any(y.get(n) == v for y in rest) for n, v in mine.items()):
            return False
    return True


def tee_name_for_hole(tee, hole: int, parents=None):
    """The parent tee's NAME on this hole, or None.

    None means either "not a combo" or "unsupported" — the caller draws nothing
    in both cases, which is the same thing from the reader's side.
    """
    if parents is None:
        parents = resolve_parents(tee)
    if not parents:
        return None
    want = _yards(tee).get(int(hole))
    if want is None:
        return None
    hits = [t for t in parents if _yards(t).get(int(hole)) == want]
    if not hits:
        return None
    # The tie rule: identical yardage means an identical shot, so take the
    # longer set and be consistent about it.
    hits.sort(key=lambda t: (-_total(t), t.tee_name or '', t.pk))
    return hits[0].tee_name


def tee_map(tee) -> dict:
    """{hole_number: parent tee name} for the whole round — {} when off.

    Built ONCE and handed over whole. The indicator is present on all eighteen
    holes or none, which is what stops it appearing and disappearing mid-round.

    **An empty map is the designed outcome, not an error.** The group reads the
    physical card, exactly as they did before this existed, and nothing on
    screen ever guesses a tee. What it is NOT is silent: a combo that cannot
    resolve is a course-data problem, and one that nobody hears about gets
    worked around eighteen holes at a time forever.
    """
    parents = resolve_parents(tee)
    if not parents:
        _report(tee)
        return {}
    out = {}
    for hole in sorted(_yards(tee)):
        name = tee_name_for_hole(tee, hole, parents=parents)
        if name:
            out[hole] = name
    # A partial answer is the failure the setup check exists to prevent.
    if len(out) != len(_yards(tee)):
        _report(tee)
        return {}
    return out


def _report(tee) -> None:
    """Say once, per process, why a combo turned itself off.

    WARNING rather than INFO because somebody has to act on it: the fix is a
    row of course data, not a code change, and it is invisible from the app —
    the golfers just quietly stop getting an indicator they never knew was
    coming.
    """
    if not is_combo(tee):
        return
    key = getattr(tee, 'pk', None)
    if key in _REPORTED:
        return
    _REPORTED.add(key)
    course = getattr(getattr(tee, 'course', None), 'name', '?')
    logger.warning('combo tee unsupported — %s [tee %s]: %s',
                   course, key, unsupported_reason(tee))


def unsupported_reason(tee) -> str:
    """Why a combo is off, for the log — never shown to a golfer.

    The likely cause is a course-data problem worth fixing once, not a golfer's
    problem to work around eighteen times, so this names the hole and what it
    was compared against.
    """
    if not is_combo(tee):
        return ''
    if resolve_parents(tee):
        return ''
    mine = _yards(tee)
    pool = candidate_parents(tee)
    if len(pool) < 2:
        return (f'{tee.tee_name}: the course has fewer than two other tee sets '
                f'for this card, so there is nothing to blend.')
    bad = [n for n, v in sorted(mine.items())
           if not any(_yards(t).get(n) == v for t in pool)]
    if bad:
        n = bad[0]
        seen = ', '.join(f'{t.tee_name}={_yards(t).get(n)}'
                         for t in pool)
        return (f'{tee.tee_name}: hole {n} is {mine[n]}y, which matches no tee '
                f'on this card ({seen}). {len(bad)} hole(s) like it.')
    return (f'{tee.tee_name}: every hole matches some tee, but no set of '
            f'{MAX_PARENTS} or fewer accounts for all of them.')
