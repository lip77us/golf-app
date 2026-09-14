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

def _alloc(summary) -> dict:
    """{pid: {hole: strokes}} for the stroke band.

    The one card that reads its allocation off the summary, and legitimately:
    `rabbit_summary` walks the FULL play order and emits `strokes` from the
    game's own allocator on every hole, scored or not — it exists precisely so
    the stroke dots do not snap around as holes come in. That is an allocation,
    not a gross-minus-net reading, so the hole in play carries a real number.

    Rabbit spreads a leg's strokes over that leg's window, so the shared
    full-round allocator would report strokes on holes this engine does not
    give them on.
    """
    out: dict = {}
    for h in (summary.get('holes') or []):
        hole = h.get('hole')
        for e in (h.get('entries') or []):
            if e.get('strokes'):
                out.setdefault(e['player_id'], {})[hole] = e['strokes']
    return out


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

    from services.live_activity_registry import (combo_tee, hole_in_play,
                                                 stroke_ribbon)
    _hip   = hole_in_play(foursome, thru)
    ribbon = stroke_ribbon(foursome, player_id, _hip, _alloc(summary))
    tee    = combo_tee(foursome, player_id, _hip)
    stake      = float((summary.get('money') or {}).get('bet_unit') or 0)

    to_par  = _gross_to_par(summary, player_id)
    bits    = []
    if to_par is not None:
        bits.append('E' if to_par == 0 else f'{to_par:+d}')
    if thru:
        bits.append(f'Thru {thru}')
    bits.append(f'${stake:,.0f} a rabbit')

    return {
        'ribbon': ribbon,
        'tee'   : tee,
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


def _cash(v) -> str:
    """A true minus sign, matching the headline everywhere else in the set."""
    sign = '+' if v > 0 else ('−' if v < 0 else '')
    return f'{sign}${abs(v):,.0f}'


def _settle_line(players, mine) -> str:
    """Who to see. **The holder takes the stake from each of the other two**,
    so the money genuinely moves between named men and the card can say which.
    """
    money = float((mine or {}).get('money') or 0)
    if money > 0:
        owe = [p for p in players if float(p.get('money') or 0) < 0]
        names = ' and '.join(_first(p) for p in owe)
        return f'Collect from {names}' if names else ''
    if money < 0:
        owed = [p for p in players if float(p.get('money') or 0) > 0]
        names = ' and '.join(_first(p) for p in owed)
        return f'Pay {names}' if names else ''
    return 'Nothing to settle'


def _first(p) -> str:
    return (p.get('short_name') or p.get('name') or '').split()[0] \
        if (p.get('short_name') or p.get('name')) else ''


def _won_line(segments, player_id) -> str:
    """`Won rabbit 3 and the last extra`.

    **The extras are named as extras**, not as rabbits four and five. A round
    that opens as three rabbits can finish as five, and a golfer who was told
    he won *rabbit 5* would go looking for it on a card that shows three.
    """
    mine = [s for s in segments
            if s.get('complete') and s.get('holder_id') == player_id]
    if not mine:
        return 'Won no rabbits'
    legs = [s for s in mine if not s.get('is_extra')]
    extras = [s for s in mine if s.get('is_extra')]
    bits = []
    if legs:
        nums = ', '.join(str(s.get('index')) for s in legs)
        bits.append(f'Won rabbit{"s" if len(legs) > 1 else ""} {nums}')
    if extras:
        word = ('the last extra' if len(extras) == 1
                else f'{len(extras)} extras')
        bits.append(word if bits else f'Won {word}')
    return ' and '.join(bits)


def rabbit_final_state(foursome, *, player_id=None) -> dict:
    """Round sign-off — **the card keeps its shape.**

    Rabbit's running card is a headline, a state slot and a line naming who
    holds it. All three still have something to say when the round is over —
    the money, the gross, and what you won — so the board stays and the slots
    are repurposed, the way the newer packets do it rather than the way Sixes
    does.

    Nassau is the opposite case and gets the three-line replacement card: its
    running frame is two match rows and two sides, and when the matches settle
    there is no board left to keep.
    """
    from services.rabbit import rabbit_summary
    from services.live_activity_registry import (gross_to_par, gross_total,
                                                 thru_line)

    summary = rabbit_summary(foursome)
    players = summary.get('players') or []
    if not players:
        return {}
    mine = next((p for p in players if p.get('player_id') == player_id), None)

    money = float((mine or {}).get('money') or 0)
    gross = gross_total(summary, player_id)

    return {
        'kind'  : KIND,
        'header': {'game': 'RABBIT', 'segment': 'ROUND COMPLETE'},
        'closed': True,
        # **Settled only, and never `$0`.** A rabbit pays when it closes; a
        # zero would say the round was played for nothing rather than that
        # nothing was won.
        'number': {'text': _cash(money) if money else 'EVEN',
                   'colour': 'mint'},
        'sides' : [
            {'names': _won_line(summary.get('segments') or [], player_id),
             'colour': '', 'leading': False},
            {'names': _settle_line(players, mine),
             'colour': '', 'leading': False},
        ],
        # `83 · GROSS`, inline. The design drew it stacked at 34px over 9px
        # and the height audit inlined it across every final in the set — it
        # was restating the locked corner two rows down anyway.
        'state' : {'word': f'{gross:g}' if gross else '', 'to_play': 'GROSS'},
        'pips'  : [],
        'final' : None,
        'footer': {'context': 'Dismisses in 5 min', 'money': ''},
        'thru'  : thru_line(18, gross_to_par(summary, player_id)),
    }
