"""
services/withdrawal.py
----------------------
**One rule for "is this golfer still in on this hole".**

A mid-round withdrawal is recorded as `FoursomeMembership.withdrew_after_hole`
— the last hole the golfer COMPLETED. Four games read that field, and until
30 Sep 2026 three of them compared it as a hole NUMBER::

    active while  h <= withdrew_after_hole

which is only the same integer when the round starts on the 1st. **A cup day
is very often a shotgun**, and off one the two come apart badly: a group out on
the 13th plays 13-18 and then 1-12, so a man who walks in after the 2nd has
played eight holes, and six of them carry a number HIGHER than 2. The
hole-number test drops him from the holes he actually played and keeps him on
the ones he missed — precisely inverted.

Withdrawal is a point in the ROUND, so it is read along the group's own play
order. Three things follow from that and all three are here, because each was
wrong in its own way in at least one game:

* **active** — position of this hole against position of the last one he
  completed.
* **the killed hole** — "the group abandoned the next hole" means the next hole
  in PLAY ORDER, not `withdrew_after_hole + 1`. Off the 13th, a withdrawal
  after the 18th kills hole 1; `+ 1` gives 19, which Skins then discarded as
  out of range, so the abandoned hole was silently scored.
* **the walk** — a run of consecutive holes is consecutive in play order. 18
  and 1 are adjacent off a shotgun and are not adjacent numbers, so a walk over
  `range(1, 19)` breaks a segment where the group never stopped and joins two
  where it did.

With no withdrawal every function here is the identity it always was, and on a
round starting at the 1st position == number - 1, so nothing changes for the
ordinary case.

See `docs/mid-round-withdrawal.md` for the feature, and
`services/hole_plan.py` for play order itself.
"""
from __future__ import annotations


def play_plan(foursome) -> tuple[list[int], dict[int, int]]:
    """``(order, positions)`` for this group — the hole numbers it plays, in
    the order it plays them, and the reverse index."""
    from services.hole_plan import play_order
    order = play_order(foursome.round, foursome)
    return order, {h: i for i, h in enumerate(order)}


def is_active(membership, hole: int, positions: dict) -> bool:
    """Can *membership* still put a ball on *hole*?"""
    wd = membership.withdrew_after_hole
    if wd is None:
        return True
    # A hole outside this group's plan is never one he is active for; an
    # unknown `wd` never keeps him in. Both default to the safe side.
    return positions.get(hole, 1 << 30) <= positions.get(wd, -1)


def active_pids(members, hole: int, positions: dict) -> list[int]:
    """The player ids among *members* still in on *hole*, in the order given."""
    return [m.player_id for m in members if is_active(m, hole, positions)]


def active_count(members, hole: int, positions: dict) -> int:
    return sum(1 for m in members if is_active(m, hole, positions))


def killed_holes(members, order: list[int], positions: dict) -> set[int]:
    """Holes the group abandoned — the one AFTER a withdrawal that asked for it.

    The next hole in play order, and nothing when the withdrawal was on the
    group's last hole (there is no next one to abandon).
    """
    out: set[int] = set()
    for m in members:
        wd = m.withdrew_after_hole
        if wd is None or not m.withdrew_killed_next_hole:
            continue
        i = positions.get(wd)
        if i is None or i + 1 >= len(order):
            continue
        out.add(order[i + 1])
    return out
