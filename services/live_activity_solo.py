"""
services/live_activity_solo.py
------------------------------
The solo games' lock screens — Stroke Play, Nassau and Match Play against par
(`~/Downloads/handoff-lock-screens-mgskins-minisingles-nassaunine-solo`,
section 4).

**Each variant borrows the card of the game it is named after**, with Par as
the opponent, and drops everything a one-golfer round does not have: no money,
no pushes, no standing, one name. They therefore declare the kinds the
installed app already draws — `stroke_play`, `nassau` and `match` — rather than
a new one, so there is nothing for `UNSHIPPED_KINDS` to hold back.

* **The headline is the NET figure** and the footer keeps the GROSS, labelled
  (`THRU 12 · GROSS +9`): two signed numbers sit on one card, and a reader has
  to be told which is which.
* **Colour:** the reader blue and Par orange — the lock set's side colours
  everywhere (score entry draws pine and clay; this surface follows the set).
  Stroke Play's number is mint on every state: it is a score, not a side.
* **Final:** not a collection — there is nothing to collect. The result, the
  gross, and "for fun".

All of it is a projection of `services.solo.solo_summary`; no golf is decided
here.
"""
from services.live_activity_registry import (fmt_to_par, gross_to_par,
                                             hole_facts, hole_in_play)

_HOLES = 18


def _ordinal(n) -> str:
    n = int(n or 0)
    if 10 <= n % 100 <= 20:
        suffix = 'TH'
    else:
        suffix = {1: 'ST', 2: 'ND', 3: 'RD'}.get(n % 10, 'TH')
    return f'{n}{suffix}'


def _read(foursome):
    """`(summary, played_holes)` or `(None, None)` when it is not a solo round."""
    from services.solo import solo_summary
    s = solo_summary(foursome.round)
    if not s.get('configured') or not s.get('holes'):
        return None, None
    return s, [h for h in s['holes'] if h.get('gross') is not None]


def _gross_par(summary, player_id):
    return gross_to_par(
        {'holes': [{'par': h['par'],
                    'scores': [{'player_id': player_id, 'gross': h['gross']}]}
                   for h in summary['holes']]}, player_id)


def _gross_total(played) -> int:
    return sum(h['gross'] for h in played)


def _thru(played, summary, player_id) -> str:
    """`THRU 12 · GROSS +9` — labelled, because the headline is net."""
    n = len(played)
    if not n:
        return 'TEE OFF'
    g = _gross_par(summary, player_id)
    return f'THRU {n} · GROSS {fmt_to_par(g)}' if g is not None \
        else f'THRU {n}'


def _first(summary) -> str:
    return (summary.get('player_name') or '').strip()


def _frame(foursome, summary, played, player_id, *, game, final=False):
    hole = None if final else hole_in_play(foursome, len(played))
    return {
        'header': {'game': game,
                   'segment': ('ROUND COMPLETE' if final or hole is None
                               else hole_facts(foursome, player_id, hole))},
        'pips'  : [],
        'final' : None,
        'thru'  : _thru(played, summary, player_id),
    }


# ── Stroke Play ─────────────────────────────────────────────────────────────

def _stroke(foursome, summary, played, player_id, *, final):
    st = summary['stroke']
    n_holes = len(summary['holes'])
    strokes = sum(h.get('strokes') or 0 for h in summary['holes'])
    name = _first(summary)
    card = _frame(foursome, summary, played, player_id,
                  game='SOLO · STROKE PLAY', final=final)
    card.update({
        'kind'  : 'stroke_play',
        'who'   : f'{name.upper()} · NET' if name else 'NET',
        # Mint on every state — a score, not a side.
        'number': {'text': fmt_to_par(st['to_par']) if played else 'E',
                   'colour': 'mint'},
        'sides' : [],
        'footer': {'context': '', 'money': ''},
    })
    if final:
        par = sum(h['par'] or 0 for h in summary['holes'])
        card['closed'] = True
        card['state'] = {'word': f'{_gross_total(played)}',
                         'to_play': f'GROSS, {n_holes} HOLES'}
        card['sides'] = [{
            'names': (f'Net {st["net_total"]} · par {par} · for fun, '
                      'nothing to settle'),
            'colour': '', 'leading': False}]
        card['footer'] = {'context': 'Saved to your rounds · 5 min',
                          'money': ''}
    else:
        card['state'] = {'word': f'{n_holes - len(played)} TO PLAY',
                         'to_play': f'{strokes} STROKES'}
    return card


# ── Nassau ──────────────────────────────────────────────────────────────────

_NINES = (('front', 'FRONT 9', 'Front'), ('back', 'BACK 9', 'Back'))


def _bet_settled(b) -> bool:
    return b['decided'] is not None or b['thru'] >= b['holes'] > 0


def _row(label, b, first):
    up, left = b['up'], b['holes'] - b['thru']
    leader = first.split(' ')[0].upper() if up > 0 else ('PAR' if up < 0
                                                          else None)
    if up and abs(up) == left and left > 0:
        count = 'DORMIE'
    else:
        count = f'{left} TO PLAY'
    row = {
        'label' : label,
        'text'  : f'{abs(up)} UP' if up else 'ALL SQ',
        'colour': 'blue' if up > 0 else 'orange' if up < 0 else 'neutral',
        # The leader's name on the same line as the count, in its colour
        # (a level row carries the count alone). `leader` is sent apart so a
        # build that draws the name in its colour can; one that does not
        # reads the whole line from `note`.
        'note'  : f'{leader} · {count}' if leader else count,
    }
    if leader:
        row['leader'] = leader
    n = len(b.get('presses') or [])
    if n:
        row['chip'] = f'+{n} PRESS'
    return row


def _settled_text(b, first, label) -> str:
    """`Front · Par 1 UP` — a settled bet's result, in the footer."""
    up = b['up']
    if not up:
        return f'{label} · Push'
    who = first.split(' ')[0] if up > 0 else 'Par'
    dec = b['decided']
    if dec and '&' in dec:
        return f'{label} · {who} {dec}'
    return f'{label} · {who} {abs(up)} UP'


def _won_lost(b) -> str:
    up = b['up']
    word = 'won' if up > 0 else 'lost' if up < 0 else 'halved'
    dec = b['decided']
    return f'{word} {dec}' if dec and '&' in dec and up else word


def _nassau(foursome, summary, played, player_id, *, final):
    nas = summary['nassau']
    first = _first(summary)
    card = _frame(foursome, summary, played, player_id,
                  game='SOLO · NASSAU', final=final)
    card.update({
        'kind'  : 'nassau',
        'number': {'text': '', 'colour': 'neutral'},
        'sides' : [],
        'state' : {'word': '', 'to_play': ''},
        'footer': {'context': '', 'money': ''},
    })
    if final:
        res = [_won_lost(nas[k]) for k in ('front', 'back', 'overall')]
        won = sum(1 for k in ('front', 'back', 'overall') if nas[k]['up'] > 0)
        lost = sum(1 for k in ('front', 'back', 'overall') if nas[k]['up'] < 0)
        card['closed'] = True
        card['number'] = {'text': f'{won} – {lost}', 'colour': 'neutral'}
        card['state'] = {'word': f'{_gross_total(played)}',
                         'to_play': f'GROSS, {len(summary["holes"])} HOLES'}
        card['sides'] = [{
            'names': f'Front {res[0]} · back {res[1]} · overall {res[2]}',
            'colour': '', 'leading': False}]
        card['footer'] = {'context': 'For fun · 5 min', 'money': ''}
        return card

    pos = len(played)                      # the hole being played, 0-based
    key = 'front' if pos < 9 else 'back'
    label = dict((k, l) for k, l, _ in _NINES)[key]
    short = dict((k, s) for k, _, s in _NINES)[key]
    rows = []
    settled_note = ''
    nine = nas[key]
    if _bet_settled(nine):
        settled_note = _settled_text(nine, first, short)
    else:
        rows.append(_row(label, nine, first))
    # The front, once the back has begun and the front is settled, still
    # reads in the footer; an UNSETTLED front never leaves the card.
    if key == 'back' and not settled_note and False:
        pass
    if key == 'back' and _bet_settled(nas['front']) and not settled_note:
        settled_note = _settled_text(nas['front'], first, 'Front')
    rows.append(_row('OVERALL', nas['overall'], first))
    card['rows'] = rows
    card['footer'] = {'context': settled_note, 'money': ''}
    return card


# ── Match Play ──────────────────────────────────────────────────────────────

def _closed_on(holes):
    """The hole the match was decided on — the first where the margin outran
    the holes left — or None."""
    up, total = 0, len(holes)
    for i, h in enumerate(holes):
        if h['result'] is None:
            continue
        up += 1 if h['result'] == 'won' else -1 if h['result'] == 'lost' else 0
        if abs(up) > total - (i + 1):
            return h['hole'], i
    return None


def _notation(decided) -> str:
    """`3&2` -> `3 & 2`; `4 up` -> `4 UP` (decided on the last hole)."""
    if not decided:
        return ''
    return decided.replace('&', ' & ') if '&' in decided \
        else decided.upper()


def _match(foursome, summary, played, player_id, *, final):
    m = summary['match']
    first = _first(summary)
    holes = summary['holes']
    up, decided = m['up'], m['decided']
    card = _frame(foursome, summary, played, player_id,
                  game='SOLO · MATCH PLAY', final=final)
    left = m['to_play']
    strokes = sum(h.get('strokes') or 0 for h in holes)
    colour = 'blue' if up > 0 else 'orange' if up < 0 else 'neutral'
    # Leader first, as the match card orders its sides.
    me = {'names': first or 'You', 'colour': 'blue', 'leading': up > 0}
    par = {'names': 'Par', 'colour': 'orange', 'leading': up < 0}
    sides = [par, me] if up < 0 else [me, par]
    closed = _closed_on(holes) if decided else None

    card.update({'kind': 'match', 'sides': sides,
                 'footer': {'context': '', 'money': ''}})
    if closed:
        hole_no, idx = closed
        card['number'] = {'text': _notation(decided), 'colour': colour}
        card['state'] = {'word': 'CLOSED',
                         'to_play': f'ON THE {_ordinal(hole_no)}'}
        after = holes[idx + 1:]
        verb = 'beat' if up > 0 else 'lost to'
        card['sides'] = [{
            'names': f'{first} {verb} Par' if up else f'{first} v Par',
            'colour': '', 'leading': False}]
        if after and not final:
            a, b = after[0]['hole'], after[-1]['hole']
            card['footer'] = {'context': (f'{a}–{b} for the card'
                                          if a != b else f'{a} for the card'),
                              'money': ''}
    else:
        card['number'] = {'text': (f'{abs(up)} UP' if up else 'ALL SQ'),
                          'colour': colour}
        if up and abs(up) == left and left > 0:
            card['state'] = {'word': 'DORMIE', 'to_play': f'{left} TO PLAY'}
        else:
            card['state'] = {'word': f'{left} TO PLAY',
                             'to_play': f'{strokes} STROKES'}
    if final:
        card['closed'] = True
        word = ('Beat par' if up > 0 else 'Lost to par' if up < 0
                else 'Halved with par')
        tail = (f', decided on the {_ordinal(closed[0]).lower()}'
                if closed else '')
        card['number'] = {'text': (_notation(decided) if decided else
                                   (f'{abs(up)} UP' if up else 'ALL SQ')),
                          'colour': colour}
        card['state'] = {'word': f'{_gross_total(played)}',
                         'to_play': f'GROSS, {len(holes)} HOLES'}
        card['sides'] = [{'names': f'{word}{tail} · for fun',
                          'colour': '', 'leading': False}]
        card['footer'] = {'context': 'Saved to your rounds · 5 min',
                          'money': ''}
    return card


# ── entry points, one per slug ──────────────────────────────────────────────

_BUILD = {'stroke': _stroke, 'nassau': _nassau, 'match': _match}


def solo_activity_state(foursome, *, player_id=None, thru=None,
                        final=False) -> dict:
    summary, played = _read(foursome)
    if summary is None:
        return {}
    build = _BUILD.get(summary['variant'])
    if build is None:
        return {}
    return build(foursome, summary, played, player_id, final=final)


def solo_final_state(foursome, *, player_id=None) -> dict:
    return solo_activity_state(foursome, player_id=player_id, final=True)
