"""
services/stableford_championship.py
-----------------------------------
Stableford Championship — total Stableford points accumulated across every
round of a tournament (all rounds count; N-of-M is deferred, matching the Low
Net Championship). Mirrors low_net_championship but ranks by points DESCENDING
and is pool-paid. Per-round points use the tournament's own table + handicap via
_build_stableford_totals(..., mode, net_pct, points_fn).
"""
from collections import defaultdict

from core.models import HandicapMode
from services.stableford import _build_stableford_totals


def _config(tournament):
    return getattr(tournament, 'stableford_championship_config', None)


def _aggregate_rounds(tournament, mode, net_pct, points_fn) -> dict:
    """{player_id: {name, points, holes_played, rounds_played,
    round_totals:[pts per round], round_labels:['R1',...]}} across all rounds."""
    rounds = list(
        tournament.rounds.order_by('round_number')
        .prefetch_related('foursomes__memberships__player'))
    aggregated: dict = {}
    for round_obj in rounds:
        per = _build_stableford_totals(
            round_obj, mode=mode, net_pct=net_pct, points_fn=points_fn)
        for pid, data in per.items():
            if data['holes_played'] == 0:
                continue
            entry = aggregated.setdefault(pid, {
                'name': data['name'], 'points': 0, 'holes_played': 0,
                'rounds_played': 0, 'round_totals': [], 'round_labels': [],
            })
            entry['points']        += data['points']
            entry['holes_played']  += data['holes_played']
            entry['rounds_played'] += 1
            entry['round_totals'].append(data['points'])
            entry['round_labels'].append(f'R{round_obj.round_number}')
    return aggregated


def stableford_championship_standings(tournament) -> list:
    config = _config(tournament)
    if config is not None:
        mode, net_pct, points_fn = (config.handicap_mode, config.net_percent,
                                    config.points_for_diff)
        payouts_cfg = {p['place']: float(p['amount'])
                       for p in (config.payouts or [])}
        excluded = set(config.excluded_player_ids or [])
    else:
        mode, net_pct = HandicapMode.NET, 100
        points_fn = lambda d: max(0, 2 - d)          # noqa: E731
        payouts_cfg, excluded = {}, set()

    aggregated = _aggregate_rounds(tournament, mode, net_pct, points_fn)
    if not aggregated:
        return []

    # Higher points = better.
    rows = sorted(aggregated.items(), key=lambda kv: -kv[1]['points'])

    def _rank_list(items):
        out, rank = [], 1
        for i, (pid, data) in enumerate(items):
            if i > 0 and data['points'] < items[i - 1][1]['points']:
                rank = i + 1
            out.append((pid, data, rank))
        return out

    ranked = _rank_list(rows)

    # Prize ranks among eligible (non-excluded) players only.
    eligible = [(pid, d) for pid, d in rows if pid not in excluded]
    prize_ranked = _rank_list(eligible)
    prize_rank_map = {pid: r for pid, _d, r in prize_ranked}
    pids_by_rank = defaultdict(list)
    for pid, _d, r in prize_ranked:
        pids_by_rank[r].append(pid)
    rank_payout = {}
    for r, pids in pids_by_rank.items():
        n = len(pids)
        total_prize = sum(payouts_cfg.get(r + j, 0.0) for j in range(n))
        rank_payout[r] = round(total_prize / n, 2) if total_prize > 0 else None

    standings = []
    for pid, data, rank in ranked:
        is_excluded = pid in excluded
        payout = (None if is_excluded
                  else rank_payout.get(prize_rank_map.get(pid)))
        standings.append({
            'rank'         : rank,
            'player_id'    : pid,
            'player_name'  : data['name'],
            'total_points' : data['points'],
            'holes_played' : data['holes_played'],
            'rounds_played': data['rounds_played'],
            'round_totals' : data['round_totals'],
            'round_labels' : data['round_labels'],
            'excluded'     : is_excluded,
            'payout'       : payout,
        })
    return standings


def stableford_championship_summary(tournament) -> dict:
    config = _config(tournament)
    standings = stableford_championship_standings(tournament)
    entry_fee = float(config.entry_fee) if config else 0.0
    table = None
    if config is not None:
        table = {'albatross': config.pts_albatross, 'eagle': config.pts_eagle,
                 'birdie': config.pts_birdie, 'par': config.pts_par,
                 'bogey': config.pts_bogey, 'double': config.pts_double}
    return {
        'handicap_mode': config.handicap_mode if config else 'net',
        'net_percent'  : config.net_percent if config else 100,
        'entry_fee'    : entry_fee,
        'pool'         : round(entry_fee * len(standings), 2),
        'total_rounds' : tournament.rounds.count(),
        'rounds_played': max((s['rounds_played'] for s in standings), default=0),
        'table'        : table,
        'results'      : standings,
    }
