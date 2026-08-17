"""
services/round_counting.py
--------------------------
Best-N-of-M round selection for tournament championships.

`Tournament.rounds_to_count` has been on the model since the first cut but was
never implemented — every round always counted. This is the one rule both
championship calculators (Low Net and Stableford) now share, so it lives here
rather than being written twice with two different tie behaviours.

The rule (docs/design-review/handoff-individual-play/SPEC.md §2):

* `rounds_to_count` unset, or >= the number of rounds played → every round
  counts. Nothing is struck.
* Otherwise the best N count and the rest are **struck through on the board,
  not hidden** — a golfer can see what he is throwing away — and the selection
  **moves as scores land**.
* **A round in progress does not compete for a counted place.** A partial round
  nearly always looks like a good one — four holes at level par would knock out
  a finished 73 — so an incomplete round can never displace a complete one. It
  still shows (in amber) and its holes are still on the card.

  It is not simply excluded, though: early in a tournament nobody has a complete
  round yet, and a board where every total reads zero is useless. So incomplete
  rounds fill any counting slots the complete rounds leave empty, in score
  order. They can occupy a vacancy; they can never win a contest.

Direction is the caller's: Low Net ranks low, Stableford ranks high, so both
pass a `key` for which **lower is better**.
"""


def select_counting_rounds(entries, rounds_to_count, key=None) -> list:
    """
    Decide which of a player's rounds count toward the championship.

    ``entries``          list of per-round dicts, in round order.
    ``rounds_to_count``  N, or None/0 for "all rounds count".
    ``key``              callable(entry) → sortable, LOWER IS BETTER.
                         Defaults to ``entry['net_to_par']``.

    Returns a list of bools parallel to ``entries`` — True = this round counts.

    An entry is treated as complete when it carries a truthy ``is_complete``.
    Entries whose key is None (nothing scored) sort last and are only ever
    chosen to fill a vacancy.
    """
    n = len(entries)
    if n == 0:
        return []
    if not rounds_to_count or rounds_to_count >= n:
        return [True] * n

    if key is None:
        def key(e):
            return e.get('net_to_par')

    def sort_key(i):
        v = key(entries[i])
        # None (no score) sorts to the very back of its own group.
        return (0, v, i) if v is not None else (1, 0, i)

    complete   = sorted((i for i in range(n) if entries[i].get('is_complete')),
                        key=sort_key)
    incomplete = sorted((i for i in range(n) if not entries[i].get('is_complete')),
                        key=sort_key)

    # Complete rounds win every contested slot; incomplete ones only fill what
    # is left over.
    chosen = set(complete[:rounds_to_count])
    if len(chosen) < rounds_to_count:
        chosen.update(incomplete[:rounds_to_count - len(chosen)])

    return [i in chosen for i in range(n)]
