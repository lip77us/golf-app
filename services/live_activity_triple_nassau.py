"""
services/live_activity_triple_nassau.py
---------------------------------------
The Triple Nassau lock screen.

Spec: `~/Downloads/handoff-triple-nassau-lock/HANDOFF.md`.

Three golfers, no teams, **every pair playing its own match** — Kelly v. Moran,
Kelly v. Reid, Moran v. Reid. Three matches, three bets each, nine bets on the
round.

**The card exists for one specific confusion: a golfer knows he is two up, and
cannot remember two up on whom.** Two-player Nassau never has that problem —
one opponent, so a bare number is unambiguous. Here a bare number is worthless,
and the whole design problem is attaching each score to its match inside the
iOS ceiling. It lands at 122pt, second clearest in the set behind Las Vegas.

## Colour says who is up, so the card never says DOWN

Each golfer owns a colour for the round — **the reader blue**, then orange and
plum in the roster's order — and a figure wears the colour of whoever is
winning that match. `2 UP` in orange under `YOU·MORAN` is Moran, two up on you.

**There is no `2 DN` anywhere on this card and this module must never produce
one.** A direction word is relative to a reader, and in `MORAN·REID` there is
no reader to be relative to: `1 UP` between two other men is meaningless until
you know which. Colour answers it inside the same glyph that carries the
number, costs no width, and is already how the play screen behaves.

It also makes the reader's own position pre-attentive — **blue means you are
winning**, across both his matches at once.

## One bet at a time, named in the header

`HOLE 13 · BACK 9`, then `HOLE 16 · OVERALL`. One bet, named once, for all
three matches. That is the trade that bought the compaction: an earlier pass
drew the full six-figure grid, fit it at 148pt, and it was unreadable — *a
table of numbers on a phone held at a tee box is a thing you resolve to look at
later.*

It works because **the three matches are always on the same bet at the same
time.** Two-player Nassau needed two rows because its two bets ran on different
clocks; here the clock is shared, so the bet label goes up to the header and
the strip stays one line deep.

## The third match is drawn quieter and never dropped

The reader is in two of three. The third is none of his money and is on the
card anyway, because Triple Nassau settles three ways and the question after
the round is not *did I win* but **who owes whom** — a golfer four up on Moran
wants to know whether Moran is also losing to Reid.

**The dimming applies to the score, not to the identity of the match.** Its
label is the same size and near the same weight as the other two: an earlier
pass had it at 8px/38%, which measured 3.04:1 and went invisible under the
always-on reduction, leaving a reader able to see a score with no way to know
whose match it was — exactly the confusion the card was built to remove.
"""
from services.live_activity_nassau import exposure_range, _money
from services.live_activity_registry import (gross_to_par, hole_in_play,
                                             surname, thru_line)

KIND = 'triple_nassau'

# The reader is always blue on his own phone. The other two take orange and
# plum in the roster's order — **assigned per reader, never per player
# record**, or three golfers in one group read the same match in three
# different colour schemes.
_OTHERS = ('orange', 'plum')


def _playing(summary, player_id) -> bool:
    """Whether the reader is one of the three. A watcher is not, and `0` is a
    player id rather than a falsehood — which is why this is an explicit
    membership test."""
    return player_id in [p.get('player_id')
                         for p in (summary.get('players') or [])]


def _colours(summary, player_id) -> dict:
    """`{player_id: colour}` — **the reader blue, always.**

    A watcher owns no colour, so the roster's order supplies all three and no
    column is held back: none of it is his money, and dimming one would imply
    the other two were his.
    """
    order = [p.get('player_id') for p in (summary.get('players') or [])]
    if player_id not in order:
        return dict(zip(order, ('blue',) + _OTHERS))
    others = [pid for pid in order if pid != player_id]
    return {player_id: 'blue', **dict(zip(others, _OTHERS))}


def _bet_key(matches, hole=None) -> str:
    """Which bet the strip is reporting.

    **The live nine while a nine is live, the overall once both nines are in.**
    Where a nine and the overall are both live the nine leads: it settles
    sooner and it is the one that gets urgent. Same precedence as the
    two-player card.

    **Driven by HOLES, not by settlements**, and that distinction is the whole
    correctness of this function. The packet's claim that the three matches
    are always on the same bet at the same time is true of holes and false of
    results: a front nine can be 5&4 in two matches and all square in the
    third. An earlier version here skipped a nine whose `result` was set and
    so jumped to the back nine on the EIGHTH hole, reporting a bet with no
    holes played while two of the front nine were still to come.

    The clock is shared because the HOLES are shared. That is the only sense
    in which it is shared at all.
    """
    if not matches:
        return 'overall'
    played = {}
    for key in ('front9', 'back9'):
        played[key] = max(
            (int(((m.get('match') or {}).get(key) or {}).get('holes_played')
                 or 0)
             for m in matches), default=0)

    for key in ('front9', 'back9'):
        if 0 < played[key] < 9:
            return key
    # Neither nine is mid-flight. One not yet started is the one coming, and
    # the hole in play breaks the tie for a round played out of order.
    unstarted = [k for k in ('front9', 'back9') if played[k] == 0]
    if unstarted:
        if hole is not None:
            want = 'front9' if hole <= 9 else 'back9'
            if want in unstarted:
                return want
        return unstarted[0]
    return 'overall'


_BET_LABEL = {'front9': 'FRONT 9', 'back9': 'BACK 9', 'overall': 'OVERALL'}


def _figure(bet, p1, p2, colours) -> dict:
    """The one number this match is worth reporting, and whose colour it wears.

    Three states, and **none of them is a direction word.**
    """
    # **Closed out, not merely finished.** A nine's `result` is only set once
    # its ninth hole is in, but a match decided 4&2 has been over for two
    # holes — and a card still reporting it as live is the one figure on here
    # a golfer would act on wrongly.
    margin = bet.get('decided_margin')
    remaining = bet.get('decided_remaining')
    result = bet.get('result')
    if margin is not None or result:
        # A settled match goes QUIET, not away — removing it would leave a gap
        # the reader has to interpret, and the roster of three is the one
        # thing on this card that never changes.
        if margin is not None and remaining:
            text = f'{abs(margin)}&{remaining}'
        elif result == 'halved':
            text = 'HALVED'
        else:
            shown = margin if margin is not None else (bet.get('margin') or 0)
            text = f'{abs(shown)} UP'
        # Grey rule, not the winner's colour: the match is over and the colour
        # is the card's way of saying *this is live and this man is ahead*.
        return {'figure': text, 'colour': 'dim', 'rule': '', 'closed': True}

    margin = int(bet.get('margin') or 0)
    if margin == 0:
        return {'figure': 'ALL SQ', 'colour': '', 'rule': '', 'closed': False}
    leader = p1 if margin > 0 else p2
    colour = colours.get(leader, 'blue')
    return {'figure': f'{abs(margin)} UP', 'colour': colour, 'rule': colour,
            'closed': False}


def _press_chip(match_summary, key) -> str:
    """`+1` on the number it doubles — **a press lands on a figure.**

    Two-player Nassau put the chip on the row; the row is now a cell, and that
    is the difference between *somebody pressed* and *Moran pressed the back
    nine against you*. Where a bet carries two it reads `+2`, never two chips.
    """
    nine = {'front9': 'front', 'back9': 'back'}.get(key)
    if nine is None:
        return ''
    live = [p for p in (match_summary.get('presses') or [])
            if p.get('nine') == nine and not p.get('result')]
    return f'+{len(live)}' if live else ''


def _label(p1, p2, names, player_id) -> str:
    """`YOU·MORAN`. Surnames, and the reader is `YOU` — on his own phone his
    own name is the one string that tells him nothing."""
    def one(pid):
        if pid == player_id:
            return 'YOU'
        return surname(names.get(pid, ''))
    return f'{one(p1)}·{one(p2)}'


def _order(matches, player_id):
    """**The reader's two first, then the third.** His are what he acts on;
    the third is context for the settlement he is about to be part of."""
    mine = [m for m in matches
            if player_id in (m.get('player1_id'), m.get('player2_id'))]
    theirs = [m for m in matches if m not in mine]
    return mine + theirs


def _strip(summary, player_id, key) -> list:
    colours = _colours(summary, player_id)
    playing = _playing(summary, player_id)
    names = {p.get('player_id'): p.get('name', '')
             for p in (summary.get('players') or [])}
    out = []
    for m in _order(summary.get('matches') or [], player_id):
        s = m.get('match') or {}
        p1, p2 = m.get('player1_id'), m.get('player2_id')
        fig = _figure(s.get(key) or {}, p1, p2, colours)
        mine = player_id in (p1, p2)
        out.append({
            'label' : _label(p1, p2, names, player_id),
            'name'  : '',
            'figure': fig['figure'],
            'colour': fig['colour'],
            'rule'  : fig['rule'],
            # Two dots in pairing order — Wolf's columns are people and these
            # are matches, which is the whole reason a column head needs two.
            'dots'  : [colours.get(p1, 'dim'), colours.get(p2, 'dim')],
            'chip'  : _press_chip(s, key),
            # Held back, never dropped — not even in always-on, where it is
            # the first thing a space-saving pass would cut.
            'dim'   : not mine and playing,
            'is_reader': mine,
        })
    return out


def _exposure(summary, player_id) -> str:
    """**Six bets wide, not three.** Settled money plus and minus every live
    stake the reader is party to, presses included — so a $5 Triple Nassau
    opens at −$30 to +$30 and converges as bets settle.

    **The third match never enters it**, which is the second reason that
    column is drawn quieter: it is the only thing on the card that does not
    move the number at the bottom.
    """
    if player_id is None:
        return ''
    low = high = 0.0
    for m in (summary.get('matches') or []):
        if player_id not in (m.get('player1_id'), m.get('player2_id')):
            continue
        l, h = exposure_range(m.get('match') or {}, None, player_id)
        low += l
        high += h
    return _money(low, high)


def _context(summary, player_id, key) -> str:
    """The round's state in words — `$5 a bet`, `front nines in`,
    `Moran settled · 2 to play`."""
    names = {p.get('player_id'): p.get('name', '')
             for p in (summary.get('players') or [])}
    mine = [m for m in (summary.get('matches') or [])
            if player_id in (m.get('player1_id'), m.get('player2_id'))]

    # A match of the reader's that has finished outright is the loudest fact
    # the left half can carry, so it takes precedence over the bet's state.
    for m in mine:
        s = m.get('match') or {}
        if (s.get('overall') or {}).get('result'):
            other = (m.get('player2_id') if m.get('player1_id') == player_id
                     else m.get('player1_id'))
            left = 18 - int((s.get('overall') or {}).get('holes_played') or 0)
            tail = f' · {left} to play' if left > 0 else ''
            return f'{surname(names.get(other, "")).title()} settled{tail}'

    first = ((summary.get('matches') or [{}])[0] or {}).get('match') or {}
    if key != 'front9' and (first.get('front9') or {}).get('result'):
        return 'front nines in'
    unit = float(summary.get('bet_unit') or 0)
    return f'${unit:,.0f} a bet' if unit else ''


def triple_nassau_activity_state(foursome, *, player_id=None,
                                 thru=None) -> dict:
    """The card, right now."""
    from services.triple_nassau import triple_nassau_summary

    summary = triple_nassau_summary(foursome)
    if not summary or not (summary.get('matches') or []):
        return {}

    played = thru or 0
    hole = hole_in_play(foursome, played)
    key = _bet_key(summary.get('matches') or [], hole)

    return {
        'kind'  : KIND,
        # **The hole and which bet the strip is reporting — two facts, one
        # string.** The bet label has to be here rather than in the strip:
        # three columns cannot each carry it, and they are all on the same one.
        'header': {'game': 'TRIPLE NASSAU',
                   'segment': f'HOLE {hole} · {_BET_LABEL[key]}' if hole
                              else _BET_LABEL[key]},
        # **No headline number while the round is running.** The strip is the
        # content, and a single figure above three matches would be the bare
        # number this card exists to abolish.
        'number': {'text': '', 'colour': 'neutral'},
        'sides' : [],
        'strip' : _strip(summary, player_id, key),
        'state' : {'word': '', 'to_play': ''},
        'pips'  : [],
        'final' : None,
        'footer': {'context': _context(summary, player_id, key),
                   'money': _exposure(summary, player_id)},
        'thru'  : thru_line(played, gross_to_par(summary, player_id)),
    }


def _cash(v) -> str:
    sign = '+' if v > 0 else ('−' if v < 0 else '')
    return f'{sign}${abs(v):,.0f}'


def triple_nassau_final_state(foursome, *, player_id=None) -> dict:
    """Round sign-off — **a three-way settlement, not a result.**

    One figure for the round in mint, then the same strip with money in place
    of holes: what the reader settles with each man and, still held back, what
    those two settle with each other. Two of the three are his to act on and
    the footer says which.

    **The rules are dropped in this state.** The money is already colour-coded
    — a figure wears the colour of whoever won that match, exactly as the
    running card does — and a 2px underline repeating it is decoration once
    nothing can change.
    """
    from services.triple_nassau import triple_nassau_summary

    summary = triple_nassau_summary(foursome)
    if not summary or not (summary.get('matches') or []):
        return {}

    colours = _colours(summary, player_id)
    playing = _playing(summary, player_id)
    names = {p.get('player_id'): p.get('name', '')
             for p in (summary.get('players') or [])}
    nets = {p.get('player_id'): float(p.get('net') or 0)
            for p in (summary.get('players') or [])}

    strip, owed, owing = [], [], []
    for m in _order(summary.get('matches') or [], player_id):
        s = m.get('match') or {}
        p1, p2 = m.get('player1_id'), m.get('player2_id')
        total = float((s.get('payouts') or {}).get('total') or 0)
        winner = p1 if total > 0 else (p2 if total < 0 else None)
        mine = player_id in (p1, p2)
        # From the READER's side when it is his; from team 1's when it is not,
        # which is the only honest reading of a match he is not in.
        signed = total if (p1 == player_id or not mine) else -total
        strip.append({
            'label' : _label(p1, p2, names, player_id),
            'name'  : '',
            'figure': _cash(signed) if total else 'EVEN',
            'colour': colours.get(winner, '') if winner else '',
            'rule'  : '',
            'dots'  : [colours.get(p1, 'dim'), colours.get(p2, 'dim')],
            'chip'  : '',
            'dim'   : not mine and playing,
            'is_reader': mine,
        })
        if mine and total:
            other = p2 if p1 == player_id else p1
            amount = abs(total)
            (owed if signed > 0 else owing).append(
                (surname(names.get(other, '')).title(), amount))

    bits = [f'Collect ${a:,.0f} from {n}' for n, a in owed]
    bits += [f'pay {n} ${a:,.0f}' for n, a in owing]
    net = nets.get(player_id, 0.0)

    return {
        'kind'  : KIND,
        'header': {'game': 'TRIPLE NASSAU', 'segment': 'ROUND COMPLETE'},
        'closed': True,
        'number': {'text': _cash(net) if net else 'EVEN', 'colour': 'mint'},
        'sides' : [],
        'strip' : strip,
        'state' : {'word': '9 BETS IN', 'to_play': '3 MATCHES'},
        'pips'  : [],
        'final' : None,
        'footer': {'context': ' · '.join(bits) or 'Nothing to settle',
                   'money': ''},
        'thru'  : thru_line(18, gross_to_par(summary, player_id)),
    }
