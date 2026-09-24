"""
services/stableford.py
----------------------
Stableford points aggregator.

Points are already calculated per hole in HoleScore.stableford_points
(auto-set in HoleScore.save):
    Albatross or better  (+3 net or better)  = 5 pts
    Eagle                (+2 net)             = 4 pts
    Birdie               (+1 net)             = 3 pts
    Par                  (0 net)              = 2 pts
    Bogey                (-1 net)             = 1 pt
    Double bogey or worse                     = 0 pts

This service sums those per player, stores a StablefordResult, and ranks.

Public API
~~~~~~~~~~
    results = calculate_stableford(round_obj)
    summary = stableford_summary(round_obj)
"""

from django.db import transaction

from scoring.models import HoleScore, StablefordResult
from tournament.models import FoursomeMembership
from core.handicap_math import round_half_up


@transaction.atomic
def calculate_stableford(round_obj) -> list:
    """
    Aggregate per-hole Stableford points into StablefordResult rows.

    Safe to call repeatedly — previous results for this round are replaced.

    Returns a list of StablefordResult instances ordered by rank.
    """
    # All real-player hole scores with stableford points for this round
    hole_scores = (
        HoleScore.objects
        .filter(
            foursome__round = round_obj,
            player__is_phantom = False,
        )
        .exclude(stableford_points=None)
        .values('player_id', 'stableford_points')
    )

    # Sum points per player
    totals: dict = {}
    for hs in hole_scores:
        pid = hs['player_id']
        totals[pid] = totals.get(pid, 0) + hs['stableford_points']

    if not totals:
        return []

    # Rank by points descending (higher = better)
    ranked = sorted(totals.items(), key=lambda x: x[1], reverse=True)

    # Persist
    StablefordResult.objects.filter(round=round_obj).delete()
    saved = []
    rank  = 1
    for i, (player_id, points) in enumerate(ranked):
        # Handle ties: same points = same rank
        if i > 0 and points < ranked[i - 1][1]:
            rank = i + 1
        saved.append(StablefordResult(
            round        = round_obj,
            player_id    = player_id,
            total_points = points,
            rank         = rank,
        ))

    StablefordResult.objects.bulk_create(saved)
    return saved


def _strokes_on_hole(hcp: int, stroke_index: int) -> int:
    """Handicap strokes received on a hole given playing handicap + stroke
    index (mirrors the Low Net allocation: one stroke per SI ≤ hcp, plus an
    extra for SI ≤ hcp−18)."""
    if hcp <= 0:
        return 0
    base = 1 if stroke_index <= (hcp % 18 or 18) else 0
    return hcp // 18 + base


def governing_config(round_obj):
    """Whose Stableford settings this round is scored on.

    Its own `StablefordGame` on a casual round — the ordinary case, and the
    one every line below was written for.

    **A round inside an individual-play STABLEFORD tournament has no
    round-level game at all**: the game belongs to the tournament, the round
    carries no `active_games` of its own, and without this the round was
    scored on a hardcoded 5/4/3/2/1/0 fallback rather than the table the TD
    set — so a club running a Modified scale saw the wrong points on the one
    screen it was entering them from. The championship config governs
    instead, which is also what makes every round of the event score on one
    table.

    The two configs are not the same model. The championship has no payout
    style, per-point rate or participant subset — those are casual-round
    ideas — so every caller reads them with `getattr` and a default.
    """
    cfg = getattr(round_obj, 'stableford_config', None)
    if cfg is not None:
        return cfg
    t = getattr(round_obj, 'tournament', None)
    if (t is not None and t.is_individual_play
            and (t.scoring_method or 'stroke') == 'stableford'):
        return getattr(t, 'stableford_championship_config', None)
    return None


def _build_stableford_totals(round_obj, *, mode=None, net_pct=None,
                             points_fn=None, participant_ids=None) -> dict:
    """{player_id: {name, points, holes_played, foursome_id, holes:{hole:pts}}}.

    Computed config-aware from gross scores + a handicap (Net% or Gross — no
    Strokes-Off) and points table, like Low Net. By default reads the round's
    own StablefordGame config (casual). The Championship passes the tournament's
    `mode`/`net_pct`/`points_fn` so every round is scored on the same table.

    `participant_ids` (a set/list of player ids) restricts the game to a SUBSET
    of the foursome — a subset side game (docs/parallel-games.md). None = all
    real players. ONLY the casual `stableford_standings` passes this from the
    round config; the Championship never does, so its scoring is unaffected.
    """
    from tournament.models import Foursome

    config = governing_config(round_obj)
    if mode is None:
        mode = config.handicap_mode if config else round_obj.handicap_mode
    if net_pct is None:
        net_pct = config.net_percent if config else round_obj.net_percent
    if points_fn is None:
        points_fn = (config.points_for_diff if config
                     else (lambda d: max(0, 2 - d)))

    foursomes = list(
        Foursome.objects.filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee'))
    _subset = set(participant_ids) if participant_ids else None
    membership_map = {
        m.player_id: m
        for fs in foursomes for m in fs.memberships.all()
        if not m.player.is_phantom
        and (_subset is None or m.player_id in _subset)
    }
    # Partial-round-aware per-hole stroke allocators (scale + re-rank on a
    # 9-hole / back-9 round); a full round reduces to the standard allocation.
    from scoring.handicap import make_strokes_fn
    strokes_fns = {fs.pk: make_strokes_fn(fs) for fs in foursomes}

    def _points(diff):
        return points_fn(diff)

    qs = (
        HoleScore.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .exclude(gross_score=None)
        .values('foursome_id', 'player_id', 'player__name',
                'hole_number', 'gross_score', 'net_score')
    )

    totals: dict = {}
    for hs in qs:
        pid = hs['player_id']
        m = membership_map.get(pid)
        if m is None:
            continue
        hole = hs['hole_number']
        # Adjusted score per the game's handicap mode. `strokes_this` is the
        # handicap strokes the player received on this hole — surfaced so the
        # points grid can show a stroke dot where a net player got a shot.
        if mode == 'gross':
            adjusted = hs['gross_score']
            strokes_this = 0
            par = None
            if m.tee_id is not None:
                par = m.tee.hole(hole).get('par')
        else:  # net (with %)
            if m.tee_id is None:
                continue
            hole_info = m.tee.hole(hole)
            par = hole_info.get('par')
            if net_pct == 100 and hs['net_score'] is not None:
                adjusted = hs['net_score']
                strokes_this = hs['gross_score'] - hs['net_score']
            else:
                eff = round_half_up((m.playing_handicap or 0) * net_pct / 100)
                strokes_this = strokes_fns[m.foursome_id](eff, m.tee, hole)
                adjusted = hs['gross_score'] - strokes_this
        if par is None:
            par = (m.tee.hole(hole).get('par') if m.tee_id else 4) or 4

        pts = _points(adjusted - par)
        d = totals.setdefault(pid, {
            'name': hs['player__name'], 'points': 0, 'holes_played': 0,
            'foursome_id': hs['foursome_id'], 'holes': {}, 'strokes': {},
            'gross': {},
        })
        d['points'] += pts
        d['holes_played'] += 1
        d['holes'][hole] = pts
        # Gross per hole so the leaderboard can show a real scorecard (a
        # modified points table makes bare points ambiguous — a "3" could be a
        # net birdie). Dots come from `strokes`.
        d['gross'][hole] = hs['gross_score']
        if strokes_this:
            d['strokes'][hole] = strokes_this
    return totals


def stableford_standings(round_obj) -> list:
    """
    Ranked standings (HIGHER points = better), with prize payouts mirroring Low
    Net: entry-fee pool split to the top finishers per the `payouts` list, ties
    sharing a rank and splitting evenly; excluded players show but earn $0.
    """
    from collections import defaultdict

    config = governing_config(round_obj)
    style = getattr(config, 'payout_style', 'pool') if config else 'pool'
    payouts_cfg  = ({p['place']: float(p['amount']) for p in (config.payouts or [])}
                    if config else {})
    excluded_ids = set(config.excluded_player_ids or []) if config else set()
    # Subset side game: restrict scoring/pool/payouts to the chosen players.
    participant_ids = (getattr(config, 'participant_player_ids', None) or None
                       if config else None)

    totals = _build_stableford_totals(round_obj, participant_ids=participant_ids)

    # Players who haven't scored sort last; otherwise by points descending.
    def _key(kv):
        d = kv[1]
        return (1, 0) if d['holes_played'] == 0 else (0, -d['points'])
    rows = sorted(totals.items(), key=_key)

    # Per-point: settle eligible, scored players via the shared wager engine,
    # which applies the optional loss cap (clip losers, rescale winners
    # pro-rata) uniformly across all three modes. Zero-sum; +ve collects.
    per_point_payout = None
    if style == 'per_point' and config is not None:
        from services.wager import (PER_POINT, WagerConfig, settle,
                                     PAY_ABOVE, PAY_WINNER, VS_AVERAGE)
        elig = {pid: d['points'] for pid, d in totals.items()
                if pid not in excluded_ids and d['holes_played'] > 0}
        if elig:
            settlement = {'first': PAY_WINNER, 'all': PAY_ABOVE,
                          'average': VS_AVERAGE}.get(config.per_point_mode,
                                                     VS_AVERAGE)
            cfg = WagerConfig(
                funding    = PER_POINT,
                settlement = settlement,
                rate       = config.per_point_rate,
                cap        = config.loss_cap,
            )
            per_point_payout = {pid: float(v)
                                for pid, v in settle(elig, cfg).items()}

    def _rank_list(items):
        out, rank = [], 1
        for i, (pid, data) in enumerate(items):
            if i > 0:
                prev = items[i - 1][1]
                prev_played = prev['holes_played'] > 0
                curr_played = data['holes_played'] > 0
                if (prev_played and curr_played and data['points'] < prev['points']) \
                        or (prev_played and not curr_played):
                    rank = i + 1
            out.append((pid, data, rank))
        return out

    ranked = _rank_list(rows)

    # Prize ranks among eligible (non-excluded) players only.
    eligible = [(pid, data) for pid, data in rows if pid not in excluded_ids]
    prize_ranked = _rank_list(eligible)
    prize_rank_map = {pid: r for pid, _d, r in prize_ranked}
    pids_by_rank: dict = defaultdict(list)
    for pid, _d, r in prize_ranked:
        pids_by_rank[r].append(pid)
    prize_rank_payout: dict = {}
    for r, pids in pids_by_rank.items():
        n = len(pids)
        total_prize = sum(payouts_cfg.get(r + j, 0.0) for j in range(n))
        prize_rank_payout[r] = round(total_prize / n, 2) if total_prize > 0 else None

    standings = []
    for pid, data, display_rank in ranked:
        is_excluded = pid in excluded_ids
        if per_point_payout is not None:
            payout = per_point_payout.get(pid)
        else:
            payout = (None if is_excluded
                      else prize_rank_payout.get(prize_rank_map.get(pid)))
        standings.append({
            'rank'        : display_rank,
            'player_id'   : pid,
            'player_name' : data['name'],
            'total_points': data['points'],
            'holes_played': data['holes_played'],
            'foursome_id' : data['foursome_id'],
            'excluded'    : is_excluded,
            'payout'      : payout,
            'holes'       : data['holes'],
            'strokes'     : data.get('strokes', {}),
            'gross'       : data.get('gross', {}),
        })
    return standings


def _stableford_stroke_index(round_obj) -> dict:
    """{hole: stroke_index} from a representative tee, so the points grid can
    show an 'Index' row — where net strokes fall."""
    from tournament.models import Foursome
    for fs in (Foursome.objects.filter(round=round_obj)
               .prefetch_related('memberships__tee')):
        for m in fs.memberships.all():
            if m.tee_id is None:
                continue
            out = {}
            for h in range(1, 19):
                si = m.tee.hole(h).get('stroke_index')
                if si is not None:
                    out[h] = si
            if out:
                return out
    return {}


def _stableford_scorecard(round_obj, standings) -> dict:
    """Per-hole GROSS scorecard (players × holes with gross + stroke dots) so the
    leaderboard can show a real scorecard next to the points — a modified points
    table makes bare points ambiguous. Shaped for the shared _MsScorecard grid."""
    from tournament.models import Foursome
    par_by_hole, si_by_hole = {}, {}
    for fs in (Foursome.objects.filter(round=round_obj)
               .prefetch_related('memberships__tee')):
        for m in fs.memberships.all():
            if m.tee_id is None:
                continue
            for h in range(1, 19):
                hd = m.tee.hole(h)
                par_by_hole.setdefault(h, hd.get('par'))
                si_by_hole.setdefault(h, hd.get('stroke_index'))
            break
        if par_by_hole:
            break

    # **The roster, not just the standings.** Standings are built from scored
    # holes, so before the first tee shot they are empty — and a card with no
    # rows cannot show anybody where his strokes fall, which is the whole point
    # of allocating them prospectively. Ranked order is kept where it exists;
    # anyone not yet on it is appended in roster order.
    players, seen = [], set()
    for s in standings:
        players.append({'player_id': s['player_id'],
                        'name': s['player_name'],
                        'short_name': (s['player_name'] or '—').split(' ')[0]})
        seen.add(s['player_id'])
    for fs in (Foursome.objects.filter(round=round_obj)
               .prefetch_related('memberships__player')):
        for m in fs.memberships.all():
            if m.player_id in seen or getattr(m.player, 'is_phantom', False):
                continue
            seen.add(m.player_id)
            players.append({'player_id': m.player_id,
                            'name': m.player.name,
                            'short_name': m.player.short_name
                                          or (m.player.name or '—').split(' ')[0]})

    # ── The holes, and the strokes, PROSPECTIVELY ─────────────────────────
    #
    # Both used to come from what had been SCORED: `holes_in_play` was the set
    # of holes with a gross on them, and `strokes` was gross minus net, which
    # exists only on a played hole. So the card grew a column at a time and a
    # golfer could not see where his shots fell until he had taken them — on
    # the one game where knowing which holes give a stroke is how you decide
    # whether to go for a green.
    #
    # Now: every hole the round plays, and the allocation from the game's own
    # allocator. `make_strokes_fn` is the one the scoring above uses, so the
    # dots and the points cannot disagree; it is also partial-round aware, so
    # a nine-hole round is scaled and re-ranked rather than given an 18-hole
    # handicap over nine holes.
    from collections import OrderedDict
    from scoring.handicap import make_strokes_fn, round_half_up
    from services.hole_plan import play_order

    config   = governing_config(round_obj)
    mode     = config.handicap_mode if config else 'net'
    net_pct  = (config.net_percent if config else 100) or 100

    order, strokes_by = [], {}
    for fs in (Foursome.objects.filter(round=round_obj)
               .prefetch_related('memberships__tee', 'memberships__player')):
        for hn in (play_order(round_obj, fs) or list(range(1, 19))):
            if hn not in order:
                order.append(hn)
        if mode == 'gross':
            continue
        fn = make_strokes_fn(fs)
        for m in fs.memberships.all():
            if m.tee_id is None or getattr(m.player, 'is_phantom', False):
                continue
            eff = round_half_up((m.playing_handicap or 0) * net_pct / 100)
            if eff <= 0:
                continue
            per = strokes_by.setdefault(m.player_id, {})
            for hn in (play_order(round_obj, fs) or list(range(1, 19))):
                n = fn(eff, m.tee, hn)
                if n:
                    per[hn] = n
    holes_in_play = order or list(range(1, 19))

    by_pid = {s['player_id']: s for s in standings}
    holes_out = []
    for hn in holes_in_play:
        holes_out.append({
            'hole'        : hn,
            'par'         : par_by_hole.get(hn),
            'stroke_index': si_by_hole.get(hn),
            # Stableford has no hole WINNER: every golfer scores his own
            # points against par, so there is nobody to green.
            'winner_id'   : None,
            'scores'      : [
                {'player_id': pl['player_id'],
                 'gross'    : (by_pid.get(pl['player_id'], {})
                               .get('gross') or {}).get(hn),
                 'strokes'  : strokes_by.get(pl['player_id'], {}).get(hn, 0),
                 # The hole's points, so one card can carry the gross block
                 # and the points block over the same hole columns.
                 'points'   : (by_pid.get(pl['player_id'], {})
                               .get('holes') or {}).get(hn)}
                for pl in players
            ],
        })
    return {'players': players, 'holes': holes_out,
            'holes_in_play': holes_in_play}


def field_standing(round_obj) -> dict:
    """Each golfer's place in the ROUND's field, keyed by player id.

    The Stableford twin of `low_net_round.field_standing`, and deliberately
    the same shape: what the score-entry standing row reports, and the one
    fact that card cannot work out for itself, since it holds one foursome
    and a place is about everybody.

    **This round, not the championship** — because this is the board the
    row's pill opens. A Stableford tournament round now draws a points tab
    (the game is the tournament's, so the round has no `active_games` of its
    own and the board used to show a stroke-play tab and nothing else). The
    championship total is a different number on a different screen, and a row
    quoting it beside a board showing today's would be two answers to one
    question on a multi-round event.

    Same two departures the stroke twin makes, both claiming less: a golfer
    who has not teed off is unranked rather than sharing the last rank
    issued, and `tied` counts only golfers who have started. `field` is every
    golfer ENTERED.
    """
    rows = stableford_standings(round_obj)

    # **Seed the whole roster.** Stableford standings are built from posted
    # scores, so before the first putt they are EMPTY — and an empty block
    # means no row, which means no named way to the leaderboard on the one
    # screen a first-time player is looking at. That is the problem the row
    # exists to solve, so it draws `Tee off` from the first tee instead.
    # (The stroke twin gets this for free: `low_net_round_standings` already
    # seeds the roster so its prospective scorecard can show.)
    roster = {
        m.player_id
        for fs in round_obj.foursomes.all()
        for m in fs.memberships.select_related('player')
        if not m.player.is_phantom
    }

    started = [r for r in rows if r.get('holes_played')]
    at_rank: dict = {}
    for r in started:
        at_rank[r['rank']] = at_rank.get(r['rank'], 0) + 1

    field = len(roster | {r['player_id'] for r in rows})
    out = {
        pid: {'metric': 'points', 'rank': None, 'tied': False,
              'field': field, 'points': None, 'thru': 0}
        for pid in roster
    }
    for r in rows:
        playing = bool(r.get('holes_played'))
        out[r['player_id']] = {
            # One payload key must never mean two shapes. The stroke twin
            # sends `net_to_par` and no `points`; a client casting blind
            # would read a points total as a score against par, which on a
            # Stableford round is roughly its opposite.
            'metric': 'points',
            'rank'  : r['rank'] if playing else None,
            'tied'  : playing and at_rank.get(r['rank'], 0) > 1,
            'field' : field,
            'points': r['total_points'] if playing else None,
            'thru'  : r.get('holes_played') or 0,
        }
    return out


def stableford_summary(round_obj) -> dict:
    """Full Stableford block for the leaderboard / watch page: ranked standings
    + the points table + pool/entry-fee + handicap settings."""
    config = governing_config(round_obj)
    standings = stableford_standings(round_obj)
    entry_fee = float(config.entry_fee) if config else 0.0
    table = None
    if config is not None:
        table = {
            'albatross': config.pts_albatross, 'eagle': config.pts_eagle,
            'birdie':    config.pts_birdie,    'par':   config.pts_par,
            'bogey':     config.pts_bogey,     'double': config.pts_double,
        }
    style = getattr(config, 'payout_style', 'pool') if config else 'pool'
    return {
        'status'        : round_obj.status,
        'handicap_mode' : config.handicap_mode if config else 'net',
        'net_percent'   : config.net_percent if config else 100,
        'payout_style'  : style,
        # `getattr` with a default, not attribute access: a Stableford
        # tournament's governing config is the CHAMPIONSHIP's, which has no
        # payout style, per-point rate or loss cap — those are casual-round
        # ideas. Reading them straight off it raises.
        'per_point_rate': float(getattr(config, 'per_point_rate', 0) or 0)
                          if config else 0.0,
        'per_point_mode': getattr(config, 'per_point_mode', 'average')
                          if config else 'average',
        'loss_cap'      : (float(config.loss_cap)
                           if config and getattr(config, 'loss_cap', None)
                           is not None else None),
        'entry_fee'     : entry_fee,
        'pool'          : (round(entry_fee * len(standings), 2)
                           if style == 'pool' else 0.0),
        'table'         : table,
        'results'       : standings,
        # Stroke index per hole (representative tee) so the points grid can
        # render an 'Index' row + dots on the holes where net strokes fall.
        'stroke_index'  : _stableford_stroke_index(round_obj),
        # Real per-hole gross scorecard (gross + stroke dots), so the tab can
        # show it alongside the points (a modified table makes points ambiguous).
        'scorecard'     : _stableford_scorecard(round_obj, standings),
    }
