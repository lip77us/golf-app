"""
services/live_activity_rabbit.py
--------------------------------
The Rabbit lock screen
(docs/design-review/handoff-live-activities/rabbit-HANDOFF.md).

A projection of `rabbit_summary`, exactly as the Sixes card is a projection of
`sixes_summary`. It computes nothing about the golf.

Three departures from Sixes, and they are the whole document:

**There are no sides.** Three golfers and one holder, so the question is binary
— held or loose — and **mint carries "held"** and does it alone. Sixes could
not use mint for a number because mint is the app's colour and picks neither
side; Rabbit has exactly one distinguished party, so there is nothing for it to
be unfair to.

**The number is a lead, not a score.** `+2` is how many holes the holder can
lose before the rabbit runs free. It is not a margin over anyone in particular.

**The shape of the round is not knowable at setup.** A rabbit is six holes from
wherever it starts, and it starts on the hole after the previous one was
decided — so a lock on the 11th makes the next rabbit holes 12–17, a full six
for a full stake, not 13–18. `services/rabbit.py` already computes this rather
than scheduling it, which is why this module can read the ranges off the
summary and never has to derive them. The consequence here is a rule:
**never print a denominator.** `RABBIT 2 · HOLES 7–12`, never `2 of 3` — a
round that opens as three rabbits can finish as five.
"""
from services.rabbit import rabbit_summary

KIND = 'rabbit'


def _live_segment(segments):
    """The rabbit being played: the first unfinished one, else the last.

    Falling back to the last matters at the end of the round — every leg is
    complete and the card should show the one just finished rather than
    nothing.
    """
    for seg in segments:
        if not seg.get('complete'):
            return seg
    return segments[-1] if segments else None


def _header(seg) -> dict:
    """`RABBIT 2 · HOLES 7-12`, or the tail in orange.

    The extra is the one leg playing for a different amount, which is what
    earns it a different colour. An early-lock rabbit is mint, not orange: it
    is a full six for a full stake and only its numbers moved.
    """
    a, b = seg.get('start_hole'), seg.get('end_hole')
    if seg.get('is_extra'):
        span = f'HOLE {a}' if a == b else f'HOLES {a}-{b}'
        return {'game': 'RABBIT', 'segment': f'EXTRA RABBIT · {span}',
                'accent': 'orange'}
    return {'game': 'RABBIT',
            'segment': f'RABBIT {seg.get("index")} · HOLES {a}-{b}'}


def _number(seg) -> dict:
    """The lead in mint, or the word LOOSE.

    `+0` is not a state — a lead run down to zero has freed the rabbit, and the
    card says so rather than showing a zero that reads like a margin.
    """
    holder = seg.get('holder_id')
    lead   = seg.get('lead') or 0
    if holder is None or lead <= 0:
        return {'text': 'LOOSE', 'colour': 'neutral'}
    return {'text': f'+{lead}', 'colour': 'mint'}


def _holes_left(seg, thru: int) -> int:
    """Holes left in THIS rabbit, which is what the lead is measured against —
    not holes left in the round."""
    end = seg.get('end_hole') or 0
    return max(0, end - max(thru, (seg.get('start_hole') or 1) - 1))


def _state(seg, holes_left: int) -> dict:
    """`HELD` / `LOOSE` / `LOCKED`, plus how many holes are left in this rabbit.

    `LOCKED` is the `DORMIE` analogue — `lead > holes_remaining` — and it is the
    one state that changes what the group does next, because the next six start
    on the next tee.

    A single-hole extra replaces the hole count with `½ STAKE`: on the 18th tee
    the number of holes left is not news, and what it pays is.
    """
    holder = seg.get('holder_id')
    lead   = seg.get('lead') or 0

    if seg.get('is_extra') and (seg.get('holes') or 0) == 1:
        sub = '½ STAKE'
    else:
        sub = f'{holes_left} TO PLAY'

    if holder is None or lead <= 0:
        return {'word': 'LOOSE', 'to_play': sub}
    if lead > holes_left:
        return {'word': 'LOCKED', 'to_play': sub}
    return {'word': 'HELD', 'to_play': sub}


def _names(seg, summary) -> list:
    """Holder on the first line, the two chasers on the second.

    When loose all three go on one dim line: there is no leader to name and the
    card should not imply one by putting somebody first.
    """
    players = summary.get('players') or []
    by_id   = {p['player_id']: p for p in players}
    holder  = seg.get('holder_id')
    lead    = seg.get('lead') or 0

    if holder is None or lead <= 0:
        everyone = ', '.join(p.get('short_name') or p.get('name') or ''
                             for p in players)
        return [{'names': everyone, 'colour': 'dim', 'leading': False}]

    held = by_id.get(holder) or {}
    chasers = ', '.join((p.get('short_name') or p.get('name') or '')
                        for p in players if p['player_id'] != holder)
    return [
        {'names': held.get('name') or held.get('short_name') or '',
         'colour': 'mint', 'leading': True},
        {'names': chasers, 'colour': 'dim', 'leading': False},
    ]


def _run_strip(segments) -> list:
    """One bar per rabbit — the only place the shape of the round is drawn.

    Generated from the computed list, so a round that ran to five rabbits shows
    five. A fixed set of pips would be a lie, which is why Sixes' three were cut
    rather than reused here.
    """
    live = _live_segment(segments)
    out  = []
    for seg in segments:
        if seg is live and not seg.get('complete'):
            out.append('extra-live' if seg.get('is_extra') else 'live')
        elif seg.get('is_extra'):
            out.append('extra')
        elif seg.get('complete') and seg.get('holder_id') is not None:
            out.append('mint')
        else:
            out.append('unplayed')
    return out


def _money(summary, player_id) -> str:
    """Settled only, and **empty until the first rabbit closes** — not `$0`.

    A rabbit in progress is worth nothing yet, and a zero implies it was played
    for nothing. This is also why the number can sit still for six holes and be
    right: under the default a loose rabbit at its last hole moves nothing.
    """
    if player_id is None:
        return ''
    if not any(s.get('complete') and s.get('holder_id') is not None
               for s in (summary.get('segments') or [])):
        return ''
    for row in (summary.get('players') or []):
        if row.get('player_id') == player_id:
            amount = row.get('money') or 0
            sign = '+' if amount > 0 else ('-' if amount < 0 else '')
            return f'{sign}${abs(amount):,.0f}'
    return ''


def _gross_to_par(summary, player_id):
    """The reader's own gross against par — one implementation,
    in the registry, because three of these drifted apart once."""
    from services.live_activity_registry import gross_to_par
    return gross_to_par(summary, player_id)

def rabbit_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The five slots for this foursome's rabbit, right now."""
    summary  = rabbit_summary(foursome)
    segments = summary.get('segments') or []
    if not segments:
        return {}

    seg = _live_segment(segments)
    if seg is None:
        return {}

    thru       = thru or 0
    holes_left = _holes_left(seg, thru)
    stake      = float((summary.get('money') or {}).get('bet_unit') or 0)

    to_par  = _gross_to_par(summary, player_id)
    bits    = []
    if to_par is not None:
        bits.append('E' if to_par == 0 else f'{to_par:+d}')
    if thru:
        bits.append(f'Thru {thru}')
    bits.append(f'${stake:,.0f} a rabbit')

    return {
        'header': _header(seg),
        'number': _number(seg),
        'sides' : _names(seg, summary),
        'state' : _state(seg, holes_left),
        'pips'  : _run_strip(segments),
        'final' : None,
        'footer': {
            'context': ' · '.join(bits),
            'money'  : _money(summary, player_id),
        },
    }
