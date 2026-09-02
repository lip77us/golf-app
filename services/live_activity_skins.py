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

**People are named** (reversed 2026-09-01 by
`design_handoff_skins_live_activity`). The earlier card named nobody, on the
grounds that in skins the field is the opponent and naming it would be a list.
The redesign disagrees for a specific reason: a list is what you get if you name
EVERYONE, but the reader only ever needs one name — who is ahead of him, or who
just took the pot. So the state slot carries a gap to one leader, and the sub
carries the last skin taken, which is the standing state of the game rather than
a flash that expires.

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


def _variation(summary) -> str:
    """`carryovers` | `pool` | `poolJunk` — three different games, and the
    header says which. Junk is not a mode of its own in the config; a pool with
    junk allowed is a third shape because junk divides the same pot."""
    if not _is_pool(summary):
        return 'carryovers'
    return 'poolJunk' if summary.get('allow_junk') else 'pool'


_GAME_LABEL = {
    'carryovers': 'SKINS · CARRYOVERS',
    'pool'      : 'SKINS · POOL',
    'poolJunk'  : 'SKINS · POOL + JUNK',
}


def _rows(summary) -> list:
    return summary.get('players') or []


def _row_for(summary, player_id):
    for r in _rows(summary):
        if r.get('player_id') == player_id:
            return r
    return None


def _played(summary) -> list:
    """Holes with a result, in play order, oldest first."""
    return [h for h in (summary.get('holes') or []) if h.get('winner_id')]


def _last_win(summary):
    """The most recent hole somebody actually won, or None.

    Skins carries the answer to "who is winning" in this rather than in a
    standing, because the last skin taken is what the group is still talking
    about on the next tee.
    """
    won = _played(summary)
    return won[-1] if won else None


def _leader(summary):
    """(row, total) for the golfer holding most skins — ties broken by the MOST
    RECENT winner, so the chaser always reads a name rather than a tie to
    unpick.
    """
    rows = [r for r in _rows(summary) if (r.get('total_skins') or 0) > 0]
    if not rows:
        return None, 0
    best = max((r.get('total_skins') or 0) for r in rows)
    tied = [r for r in rows if (r.get('total_skins') or 0) == best]
    if len(tied) > 1:
        last = _last_win(summary)
        wid  = last.get('winner_id') if last else None
        for r in tied:
            if r.get('player_id') == wid:
                return r, best
    return tied[0], best


def _short(row) -> str:
    if not row:
        return ''
    return (row.get('short_name') or row.get('name') or '').strip()


def _shares(summary) -> int:
    """Pool divisor: skins AND junk points, because a junk point is worth
    exactly what a skin is worth and divides the same pot. One pot, not two."""
    return sum((r.get('total_skins') or 0) for r in _rows(summary))


def _gross_to_par(summary, player_id):
    """The reader's own gross against par — one implementation,
    in the registry, because three of these drifted apart once."""
    from services.live_activity_registry import gross_to_par
    return gross_to_par(summary, player_id)

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


def _state_slot(summary, player_id, variation, hole):
    """The right-hand block — three readings of one game state.

    Only the second line changes between them. A watcher is not a degraded
    player: he trades the reader's own count for who is actually ahead, because
    nothing on his card is personal.
    """
    leader, lead_n = _leader(summary)
    reader  = _row_for(summary, player_id)
    l_short = _short(leader)

    if player_id is None:                       # watcher
        if leader is None:
            return {'word': 'NO SKINS', 'to_play': 'YET'}
        return {'word': l_short.upper(), 'to_play': f'LEADS · {lead_n}'}

    mine = (reader.get('total_skins') or 0) if reader else 0

    if variation in ('pool', 'poolJunk'):
        # Pool leads with the price of a skin, not with a standing: the number
        # that moves is what one is WORTH, and it falls all round.
        value = _skin_value(summary)
        if variation == 'poolJunk':
            junk = sum((r.get('junk_skins') or 0) for r in _rows(summary))
            return {'word': f'{junk} JUNK', 'to_play': f'{_cash(value)} EACH NOW'}
        return {'word': _cash(value), 'to_play': 'A SKIN NOW'}

    word = f'{mine} SKIN' + ('' if mine == 1 else 'S')
    if leader is None or (reader is not None
                          and leader.get('player_id') == player_id):
        return {'word': word, 'to_play': 'YOU LEAD'}
    # A GAP, not a placing: how many skins he has to take to draw level. "1ST
    # OF 4" reads like a stroke-play finish and means nothing of the kind.
    return {'word': word, 'to_play': f'{l_short} +{lead_n - mine}'}


def _sub_line(summary, variation, hole, riding) -> str:
    """Where the pot came from, or the last skin taken.

    The named line PERSISTS across holes — "Sam Reid took the 6th" still reads
    on the 9th if nobody has won since. It is the standing state of the game,
    and blanking it on the next tee would hide the answer to the question the
    headline raises.
    """
    if variation == 'carryovers':
        if riding > 1:
            return (f'{riding} skins, carried from the '
                    f'{_ordinal(_carry_origin(hole, riding))}')
        return 'A fresh skin'

    last = _last_win(summary)
    if not last:
        return 'No skins taken yet'
    who  = last.get('winner_short') or 'Someone'
    line = f'{who} took the {_ordinal(last.get("hole") or 0)}'
    if variation == 'poolJunk':
        # One hole can produce two shares, and that is the thing about this
        # variation a reader has to see once to understand.
        junk = sum(j.get('count') or 0 for j in (last.get('junk') or []))
        if junk:
            line += f' — 1 skin, {junk} junk' if junk != 1 else ' — 1 skin, 1 junk'
    return line


def _footer(summary, player_id, variation, hole, settled) -> dict:
    money = summary.get('money') or {}
    par   = _par(summary, hole)
    bits  = []

    if player_id is None:
        # Nothing personal survives on a watcher's card, so par takes the slot
        # gross would have had.
        if variation == 'carryovers':
            bits.append(f'Par {par}' if par else 'Par —')
            bits.append(f'{settled} settled')
        else:
            bits.append(f'{_cash(float(money.get("pool") or 0))} pot')
            bits.append(f'par {par}' if par else 'par —')
        n = len([r for r in _rows(summary)])
        return {'context': ' · '.join(bits), 'money': f'{n} playing'}

    if variation == 'carryovers':
        to_par = _gross_to_par(summary, player_id)
        if to_par is not None:
            bits.append('E' if to_par == 0 else f'{to_par:+d}')
        bits.append(f'{_cash(float(money.get("bet_unit") or 0))} a player')
        bits.append(f'{settled} settled')
    else:
        bits.append(f'{_cash(float(money.get("pool") or 0))} pot')
        row  = _row_for(summary, player_id)
        mine = (row.get('skins_won') or 0) if row else 0
        bits.append(f'{mine} skin' + ('' if mine == 1 else 's'))
        if variation == 'poolJunk':
            j = (row.get('junk_skins') or 0) if row else 0
            bits.append(f'{j} junk')
        else:
            bits.append(f'{_cash(float(money.get("bet_unit") or 0))} ante')
    return {'context': ' · '.join(bits),
            'money'  : _money_line(summary, player_id)}


def skins_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The five slots for this foursome's skins game, right now."""
    summary = skins_summary(foursome)
    if not summary or not _rows(summary):
        return {}

    thru      = thru or 0
    hole      = min(18, max(1, thru + 1))      # the hole being played
    riding    = _carry_run(summary, hole)
    variation = _variation(summary)
    settled   = len(_played(summary))

    par   = _par(summary, hole)
    # Par belongs in the header here and on no other card: net skins turn on
    # strokes, and whether a 4 is good enough is the question the number asks.
    where = f'HOLE {hole}' + (f' · PAR {par}' if par else '')
    head  = {'game': _GAME_LABEL[variation], 'segment': where}

    # ── the slots reorder when a carry breaks ────────────────────────────────
    # A running card leads with the money at stake. A card just after a payout
    # leads with the golfer who took it, and the next hole's pot demotes to the
    # sub-line: six dollars after thirty-six is a footnote. This holds until
    # the next hole is scored, which is as long as it is the news.
    last = _last_win(summary)
    if (variation == 'carryovers' and last
            and (last.get('skins_value') or 1) > 1
            and (last.get('hole') or 0) == hole - 1):
        won_n   = int(last.get('skins_value') or 1)
        won_amt = won_n * float(summary.get('per_point_rate') or 0)
        nxt     = float(summary.get('per_point_rate') or 0)
        who     = last.get('winner_short') or 'Someone'
        leader, lead_n = _leader(summary)
        return {
            'header': head,
            'number': {'text': who.upper(), 'colour': 'mint'},
            'sides' : [{'names': f'{_cash(nxt)} on the line on the '
                                 f'{_ordinal(hole)} — no carry',
                        'colour': 'dim', 'leading': False}],
            'state' : {'word': f'WON {_cash(won_amt)}',
                       'to_play': f'ON THE {_ordinal(last.get("hole")).upper()}'},
            'pips'  : [],
            'final' : None,
            'footer': {'context': f'{settled} skins · {_short(leader)} '
                                  f'leads — {lead_n}',
                       'money'  : _money_line(summary, player_id)},
        }

    if variation in ('pool', 'poolJunk'):
        n = _shares(summary)
        headline = f'{n} SKIN' + ('' if n == 1 else 'S')
    else:
        headline = _cash(_headline(summary, riding))

    return {
        'header': head,
        'number': {'text': headline, 'colour': 'mint'},
        'sides' : [{'names': _sub_line(summary, variation, hole, riding),
                    'colour': 'dim', 'leading': False}],
        'state' : _state_slot(summary, player_id, variation, hole),
        'pips'  : [],
        'final' : None,
        'footer': _footer(summary, player_id, variation, hole, settled),
    }


def skins_final_state(foursome, *, player_id=None) -> dict:
    """The closing frame, on round sign.

    The one card in the set that opens with a sentence rather than a value, and
    the only place the per-skin figure is knowable: a pool is not divided until
    the last hole is in. Generic on purpose — it is the group's result and the
    watchers' at the same moment, and personalising one line would make it read
    differently to every person looking at it.
    """
    summary = skins_summary(foursome)
    if not summary or not _rows(summary):
        return {}

    money   = summary.get('money') or {}
    settled = len(_played(summary))
    shares  = _shares(summary)
    pot     = float(money.get('pool') or 0)
    holders = [r for r in _rows(summary) if (r.get('total_skins') or 0) > 0]
    holders.sort(key=lambda r: (-(r.get('total_skins') or 0), _short(r)))

    # No ranking and no tiebreak: in a pool there is no overall winner, only
    # golfers holding skins.
    winners = ' · '.join(f'{_short(r)} {r.get("total_skins")}' for r in holders)

    if _is_pool(summary):
        value = pot / shares if shares else 0.0
        fin   = {'value': _cash(value), 'label': f'per skin — {shares} won'}
    else:
        fin   = {'value': f'{settled}', 'label': 'skins settled'}

    return {
        'header': {'game': _GAME_LABEL[_variation(summary)],
                   'segment': f'{settled} HOLES · {len(_rows(summary))} GOLFERS'},
        'number': {'text': fin['value'], 'colour': 'mint'},
        'sides' : [{'names': f'Winners: {winners}' if winners
                             else 'No skins were won',
                    'colour': 'dim', 'leading': False}],
        'state' : {'word': 'ROUND', 'to_play': 'COMPLETE'},
        'pips'  : [],
        # Must match the Swift `Final` struct exactly — {amount, detail,
        # collect}, none of them optional. A shape it cannot decode is not an
        # error anyone sees: APNs accepts the push and the phone drops it, so
        # the board simply stops. Same three fields Sixes fills.
        'final' : {
            'amount' : fin['value'],
            'detail' : fin['label'],
            # Nobody is owed anybody in a pool — the ante was already in. This
            # says what was divided rather than inventing a settle instruction.
            'collect': (f'Winners: {winners}' if winners
                        else 'No skins were won'),
        },
        'footer': {'context': f'{len(_rows(summary))} golfers · '
                              f'{_cash(pot)} pot · {settled} settled',
                   'money'  : _money_line(summary, player_id)},
    }
