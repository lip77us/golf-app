"""
services/player_labels.py
-------------------------
Golfer labels for screens that talk in SENTENCES.

`Player.short_name` is at most five characters and auto-fills to initials,
which is right for a match line read at arm's length and wrong the moment a
label has to carry a possessive or join two names: `PL's call` and `PL + DK`
are not phrases a golfer reads.  A first name is.

Second user is when a rule gets its own module — Wolf's tray needed this and
Las Vegas' needed the same thing a day later, and the receipt's `_field_labels`
answers the opposite question (which SURNAME to lengthen) for its own reasons.
"""


def first_names(by_pid: dict) -> dict:
    """``{player_id: label}`` — the FIRST name, lengthened only where two
    golfers in the group share one.

    Two Daves in a foursome is ordinary, so the ambiguous ones — and only
    those, as the settlement receipt's labels do — take a surname initial:
    ``Dave K``.  A golfer with one name falls back to his short name.
    """
    first = {}
    for pid, player in by_pid.items():
        parts = (getattr(player, 'name', '') or '').split()
        first[pid] = parts[0] if parts else (player.short_name or '')
    seen = {}
    for pid, f in first.items():
        seen.setdefault(f.lower(), []).append(pid)
    out = {}
    for pid, f in first.items():
        if len(seen.get(f.lower(), [])) < 2:
            out[pid] = f
            continue
        parts = (by_pid[pid].name or '').split()
        out[pid] = f'{f} {parts[1][0]}' if len(parts) > 1 else (
            by_pid[pid].short_name or f)
    return out


# ---------------------------------------------------------------------------
# Card order
# ---------------------------------------------------------------------------

#: A golfer not on this foursome's card sorts last rather than first, so a
#: stray id cannot silently take the top of a side.
_LAST = 1 << 30


def card_order(foursome) -> dict:
    """``{player_id: rank}`` — where each golfer sits on the CARD.

    **Because `Team.players` is a many-to-many with no ordering.** Every
    team-based game reads a side's golfers off that relation, and the
    database returns them in whatever order it likes: `Sam + Mike` on one
    request and `Mike + Sam` on the next, from the same rows. That is the
    name of a SIDE, reordering under the reader on the board, the tray, the
    side headers and the money rows.

    It has now been found three times — the Sixes anchor took its anchor
    from set iteration, `nassau_summary` and `fourball_summary` each shipped
    it, and the second two were found only by a fixture regenerating
    differently and a test failing under `--parallel`. An unstable order is
    invisible to a test whose fixture agrees with it, which is why this is
    one function rather than four sorts.

    `FoursomeMembership.Meta.ordering` is `['id']`, so this is creation
    order — the order the golfers are listed everywhere else in the app.
    """
    return {m.player_id: i
            for i, m in enumerate(foursome.memberships.all())}


def in_card_order(players, rank: dict) -> list:
    """`players` sorted by [card_order]'s rank. See its docstring."""
    return sorted(players, key=lambda p: rank.get(p.id, _LAST))
