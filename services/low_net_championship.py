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
* Totals are summed across the rounds that COUNT — every round when
  ``Tournament.rounds_to_count`` is unset, otherwise the best N of them
  (services/round_counting.py).  A round in progress can never displace a
  finished one; dropped rounds stay on the board, struck through.
* Players are ranked lowest-to-highest (low net wins).
* Ties share the same rank; prize money for tied positions is split equally.

Public API
~~~~~~~~~~
    standings = low_net_championship_standings(tournament)
    summary   = low_net_championship_summary(tournament)
"""

from collections import defaultdict

from services.low_net_round import _build_ln_player_totals
from services.round_counting import select_counting_rounds


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _aggregate_rounds(tournament, handicap_mode: str, net_percent: int) -> dict:
    """
    Return {player_id: {'name': str, 'total': int, 'holes_played': int,
                        'par_played': int, 'rounds_played': int,
                        'round_totals': [int, ...],
                        'round_pars':   [int, ...],
                        'round_counts': [bool, ...],
                        'round_complete': [bool, ...]}}
    across the tournament's rounds, ordered by round_number.

    round_pars is the par played per round (parallel to round_totals), used
    to compute per-round net-to-par for display.  round_counts flags which of
    those rounds feed the cumulative total under best-N-of-M — the board draws
    the others struck through.

    Players who did not play a particular round simply do not contribute
    that round's total (they still appear in the output if they played at
    least one round).  ``total``/``par_played``/``holes_played`` are the
    COUNTING aggregates; ``rounds_played`` is every round they teed off in.
    """
    rounds = list(
        tournament.rounds
        .order_by('round_number')
        .prefetch_related('foursomes__memberships__player')
    )
    # Individual play: the cap is a rule, not a setting, and holds at any
    # allowance. A cup keeps the historic Net-100%-only behaviour.
    force_cap = tournament.is_individual_play

    # Per-player, per-round rows first — the best-N selection needs to see a
    # player's whole tournament before any of it can be summed.
    per_player: dict = {}

    for round_obj in rounds:
        round_totals = _build_ln_player_totals(
            round_obj, handicap_mode, net_percent, force_cap=force_cap)
        expected = round_obj.num_holes or 18

        for pid, data in round_totals.items():
            if data['holes_played'] == 0:
                continue  # skip players with no holes scored this round

            entry = per_player.setdefault(pid, {
                'name'    : data['name'],
                'handicap': data.get('handicap', 0),
                'rows'    : [],
            })
            entry['rows'].append({
                'total'       : data['total'],
                'par'         : data['par_played'],
                'holes'       : data['holes_played'],
                'net_to_par'  : data['total'] - data['par_played'],
                'is_complete' : data['holes_played'] >= expected,
                'label'       : f'R{round_obj.round_number}',
                'hole_detail' : [
                    {'hole': h, **v}
                    for h, v in sorted(data.get('holes', {}).items())
                ],
            })

    aggregated: dict = {}
    for pid, entry in per_player.items():
        rows   = entry['rows']
        counts = select_counting_rounds(rows, tournament.rounds_to_count)

        aggregated[pid] = {
            'name'          : entry['name'],
            'handicap'      : entry['handicap'],
            'total'         : sum(r['total'] for r, c in zip(rows, counts) if c),
            'holes_played'  : sum(r['holes'] for r, c in zip(rows, counts) if c),
            'par_played'    : sum(r['par']   for r, c in zip(rows, counts) if c),
            'rounds_played' : len(rows),
            'round_totals'  : [r['total'] for r in rows],
            'round_pars'    : [r['par'] for r in rows],
            'round_holes'   : [r['hole_detail'] for r in rows],
            'round_labels'  : [r['label'] for r in rows],
            'round_counts'  : counts,
            'round_complete': [r['is_complete'] for r in rows],
        }

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
            'handicap'      : data.get('handicap', 0),
            'round_totals'  : data['round_totals'],
            'round_ntps'    : round_ntps,
            'round_holes'   : data.get('round_holes', []),
            'round_labels'  : data.get('round_labels', []),
            # Best-N-of-M: which columns feed the total. The board strikes the
            # rest through rather than hiding them, and an incomplete round is
            # drawn in amber (it can fill a vacancy but never displace a
            # finished round — see services/round_counting.py).
            'round_counts'  : data.get('round_counts', []),
            'round_complete': data.get('round_complete', []),
            'payout'        : rank_payout.get(r),
        })

    return standings


def low_net_championship_summary(tournament, round_id: int | None = None) -> dict:
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

    if round_id is not None:
        # Single-round view: compute standings using only this round
        from services.low_net_round import _build_ln_player_totals
        from tournament.models import Round as _Round
        try:
            round_obj = tournament.rounds.get(pk=round_id)
            round_totals = _build_ln_player_totals(
                round_obj, hmode, npct,
                force_cap=tournament.is_individual_play)
            single_round_standings = []
            for pid, data in round_totals.items():
                if data['holes_played'] == 0:
                    continue
                ntp = (data['total'] - data['par_played']) if data['holes_played'] > 0 else None
                holes_list = [
                    {'hole': h, **v}
                    for h, v in sorted(data.get('holes', {}).items())
                ]
                single_round_standings.append({
                    'rank'         : 0,
                    'player_name'  : data['name'],
                    'net_total'    : data['total'],
                    'net_to_par'   : ntp,
                    'holes_played' : data['holes_played'],
                    'rounds_played': 1,
                    'handicap'     : data.get('handicap', 0),
                    'round_totals' : [data['total']],
                    'round_ntps'   : [ntp] if ntp is not None else [],
                    'round_holes'  : [holes_list],
                    'round_labels' : [f'R{round_obj.round_number}'],
                    'round_counts' : [True],
                    'round_complete': [
                        data['holes_played'] >= (round_obj.num_holes or 18)],
                    'payout'       : None,
                })
            single_round_standings.sort(key=lambda x: (x['net_to_par'] if x['net_to_par'] is not None else 999, -x['holes_played']))
            for i, row in enumerate(single_round_standings, 1):
                row['rank'] = i
            standings = single_round_standings
        except Exception:
            standings = low_net_championship_standings(tournament)
    else:
        standings = low_net_championship_standings(tournament)

    if round_id is not None:
        total_rounds  = 1
        played_rounds = 1 if standings else 0
    else:
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
        # Best-N-of-M, for the board's chip strip ("Best 3 of 4"). Null when
        # every round counts, which is also the only state below three rounds —
        # the Scoring step never asks the question there.
        'rounds_to_count': (None if round_id is not None
                            else tournament.rounds_to_count),
        'counting_rule' : (None if round_id is not None
                           else tournament.counting_rule_label),
        'results'       : [
            {
                'rank'          : s['rank'],
                'name'          : s['player_name'],
                'net_total'     : s['net_total'],
                'net_to_par'    : s['net_to_par'],
                'holes_played'  : s['holes_played'],
                'rounds_played' : s['rounds_played'],
                'handicap'      : s.get('handicap', 0),
                'round_totals'  : s['round_totals'],
                'round_ntps'    : s['round_ntps'],
                'round_holes'   : s.get('round_holes', []),
                'round_labels'  : s.get('round_labels', []),
                'round_counts'  : s.get('round_counts', []),
                'round_complete': s.get('round_complete', []),
                'payout'        : s['payout'],
            }
            for s in standings
        ],
    }
