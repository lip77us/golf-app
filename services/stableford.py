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


def _build_stableford_totals(round_obj, *, mode=None, net_pct=None,
                             points_fn=None) -> dict:
    """{player_id: {name, points, holes_played, foursome_id, holes:{hole:pts}}}.

    Computed config-aware from gross scores + a handicap (Net% or Gross — no
    Strokes-Off) and points table, like Low Net. By default reads the round's
    own StablefordGame config (casual). The Championship passes the tournament's
    `mode`/`net_pct`/`points_fn` so every round is scored on the same table.
    """
    from tournament.models import Foursome

    config = getattr(round_obj, 'stableford_config', None)
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
    membership_map = {
        m.player_id: m
        for fs in foursomes for m in fs.memberships.all()
        if not m.player.is_phantom
    }

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
        # Adjusted score per the game's handicap mode.
        if mode == 'gross':
            adjusted = hs['gross_score']
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
            else:
                si  = hole_info.get('stroke_index', 18)
                eff = round((m.playing_handicap or 0) * net_pct / 100)
                adjusted = hs['gross_score'] - _strokes_on_hole(eff, si)
        if par is None:
            par = (m.tee.hole(hole).get('par') if m.tee_id else 4) or 4

        pts = _points(adjusted - par)
        d = totals.setdefault(pid, {
            'name': hs['player__name'], 'points': 0, 'holes_played': 0,
            'foursome_id': hs['foursome_id'], 'holes': {},
        })
        d['points'] += pts
        d['holes_played'] += 1
        d['holes'][hole] = pts
    return totals


def stableford_standings(round_obj) -> list:
    """
    Ranked standings (HIGHER points = better), with prize payouts mirroring Low
    Net: entry-fee pool split to the top finishers per the `payouts` list, ties
    sharing a rank and splitting evenly; excluded players show but earn $0.
    """
    from collections import defaultdict

    config = getattr(round_obj, 'stableford_config', None)
    style = config.payout_style if config else 'pool'
    payouts_cfg  = ({p['place']: float(p['amount']) for p in (config.payouts or [])}
                    if config else {})
    excluded_ids = set(config.excluded_player_ids or []) if config else set()

    totals = _build_stableford_totals(round_obj)

    # Players who haven't scored sort last; otherwise by points descending.
    def _key(kv):
        d = kv[1]
        return (1, 0) if d['holes_played'] == 0 else (0, -d['points'])
    rows = sorted(totals.items(), key=_key)

    # Per-point ("pay everyone above you"): net = rate × (n·pts − total) across
    # eligible, scored players. Zero-sum; +ve collects, −ve pays.
    per_point_payout = None
    if style == 'per_point' and config is not None:
        rate = float(config.per_point_rate)
        elig = [(pid, d['points']) for pid, d in totals.items()
                if pid not in excluded_ids and d['holes_played'] > 0]
        n = len(elig)
        if config.per_point_mode == 'first' and n:
            # Only the leader(s) collect: everyone else pays the leader their
            # points deficit × rate; ties for first split the take.
            top = max(p for _pid, p in elig)
            winners = [pid for pid, p in elig if p == top]
            take = sum((top - p) * rate for _pid, p in elig)
            per_winner = round(take / len(winners), 2)
            per_point_payout = {
                pid: (per_winner if pid in winners
                      else round(-(top - p) * rate, 2))
                for pid, p in elig
            }
        else:  # 'all' — pay everyone above you
            tot = sum(p for _pid, p in elig)
            per_point_payout = {
                pid: round(rate * (n * pts - tot), 2) for pid, pts in elig
            }

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
        })
    return standings


def stableford_summary(round_obj) -> dict:
    """Full Stableford block for the leaderboard / watch page: ranked standings
    + the points table + pool/entry-fee + handicap settings."""
    config = getattr(round_obj, 'stableford_config', None)
    standings = stableford_standings(round_obj)
    entry_fee = float(config.entry_fee) if config else 0.0
    table = None
    if config is not None:
        table = {
            'albatross': config.pts_albatross, 'eagle': config.pts_eagle,
            'birdie':    config.pts_birdie,    'par':   config.pts_par,
            'bogey':     config.pts_bogey,     'double': config.pts_double,
        }
    style = config.payout_style if config else 'pool'
    return {
        'status'        : round_obj.status,
        'handicap_mode' : config.handicap_mode if config else 'net',
        'net_percent'   : config.net_percent if config else 100,
        'payout_style'  : style,
        'per_point_rate': float(config.per_point_rate) if config else 0.0,
        'per_point_mode': config.per_point_mode if config else 'all',
        'entry_fee'     : entry_fee,
        'pool'          : (round(entry_fee * len(standings), 2)
                           if style == 'pool' else 0.0),
        'table'         : table,
        'results'       : standings,
    }
