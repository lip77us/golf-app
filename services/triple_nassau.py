"""
services/triple_nassau.py
-------------------------
Triple Nassau — three players, three simultaneous 1-v-1 Nassaus (a round-robin)
driven by one setup.

The three matches are ordinary child ``NassauGame`` rows (game_type
triple_1/2/3, linked to a ``TripleNassauGame`` container by
``NassauGame.triple_game``), so the entire per-match Nassau engine — Front 9 /
Back 9 / Overall, presses, close-out, loss cap — is reused as-is via
``services.nassau.calculate_nassau`` / ``nassau_summary``.

Two things differ from a standalone Nassau, both handled here + in nassau.py:

* **Handicap is per PAIR, not per field.**  Each 1v1 is allocated on its own two
  players (the lower plays to 0; the higher gets the pairwise difference on the
  lowest stroke indexes) — see ``services.nassau._build_pair_so_index``.  So the
  same player can get 10 strokes against one opponent and 5 against another.
* **Settlement nets each player's two matches.**  Every match is zero-sum between
  its pair; a player's position is the sum of their two matches
  (``triple_nassau_summary``'s ``players[*].net`` + ``services.settlement``).

Workflow (same shape as the other casual games):
  1. setup_triple_nassau(...) creates the container + three child NassauGames.
  2. calculate_triple_nassau(foursome) runs after every score submission.
  3. triple_nassau_summary(foursome) returns the JSON the mobile UI consumes.
"""

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import NassauGame, TripleNassauGame
from services.nassau import (
    setup_nassau, calculate_nassau, nassau_summary, TRIPLE_CHILD_SLUGS,
)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

def _pairs(order: list) -> list:
    """The three round-robin pairings of a 3-player roster, in child order:
    match 1 = (p0, p1), match 2 = (p0, p2), match 3 = (p1, p2)."""
    a, b, c = order
    return [(a, b), (a, c), (b, c)]


@transaction.atomic
def setup_triple_nassau(
    foursome,
    player_ids:    list,
    handicap_mode: str   = HandicapMode.NET,
    net_percent:   int   = 100,
    press_mode:    str   = 'none',
    press_unit:    float = 0.00,
    loss_cap             = None,
) -> TripleNassauGame:
    """Create (or replace) THIS foursome's Triple Nassau: a container plus three
    child 1v1 NassauGames (Standard variant, full Front 9 / Back 9 / Overall).

    player_ids: exactly three Player PKs, in display order.  Config (handicap
    mode, net %, press rule, loss cap) is shared across all three matches; the
    stake is the round's bet_unit, as with a standalone Nassau.
    """
    ids = [int(p) for p in player_ids]
    if len(ids) != 3 or len(set(ids)) != 3:
        raise ValueError("Triple Nassau needs exactly three distinct players.")

    # Replace any prior Triple Nassau (cascades to its child matches), plus any
    # stray triple child rows left behind by an interrupted setup.
    TripleNassauGame.objects.filter(foursome=foursome).delete()
    NassauGame.objects.filter(
        foursome=foursome, game_type__in=TRIPLE_CHILD_SLUGS).delete()

    container = TripleNassauGame.objects.create(
        foursome=foursome, player_order=ids, status=MatchStatus.PENDING)

    for slug, (a, b) in zip(TRIPLE_CHILD_SLUGS, _pairs(ids)):
        game = setup_nassau(
            foursome,
            team1_ids     = [a],
            team2_ids     = [b],
            handicap_mode = handicap_mode,
            net_percent   = net_percent,
            press_mode    = press_mode,
            press_unit    = press_unit,
            variant       = 'none',       # Tiebreak / Claremont need 2v2
            play_front    = True,
            play_back     = True,
            play_overall  = True,
            single_match  = False,
            loss_cap      = loss_cap,
            game_type     = slug,
        )
        game.triple_game = container
        game.save(update_fields=['triple_game'])

    return container


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

def _container_for(foursome):
    return foursome.triple_nassau_games.first()


@transaction.atomic
def calculate_triple_nassau(foursome) -> TripleNassauGame | None:
    """Recompute all three child matches and roll the container status up."""
    container = _container_for(foursome)
    if container is None:
        return None

    children = list(container.matches.all())
    any_scored, all_complete = False, bool(children)
    for child in children:
        g = calculate_nassau(foursome, child.game_type)
        if g is None:
            all_complete = False
            continue
        if g.status != MatchStatus.PENDING:
            any_scored = True
        if g.status != MatchStatus.COMPLETE:
            all_complete = False

    container.status = (
        MatchStatus.COMPLETE    if (children and all_complete)
        else MatchStatus.IN_PROGRESS if any_scored
        else MatchStatus.PENDING
    )
    container.save(update_fields=['status'])
    return container


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def _pid_of(team_list):
    """The single player id of a 1v1 team's player list (or None)."""
    return team_list[0]['player_id'] if team_list else None


def triple_nassau_summary(foursome) -> dict | None:
    """JSON-serialisable summary: the three per-pair Nassau summaries plus a
    per-player net rollup (each player's two matches summed).  Returns None when
    no Triple Nassau is configured."""
    container = _container_for(foursome)
    if container is None:
        return None

    order    = container.player_order or []
    members  = {m.player_id: m
                for m in foursome.memberships.select_related('player')}

    def _pinfo(pid):
        m = members.get(pid)
        p = m.player if m else None
        return {
            'player_id'       : pid,
            'name'            : p.name if p else '',
            'short_name'      : p.short_name if p else '',
            'playing_handicap': (m.playing_handicap if m else None),
        }

    matches   = []
    net_by_pid = {pid: 0.0 for pid in order}
    cfg = {'handicap_mode': None, 'net_percent': 100, 'press_mode': 'none',
           'bet_unit': float(foursome.round.bet_unit), 'press_unit': 0.0}

    for child in container.matches.all().order_by('game_type'):
        s = nassau_summary(foursome, child.game_type)
        if s is None:
            continue
        p1 = _pid_of(s['teams'].get('team1', []))
        p2 = _pid_of(s['teams'].get('team2', []))
        total = float(s['payouts']['total'])   # +ve = team1 (p1) up; per player
        if p1 is not None:
            net_by_pid[p1] = net_by_pid.get(p1, 0.0) + total
        if p2 is not None:
            net_by_pid[p2] = net_by_pid.get(p2, 0.0) - total
        cfg['handicap_mode'] = s.get('handicap_mode')
        cfg['net_percent']   = s.get('net_percent', 100)
        cfg['press_mode']    = s.get('press_mode', 'none')
        cfg['press_unit']    = float(s.get('press_unit', 0.0) or 0.0)
        matches.append({
            'game_type' : child.game_type,
            'player1_id': p1,
            'player2_id': p2,
            'match'     : s,
        })

    players = [
        {**_pinfo(pid), 'net': round(net_by_pid.get(pid, 0.0), 2)}
        for pid in order
    ]

    # Round-progress scorecard for ALL three players (gross + par + SI), merged
    # from the children (each child's scorecard lists only its two players, but
    # every player appears in two of the three, so the union covers all three).
    sc_by_hole: dict = {}
    hole_order: list = []
    for m in matches:
        for h in (m['match'].get('scorecard') or {}).get('holes', []):
            hn = h['hole']
            if hn not in sc_by_hole:
                sc_by_hole[hn] = {
                    'hole': hn, 'par': h.get('par'),
                    'stroke_index': h.get('stroke_index'), 'gross': {},
                }
                hole_order.append(hn)
            for sr in h.get('scores', []):
                if sr.get('gross') is not None:
                    sc_by_hole[hn]['gross'][sr['player_id']] = sr['gross']

    return {
        'status'       : container.status,
        'handicap_mode': cfg['handicap_mode'],
        'net_percent'  : cfg['net_percent'],
        'press_mode'   : cfg['press_mode'],
        'bet_unit'     : cfg['bet_unit'],
        'press_unit'   : cfg['press_unit'],
        'players'      : players,   # roster in display order + per-player net
        'matches'      : matches,   # each: player ids + full NassauSummary
        'scorecard'    : {'holes': [sc_by_hole[hn] for hn in hole_order]},
    }


# ---------------------------------------------------------------------------
# Score-entry card — `~/Downloads/handoff-triple-nassau-score-entry`
# ---------------------------------------------------------------------------

def _money(v: float) -> str:
    a = abs(v)
    return f'${a:g}' if a == int(a) else f'${a:.2f}'


def triple_nassau_hole_card(foursome, hole: int) -> dict:
    """Everything the Triple Nassau score-entry screen draws for ONE hole.

    **Three Nassau cards, composed.** Each match is an ordinary child Nassau,
    so each block here is `services.nassau.nassau_hole_card` for that child —
    its nets on that pair's strokes, its bets, its presses and whether a
    manual press is on offer. Nothing about a match is decided here; what
    this adds is the roster (who strokes against whom, on this hole and over
    the round) and each golfer's money across his two matches.

    Returns `{}` when no Triple Nassau is set up.
    """
    from services.hole_plan import play_order
    from services.nassau import nassau_hole_card
    from services.player_labels import first_names

    container = _container_for(foursome)
    if container is None:
        return {}
    seat = [int(p) for p in (container.player_order or [])]
    order = play_order(foursome.round, foursome) or list(range(1, 19))
    if hole not in order or len(seat) != 3:
        return {}
    pos = order.index(hole)
    back = pos >= len(order) // 2

    members = {m.player_id: m
               for m in foursome.memberships.select_related('player')
               if not m.player.is_phantom}
    if any(pid not in members for pid in seat):
        return {}
    first = first_names({pid: members[pid].player for pid in seat})

    cards = []
    for child in container.matches.all().order_by('game_type'):
        c = nassau_hole_card(foursome, hole, child.game_type)
        if not c:
            return {}
        cards.append((child, c))
    if len(cards) != 3:
        return {}

    mode = cards[0][0].handicap_mode
    pairwise = mode == HandicapMode.STROKES_OFF

    gross = {pid: None for pid in seat}
    par = {}
    # strokes[pid][opponent] on THIS hole, and over the round
    here = {pid: {} for pid in seat}
    gets = {pid: {} for pid in seat}
    matches, net = [], {pid: 0.0 for pid in seat}
    for child, c in cards:
        ids = [s['player_ids'][0] for s in c['sides']]
        rows = {r['player_id']: r for r in c['players']}
        totals = {p['player_id']: (p.get('phcp_in_play') or 0)
                  for p in (nassau_summary(foursome, child.game_type) or {})
                  .get('scorecard', {}).get('players', [])}
        for me, other in ((ids[0], ids[1]), (ids[1], ids[0])):
            r = rows[me]
            gross[me] = r['gross']
            here[me][other] = r['strokes'] or 0
            gets[me][other] = totals.get(me, 0)
        par.setdefault('par', c.get('par'))
        par.setdefault('stroke_index', c.get('stroke_index'))

        # Only the nine in play, then the overall. A settled front nine
        # leaves the tray at the turn — it is on the board and in the money.
        want = ('back' if back else 'front', 'overall')
        chips = []
        for line in c['lines']:
            if line['key'] not in want:
                continue
            for chip in line['chips']:
                name, text = chip.get('name') or '', chip['text']
                value = text[len(name):].strip() if text.startswith(name) \
                    else text
                lead = chip.get('leader')
                chips.append({
                    'label'    : name,
                    'value'    : value,
                    'state'    : chip['state'],
                    'leader_id': ids[lead - 1] if lead in (1, 2) else None,
                    'manual'   : bool(chip.get('manual')),
                })
        w = c.get('winner')
        live = float(next((e['amount'] for e in c['money']
                           if e['side'] == 1), 0.0))
        net[ids[0]] += live
        net[ids[1]] -= live
        nxt = order[pos + 1] if pos + 1 < len(order) else None
        matches.append({
            'game_type' : child.game_type,
            'player_ids': ids,
            'names'     : [first[ids[0]], first[ids[1]]],
            'nets'      : [c['sides'][0]['best'], c['sides'][1]['best']],
            'winner_id' : (ids[0] if w == 'team1' else
                           ids[1] if w == 'team2' else None),
            'halved'    : w == 'halved',
            'chips'     : chips,
            # The engine's answer to whether a press may be called; the
            # tray only draws the button on a hole that is fully in.
            'press_start': nxt if (c.get('can_press') and c['hole_complete']
                                   and nxt is not None) else None,
            'live'      : live,
        })

    players = []
    for i, pid in enumerate(seat):
        m = members[pid]
        if pairwise:
            pills = [{'text': f'{n} v {first[o]}', 'vs_id': o}
                     for o, n in gets[pid].items() if n]
            if not pills:
                pills = [{'text': 'plays off scratch', 'vs_id': None}]
            dots = [o for o in seat if o != pid
                    for _ in range(here[pid].get(o, 0))]
            vs = [first[o] for o in seat
                  if o != pid and here[pid].get(o, 0)]
            stroke_text = ('stroke v ' + ', '.join(vs)) if vs else 'no strokes'
        else:
            # Net and gross give a golfer ONE allowance, the same in both
            # his matches, so there is one pill and one set of dots.
            n = max(gets[pid].values() or [0])
            k = max(here[pid].values() or [0])
            pills = [{'text': f'gets {n}', 'vs_id': None}] if n else []
            dots = [None] * k
            stroke_text = ('no strokes' if not k else
                           f'{k} stroke' + ('' if k == 1 else 's'))
        players.append({
            'player_id'      : pid,
            'seat'           : i,
            'name'           : m.player.name,
            'first'          : first[pid],
            'short'          : m.player.short_name,
            'course_handicap': m.course_handicap,
            'gross'          : gross[pid],
            'pills'          : pills,
            'dots'           : dots,
            'strokes'        : max(here[pid].values() or [0]),
            'stroke_text'    : stroke_text,
        })

    scored = sum(1 for p in players if p['gross'] is not None)
    complete = scored == 3
    round_over = complete and pos == len(order) - 1
    stake = float(foursome.round.bet_unit or 0)

    money = []
    if stake:
        money = sorted(
            ({'player_id': pid, 'name': members[pid].player.name,
              'amount': round(net[pid], 2)} for pid in seat),
            key=lambda e: -e['amount'])
    pays = []
    if round_over and stake:
        for mt in matches:
            a, b = mt['names']
            if abs(mt['live']) < 0.005:
                pays.append(f'{a} and {b} are square')
            elif mt['live'] > 0:
                pays.append(f'{b} pays {a} {_money(mt["live"])}')
            else:
                pays.append(f'{a} pays {b} {_money(mt["live"])}')
    for mt in matches:
        del mt['live']

    return {
        'hole'         : hole,
        'par'          : par.get('par'),
        'stroke_index' : par.get('stroke_index'),
        'thru'         : pos + 1,
        'title'        : 'Triple Nassau',
        'stake'        : stake,
        'press_stake'  : float(cards[0][1].get('press_stake') or 0),
        'players'      : players,
        'matches'      : matches,
        'scored'       : scored,
        'hole_complete': complete,
        'money'        : money,
        'pays'         : pays,
        'round_over'   : round_over,
        'next_hole'    : order[pos + 1] if pos + 1 < len(order) else None,
    }
