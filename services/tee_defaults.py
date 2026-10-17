"""Which tee a golfer is offered by default.

**Today's rule is `sort_priority`, and at Tilden it gets women wrong.** The
men's side is maintained (White is 8, the lowest, so men default to White --
correct), but the women's lowest is WHITE at 12 against RED at 15, so a woman
is offered White when most of them play Red. Fixing that course's data would
fix that course; this fixes the rule.

**The rule: the basis tee for its own sex, one step SHORTER for the other.**
Paul, 17 Oct: *"women default to the women's tee of the same name, although
in Tilden's case most women play from the Red... It could be 1 down from the
men default, more likely to be correct."*

**One step is one POSITION down the golfer's own tee list, after matching
the basis to its counterpart.** The obvious implementation -- "the longest
women's tee shorter than the men's basis" -- is too fragile, and the two
Tilden rows in our own database prove it: production has men's White and
women's WHITE at exactly 5764 yards, so a strict `<` skips WHITE and lands on
RED; the other row has them at 5778 and 5769, nine yards apart, so the same
rule lands on WHITE. Nine yards must not decide which tee a woman is offered.

So: find the women's tee that CORRESPONDS to the basis -- same name first,
nearest yardage otherwise -- and step one position shorter from there. Both
Tilden rows then give RED, and `White - sixes` (a 5778-yard men's variant
that exists for one game) matches WHITE by yardage and steps to RED as well.
"""

from __future__ import annotations


def tee_yards(tee) -> int:
    """Total yardage, or 0 when a tee carries no hole data.

    Rating-and-slope-only tees are legal (the import gate admits them as a
    soft warning), and 0 is what excludes them from a length ordering rather
    than ranking them as the shortest on the course.
    """
    total = 0
    for h in (tee.holes or []):
        try:
            total += int((h or {}).get('yards') or 0)
        except (TypeError, ValueError):
            continue
    return total


def _eligible(tees, sex):
    """Tees a golfer of `sex` may be offered -- their own plus any unisex."""
    return [t for t in tees if not t.sex or t.sex == sex]


def default_tee_for(sex, basis_tee, tees):
    """The tee to offer a golfer of `sex`, or None to leave today's rule alone.

    `tees` is the course's CURRENT tees. Returns None whenever the question
    cannot be answered honestly -- no basis set, no eligible tee, no yardages
    to measure with -- and the caller then falls back to `sort_priority`,
    which is the shipped behaviour.
    """
    if basis_tee is None:
        return None
    options = _eligible(tees, sex)
    if not options:
        return None

    # Same sex as the basis (or the basis is unisex): it IS the default.
    if not basis_tee.sex or basis_tee.sex == sex:
        return basis_tee if basis_tee in options else None

    by_length = sorted(options, key=tee_yards, reverse=True)
    measurable = [t for t in by_length if tee_yards(t) > 0]
    if not measurable:
        return None

    # The counterpart: the tee on THIS golfer's side that corresponds to the
    # basis. Name first, because "White" and "WHITE" are the same boxes and
    # a club names them that way on purpose.
    name = (basis_tee.tee_name or '').strip().lower()
    counterpart = next(
        (t for t in measurable if (t.tee_name or '').strip().lower() == name),
        None)
    if counterpart is None:
        basis_yards = tee_yards(basis_tee)
        if not basis_yards:
            return None
        # Nearest by length. Not "the longest shorter one" -- see the module
        # docstring; a few yards either way must not change the answer.
        counterpart = min(measurable,
                          key=lambda t: abs(tee_yards(t) - basis_yards))

    i = measurable.index(counterpart)
    # One down, clamped: past the end, "one shorter" still means the front
    # tees rather than nothing.
    return measurable[min(i + 1, len(measurable) - 1)]
