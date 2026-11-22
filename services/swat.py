"""
services/swat.py
----------------
Oakmont SWAT — a field-wide team game for 12 or more golfers.

Rules (docs/design-review/handoff-oakmont-swat/HANDOFF.md, 22 Nov 2026)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* N golfers, N >= 12; ``T = ceil(N / 4)`` teams. The teams START in snake
  order by Handicap Index, lowest first (ties: lower course handicap, then
  surname) — team 1..T, T..1, 1..T … — and the TD may move or swap anyone as
  long as every team keeps 3 or 4 golfers (3 to 5 with fivesomes allowed).
* Each team is one group (a Foursome row). Its hole score is its best GROSS
  ball; the index only sets the starting order.
* A team of three plays a PHANTOM fourth ball: on each hole the gross of one
  "bottom golfer" (the highest index on a team of four or more), in an order
  drawn at random when the round starts. Nothing the clients receive names the
  donor until every group has finished.
* Every pair of teams plays a match-play Nassau on the best balls — front,
  back, overall, a point a hole — over only the holes BOTH have finished. A bet
  settles when its nine is done or when it is closed out (margin > holes left).
* Each bet is worth a TEAM stake = 4 x the foursome golfer's stake; a team's
  golfers split it by real team size. The phantom never pays and is never paid.

Nothing here is stored but the config: teams are the round's foursomes, and
every figure is derived on read, so correcting a score moves the money.

Public API
~~~~~~~~~~
    snake_deal(golfers)                  pure — the starting teams and bands
    team_name(golfers)                   pure — "Team Lipkin"
    shape_problem(sizes, allow_five)     pure — why a set of teams is not legal
    draw_phantom_order(donor_ids, rng)   pure — the 18-hole donor list
    setup_swat(round, ...)               config + game switch
    apply_teams(round, teams, tees)      write the groups + the phantom draw
    swat_summary(round, viewer_id=None)  the leaderboard block
"""
import math
import random
from decimal import Decimal, ROUND_HALF_UP

from core.models import Player, RoundStatus
from games.models import SwatConfig
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership

MIN_FIELD = 12
BANDS = 'ABCDE'
HOLES = 18
BETS = (('Front', 1, 9), ('Back', 10, 18), ('Overall', 1, 18))
TEAM_STAKE_FACTOR = 4


class SwatError(ValueError):
    """A SWAT setup the rules refuse; the message is the TD's sentence."""


# --------------------------------------------------------------------------
# Pure rules
# --------------------------------------------------------------------------

def surname(name: str) -> str:
    parts = (name or '').split()
    return parts[-1] if parts else ''


def _sort_key(g):
    return (float(g['index']), int(g.get('ch') or 0), surname(g['name']).lower())


def snake_deal(golfers: list) -> dict:
    """Deal *golfers* into teams in snake order.

    Each golfer is ``{'id', 'name', 'index', 'ch'?}``. Returns
    ``{'teams': [[id, ...], ...], 'bands': {id: 'A'}}``. The band is the
    golfer's row in the deal — A is the T lowest indexes, B the next T — and
    it is NOT recomputed when the TD moves anybody.
    """
    ordered = sorted(golfers, key=_sort_key)
    n = len(ordered)
    t = max(1, math.ceil(n / 4))
    teams = [[] for _ in range(t)]
    bands = {}
    for k, g in enumerate(ordered):
        tier, pos = divmod(k, t)
        team = pos if tier % 2 == 0 else t - 1 - pos
        teams[team].append(g['id'])
        bands[g['id']] = BANDS[min(tier, len(BANDS) - 1)]
    return {'teams': teams, 'bands': bands}


def team_name(members: list) -> str:
    """"Team" plus the lowest-index golfer's surname; follows any move."""
    if not members:
        return 'Team'
    low = sorted(members, key=_sort_key)[0]
    return f'Team {surname(low["name"])}'.strip()


def shape_problem(sizes: list, allow_fivesomes: bool = False):
    """The sentence a set of team sizes breaks, or None when it is legal."""
    n = sum(sizes)
    if n < MIN_FIELD:
        return (f'SWAT needs at least {MIN_FIELD} golfers — you have {n}.')
    top = 5 if allow_fivesomes else 4
    for s in sizes:
        if s < 3:
            return 'Every team needs at least three golfers.'
        if s > top:
            return (f'A team of {s} is too many — '
                    f'{"turn on Allow fivesomes for groups of five" if top == 4 else "five is the most"}.')
    if any(s == 3 for s in sizes) and not any(s >= 4 for s in sizes):
        return ('A threesome needs a team of four to draw its phantom from.')
    return None


def draw_phantom_order(donor_ids: list, rng=None) -> list:
    """The donor for each of 18 holes: shuffled, reshuffled every pass."""
    if not donor_ids:
        return []
    rng = rng or random.SystemRandom()
    order = []
    while len(order) < HOLES:
        deck = list(donor_ids)
        rng.shuffle(deck)
        order.extend(deck)
    return order[:HOLES]


def _cents(value) -> int:
    return int((Decimal(str(value)) * 100).quantize(Decimal('1'),
                                                    rounding=ROUND_HALF_UP))


def _each(net_cents: int, size: int) -> float:
    """A golfer's share, to the cent, half away from zero."""
    if not size:
        return 0.0
    share = (Decimal(net_cents) / Decimal(size)).quantize(
        Decimal('1'), rounding=ROUND_HALF_UP)
    return float(share) / 100.0


# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

def setup_swat(round_obj, *, stake=6, allow_fivesomes=False):
    """Save the SWAT config and switch the game on for the round."""
    from services.group_field import refuse_if_another_one_pool_game
    refuse_if_another_one_pool_game(round_obj, 'oakmont_swat')
    stake = Decimal(str(stake))
    if stake < 0:
        raise SwatError('The stake cannot be negative.')
    cfg, _ = SwatConfig.objects.update_or_create(
        round=round_obj,
        defaults={'stake': stake, 'allow_fivesomes': bool(allow_fivesomes)})
    active = list(round_obj.active_games or [])
    if 'oakmont_swat' not in active:
        active.append('oakmont_swat')
        round_obj.active_games = active
        round_obj.save(update_fields=['active_games'])
    return cfg


def field_golfers(player_ids: list) -> list:
    """The ``snake_deal`` input for real golfers, in the order given."""
    players = {p.pk: p for p in Player.objects.filter(
        pk__in=player_ids, is_phantom=False)}
    out = []
    for pid in player_ids:
        p = players.get(pid)
        if p is None:
            raise SwatError(f'Unknown golfer {pid}.')
        out.append({'id': p.pk, 'name': p.name, 'short': p.short_name,
                    'index': float(p.handicap_index or 0), 'ch': 0})
    return out


def preview_teams(player_ids: list, *, allow_fivesomes=False,
                  teams=None) -> dict:
    """What the Teams screen draws. *teams* is the TD's own arrangement; with
    none, the snake deal. Never writes."""
    golfers = field_golfers(player_ids)
    by_id = {g['id']: g for g in golfers}
    dealt = snake_deal(golfers)
    arrangement = teams if teams is not None else dealt['teams']
    seen = [pid for t in arrangement for pid in t]
    if sorted(seen) != sorted(player_ids):
        raise SwatError('Every golfer must be on exactly one team.')
    problem = shape_problem([len(t) for t in arrangement], allow_fivesomes)
    edited = [sorted(t) for t in arrangement] != [sorted(t) for t in dealt['teams']]
    out_teams = []
    for t in arrangement:
        members = [by_id[pid] for pid in t]
        out_teams.append({
            'name': team_name(members),
            'size': len(t),
            'three': len(t) == 3,
            'five': len(t) == 5,
            'players': [{'id': m['id'], 'name': m['name'],
                         'short': m['short'], 'index': m['index'],
                         'band': dealt['bands'][m['id']]} for m in members]})
    n = len(player_ids)
    return {'field': n, 'teams': out_teams, 'problem': problem,
            'edited': edited, 'threesomes': sum(1 for t in arrangement if len(t) == 3),
            'matches': (len(arrangement) * (len(arrangement) - 1)) // 2,
            'bands': dealt['bands']}


def bottom_golfers(teams: list, by_id: dict) -> list:
    """The highest-index golfer of each team of four or more."""
    donors = []
    for t in teams:
        if len(t) >= 4:
            top = sorted((by_id[pid] for pid in t), key=_sort_key)[-1]
            donors.append(top['id'])
    return donors


def apply_teams(round_obj, teams: list, tee_by_player: dict, *,
                allowance: float = 1.0) -> list:
    """Write the teams as the round's groups and draw the phantom order.

    *teams* is ``[[player_id, ...], ...]``; *tee_by_player* maps each golfer to
    his tee. Refused once a real score exists (``setup_round`` raises
    ``RoundRegroupLocked``) — the draw belongs to the groups that scored it.
    """
    from services.round_setup import setup_round
    cfg = SwatConfig.objects.filter(round=round_obj).first()
    if cfg is None:
        raise SwatError('Set the SWAT game up before dealing teams.')
    ids = [pid for t in teams for pid in t]
    problem = shape_problem([len(t) for t in teams], cfg.allow_fivesomes)
    if problem:
        raise SwatError(problem)
    golfers = field_golfers(ids)
    by_id = {g['id']: g for g in golfers}
    dealt = snake_deal(golfers)

    players = []
    for number, t in enumerate(teams, start=1):
        for pid in t:
            tee = tee_by_player.get(pid)
            if tee is None:
                raise SwatError(f'Golfer {pid} has no tee.')
            players.append({'player_id': pid, 'tee_id': tee,
                            'group_number': number})
    created = setup_round(round_obj, players, handicap_allowance=allowance,
                          randomise=False)

    cfg.bands = {str(k): v for k, v in dealt['bands'].items()}
    cfg.edited = ([sorted(t) for t in teams]
                  != [sorted(t) for t in dealt['teams']])
    cfg.phantom_order = draw_phantom_order(bottom_golfers(teams, by_id))
    cfg.save(update_fields=['bands', 'edited', 'phantom_order'])
    return created


# --------------------------------------------------------------------------
# Reading the round
# --------------------------------------------------------------------------

def _par_by_hole(tee) -> dict:
    return {int(h['number']): int(h['par']) for h in (tee.holes or [])}


def _si_by_hole(tee) -> dict:
    return {int(h['number']): int(h['stroke_index'])
            for h in (tee.holes or []) if h.get('stroke_index')}


def _load(round_obj):
    cfg = SwatConfig.objects.filter(round=round_obj).first()
    if cfg is None:
        return None
    foursomes = list(Foursome.objects.filter(round=round_obj)
                     .order_by('group_number'))
    mems = (FoursomeMembership.objects
            .filter(foursome__in=foursomes, player__is_phantom=False)
            .select_related('player', 'tee').order_by('id'))
    by_f = {f.pk: [] for f in foursomes}
    for m in mems:
        by_f[m.foursome_id].append(m)
    gross = {}
    for pid, hole, g in (HoleScore.objects
                         .filter(foursome__in=foursomes,
                                 gross_score__isnull=False)
                         .values_list('player_id', 'hole_number',
                                      'gross_score')):
        gross.setdefault(pid, {})[hole] = g
    bands = {int(k): v for k, v in (cfg.bands or {}).items()}
    teams = []
    for f in foursomes:
        ms = by_f[f.pk]
        if not ms:
            continue
        golfers = [{'id': m.player_id, 'name': m.player.name,
                    'short': m.player.short_name,
                    'index': float(m.player.handicap_index or 0),
                    'ch': m.course_handicap or 0,
                    'band': bands.get(m.player_id, ''),
                    'par': _par_by_hole(m.tee) if m.tee else {},
                    'si': _si_by_hole(m.tee) if m.tee else {},
                    'wd': m.withdrew_after_hole} for m in ms]
        teams.append({'foursome': f, 'golfers': golfers,
                      'name': team_name(golfers), 'size': len(golfers),
                      'three': len(golfers) == 3, 'five': len(golfers) == 5})
    return cfg, teams, gross


def _donor(cfg, hole: int):
    order = cfg.phantom_order or []
    return order[hole - 1] if 0 < hole <= len(order) else None


def _team_holes(cfg, team, gross) -> dict:
    """Per hole: ``{'balls': {pid: g}, 'phantom': g|None, 'real_in': bool,
    'finished': bool, 'best': int|None}`` for the holes any real golfer has."""
    out = {}
    for h in range(1, HOLES + 1):
        active = [g for g in team['golfers']
                  if g['wd'] is None or h <= g['wd']]
        balls = {g['id']: gross.get(g['id'], {}).get(h) for g in active}
        real_in = bool(active) and all(v is not None for v in balls.values())
        phantom = None
        if team['three']:
            d = _donor(cfg, h)
            phantom = gross.get(d, {}).get(h) if d else None
        finished = real_in and (not team['three'] or phantom is not None)
        best = None
        if finished:
            vals = [v for v in balls.values() if v is not None]
            if phantom is not None:
                vals.append(phantom)
            best = min(vals) if vals else None
        out[h] = {'balls': balls, 'phantom': phantom, 'real_in': real_in,
                  'finished': finished, 'best': best}
    return out


def _nassau(a_holes, b_holes) -> dict:
    """One match over the holes both teams have finished."""
    res = {}
    for h in range(1, HOLES + 1):
        x, y = a_holes[h], b_holes[h]
        if x['finished'] and y['finished']:
            res[h] = (x['best'] > y['best']) - (x['best'] < y['best'])
            res[h] = -res[h]            # lower is better: +1 = a wins the hole
    bets = []
    for key, lo, hi in BETS:
        span = range(lo, hi + 1)
        of = len(span)
        played = [h for h in span if h in res]
        margin = sum(res[h] for h in played)
        p = len(played)
        done = p == of or abs(margin) > of - p
        if not done:
            result = None
        elif margin == 0:
            result = 'P'
        else:
            result = 'W' if margin > 0 else 'L'
        bets.append({'key': key, 'margin': margin, 'played': p, 'of': of,
                     'done': done, 'closed': done and p < of,
                     'left': of - p, 'result': result})
    return {'holes': res, 'bets': bets, 'thru': len(res)}


def _rank(rows, key):
    rows.sort(key=key, reverse=True)
    last, place = None, 0
    for i, r in enumerate(rows, start=1):
        v = key(r)
        if v != last:
            place, last = i, v
        r['place'] = place
        r['tied'] = sum(1 for x in rows if key(x) == v) > 1


# --------------------------------------------------------------------------
# The summary
# --------------------------------------------------------------------------

def swat_summary(round_obj, viewer_id=None) -> dict:
    """The leaderboard block. ``viewer_id`` is a golfer's player id (to mark
    his team); the phantom's donors are named only once every group is in."""
    loaded = _load(round_obj)
    if loaded is None:
        return {}
    cfg, teams, gross = loaded
    if not teams:
        return {'configured': True, 'stake': float(cfg.stake), 'teams': [],
                'allow_fivesomes': cfg.allow_fivesomes, 'matches': []}

    stake_c = _cents(cfg.stake)
    team_stake_c = TEAM_STAKE_FACTOR * stake_c
    for t in teams:
        t['holes'] = _team_holes(cfg, t, gross)
        t['thru'] = sum(1 for v in t['holes'].values() if v['finished'])
        t['last'] = max((h for h, v in t['holes'].items() if v['finished']),
                        default=0)
        t['net_c'] = 0
        t['w'] = t['l'] = t['p'] = 0

    matches = []
    for i in range(len(teams)):
        for j in range(i + 1, len(teams)):
            a, b = teams[i], teams[j]
            m = _nassau(a['holes'], b['holes'])
            for bet in m['bets']:
                if bet['result'] == 'W':
                    a['net_c'] += team_stake_c; b['net_c'] -= team_stake_c
                    a['w'] += 1; b['l'] += 1
                elif bet['result'] == 'L':
                    a['net_c'] -= team_stake_c; b['net_c'] += team_stake_c
                    a['l'] += 1; b['w'] += 1
                elif bet['result'] == 'P':
                    a['p'] += 1; b['p'] += 1
            matches.append({'a': a['foursome'].pk, 'b': b['foursome'].pk,
                            'thru': m['thru'], 'bets': m['bets']})

    n_teams = len(teams)
    all_final = all(t['thru'] == HOLES for t in teams)
    total_bets = 3 * n_teams * (n_teams - 1) // 2

    rows = []
    for t in teams:
        f = t['foursome']
        phantom = None
        if t['three']:
            phantom = {}
            for h, v in t['holes'].items():
                # Shown only once the team's own golfers have entered the hole.
                phantom[h] = v['phantom'] if v['real_in'] else None
        par = {}
        for g in t['golfers']:
            for h, p in g['par'].items():
                par.setdefault(h, p)
        best_to_par = sum(v['best'] - par.get(h, 0)
                          for h, v in t['holes'].items() if v['finished'])
        rows.append({
            'id': f.pk, 'group': f.group_number, 'name': t['name'],
            'size': t['size'], 'three': t['three'], 'five': t['five'],
            'is_viewer': viewer_id in {g['id'] for g in t['golfers']},
            'players': [{'id': g['id'], 'name': g['name'],
                         'short': g['short'], 'index': g['index'],
                         'band': g['band']} for g in t['golfers']],
            'thru': t['thru'], 'last_hole': t['last'],
            'finished': t['thru'] == HOLES,
            'wins': t['w'], 'losses': t['l'], 'pushes': t['p'],
            'open_bets': 3 * (n_teams - 1) - (t['w'] + t['l'] + t['p']),
            'money': t['net_c'] / 100.0,
            'each': _each(t['net_c'], t['size']),
            'best_to_par': best_to_par,
            'best': {h: v['best'] for h, v in t['holes'].items()
                     if v['finished']},
            'phantom': phantom,
            '_net_c': t['net_c'],
        })
    _rank(rows, key=lambda r: r['_net_c'])

    # Gross, by golfer: the board's By player view.
    players = []
    for t, r in zip(teams, rows):
        for g in t['golfers']:
            played = gross.get(g['id'], {})
            players.append({
                'id': g['id'], 'name': g['name'], 'short': g['short'],
                'team': r['name'], 'team_id': r['id'], 'band': g['band'],
                'index': g['index'], 'thru': len(played),
                'gross': sum(played.values()),
                'par': sum(g['par'].get(h, 0) for h in played),
                'holes': {h: v for h, v in played.items()}})

    if all_final:
        donors = {}
        by_pid = {g['id']: g for t in teams for g in t['golfers']}
        for h in range(1, HOLES + 1):
            d = _donor(cfg, h)
            if d in by_pid:
                donors[h] = by_pid[d]['short']
        for r in rows:
            if r['three']:
                r['phantom_donors'] = donors

    # Gross board: ranked by best ball to par, lowest first. A team with no
    # holes finished is unranked rather than tied at level par.
    ranked = sorted((r for r in rows if r['thru']),
                    key=lambda r: r['best_to_par'])
    last, place = None, 0
    for i, r in enumerate(ranked, start=1):
        if r['best_to_par'] != last:
            place, last = i, r['best_to_par']
        r['gross_place'] = place
        r['gross_tied'] = sum(1 for x in ranked
                              if x['best_to_par'] == r['best_to_par']) > 1
    for r in rows:
        r.setdefault('gross_place', None)
        r.setdefault('gross_tied', False)

    par_map, si_map = {}, {}
    for t in teams:
        for g in t['golfers']:
            for h, v in g['par'].items():
                par_map.setdefault(h, v)
            for h, v in g['si'].items():
                si_map.setdefault(h, v)

    for r in rows:
        del r['_net_c']
    return {
        'par': par_map, 'si': si_map,
        'configured': True, 'status': round_obj.status,
        'stake': float(cfg.stake), 'team_stake': team_stake_c / 100.0,
        'allow_fivesomes': cfg.allow_fivesomes, 'edited': cfg.edited,
        'teams': rows, 'matches': matches, 'players': players,
        'bets_total': total_bets,
        'bets_open': total_bets - sum(
            1 for m in matches for b in m['bets'] if b['done']),
        'final': all_final,
        'max_loss': (3 * (n_teams - 1) * team_stake_c) / 100.0,
    }


# --------------------------------------------------------------------------
# Score entry: one hole, one team
# --------------------------------------------------------------------------

def _ordinal(n: int) -> str:
    if 10 <= n % 100 <= 20:
        suffix = 'th'
    else:
        suffix = {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')
    return f'{n}{suffix}'


def swat_hole_card(foursome, hole: int) -> dict:
    """Everything the SWAT tray draws for this team's *hole*.

    Renders the engine and decides nothing: balls, best ball and the matches
    come from the same `_team_holes` / `_nassau` the board reads, so the tray
    and the leaderboard cannot disagree. The phantom is NEVER named here, and
    its score appears only once the team's own golfers have entered the hole.
    """
    rnd = foursome.round
    loaded = _load(rnd)
    if loaded is None:
        return {}
    cfg, teams, gross = loaded
    me = next((t for t in teams if t['foursome'].pk == foursome.pk), None)
    if me is None:
        return {}
    for t in teams:
        t['holes'] = _team_holes(cfg, t, gross)
    mine = me['holes'][hole]

    # -- the balls -------------------------------------------------------
    rows = []
    for g in me['golfers']:
        rows.append({'player_id': g['id'], 'name': g['name'],
                     'short': g['short'], 'index': g['index'],
                     'gross': mine['balls'].get(g['id']),
                     'par': g['par'].get(hole)})
    par = next((g['par'].get(hole) for g in me['golfers']
                if g['par'].get(hole)), None)

    phantom = None
    if me['three']:
        if not mine['real_in']:
            phantom = {'state': 'locked', 'score': None}
        elif mine['phantom'] is None:
            phantom = {'state': 'later', 'score': None}
        else:
            phantom = {'state': 'open', 'score': mine['phantom']}

    real_scores = [v for v in mine['balls'].values() if v is not None]
    waiting = bool(phantom and phantom['state'] != 'open')
    balls = []
    if mine['real_in']:
        for g in me['golfers']:
            balls.append({'label': g['short'], 'gross': mine['balls'][g['id']],
                          'phantom': False})
        if phantom and phantom['state'] == 'open':
            balls.append({'label': 'Phantom', 'gross': phantom['score'],
                          'phantom': True})
        balls.sort(key=lambda b: b['gross'])
        best = balls[0]['gross'] if balls else None
        for b in balls:
            b['counts'] = b['gross'] == best
        tied = sum(1 for b in balls if b['counts']) > 1
        for b in balls:
            b['tied'] = b['counts'] and tied
    else:
        best = None
    best_real = min(real_scores) if real_scores else None
    waiting_note = None
    if waiting and best_real is not None:
        waiting_note = ('The phantom has to score %d or better to count.'
                        % (best_real - 1) if best_real > 1 else
                        'Waiting on the phantom.')

    # -- this hole against every other team ------------------------------
    won = lost = halved = 0
    to_play = []
    for t in teams:
        if t is me:
            continue
        other = t['holes'][hole]
        if mine['finished'] and other['finished']:
            if mine['best'] < other['best']:
                won += 1
            elif mine['best'] > other['best']:
                lost += 1
            else:
                halved += 1
        else:
            to_play.append(t['name'])
    try:
        from services.hole_plan import play_order
        order = play_order(rnd, foursome)
        nth = order.index(hole) + 1
    except Exception:
        nth = hole

    # -- money to date and where the overall stands -----------------------
    stake_c = TEAM_STAKE_FACTOR * _cents(cfg.stake)
    net_c = w = l = p = 0
    up = level = down = 0
    settled = 0
    for t in teams:
        if t is me:
            continue
        m = _nassau(me['holes'], t['holes'])
        for bet in m['bets']:
            if bet['done']:
                settled += 1
            if bet['result'] == 'W':
                net_c += stake_c; w += 1
            elif bet['result'] == 'L':
                net_c -= stake_c; l += 1
            elif bet['result'] == 'P':
                p += 1
        overall = m['bets'][2]
        if overall['played']:
            if overall['margin'] > 0:
                up += 1
            elif overall['margin'] < 0:
                down += 1
            else:
                level += 1
    n_others = len(teams) - 1
    total = 3 * n_others
    if me['five']:
        split = 'a fifth each'
    elif me['three']:
        split = 'a third each'
    else:
        split = 'a quarter each'
    return {
        'hole': hole, 'par': par, 'nth': nth,
        'ordinal': _ordinal(nth),
        'team': {'id': foursome.pk, 'name': me['name'], 'size': me['size'],
                 'three': me['three'], 'five': me['five']},
        'players': rows,
        'phantom': phantom,
        'complete': bool(mine['real_in']),
        'waiting': waiting,
        'best': best,
        'balls': balls,
        'waiting_note': waiting_note,
        'versus': {'teams': n_others, 'won': won, 'lost': lost,
                   'halved': halved,
                   'to_play': to_play if mine['finished'] else [],
                   'waiting': waiting,
                   'still_to_play': len(to_play)},
        'money': {'team': net_c / 100.0, 'each': _each(net_c, me['size']),
                  'split': split, 'won': w, 'lost': l, 'pushed': p,
                  'open': total - settled,
                  'overall': {'up': up, 'level': level, 'down': down}},
    }
