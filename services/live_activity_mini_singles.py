"""
services/live_activity_mini_singles.py
--------------------------------------
The Mini Singles lock screen (`match_play`)
(`~/Downloads/handoff-lock-screens-mgskins-minisingles-nassaunine-solo`,
section 2).

Mini Singles is a bracket inside one group: four golfers play two nine-hole
semis, then the Finals and 3rd place on the back nine; three golfers play
5-3-1 points over the front and the top two play the Finals. It is built on
the **match card**, with one big number for the reader's own match — and one
line, in the footer, for the other match running beside it, because that match
decides who he plays next.

**A projection, not a calculation.** Both shapes are read off the cards the
score-entry tray already draws (`mini_singles_hole_card`,
`three_person_hole_card`), which in turn render the engines — so the lock
screen, the tray and the leaderboard cannot disagree about a margin.

Rules the packet states that this module keeps:

* **Holes to play are the NINE's** (`5 TO PLAY` / `OF 9`), never counted
  against eighteen — every match in this game is nine holes.
* **The higher seed is blue, the lower orange, in every match** — fixed, so a
  number can wear a colour for the whole round. Two lines, leader first.
* **No yardage in the header** (the game name never shrinks, and
  `MINI SINGLES · 3RD PLACE` is long).
* **No stake while running** — an entry paid into a group pot on the first tee
  is neither news nor at risk. The money arrives on the final state, **net of
  the entry**.
* **No pushes** — every hole of both matches happened inside the group.

It declares the kind the installed app already draws (`match`).
"""
from services.live_activity_registry import (gross_total, gross_to_par,
                                             hole_in_play, holes_played,
                                             thru_line)

KIND = 'match'


def _ordinal(n) -> str:
    n = int(n or 0)
    if 10 <= n % 100 <= 20:
        suffix = 'TH'
    else:
        suffix = {1: 'ST', 2: 'ND', 3: 'RD'}.get(n % 10, 'TH')
    return f'{n}{suffix}'


def _surname(full: str) -> str:
    parts = (full or '').strip().split()
    return parts[-1] if parts else ''


def _members(foursome):
    return [m for m in foursome.memberships.select_related('player')
            if not m.player.is_phantom]


def _par_of(foursome, player_id, hole):
    for m in foursome.memberships.select_related('tee'):
        if (player_id is None or m.player_id == player_id) and m.tee_id:
            try:
                return m.tee.hole(hole).get('par')
            except Exception:
                return None
    return None


def _segment(foursome, player_id, hole, label) -> str:
    """`HOLE 5 · PAR 4` — **no yardage**, on purpose."""
    bits = [f'HOLE {hole}'] if hole else []
    par = _par_of(foursome, player_id, hole) if hole else None
    if par:
        bits.append(f'PAR {par}')
    return ' · '.join(bits)


def _cash(v) -> str:
    v = float(v or 0)
    body = f'{abs(v):,.2f}'.rstrip('0').rstrip('.')
    return ('−$' if v < 0 else '+$') + body


def _margin_int(text) -> int:
    """`3 UP` → 3; `AS` → 0."""
    digits = ''.join(c for c in (text or '') if c.isdigit())
    return int(digits) if digits and 'UP' in (text or '').upper() else 0


def _notation(text) -> str:
    """`2&1` → `2 & 1`."""
    return (text or '').replace('&', ' & ')


# ===========================================================================
# Four golfers: two semis, then the Finals and 3rd place
# ===========================================================================

def _four(foursome, player_id, played, *, final):
    from services.tournament_match_play import mini_singles_hole_card
    from services.player_labels import first_names

    members = _members(foursome)
    order = None
    from services.hole_plan import play_order
    order = play_order(foursome.round, foursome) or list(range(1, 19))
    hole = order[played - 1] if played else order[0]
    if final:
        hole = order[-1]
    card = mini_singles_hole_card(foursome, hole)
    if not card or not card.get('blocks'):
        return {}

    by_first = first_names({m.player_id: m.player for m in members})
    full = {by_first[m.player_id]: m.player.name for m in members}
    blocks = card['blocks']

    mine_title = next((p['match'] for p in card.get('players', [])
                       if p['player_id'] == player_id), '')
    mine = next((b for b in blocks if b['title'] == mine_title), blocks[0])
    others = [b for b in blocks if b is not mine]

    g_name = lambda n: full.get(n, n)
    n1, n2 = mine['names']
    leader = mine['leader']
    colour = {1: 'blue', 2: 'orange'}.get(leader, 'neutral')

    def side(seat, names):
        return {'names': names, 'colour': 'blue' if seat == 1 else 'orange',
                'leading': leader == seat}

    seat_sides = {1: side(1, g_name(n1)), 2: side(2, g_name(n2))}
    sides = [seat_sides[2], seat_sides[1]] if leader == 2 \
        else [seat_sides[1], seat_sides[2]]

    title = mine['title']
    seg_label = {'Finals': 'FINALS', '3rd place': '3RD PLACE'}.get(
        title, title.upper())
    tiles = mine['tiles']
    played_tiles = [t for t in tiles if t['state'] in ('p1', 'p2', 'halved')]
    left = max(9 - len(played_tiles), 0)
    margin_text = mine['margin']
    semi = title.startswith('Semi')
    level_after_nine = semi and mine['head'] in ('All square after 9',
                                                 'Still level')

    # ── the other match, one line, in the footer ───────────────────────
    def other_line():
        if level_after_nine:
            # Its golfers: the winner meets the waiting finalist.
            waiting = next((b for b in others if b['title'] == 'Finals'), None)
            if waiting is not None:
                known = next((n for n in waiting['names'] if n != 'TBD'), '')
                if known:
                    return f'Winner plays {_surname(g_name(known))}'
            # Level after nine on the 9th itself: the other semi is over and
            # its winner is the man waiting.
            done = next((b for b in others if b['title'].startswith('Semi')
                         and b['decided'] and b['leader']), None)
            if done is not None:
                return ('Winner plays '
                        f'{_surname(g_name(done["names"][done["leader"] - 1]))}')
            return ''
        if mine.get('tbd'):
            return 'Scored from the 10th against both'
        for b in others:
            if b.get('tbd'):
                continue
            ln = (b['names'][b['leader'] - 1] if b['leader'] else '')
            t = b['title'] if b['title'] != 'Finals' else 'Finals'
            t = {'3rd place': '3rd'}.get(t, t)
            if b['decided'] and b['leader']:
                # a closed match: the result stands in the footer
                return (f'{t} · {_surname(g_name(ln))} '
                        f'{_notation(b["margin"])}')
            if b['leader']:
                return (f'{t} · {_surname(g_name(ln))} {b["margin"]}')
            return f'{t} · All square'
        return ''

    # ── the state slot ─────────────────────────────────────────────────
    closed = bool(mine['decided']) and not level_after_nine
    last_tile = played_tiles[-1]['hole'] if played_tiles else None
    if mine.get('tbd'):
        number = {'text': ('ALL SQ' if margin_text == 'AS'
                           else margin_text), 'colour': colour}
        state = {'word': 'v TBD', 'to_play': 'SEMI 2 PLAYING ON'
                 if semi is False else ''}
        # The waiting finalist: scored from the 10th against both.
        playing_on = next((b for b in others if b['title'].startswith('Semi')
                           and b['head'] in ('All square after 9',
                                             'Still level')), None)
        if playing_on:
            state['to_play'] = f'{playing_on["title"].upper()} PLAYING ON'
            sides = [seat_sides[1],
                     {'names': 'v ' + ' or '.join(
                         _surname(g_name(n)) for n in playing_on['names']),
                      'colour': '', 'leading': False}]
    elif level_after_nine:
        number = {'text': 'ALL SQ', 'colour': 'neutral'}
        state = {'word': 'PLAYING ON', 'to_play': 'NEXT HOLE WON'}
    elif closed:
        number = {'text': _notation(margin_text) if margin_text != 'AS'
                  else 'ALL SQ', 'colour': colour}
        if semi:
            won = (leader == 1 and mine_seat(foursome, player_id, mine,
                                             members, by_first) == 1) or (
                leader == 2 and mine_seat(foursome, player_id, mine,
                                          members, by_first) == 2)
            state = ({'word': 'THROUGH', 'to_play': 'TO THE FINALS'} if won
                     else {'word': '3RD PLACE', 'to_play': 'FROM THE 10TH'})
        else:
            state = {'word': 'CLOSED',
                     'to_play': (f'ON THE {_ordinal(last_tile)}'
                                 if last_tile else '')}
        if leader:
            w = g_name(mine['names'][leader - 1])
            lo = g_name(mine['names'][2 - leader])
            sides = [{'names': f'{w} beat {lo}', 'colour': '',
                      'leading': False}]
    else:
        n = _margin_int(margin_text)
        number = {'text': 'ALL SQ' if margin_text == 'AS' else margin_text,
                  'colour': colour}
        state = ({'word': 'DORMIE', 'to_play': f'{left} TO PLAY'}
                 if n and n == left and left else
                 {'word': f'{left} TO PLAY', 'to_play': 'OF 9'})

    to_par = _gross_par_for(foursome, player_id)
    card_out = {
        'kind'  : KIND,
        'header': {'game': f'MINI SINGLES · {seg_label}',
                   'segment': _segment(foursome, player_id,
                                       hole_in_play(foursome, played),
                                       seg_label)},
        'number': number,
        'sides' : sides,
        'state' : state,
        'pips'  : [],
        'final' : None,
        'footer': {'context': other_line(), 'money': ''},
        'thru'  : thru_line(played, to_par),
    }
    if final:
        return _four_final(foursome, player_id, card, hole, members, by_first)
    return card_out


def mine_seat(foursome, player_id, block, members, by_first):
    """Which seat (1 higher seed / 2 lower) the reader holds in a block."""
    me = by_first.get(player_id)
    if me is None:
        return 0
    return 1 if block['names'][0] == me else 2 if block['names'][1] == me else 0


def _gross_par_for(foursome, player_id):
    from scoring.models import HoleScore
    if player_id is None:
        return None
    total, n = 0, 0
    m = next((m for m in foursome.memberships.select_related('tee')
              if m.player_id == player_id), None)
    if m is None or not m.tee_id:
        return None
    for hs in HoleScore.objects.filter(foursome=foursome, player_id=player_id,
                                       gross_score__isnull=False):
        par = m.tee.hole(hs.hole_number).get('par')
        if par:
            total += hs.gross_score - par
            n += 1
    return total if n else None


def _gross_sum(foursome, player_id) -> int:
    from scoring.models import HoleScore
    return sum(hs.gross_score for hs in HoleScore.objects.filter(
        foursome=foursome, player_id=player_id, gross_score__isnull=False))


def _four_final(foursome, player_id, base, hole, members, by_first):
    """`GROUP COMPLETE` — the collection, **net of the entry**."""
    from services.tournament_match_play import mini_singles_hole_card
    card = mini_singles_hole_card(foursome, 18)
    result = (card or {}).get('result') or {}
    row = next((r for r in result.get('rows', [])
                if r['player_id'] == player_id), None)
    winner = (card or {}).get('winner') or {}
    place = row['place'] if row else ''
    if row:
        amount = row['amount']
    else:
        amount = place or 'DONE'
    line = ''
    if row:
        line = {'1st': '1st', 'T1': '1st'}.get(place, place.lower() or '')
        if winner.get('name') and place in ('1st', 'T1'):
            line += ' · won the Finals'
            if card.get('winner', {}).get('line'):
                line += ' · through to day 2'
    base['header'] = {'game': 'MINI SINGLES', 'segment': 'GROUP COMPLETE'}
    base['closed'] = True
    base['number'] = {'text': amount, 'colour': 'neutral'}
    base['state'] = {'word': str(_gross_sum(foursome, player_id)),
                     'to_play': 'GROSS, 18 HOLES'}
    base['sides'] = [{'names': line, 'colour': '', 'leading': False}] \
        if line else []
    base['footer'] = {'context': 'Dismisses in 5 min', 'money': ''}
    return base


# ===========================================================================
# Three golfers: points over the front, then a Finals
# ===========================================================================

def _three(foursome, player_id, played, *, final):
    from services.three_person_match import three_person_hole_card
    from services.hole_plan import play_order

    order = play_order(foursome.round, foursome) or list(range(1, 19))
    hole = order[-1] if final else (order[played - 1] if played else order[0])
    card = three_person_hole_card(foursome, hole)
    if not card:
        return {}
    full = {p['first']: p['name'] for p in card['players']}
    by_id = {p['player_id']: p for p in card['players']}
    me = by_id.get(player_id)
    to_par = _gross_par_for(foursome, player_id)
    seg = _segment(foursome, player_id, hole_in_play(foursome, played), '')

    if final:
        return _three_final(foursome, player_id, card, me)

    if card['phase'] == 'finals' and card.get('finals'):
        f = card['finals']
        if me and me['role'] == 'third':
            lead = f['leader'] or ''
            finalist = f['names']
            others = f"{finalist[0]} v {finalist[1]}"
            sub = (f"Finals · {lead} {f['standing']}" if f['leader']
                   else f'Finals · {others} all square')
            return {
                'kind': KIND,
                'header': {'game': 'MINI SINGLES · POINTS', 'segment': seg},
                'number': {'text': '3RD', 'colour': 'mint'},
                'sides': [{'names': sub, 'colour': '', 'leading': False}],
                'state': {'word': 'OUT', 'to_play': 'AFTER THE 10TH'},
                'pips': [], 'final': None,
                'footer': {'context': '', 'money': ''},
                'thru': thru_line(played, to_par),
            }
        a_id, b_id = f['a_id'], f['b_id']
        lead_id = f['leader_id']
        n1, n2 = (by_id[a_id]['name'], by_id[b_id]['name'])
        leader = 1 if lead_id == a_id else 2 if lead_id == b_id else None
        colour = {1: 'blue', 2: 'orange'}.get(leader, 'neutral')
        seats = {1: {'names': n1, 'colour': 'blue', 'leading': leader == 1},
                 2: {'names': n2, 'colour': 'orange', 'leading': leader == 2}}
        sides = [seats[2], seats[1]] if leader == 2 else [seats[1], seats[2]]
        std = f['standing']
        if f['closed']:
            number = {'text': std.replace('&', ' & '), 'colour': colour}
            state = {'word': 'CLOSED', 'to_play': ''}
        else:
            n = int(''.join(c for c in std if c.isdigit()) or 0) \
                if 'UP' in std else 0
            left = f['to_play']
            number = {'text': std if 'UP' in std else 'ALL SQ',
                      'colour': colour}
            state = ({'word': 'DORMIE', 'to_play': f'{left} TO PLAY'}
                     if n and n == left and left else
                     {'word': f'{left} TO PLAY', 'to_play': 'OF 9'})
        return {
            'kind': KIND,
            'header': {'game': 'MINI SINGLES · FINALS', 'segment': seg},
            'number': number, 'sides': sides, 'state': state,
            'pips': [], 'final': None,
            'footer': {'context': '', 'money': ''},
            'thru': thru_line(played, to_par),
        }

    # ── the front nine (and while points play on) ──────────────────────
    table = card['table']
    my_row = next((r for r in table if r['player_id'] == player_id), None)
    ranked = sorted(table, key=lambda r: -float(r['total']))
    pts = {r['player_id']: float(r['total']) for r in table}
    sub = ' · '.join(
        f"{_surname(r['name'])} {r['total']}" for r in
        sorted(table, key=lambda r: -float(r['total'])))
    holes_in = len([t for t in table if t.get('pts') is not None]) and None
    done = min(card['thru'], 9)
    left = max(9 - done, 0)
    if card['play_on'] or (card['hole'] >= 9 and 'level for 2nd'
                           in card.get('line', '')):
        level = [r for r in ranked[1:] if pts[r['player_id']] ==
                 pts[ranked[2]['player_id']]] if len(ranked) == 3 else []
        with_whom = ''
        if my_row and level:
            other = next((r for r in level if r['player_id'] != player_id),
                         None)
            with_whom = f'LEVEL WITH {_surname(other["name"]).upper()}' \
                if other else ''
        place = my_row['place'] if my_row else ''
        return {
            'kind': KIND,
            'header': {'game': 'MINI SINGLES · POINTS', 'segment': seg},
            'number': {'text': place or 'T2', 'colour': 'mint'},
            'sides': [{'names': sub, 'colour': '', 'leading': False}],
            'state': {'word': 'PLAYING ON', 'to_play': with_whom},
            'pips': [], 'final': None,
            'footer': {'context': 'Next hole won decides 2nd', 'money': ''},
            'thru': thru_line(played, to_par),
        }
    if my_row is None:
        return {}
    my_pts = pts[player_id]
    pos = [r['player_id'] for r in ranked].index(player_id)
    if pos <= 1:
        # In the top two (or 1st): the margin over 3rd is the cut.
        margin = my_pts - pts[ranked[2]['player_id']]
        word, cap = f'+{margin:g}', f'OVER 3RD · {left} TO PLAY'
    else:
        margin = pts[ranked[1]['player_id']] - my_pts
        word, cap = f'−{margin:g}', f'TO 2ND · {left} TO PLAY'
    return {
        'kind': KIND,
        'header': {'game': 'MINI SINGLES · POINTS', 'segment': seg},
        # Places are never coloured.
        'number': {'text': _ordinal(pos + 1) if my_row['place'].isdigit()
                   else my_row['place'], 'colour': 'mint'},
        'sides': [{'names': sub, 'colour': '', 'leading': False}],
        'state': {'word': word, 'to_play': cap},
        'pips': [], 'final': None,
        'footer': {'context': '5-3-1 · top two to the Finals', 'money': ''},
        'thru': thru_line(played, to_par),
    }


def _three_final(foursome, player_id, card, me):
    result = card.get('result') or {}
    row = next((r for r in result.get('rows', [])
                if r['player_id'] == player_id), None)
    f = card.get('finals') or {}
    place = row['place'] if row else ''
    amount = (_cash(row['net']) if row and row.get('net') is not None
              else (place.upper() or 'DONE'))
    line = ''
    if row and place == '1st':
        line = f"1st · won the Finals {f.get('standing', '')}".strip()
        if card.get('pot'):
            line += f" · ${row_paid(result, row):g} of the " \
                    f"${card['pot']:g} pot"
    elif row:
        line = place
    return {
        'kind': KIND,
        'header': {'game': 'MINI SINGLES', 'segment': 'GROUP COMPLETE'},
        'closed': True,
        'number': {'text': amount, 'colour': 'neutral'},
        'sides': [{'names': line, 'colour': '', 'leading': False}]
        if line else [],
        'state': {'word': str(_gross_sum(foursome, player_id)),
                  'to_play': 'GROSS, 18 HOLES'},
        'pips': [], 'final': None,
        'footer': {'context': 'Dismisses in 5 min', 'money': ''},
        'thru': thru_line(18, _gross_par_for(foursome, player_id)),
    }


def row_paid(result, row) -> float:
    """What the place paid, gross of the entry (net + entry)."""
    return float((row.get('net') or 0) + (result.get('entry') or 0))


# ===========================================================================
# Entry points
# ===========================================================================

def _kind_of(foursome) -> str:
    n = len(_members(foursome))
    return 'four' if n == 4 else 'three' if n == 3 else ''


def mini_singles_activity_state(foursome, *, player_id=None, thru=None,
                                final=False) -> dict:
    played = holes_played(foursome) if thru is None else thru
    kind = _kind_of(foursome)
    if kind == 'four':
        return _four(foursome, player_id, played, final=final)
    if kind == 'three':
        return _three(foursome, player_id, played, final=final)
    return {}


def mini_singles_final_state(foursome, *, player_id=None) -> dict:
    return mini_singles_activity_state(foursome, player_id=player_id,
                                       thru=18, final=True)
