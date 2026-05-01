"""
services/low_net_championship.py
---------------------------------
Low Net Championship calculator — cumulative net strokes across all rounds
of a Tournament.

Rules
~~~~~
* Each player's adjusted net total for each round is computed using
  _build_ln_player_totals() from services/low_net_round.py, which applies:
    - handicap adjustment per the championship config (net / gross / strokes_off)
    - double-bogey cap (max par + 2 per hole)
* Totals are summed across every round in the tournament.
* Players are ranked lowest-to-highest (low net wins).
* Ties share the same rank; prize money for tied positions is split equally.
* rounds_to_count on the Tournament is documented but not yet implemented —
  all rounds always count.  The loop is structured so that N-of-M selection
  can be added in a future pass without restructuring.

Public API
~~~~~~~~~~
    standings = low_net_championship_standings(tournament)
    summary   = low_net_championship_summary(tournament)
"""

from collections import defaultdict

from services.low_net_round import _build_ln_player_totals


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _aggregate_rounds(tournament, handicap_mode: str, net_percent: int) -> dict:
    """
    Return {player_id: {'name': str, 'total': int, 'holes_played': int,
                        'par_played': int, 'rounds_played': int,
                        'round_totals': [int, ...],
                        'round_pars':   [int, ...]}}
    accumulated across all rounds in the tournament, ordered by round_number.

    round_pars is the par played per round (parallel to round_totals), used
    to compute per-round net-to-par for display.

    Players who did not play a particular round simply do not contribute
    that round's total (they still appear in the output if they played at
    least one round).
    """
    rounds = list(
        tournament.rounds
        .order_by('round_number')
        .prefetch_related('foursomes__memberships__player')
    )

    aggregated: dict = {}

    for round_obj in rounds:
        round_totals = _build_ln_player_totals(round_obj, handicap_mode, net_percent)

        for pid, data in round_totals.items():
            if data['holes_played'] == 0:
                continue  # skip players with no holes scored this round

            entry = aggregated.setdefault(pid, {
                'name'         : data['name'],
                'total'        : 0,
                'holes_played' : 0,
                'par_played'   : 0,
                'rounds_played': 0,
                'round_totals' : [],   # per-round net strokes
                'round_pars'   : [],   # par played per round (parallel)
            })
            entry['total']         += data['total']
            entry['holes_played']  += data['holes_played']
            entry['par_played']    += data['par_played']
            entry['rounds_played'] += 1
            entry['round_totals'].append(data['total'])
            entry['round_pars'].append(data['par_played'])

    return aggregated


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def low_net_championship_standings(tournament) -> list:
    """
    Calculate cumulative Low Net standings across all rounds in the tournament.

    Reads LowNetChampionshipConfig if present; falls back to full net (100%).

    Returns a list of dicts ordered by cumulative net-to-par (lowest first):
    [
        {
            'rank'          : int,
            'player_id'     : int,
            'player_name'   : str,
            'net_total'     : int,       # cumulative capped net strokes
            'net_to_par'    : int|None,  # net_total − par_played
            'holes_played'  : int,
            'rounds_played' : int,
            'round_totals'  : [int, ...],  # net total per round in order
            'payout'        : float|None,
        },
        ...
    ]
    """
    try:
        config        = tournament.low_net_championship_config
        handicap_mode = config.handicap_mode
        net_percent   = config.net_percent
        payouts_cfg   = {p['place']: float(p['amount']) for p in (config.payouts or [])}
    except Exception:
        from core.models import HandicapMode
        handicap_mode = HandicapMode.NET
        net_percent   = 100
        payouts_cfg   = {}

    aggregated = _aggregate_rounds(tournament, handicap_mode, net_percent)

    if not aggregated:
        return []

    # Sort by net-to-par; ties broken by most holes played (ascending sort,
    # so negate holes_played); players with no holes go to the bottom.
    def _sort_key(kv):
        d = kv[1]
        if d['holes_played'] == 0:
            return (1, 0, 0)
        return (0, d['total'] - d['par_played'], -d['holes_played'])

    rows = sorted(aggregated.items(), key=_sort_key)

    # Assign ranks.
    ranked = []
    rank = 1
    for i, (pid, data) in enumerate(rows):
        if i > 0:
            prev_ntp = rows[i - 1][1]['total'] - rows[i - 1][1]['par_played']
            curr_ntp = data['total'] - data['par_played']
            if curr_ntp > prev_ntp:
                rank = i + 1
        ranked.append((pid, data, rank))

    # Tie-split payouts: group by rank, pool all consumed places, divide evenly.
    pids_by_rank: dict = defaultdict(list)
    for pid, data, r in ranked:
        pids_by_rank[r].append(pid)

    rank_payout: dict = {}
    for r, pids in pids_by_rank.items():
        n = len(pids)
        total_prize = sum(payouts_cfg.get(r + j, 0.0) for j in range(n))
        rank_payout[r] = round(total_prize / n, 2) if total_prize > 0 else None

    standings = []
    for pid, data, r in ranked:
        hp         = data['holes_played']
        ntp        = (data['total'] - data['par_played']) if hp > 0 else None
        round_ntps = [
            tot - par
            for tot, par in zip(data['round_totals'], data['round_pars'])
        ]
        standings.append({
            'rank'          : r,
            'player_id'     : pid,
            'player_name'   : data['name'],
            'net_total'     : data['total'],
            'net_to_par'    : ntp,
            'holes_played'  : hp,
            'rounds_played' : data['rounds_played'],
            'round_totals'  : data['round_totals'],
            'round_ntps'    : round_ntps,   # per-round net-to-par for display
            'payout'        : rank_payout.get(r),
        })

    return standings


def low_net_championship_summary(tournament) -> dict:
    """
    Return a serialisable summary of the Low Net Championship:
    {
        'handicap_mode' : str,
        'net_percent'   : int,
        'entry_fee'     : float,
        'payouts'       : [{'place': int, 'amount': float}, ...],
        'total_rounds'  : int,       # rounds in the tournament
        'rounds_played' : int,       # rounds with at least one score
        'results'       : [
            {
                'rank'          : int,
                'name'          : str,
                'net_total'     : int,
                'net_to_par'    : int|None,
                'holes_played'  : int,
                'rounds_played' : int,
                'round_totals'  : [int, ...],
                'payout'        : float|None,
            },
            ...
        ],
    }
    """
    try:
        config      = tournament.low_net_championship_config
        entry_fee   = float(config.entry_fee)
        payouts_cfg = config.payouts or []
        hmode       = config.handicap_mode
        npct        = config.net_percent
    except Exception:
        from core.models import HandicapMode
        entry_fee   = 0.0
        payouts_cfg = []
        hmode       = HandicapMode.NET
        npct        = 100

    standings = low_net_championship_standings(tournament)

    total_rounds  = tournament.rounds.count()
    played_rounds = tournament.rounds.filter(
        foursomes__memberships__isnull=False
    ).distinct().count()

    return {
        'handicap_mode' : hmode,
        'net_percent'   : npct,
        'entry_fee'     : entry_fee,
        'payouts'       : payouts_cfg,
        'total_rounds'  : total_rounds,
        'rounds_played' : played_rounds,
        'results'       : [
            {
                'rank'          : s['rank'],
                'name'          : s['player_name'],
                'net_total'     : s['net_total'],
                'net_to_par'    : s['net_to_par'],
                'holes_played'  : s['holes_played'],
                'rounds_played' : s['rounds_played'],
                'round_totals'  : s['round_totals'],
                'round_ntps'    : s['round_ntps'],
                'payout'        : s['payout'],
            }
            for s in standings
        ],
    }
