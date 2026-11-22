"""
services/live_activity_swat.py
------------------------------
The Oakmont SWAT lock screen
(docs/design-review/handoff-oakmont-swat/HANDOFF.md §6).

**Built from Nassau's card, because each row IS a Nassau** — so it declares
`kind = 'nassau'` and needs no new Swift layout. The header names the game and
the reader's team; there is one row for every other team: the nine being
played against them as the big figure (in the reader's colour when he leads,
the opponent's when he trails), and at the right the overall against them and
how far the match has got (`1 DN OVERALL · THRU 15`).

A projection of `services.swat`, which owns the golf. Three rows at most — the
closest matches — with `+N more` in the footer, so the card never outgrows the
height budget on a six-team field. The footer is money EACH: settled money
plus or minus every open bet, at the team stake split by real team size (a
threesome golfer's figures are 4/3 of a foursome golfer's).

The phantom is never named here, and there is no push per hole.
"""
from services import swat as _swat
from services.live_activity_nassau import _money

KIND = 'nassau'
MAX_ROWS = 3


def _surname_upper(team_name: str) -> str:
    return team_name.replace('Team ', '', 1).upper()


def _overall_text(margin: int) -> str:
    if not margin:
        return 'AS'
    return f'{abs(margin)} {"UP" if margin > 0 else "DN"}'


def _row(opp, match, nine: int) -> dict:
    bet = match['bets'][nine]
    overall = match['bets'][2]
    margin = bet['margin']
    if bet['done']:
        text = {'W': 'WON', 'L': 'LOST', 'P': 'HALVED'}[bet['result']]
        colour = {'W': 'blue', 'L': 'orange', 'P': 'neutral'}[bet['result']]
    elif margin == 0:
        text, colour = 'ALL SQ', 'neutral'
    else:
        text = f'{abs(margin)} {"UP" if margin > 0 else "DN"}'
        colour = 'blue' if margin > 0 else 'orange'
    return {
        'label': f'v {_surname_upper(opp["name"])}',
        'text': text,
        'colour': colour,
        'note': f'{_overall_text(overall["margin"])} OVERALL · '
                f'THRU {match["thru"]}',
    }


def swat_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    from services.live_activity_registry import hole_facts, hole_in_play
    loaded = _swat._load(foursome.round)
    if loaded is None:
        return {}
    cfg, teams, gross = loaded
    me = next((t for t in teams if t['foursome'].pk == foursome.pk), None)
    if me is None or len(teams) < 2:
        return {}
    for t in teams:
        t['holes'] = _swat._team_holes(cfg, t, gross)
    my_thru = sum(1 for v in me['holes'].values() if v['finished'])
    hole = hole_in_play(foursome, my_thru) or min(18, my_thru + 1)
    nine = 0 if hole <= 9 else 1

    stake_c = _swat.TEAM_STAKE_FACTOR * _swat._cents(cfg.stake)
    net_c = open_bets = 0
    entries = []
    for t in teams:
        if t is me:
            continue
        m = _swat._nassau(me['holes'], t['holes'])
        for bet in m['bets']:
            if bet['result'] == 'W':
                net_c += stake_c
            elif bet['result'] == 'L':
                net_c -= stake_c
            if not bet['done']:
                open_bets += 1
        entries.append((t, m))

    # Closest matches first: the nine being played, then the overall.
    entries.sort(key=lambda e: (abs(e[1]['bets'][nine]['margin'])
                                if not e[1]['bets'][nine]['done'] else 99,
                                abs(e[1]['bets'][2]['margin'])))
    shown, extra = entries[:MAX_ROWS], max(0, len(entries) - MAX_ROWS)
    rows = [_row(t, m, nine) for t, m in shown]

    size = me['size']
    low = (net_c - open_bets * stake_c) / 100.0 / size
    high = (net_c + open_bets * stake_c) / 100.0 / size
    who = ('3 + phantom' if me['three']
           else f'{size} golfers')
    bits = [who, f'THRU {my_thru}']
    if extra:
        bits.append(f'+{extra} MORE')
    return {
        'kind': KIND,
        'ribbon': '',
        'tee': '',
        'header': {'game': f'SWAT · {me["name"].upper()}',
                   'segment': hole_facts(foursome, player_id, hole)},
        'number': {'text': '', 'colour': 'neutral'},
        'rows': rows,
        'sides': [],
        'state': {'word': '', 'to_play': ''},
        'pips': [],
        'final': None,
        'footer': {'context': ' · '.join(bits),
                   'money': _money(low, high) + ' each' if player_id else ''},
    }


def swat_final_state(foursome, *, player_id=None) -> dict:
    """Sign-off: money each, the record and where the team finished."""
    summary = _swat.swat_summary(foursome.round)
    row = next((t for t in summary.get('teams', [])
                if t['id'] == foursome.pk), None)
    if row is None:
        return {}
    each = row['each']
    amount = (f'{"+" if each > 0 else "−"}${abs(each):,.0f}'
              if each else 'EVEN')
    n = len(summary['teams'])
    best = sum(row['best'].values()) if row['best'] else 0
    place = row['place']
    suffix = {1: 'st', 2: 'nd', 3: 'rd'}.get(place if place < 20 else place % 10, 'th')
    detail = f'Won {row["wins"]}, lost {row["losses"]}'
    if row['pushes']:
        detail += f' · {row["pushes"]} pushed'
    return {
        'kind': KIND,
        'header': {'game': f'SWAT · {row["name"].upper()}',
                   'segment': 'ROUND COMPLETE'},
        'number': {'text': amount, 'colour': 'neutral'},
        'sides': [],
        'state': {'word': '', 'to_play': ''},
        'pips': [],
        'footer': {'context': f'{best} team best ball', 'money': ''},
        'final': {'amount': amount, 'detail': detail,
                  'collect': f'{place}{suffix} of {n}'},
    }
