"""
services/live_activity_wolf.py
------------------------------
The Wolf lock screen.

Spec: `~/Downloads/handoff-lock-screens 2/wolf/HANDOFF.md`.

## The structural break: the headline is the PRICE of the hole

Every other card in the set headlines a standing. Wolf headlines **what this
hole pays** — `1 PT`, `2 PTS`, `4 PTS`.

That figure is not a property of the format. It is **a decision one man made
ninety seconds ago**, and it is the only thing anyone on the tee is talking
about. A standing is the wrong headline here for the same reason it is the
right one in Points: in Points the totals are the game and the hole is
arithmetic; in Wolf the hole is a negotiation and the totals are its residue.

The totals are still on the card, at full accuracy, in the strip. They are
just not the news.

## Before the call, the price is a range

`1–4 PTS`, with `MORAN · TO CALL` beside it. The wolf has the tee and the sides
do not exist yet, so a card naming a single number would be inventing one. It
converges the moment the decision is made — and it is the state a golfer is
most likely to be glancing at, because the card is read on the tee.

## Nothing here hard-codes four

The lone multiplier is a **setup field**. The header reads it; it does not
assert it. A group that set three gets `WOLF · LONE 3` and a headline that tops
out at `3 PTS`, and the range, the headline and the header string all derive
from the same setting.

## A halved hole is VOID

No points, no carry, no widened range, no chip. An earlier design pass drew
halved-and-carried with the range opening at `2–8 PTS`; **that state does not
exist** and is not built.

## It pushes nothing

The wolf calls his partner out loud, on the tee, with the other three inside
twenty feet. There is no announcement to make that the tee box has not already
made.
"""
from services.live_activity_registry import (hole_facts, hole_in_play,
                                             strip_column, thru_line)

KIND = 'wolf'


def _points_cfg(summary) -> dict:
    return summary.get('points') or {}


def _hole(summary, hole):
    for h in (summary.get('holes') or []):
        if h.get('hole') == hole:
            return h
    return None


def _price(summary, hole_row) -> tuple:
    """`(text, is_range)` — what this hole pays.

    A decided hole names its number. An undecided one names the RANGE, from
    the ordinary team point up to whatever this group set the lone wolf at.
    """
    cfg  = _points_cfg(summary)
    team = int(cfg.get('team_win') or 1)
    top  = _top_price(cfg)

    decision = (hole_row or {}).get('decision')
    pot = (hole_row or {}).get('pot')
    if decision in ('partner', 'lone', 'blind') and pot:
        n = int(pot)
        return (f'{n} PT' if n == 1 else f'{n} PTS'), False
    return f'{team}–{top} PTS', True


def _top_price(cfg) -> int:
    """The most this hole can pay.

    **Blind is optional and off by default**, so its multiplier does not widen
    the range merely by existing in the config — `blind_wolf_points` has a
    non-zero default whether or not the group plays it. A range that topped out
    at 6 on a group that has never declared blind would be naming a price
    nobody can pay.
    """
    lone = int(cfg.get('lone_wolf') or 3)
    if _blind_on(cfg):
        return max(lone, int(cfg.get('blind_wolf') or 0))
    return lone


def _blind_on(cfg) -> bool:
    """Whether this group actually plays blind wolf.

    The engine has no dedicated switch, so the honest test is whether the rule
    is in force at all: `require_lone_or_blind` is the only setting that makes
    a blind declaration part of the game. If a switch is added later, it
    replaces this one line and nothing else.
    """
    return bool(cfg.get('require_lone_or_blind')) and bool(cfg.get('blind_wolf'))


def _header(summary) -> str:
    """`WOLF · LONE 4` — the scoring table, named.

    Groups do not agree on what a lone wolf is worth, and two groups on the
    same four totals under different multipliers are not playing the same game.
    """
    cfg  = _points_cfg(summary)
    bits = [f"LONE {int(cfg.get('lone_wolf') or 3)}"]
    if _blind_on(cfg):
        bits.append(f"BLIND {int(cfg['blind_wolf'])}")
    return 'WOLF · ' + ' · '.join(bits)


def _sides_of(hole_row, real_ids) -> dict:
    """`{pid: 'blue'|'orange'}` — the wolf's side and the field.

    Empty before a call: **unclaimed is uncoloured**, and that grey is the
    honest state. Three of these men are about to be on a side and none of them
    knows which.
    """
    if not hole_row:
        return {}
    decision = hole_row.get('decision')
    if decision not in ('partner', 'lone', 'blind'):
        return {}
    wolf = hole_row.get('wolf_id')
    partner = hole_row.get('partner_id')
    out = {}
    for pid in real_ids:
        if pid == wolf or (partner and pid == partner):
            out[pid] = 'blue'
        else:
            out[pid] = 'orange'
    return out


def _next_wolf(summary, hole):
    """Whoever has the following hole, when the card knows.

    On the last two holes the wolf is **whoever is in last place at that
    moment**, recalculated between them — so the hole after next may genuinely
    not be knowable yet, and the card says so rather than guessing.
    """
    holes = summary.get('holes') or []
    for i, h in enumerate(holes):
        if h.get('hole') == hole and i + 1 < len(holes):
            return holes[i + 1]
    return None


def _footer(summary, player_id, hole, real_ids):
    """`You are wolf on 9` — the one question a golfer has that the hole in
    front of him cannot answer.

    On the front nine it is trivial arithmetic he should not have to do. **On
    the back nine it stops being arithmetic**, which is the case for the slot:
    the rotation runs out, and the last two holes go to whoever is last in
    points — 17 resolved from the standing at the time, 18 recalculated after
    17. So from about the 13th, who is wolf on 17 depends on scores that have
    not happened yet, and the card is the only thing that knows.
    """
    holes = summary.get('holes') or []
    if player_id is None or not holes:
        return ''
    upcoming = [h for h in holes
                if hole is not None and (h.get('hole') or 0) >= hole]
    mine = next((h for h in upcoming if h.get('wolf_id') == player_id), None)
    if mine is not None:
        n = mine.get('hole')
        return 'You are wolf on this hole' if n == hole else f'You are wolf on {n}'
    # Nothing left in the rotation for him — which on the back nine means the
    # last two are still open.
    tail = holes[-2:]
    unknown = [h.get('hole') for h in tail if h.get('wolf_id') is None]
    if unknown:
        return f'{unknown[0]} to the low man'
    return ''


def wolf_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The card, right now."""
    from services.wolf import wolf_summary
    from services.live_activity_registry import gross_to_par

    summary = wolf_summary(foursome)
    players = summary.get('players') or []
    if not players:
        return {}

    played = thru or 0
    hole = hole_in_play(foursome, played)
    row = _hole(summary, hole)
    real_ids = [p.get('player_id') for p in players]
    sides = _sides_of(row, real_ids)

    price, is_range = _price(summary, row)
    wolf_id = (row or {}).get('wolf_id')
    nxt = _next_wolf(summary, hole)
    next_id = (nxt or {}).get('wolf_id')

    best = max((p.get('points') or 0) for p in players) if players else 0

    # **Rotation order, not standings order.** `summary['players']` is sorted
    # by money for the leaderboard, so a strip built from it would reorder
    # itself as the money moved — and the `NEXT` label, which is about the
    # seat, would jump around with it. Same finding as Survivor's track, where
    # standings order made the rows disagree with every other surface.
    seats = summary.get('wolf_order') or []
    by_pid = {p.get('player_id'): p for p in players}
    ordered = [by_pid[pid] for pid in seats if pid in by_pid]
    ordered += [p for p in players if p.get('player_id') not in set(seats)]

    strip = []
    for p in ordered:
        pid = p.get('player_id')
        label = 'WOLF' if pid == wolf_id else ('NEXT' if pid == next_id else '')
        strip.append(strip_column(
            name=p.get('name') or p.get('short_name') or '',
            figure=f"{p.get('points') or 0:g}",
            label=label,
            rule=sides.get(pid, ''),
            is_reader=pid == player_id,
            is_leader=(p.get('points') or 0) == best and best > 0,
        ))

    # The state slot names who has the tee while the price is still a range,
    # and tells the reader when it is him.
    if is_range and wolf_id:
        if wolf_id == player_id:
            state = {'word': 'YOU', 'to_play': 'ARE THE WOLF'}
        else:
            short = (row or {}).get('wolf_short') or ''
            state = {'word': short.upper(), 'to_play': 'TO CALL'}
    elif wolf_id == player_id:
        state = {'word': 'YOU', 'to_play': 'ARE THE WOLF'}
    else:
        decision = (row or {}).get('decision')
        state = {'word': (decision or '').upper(), 'to_play': ''}

    unit = float((summary.get('money') or {}).get('bet_unit') or 0)
    return {
        'kind'  : KIND,
        'header': {'game': _header(summary),
                   'segment': hole_facts(foursome, player_id, hole)},
        # The price of the hole, not a standing. The totals are in the strip.
        'number': {'text': price, 'colour': 'mint'},
        'sides' : [],
        'strip' : strip,
        'state' : state,
        'pips'  : [],
        'final' : None,
        'footer': {'context': _footer(summary, player_id, hole, real_ids),
                   'money': f'${unit:,.0f} a point' if unit else ''},
        'thru'  : thru_line(played, gross_to_par(summary, player_id)),
    }
