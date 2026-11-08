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
