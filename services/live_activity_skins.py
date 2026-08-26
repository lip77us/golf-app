"""
services/live_activity_skins.py
-------------------------------
The Skins lock screen
(docs/design-review/handoff-live-activities/skins-HANDOFF.md).

A projection of `skins_summary`.

**The one big number is back.** Nassau needed two rows because two matches are
always live; skins has exactly one thing that pays — the hole you are standing
on — so the composition returns to the single headline.

**Money in the headline is the documented exception.** The other three cards
push money to the footer because a lock screen is a neutral board and personal
money in the headline breaks it. Skins is the one game where the pot is not
personal: everyone on the tee is playing for the same $18. No other card may do
this.

**Nobody is named.** In skins the field is the opponent, and naming it would be
a list — the thing a lock screen has least room for. The slot holds where the
pot came from instead, which is the story of the hole and the reason the number
is big.

What is NOT here, and why
~~~~~~~~~~~~~~~~~~~~~~~~~
The packet's `PROVISIONAL` / `n GROUPS OUT` axis is **not implemented, because
it has no reachable state.** Skins in this app is always single-group (ruling
recorded in `SPEC.md`), so every skin is decided the moment the group holes
out and `outstanding_groups` is structurally zero. An unreachable branch on a
money display is worse than an absent one.

Its only push went with it: "a skin settles behind you" cannot happen inside
one group. The card is ambient and updates on score.
"""
from services.skins import skins_summary

KIND = 'skins'


def _is_pool(summary) -> bool:
    return (summary.get('payout_style') or 'pool') == 'pool'


def _par(summary, hole):
    for h in (summary.get('holes') or []):
        if h.get('hole') == hole:
            return h.get('par')
    return None


def _carry_run(summary, hole) -> int:
    """How many skins are riding on `hole` — 1, plus every hole behind it that
    was played and carried.

    Counted off the played holes rather than read off the current one, because
    the hole being played has no result row yet.
    """
    if not summary.get('carryover'):
        return 1
    by_hole = {h['hole']: h for h in (summary.get('holes') or [])}
    riding, back = 1, hole - 1
    while back >= 1:
        prev = by_hole.get(back)
        if not prev or not prev.get('is_carry'):
            break
        riding += 1
        back   -= 1
    return riding


def _carry_origin(hole, riding):
    return hole - riding + 1


def _skin_value(summary) -> float:
    """What one skin is worth right now.

    Pool divides one pot among however many skins get won, so **every new skin
    makes yours worth less** — the card says that out loud rather than leaving
    the reader to divide.
    """
    money = summary.get('money') or {}
    if _is_pool(summary):
        pool  = float(money.get('pool') or 0)
        total = int(money.get('total_skins') or 0)
        return pool / total if total else pool
    return float(summary.get('per_point_rate') or 0)


def _headline(summary, riding) -> float:
    """Pool shows the pot; per-skin shows what this hole is carrying."""
    if _is_pool(summary):
        return float((summary.get('money') or {}).get('pool') or 0)
    return riding * float(summary.get('per_point_rate') or 0)


def _cash(amount) -> str:
    return f'${amount:,.0f}'


def _story(summary, hole, riding) -> list:
    """Where the pot came from — the reason the number is big.

    In pool mode the arithmetic is the story instead: the pool is fixed and the
    share falls, so the reader needs the count rather than the origin.
    """
    money = summary.get('money') or {}
    if _is_pool(summary):
        won = int(money.get('total_skins') or 0)
        line = (f'{won} skins won so far · {_cash(float(money.get("pool") or 0))}'
                f' in the pool')
    elif riding > 1:
        line = f'{riding} skins, carried from the {_ordinal(_carry_origin(hole, riding))}'
    else:
        line = 'A fresh skin'
    return [{'names': line, 'colour': 'dim', 'leading': False}]


def _ordinal(n: int) -> str:
    if 10 <= n % 100 <= 20:
        suffix = 'th'
    else:
        suffix = {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')
    return f'{n}{suffix}'


def _state(summary, riding) -> dict:
    """Pool's share, or whether this hole is carrying.

    Not `ALL IN` / `PROVISIONAL`: single-group skins settle inside the group, so
    that pair would be a constant, and a label that never changes is a label
    nobody reads.
    """
    value = _skin_value(summary)
    if _is_pool(summary):
        return {'word': _cash(value), 'to_play': 'A SKIN, FALLING'}
    return {'word': 'CARRIED' if riding > 1 else '—',
            'to_play': f'{_cash(value)} A SKIN'}


def _gross_to_par(summary, player_id):
    if player_id is None:
        return None
    total, played = 0, 0
    for hole in (summary.get('holes') or []):
        par = hole.get('par')
        for sc in (hole.get('scores') or []):
            if sc.get('player_id') != player_id:
                continue
            gross = sc.get('gross')
            if gross is not None and par:
                total  += gross - par
                played += 1
    return total if played else None


def _money_line(summary, player_id) -> str:
    """Net settled money, **both directions**.

    `+$4` after six skins means two collected and four paid for. A gross count
    of skins won reads like a win when you are down, which is why the slot is a
    signed net and not a tally.
    """
    if player_id is None:
        return ''
    settled = sum(1 for h in (summary.get('holes') or []) if h.get('winner_id'))
    if not settled:
        return ''
    for row in (summary.get('players') or []):
        if row.get('player_id') == player_id:
            net = row.get('net') or 0
            sign = '+' if net > 0 else ('-' if net < 0 else '')
            return f'{sign}${abs(net):,.0f}'
    return ''


def skins_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The five slots for this foursome's skins game, right now."""
    summary = skins_summary(foursome)
    if not summary or not (summary.get('players') or []):
        return {}

    thru = thru or 0
    hole = min(18, max(1, thru + 1))      # the hole being played
    riding = _carry_run(summary, hole)

    money   = summary.get('money') or {}
    settled = sum(1 for h in (summary.get('holes') or []) if h.get('winner_id'))

    # Par belongs in the header here and on no other card: net skins turn on
    # strokes, and whether a 4 is good enough is the question the number is
    # asking.  It also makes the footer's gross the other half of that sentence.
    par = _par(summary, hole)
    where = f'HOLE {hole}' + (f' · PAR {par}' if par else '')

    to_par = _gross_to_par(summary, player_id)
    bits = []
    if to_par is not None:
        bits.append('E' if to_par == 0 else f'{to_par:+d}')
    bits.append(f'{_cash(float(money.get("bet_unit") or 0))} a player')
    bits.append(f'{settled} settled')

    return {
        'header': {'game': 'SKINS' + (' · POOL' if _is_pool(summary) else ''),
                   'segment': where},
        'number': {'text': _cash(_headline(summary, riding)),
                   'colour': 'mint'},
        'sides' : _story(summary, hole, riding),
        'state' : _state(summary, riding),
        'pips'  : [],
        'final' : None,
        'footer': {'context': ' · '.join(bits),
                   'money'  : _money_line(summary, player_id)},
    }
