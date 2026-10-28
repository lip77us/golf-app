"""The settings a round is actually being played under, named once.

Asked for by Paul on 28 Oct 2026: *"It would be good to know the settings
that I am playing with in the leaderboard… In all games."*

**One writer, server-side.** Each game's board could name its own handicap
mode and allowance, and about twenty-five of them would then be twenty-five
places that spell the same six rules — which is the failure this codebase has
already paid for with ``gross_to_par`` (three copies, one wrong, failing
invisibly) and with the skins rules chip, where the client re-derived labels
the server had already written. So the server emits the WORDS and the client
renders them, exactly as ``skin_rules`` does.

It reads the keys the summaries already share rather than asking each game:
``handicap`` / ``handicap_mode`` / ``net_percent`` appear in 58, 40 and 69
places across ``services/``, because they are this codebase's conventions and
not one game's invention. A game with a rule nobody else has keeps saying it
on its own card — this is the common floor, not a replacement for it.

**Nothing is guessed.** An unknown value is SKIPPED rather than printed, so a
new mode shows nothing instead of showing a golfer ``keep_rotating``; a
missing key is simply a rule this game does not have. The order is FIXED, so
two cards never list the same facts in a different order — the same reason
``console.plan._FIELD_ORDER`` exists, since a summary built from a jsonb
column does not preserve key order.

**The stake is deliberately absent.** Its unit is game-specific — a hole, a
skin, a point, a ball — so naming it generically would mean guessing, and
every board already carries its own money line. What belongs here is the
RULES a golfer forgets he agreed to.
"""

from __future__ import annotations

_HANDICAP = {
    'net':         'Net',
    'gross':       'Gross',
    'strokes_off': 'Strokes off',
}

_VARIANT = {
    'claremont':    'Claremont',
    'tiebreak_2nd': '2nd-ball tie-break',
}

_FORMAT = {
    'high_low': 'High-low',
}

_ALLOCATION = {
    'per_segment': 'Strokes per segment',
}

_PRESS = {
    'manual':      'Manual presses',
    'auto':        'Auto presses',
    'both':        'Manual + auto presses',
    'manual_auto': 'Auto + one by hand',
}

_PAYOUT = {
    'pool':       'Pool',
    'pay_around': 'Pay around',
    'average':    'Against the average',
    'all':        'Pay everyone above',
    'first':      'Pay the leader',
}


def handicap_chip(mode: str | None, net_percent=None, *,
                  always_percent: bool = False) -> str | None:
    """``Net 90%`` — PUBLIC, so a game with no ``handicap_mode`` can still use
    the one spelling of these words.

    Solo is the case: it has no mode field at all (a solo game against par in
    gross is stroke play with extra words), so it cannot be read generically —
    and its allowance is the ONLY setting it has, which is why it passes
    ``always_percent`` and states 100% rather than hiding it.
    """
    label = _HANDICAP.get(mode)
    if label is None:
        return None
    if mode == 'gross':
        # An allowance on a gross game is a number that applies to nothing.
        return label
    try:
        p = int(net_percent)
    except (TypeError, ValueError):
        return label
    if p == 100 and not always_percent:
        return label
    return f'{label} {p}%'


def _handicap_chip(s: dict) -> str | None:
    """``Net 90%`` — the mode, with the allowance only when it is not 100.

    Reads the nested ``handicap`` block first and the flat keys second,
    because both shapes are live: the newer summaries nest it and the older
    ones do not.
    """
    h = s.get('handicap')
    if isinstance(h, dict):
        mode, pct = h.get('mode'), h.get('net_percent')
    else:
        mode, pct = s.get('handicap_mode'), s.get('net_percent')
    return handicap_chip(mode, pct)


def _money(v) -> str:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return ''
    return f'${f:,.0f}' if f == int(f) else f'${f:,.2f}'


def settings_chips(summary: dict) -> list[str]:
    """The rules in force, one short chip each, in a fixed order."""
    if not isinstance(summary, dict):
        return []
    out: list[str] = []

    hc = _handicap_chip(summary)
    if hc:
        out.append(hc)

    for key, table in (('variant', _VARIANT),
                       ('scoring_format', _FORMAT),
                       ('handicap_allocation', _ALLOCATION),
                       ('press_mode', _PRESS)):
        chip = table.get(summary.get(key))
        if chip:
            out.append(chip)

    carry = summary.get('carryover')
    if isinstance(carry, bool):
        out.append('Carries on' if carry else 'No carry')

    # `payout_style` and `per_point_mode` are two halves of one answer: the
    # style says pool or per-point and the mode says WHICH per-point. Naming
    # `per_point` itself would tell a golfer nothing the mode does not.
    style = summary.get('payout_style')
    if style == 'per_point':
        chip = _PAYOUT.get(summary.get('per_point_mode'))
    else:
        chip = _PAYOUT.get(style)
    if chip:
        out.append(chip)

    cap = summary.get('loss_cap')
    if cap not in (None, '', 0, 0.0):
        money = _money(cap)
        if money:
            out.append(f'Loses at most {money}')

    return out


def attach(games: dict) -> None:
    """Write ``settings`` onto every game block in an assembled leaderboard.

    Done in ONE pass at the end rather than at the forty-six places a block
    is built, which is what keeps this a single writer.

    **Multi-group blocks disagree about their list's key** — ``by_group`` in
    some games, ``foursomes`` in others — so this scans every list of dicts
    carrying a ``summary``, which is exactly what ``api.views._block_uses_so``
    does and for the same reason: picking one key hid a Points 5-3-1 round
    from the Strokes-Off tab. There the settings belong to the GROUP, since
    two foursomes in one round can be playing different allowances.

    Silent on anything it does not recognise, and it never replaces a
    ``settings`` key a game set for itself.
    """
    if not isinstance(games, dict):
        return
    for block in games.values():
        if not isinstance(block, dict):
            continue
        groups = _group_rows(block)
        if groups:
            per_group = []
            for g in groups:
                chips = g.get('settings')
                if not isinstance(chips, list):
                    chips = settings_chips(g.get('summary'))
                    if chips:
                        g['settings'] = chips
                per_group.append(chips or [])
            # The BLOCK gets the chips only when every group agrees, which is
            # every casual round and most tournaments. Two foursomes can play
            # different allowances, and a board that stated one group's rules
            # at the top of a tab covering both would be telling half the
            # field something untrue — so there, the block says nothing and
            # each group's own card carries them.
            if 'settings' not in block and per_group and per_group[0] \
                    and all(c == per_group[0] for c in per_group):
                block['settings'] = list(per_group[0])
            continue
        if 'settings' in block:
            continue
        chips = settings_chips(block)
        if chips:
            block['settings'] = chips


def _group_rows(block: dict) -> list[dict]:
    """Every per-group row in a block, whatever the list is called."""
    rows: list[dict] = []
    for value in block.values():
        if not isinstance(value, list):
            continue
        for item in value:
            if isinstance(item, dict) and isinstance(item.get('summary'), dict):
                rows.append(item)
    return rows
