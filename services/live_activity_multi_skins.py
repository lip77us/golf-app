"""
services/live_activity_multi_skins.py
-------------------------------------
The Multi-Group Skins lock screen
(`~/Downloads/handoff-lock-screens-mgskins-minisingles-nassaunine-solo`,
section 1).

Field-scored skins: sixteen golfers, several groups, one pot, no carries. **A
hole is decided only when the last group has posted it**, so what a golfer
cannot see from where he stands is holes *closing out behind him* — and that
is what the card reports. It is not about the reader: his own round is on the
entry screen he opens every hole. The one personal figure is the footer's
right corner (`THRU 9 · +6`), because every card in the set carries it.

A projection of `services.multi_skins.multi_skins_summary`; no golf is decided
here.

* **The headline is the LAST HOLE TO CLOSE** — its winner (mint), `HALVED`, or
  `NO SKINS` before any hole has closed. The state slot names the hole
  (`HOLE 9` / `WON THE SKIN`; `HOLE 1` / `LAST GROUP ON IT` before the first).
* **No money while running.** A skin's value is the pot divided by however
  many skins get won, so it is unknown until the last hole closes. The first
  dollar figure is on the round-complete card (`$32 per skin — 6 won`).
* **Watchers** get the same card with the two personal corners changed: a
  `WATCHING` chip where the hole was, and `16 GOLFERS` where the gross was.
* **Names** arrive as three tries in `number.alts` (full name, initial and
  surname, surname) because which one fits is a question of measured width at
  36pt that only the client can answer; the server never truncates.

It declares its own kind, `multi_skins`, which draws through the shared board
layout — and which is **held in `UNSHIPPED_KINDS` until the build carrying it
ships**, since an installed build that does not know the kind would draw the
"update Halved" nag on a game that had no board at all.
"""
from services.live_activity_registry import (gross_to_par, hole_in_play,
                                             thru_line)

KIND = 'multi_skins'


def _variants(full: str) -> list:
    """`['Sam Reid', 'S. Reid', 'Reid']` — widest first."""
    parts = (full or '').strip().split()
    if len(parts) < 2:
        return [full or '']
    return [full, f'{parts[0][0]}. {parts[-1]}', parts[-1]]


def _initial_surname(full: str) -> str:
    v = _variants(full)
    return v[1] if len(v) > 1 else v[0]


def _surname(full: str) -> str:
    return _variants(full)[-1]


def _closed(h) -> bool:
    return h.get('winner_id') is not None or bool(h.get('is_dead'))


def _leaders_on_open_holes(holes) -> int:
    """Open holes where somebody has posted and there is ONE sole low net."""
    n = 0
    for h in holes:
        if _closed(h):
            continue
        nets = [s['gross'] - (s.get('strokes') or 0)
                for s in h.get('scores') or [] if s.get('gross') is not None]
        if nets and nets.count(min(nets)) == 1:
            n += 1
    return n


def _top(players, holes):
    """`(player, skins)` for the most skins — ties to the most recent winner."""
    won = {p['player_id']: p for p in players if (p.get('skins_won') or 0) > 0}
    if not won:
        return None, 0
    best = max(p['skins_won'] for p in won.values())
    tied = {pid for pid, p in won.items() if p['skins_won'] == best}
    for h in sorted((h for h in holes if h.get('winner_id') in tied),
                    key=lambda h: h['hole'], reverse=True):
        return won[h['winner_id']], best
    return None, best


def _pool_state(foursome):
    from services.multi_skins import multi_skins_summary
    s = multi_skins_summary(foursome.round)
    if not s or not s.get('players'):
        return None
    return s


def multi_skins_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    s = _pool_state(foursome)
    if s is None:
        return {}
    holes = s['holes']
    players = s['players']
    by_id = {p['player_id']: p for p in players}
    closed = [h for h in holes if _closed(h)]
    awarded = sum(1 for h in closed if h.get('winner_id') is not None)
    halved = len(closed) - awarded
    golfers = len(players)
    played = thru or 0
    is_player = player_id is not None and player_id in by_id

    # ── headline and state: the last hole to close ─────────────────────
    if closed:
        last = max(closed, key=lambda h: h['hole'])
        state = {'word': f'HOLE {last["hole"]}',
                 'to_play': ('WON THE SKIN' if last.get('winner_id')
                             is not None else 'NO SKIN')}
        if last.get('winner_id') is not None:
            full = (by_id.get(last['winner_id']) or {}).get('name', '')
            number = {'text': full, 'colour': 'mint',
                      'alts': _variants(full)}
        else:
            number = {'text': 'HALVED', 'colour': 'neutral'}
    else:
        number = {'text': 'NO SKINS', 'colour': 'neutral'}
        state = {'word': 'HOLE 1', 'to_play': 'LAST GROUP ON IT'}

    stat = f'{awarded} skins awarded · {halved} halved' if closed \
        else f'0 awarded · 0 halved · {golfers} golfers'

    leaders = _leaders_on_open_holes(holes)
    top, top_n = _top(players, holes)
    if top is not None:
        left = (f'{leaders} leader{"s" if leaders != 1 else ""} · '
                if leaders else '')
        footer_left = (f'{left}{_initial_surname(top["name"])} leads on '
                       f'{top_n}')
    elif leaders:
        footer_left = ('1 leader on an open hole' if leaders == 1
                       else f'{leaders} leaders on open holes')
    else:
        footer_left = ''

    header = {'game': 'MULTI-GROUP SKINS', 'segment': ''}
    if is_player:
        hole = hole_in_play(foursome, played)
        bits = [f'HOLE {hole}'] if hole else []
        par = _par(s, hole)
        if par:
            bits.append(f'PAR {par}')
        header['segment'] = ' · '.join(bits)
        corner = thru_line(played, gross_to_par(s, player_id))
    else:
        header['chip'] = 'WATCHING'
        corner = f'{golfers} GOLFERS'

    return {
        'kind'  : KIND,
        'header': header,
        'number': number,
        'sides' : [{'names': stat, 'colour': '', 'leading': False}],
        'state' : state,
        'pips'  : [],
        'final' : None,
        'footer': {'context': footer_left, 'money': ''},
        'thru'  : corner,
    }


def _par(summary, hole):
    for h in summary.get('holes') or []:
        if h.get('hole') == hole:
            return h.get('par')
    return None


def multi_skins_final_state(foursome, *, player_id=None) -> dict:
    """`ROUND COMPLETE` — the first card with a dollar figure on it."""
    s = _pool_state(foursome)
    if s is None:
        return {}
    holes, players = s['holes'], s['players']
    closed = [h for h in holes if _closed(h)]
    awarded = sum(1 for h in closed if h.get('winner_id') is not None)
    halved = len(closed) - awarded
    money = s.get('money') or {}
    pool = float(money.get('pool') or 0)
    total = int(money.get('total_skins') or awarded)
    card = multi_skins_activity_state(foursome, player_id=player_id,
                                      thru=18)
    if not card:
        return {}

    if total:
        per = pool / total
        per_txt = f'${per:,.2f}'.rstrip('0').rstrip('.')
        headline = f'{per_txt} per skin — {total} won'
    else:
        headline = 'No skins won'

    # Winners by skins, ties to the most recent — surnames, so the row stays
    # on one line.
    winners = [p for p in players if (p.get('skins_won') or 0) > 0]

    def recency(p):
        hs = [h['hole'] for h in holes if h.get('winner_id') == p['player_id']]
        return max(hs) if hs else 0

    winners.sort(key=lambda p: (-p['skins_won'], -recency(p)))
    row = 'Winners: ' + ' · '.join(
        f'{_surname(p["name"])}  {p["skins_won"]}' for p in winners) \
        if winners else ''

    card['header'] = {'game': 'MULTI-GROUP SKINS',
                      'segment': 'ROUND COMPLETE'}
    card['closed'] = True
    card['number'] = {'text': headline, 'colour': 'neutral'}
    card['state'] = {'word': '', 'to_play': ''}
    card['sides'] = [{'names': row, 'colour': '', 'leading': False}] \
        if row else []
    pool_txt = f'${pool:,.0f}'
    card['footer'] = {'context': (f'{len(players)} golfers · {pool_txt} pot'
                                  f' · {halved} halved'), 'money': ''}
    return card
