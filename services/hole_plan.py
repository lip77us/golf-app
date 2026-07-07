"""
services/hole_plan.py
---------------------
The single source of truth for WHICH holes a round plays and in WHAT ORDER —
replacing the app's hardcoded assumption of "holes 1..18 in order".

A round plays ``num_holes`` consecutive holes starting at ``starting_hole``,
wrapping around the course's hole count (the "universe" — 18, or 9 for a short
course). For a shotgun start each Foursome can override the starting hole; the
round-level ``starting_hole`` is the default.

Three views (see docs/hole-flexibility.md):
  * ``holes_in_play(round)``        -> set[int]        scoring + completion
                                                       (ORDER-FREE — a birdie
                                                       counts the same whenever
                                                       played)
  * ``play_order(round, foursome)`` -> list[int]       entry UI, "next hole"
                                                       gate, AND segment games
                                                       (ORDERED)
  * ``segment(round, foursome, n)`` -> list[list[int]] play-order thirds/halves
                                                       for OUT/IN, Nassau
                                                       front/back, Sixes/Triple
                                                       Cup — by POSITION, not by
                                                       absolute hole number.

Defaults (num_holes=18, starting_hole=1) reproduce a standard round exactly:
play order is 1..18 and every helper returns what the old hardcoded code did.
"""

DEFAULT_HOLE_COUNT = 18


def course_hole_count(round) -> int:
    """The course's hole universe — 18, or 9 for a short course.

    Derived from the current (non-superseded) tees' hole data; the tees on a
    course all share a hole count, so we take the max present. Falls back to 18
    when no tee holes are available.
    """
    counts = [
        len(t.holes)
        for t in round.course.tees.filter(superseded_by__isnull=True)
        if t.holes
    ]
    return max(counts) if counts else DEFAULT_HOLE_COUNT


def effective_start(round, foursome=None) -> int:
    """This group's starting hole: the foursome's shotgun override if set,
    else the round's ``starting_hole`` (default 1)."""
    if foursome is not None and getattr(foursome, 'starting_hole', None):
        return foursome.starting_hole
    return round.starting_hole or 1


def _num_holes(round, universe: int) -> int:
    # Never claim to play more holes than the course has (single-loop only for
    # now; looping a short course to 18 is a deferred tee-data slice).
    return min(round.num_holes or DEFAULT_HOLE_COUNT, universe)


def play_order(round, foursome=None) -> list[int]:
    """The ordered sequence of hole numbers this group plays — starting at its
    effective start and wrapping around the course's hole count.

    Shotgun example (start=8 on an 18-hole course): 8,9,…,18,1,…,7.
    """
    universe = course_hole_count(round)
    start = effective_start(round, foursome)
    n = _num_holes(round, universe)
    return [(start - 1 + i) % universe + 1 for i in range(n)]


def holes_in_play(round, foursome=None) -> set[int]:
    """The SET of hole numbers that count for scoring and completion. Order is
    irrelevant here — use this everywhere the old code did ``range(1, 19)``.

    When num_holes == the course size (incl. every shotgun, which is a full 18),
    this set is the same for every group regardless of start; only the ORDER
    (``play_order``) differs.
    """
    return set(play_order(round, foursome))


def segment(round, foursome, n_parts: int) -> list[list[int]]:
    """Split the play order into ``n_parts`` consecutive runs and return the
    hole numbers in each — by POSITION in the play sequence, not by absolute
    hole number.

    2 parts = front/back (and the scorecard OUT/IN); 3 parts = Sixes /
    Triple Cup thirds. A group starting on hole 8 gets front/back 8→16 / 17→7
    and thirds 8-13 / 14-1 / 2-7. When the round starts on hole 1 this reduces
    to the classic hole-number segments (1-9/10-18, 1-6/7-12/13-18).

    Any remainder from a non-even division is appended to the last segment.
    """
    order = play_order(round, foursome)
    n = len(order)
    size = n // n_parts
    parts = [order[i * size:(i + 1) * size] for i in range(n_parts)]
    if size * n_parts < n:                     # non-even division
        parts[-1].extend(order[size * n_parts:])
    return parts
