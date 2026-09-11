"""
services/stableford_championship.py
-----------------------------------
Stableford Championship — total Stableford points accumulated across the rounds
that COUNT (every round, or the best N when ``Tournament.rounds_to_count`` is
set — services/round_counting.py). Mirrors low_net_championship but ranks by
points DESCENDING and is pool-paid. Per-round points use the tournament's own
table + handicap via _build_stableford_totals(..., mode, net_pct, points_fn).

The card the board draws for a Stableford row is **gross and points, not
per-hole net** — a golfer who wants his 18-hole net has the gross and the stroke
allocation right there — so the per-round hole detail carries gross + strokes +
points and no net column.
"""
from core.models import HandicapMode
from services.flights import prefixed_name
from services.round_counting import select_counting_rounds
from services.stableford import _build_stableford_totals


def _config(tournament):
    return getattr(tournament, 'stableford_championship_config', None)


def _aggregate_rounds(tournament, mode, net_pct, points_fn) -> dict:
    """{player_id: {name, points, holes_played, rounds_played,
    round_totals:[pts per round], round_labels:['R1',...],
    round_counts:[bool], round_complete:[bool], round_holes:[[...]]}}."""
    rounds = list(
        tournament.rounds.order_by('round_number')
        .prefetch_related('foursomes__memberships__player'))

    # Per-player, per-round rows first — best-N needs the whole tournament in
    # hand before any of it can be summed.
    per_player: dict = {}
    for round_obj in rounds:
        per = _build_stableford_totals(
            round_obj, mode=mode, net_pct=net_pct, points_fn=points_fn)
        expected = round_obj.num_holes or 18
        for pid, data in per.items():
            if data['holes_played'] == 0:
                continue
            entry = per_player.setdefault(pid, {'name': data['name'], 'rows': []})
            entry['rows'].append({
                'points'     : data['points'],
                'holes'      : data['holes_played'],
                'is_complete': data['holes_played'] >= expected,
                'label'      : f'R{round_obj.round_number}',
                'number'     : round_obj.round_number,
                'hole_detail': [
                    {'hole': h,
                     'points' : pts,
                     'gross'  : (data.get('gross') or {}).get(h),
                     'strokes': (data.get('strokes') or {}).get(h, 0)}
                    for h, pts in sorted(data.get('holes', {}).items())
                ],
            })

    aggregated: dict = {}
    for pid, entry in per_player.items():
        rows = entry['rows']
        # Higher points is better, so negate for the lower-is-better selector.
        counts = select_counting_rounds(
            rows, tournament.rounds_to_count, key=lambda r: -r['points'])
        aggregated[pid] = {
            'name'          : entry['name'],
            'points'        : sum(r['points'] for r, c in zip(rows, counts) if c),
            'holes_played'  : sum(r['holes'] for r, c in zip(rows, counts) if c),
            'rounds_played' : len(rows),
            'round_totals'  : [r['points'] for r in rows],
            'round_labels'  : [r['label'] for r in rows],
            'round_holes'   : [r['hole_detail'] for r in rows],
            'round_counts'  : counts,
            'round_complete': [r['is_complete'] for r in rows],
            # Rows are appended in round_number order, so the last one with any
            # scores is the player's current round + holes-thru in it.
            'current_round' : rows[-1]['number'],
            'current_thru'  : rows[-1]['holes'],
        }
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

    # Flights (docs/flights-plan.md). Unflighted is one flight holding
    # everybody, so this is ONE code path — the shipped behaviour is the
    # degenerate case rather than a branch that can drift from the flighted one.
    #
    # `eligible` matters more here than in Low Net: Stableford pays among
    # non-excluded golfers only, and the helper reproduces the shipped rule —
    # an excluded golfer keeps his display rank while the prize ranking is
    # recomputed over the eligible alone.
    from services.flights import flight_map, rank_in_flights
    flights = flight_map(tournament)

    ranked_f, payouts = rank_in_flights(
        aggregated,
        sort_key=lambda kv: -kv[1]['points'],       # higher points = better
        rank_key=lambda kv: kv[1]['points'],
        flight_of=lambda pid: flights.get(pid, 1),
        payouts_cfg=payouts_cfg,
        eligible=set(aggregated) - set(excluded),
    )
    flight_of = {pid: f for pid, _d, _r, f in ranked_f}

    standings = []
    for pid, data, rank, _flight in ranked_f:
        is_excluded = pid in excluded
        payout = None if is_excluded else payouts.get(pid)
        standings.append({
            'rank'         : rank,
            'flight'       : flight_of.get(pid) if flights else None,
            'player_id'    : pid,
            'player_name'  : data['name'],
            'total_points' : data['points'],
            'holes_played' : data['holes_played'],
            'rounds_played': data['rounds_played'],
            'current_round': data.get('current_round'),
            'current_thru' : data.get('current_thru', 0),
            'round_totals' : data['round_totals'],
            'round_labels' : data['round_labels'],
            'round_holes'  : data.get('round_holes', []),
            'round_counts' : data.get('round_counts', []),
            'round_complete': data.get('round_complete', []),
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
        'rounds_to_count': tournament.rounds_to_count,
        'counting_rule': tournament.counting_rule_label,
        'flight_count' : tournament.flight_count or 0,
        'table'        : table,
        # COPIES, not the standings rows themselves. The stopgap flight prefix
        # is a display concern; mutating these in place would put `A · ` into
        # settlement and the receipt, which read the standings directly.
        'results'      : [
            {**s_, 'player_name': prefixed_name(
                s_['player_name'], s_.get('flight'),
                bool(tournament.flight_count > 1))}
            for s_ in standings
        ],
    }
