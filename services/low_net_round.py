"""
services/low_net_round.py
-------------------------
Low Net (Round) calculator — individual game, single round.

Each player's total adjusted score (18 holes) is ranked lowest-to-highest.
Lowest score wins.

Scoring
~~~~~~~
* Per-hole score is adjusted per LowNetRoundConfig (or defaults to full net):
    - 'net'         : gross − strokes (playing_handicap × net_percent / 100)
    - 'gross'       : raw gross score
    - 'strokes_off' : gross − max(0, own_handicap − round_low_handicap),
                      strokes allocated by hole stroke_index.
  The strokes_off reference is the lowest playing_handicap across ALL
  foursomes in the round.
* A double-bogey cap is always applied: effective = min(adjusted, par + 2).

Public API
~~~~~~~~~~
    standings = low_net_round_standings(round_obj)
    summary   = low_net_round_summary(round_obj)
"""

from core.models import HandicapMode
from scoring.models import HoleScore
from scoring.handicap import _effective_hcp, _strokes_on_hole
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Internal helper
# ---------------------------------------------------------------------------

def _build_ln_player_totals(round_obj, handicap_mode, net_percent):
    """
    Return {player_id: {'name': str, 'total': int, 'holes_played': int}}
    for all real players in the round, with handicap adjustment and
    double-bogey cap applied.
    """
    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee')
    )

    # membership lookup: {player_id: membership}  (across all foursomes)
    membership_map = {}
    for fs in foursomes:
        for m in fs.memberships.all():
            if not m.player.is_phantom:
                membership_map[m.player_id] = m

    # par lookup: {foursome_id: {hole_number: par}}
    par_index = {}
    for fs in foursomes:
        first_m = next(
            (m for m in fs.memberships.all() if m.tee_id is not None), None
        )
        if first_m:
            par_index[fs.pk] = {h['number']: h['par'] for h in first_m.tee.holes}

    # For strokes_off: round-wide lowest playing_handicap (real players only)
    low_hcp = 0
    if handicap_mode == HandicapMode.STROKES_OFF:
        all_hcps = [m.playing_handicap for m in membership_map.values()]
        low_hcp  = min(all_hcps) if all_hcps else 0

    qs = (
        HoleScore.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .exclude(gross_score=None)
        .values('foursome_id', 'player_id', 'player__name',
                'hole_number', 'gross_score', 'net_score')
    )

    totals: dict = {}  # {player_id: {'name', 'total', 'holes_played'}}

    for hs in qs:
        pid  = hs['player_id']
        hole = hs['hole_number']
        fid  = hs['foursome_id']

        membership = membership_map.get(pid)
        if membership is None:
            continue

        # ── Handicap adjustment ─────────────────────────────────────────────
        if handicap_mode == HandicapMode.GROSS:
            adjusted = hs['gross_score']

        elif handicap_mode == HandicapMode.NET:
            if net_percent == 100 and hs['net_score'] is not None:
                adjusted = hs['net_score']
            else:
                if membership.tee_id is None:
                    continue
                si  = membership.tee.hole(hole).get('stroke_index', 18)
                eff = _effective_hcp(membership.playing_handicap, net_percent)
                adjusted = hs['gross_score'] - _strokes_on_hole(eff, si)

        else:  # STROKES_OFF
            if membership.tee_id is None:
                continue
            si       = membership.tee.hole(hole).get('stroke_index', 18)
            so       = max(0, membership.playing_handicap - low_hcp)
            adjusted = hs['gross_score'] - _strokes_on_hole(so, si)

        # ── Double-bogey cap ────────────────────────────────────────────────
        par    = par_index.get(fid, {}).get(hole, 4)
        capped = min(adjusted, par + 2)

        entry = totals.setdefault(pid, {
            'name'        : hs['player__name'],
            'total'       : 0,
            'holes_played': 0,
            'par_played'  : 0,
            'foursome_id' : fid,
        })
        entry['total']        += capped
        entry['holes_played'] += 1
        entry['par_played']   += par

    return totals


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def low_net_round_standings(round_obj) -> list:
    """
    Calculate adjusted totals for all real players in the round.

    Reads LowNetRoundConfig if present; falls back to full net (100%).

    Returns a list of dicts ordered by total (lowest first), with ties
    sharing the same rank and the prize pool split evenly among them:
        {
            'rank'        : int,
            'player_id'   : int,
            'player_name' : str,
            'net_total'   : int,
            'net_to_par'  : int | None,
            'holes_played': int,
            'foursome_id' : int,
            'payout'      : float | None,
        }
    """
    try:
        config        = round_obj.low_net_config
        handicap_mode = config.handicap_mode
        net_percent   = config.net_percent
        payouts_cfg   = {p['place']: float(p['amount']) for p in (config.payouts or [])}
        excluded_ids  = set(config.excluded_player_ids or [])
    except Exception:
        handicap_mode = HandicapMode.NET
        net_percent   = 100
        payouts_cfg   = {}
        excluded_ids  = set()

    player_totals = _build_ln_player_totals(round_obj, handicap_mode, net_percent)

    # Sort by net-to-par (total − par_played) so rankings are always in
    # par-relative order regardless of tee/course-par differences between
    # foursomes.  Players with no holes played sort last.
    def _sort_key(kv):
        d = kv[1]
        if d['holes_played'] == 0:
            return (1, 0)           # unsorted players go to the bottom
        return (0, d['total'] - d['par_played'])

    rows = sorted(player_totals.items(), key=_sort_key)

    # ── Assign display ranks (all players, including excluded) ────────────────
    ranked = []  # [(pid, data, display_rank)]
    rank = 1
    for i, (pid, data) in enumerate(rows):
        if i > 0:
            prev = rows[i - 1][1]
            curr = data
            prev_ntp = prev['total'] - prev['par_played']
            curr_ntp = curr['total'] - curr['par_played']
            if curr_ntp > prev_ntp:
                rank = i + 1
        ranked.append((pid, data, rank))

    # ── Prize ranking — eligible (non-excluded) players only ─────────────────
    # Excluded players appear in the standings with their score visible, but
    # they cannot win prize money.  Prize positions are assigned as if excluded
    # players were not competing, so the $1st prize goes to the best-scoring
    # *eligible* player, $2nd to the next, and so on.
    from collections import defaultdict

    eligible_rows = [(pid, data) for pid, data in rows if pid not in excluded_ids]

    prize_rank = 1
    eligible_ranked: list = []   # [(pid, prize_rank)]
    for i, (pid, data) in enumerate(eligible_rows):
        if i > 0:
            prev_ntp = eligible_rows[i-1][1]['total'] - eligible_rows[i-1][1]['par_played']
            curr_ntp = data['total'] - data['par_played']
            if curr_ntp > prev_ntp:
                prize_rank = i + 1
        eligible_ranked.append((pid, prize_rank))

    prize_rank_map: dict = {pid: r for pid, r in eligible_ranked}

    # Tied-payout splitting among eligible players.
    pids_by_prize_rank: dict = defaultdict(list)
    for pid, r in eligible_ranked:
        pids_by_prize_rank[r].append(pid)

    prize_rank_payout: dict = {}
    for r, pids in pids_by_prize_rank.items():
        n = len(pids)
        total_prize = sum(payouts_cfg.get(r + j, 0.0) for j in range(n))
        per_player  = round(total_prize / n, 2) if total_prize > 0 else None
        prize_rank_payout[r] = per_player

    # ── Build standings list ──────────────────────────────────────────────────
    standings = []
    for pid, data, display_rank in ranked:
        hp          = data['holes_played']
        ntp         = (data['total'] - data['par_played']) if hp > 0 else None
        is_excluded = pid in excluded_ids
        payout      = None if is_excluded else prize_rank_payout.get(prize_rank_map.get(pid))
        standings.append({
            'rank'        : display_rank,
            'player_id'   : pid,
            'player_name' : data['name'],
            'net_total'   : data['total'],
            'net_to_par'  : ntp,
            'holes_played': hp,
            'foursome_id' : data.get('foursome_id'),
            'excluded'    : is_excluded,
            'payout'      : payout,
        })

    return standings


def low_net_round_summary(round_obj) -> dict:
    """
    Return serialisable summary dict:
        {
          'handicap_mode': str,
          'net_percent'  : int,
          'entry_fee'    : float,
          'payouts'      : [{'place': int, 'amount': float}, ...],
          'results'      : [
              {'rank', 'name', 'total_net', 'holes_played', 'payout'}, ...
          ]
        }
    """
    try:
        config      = round_obj.low_net_config
        entry_fee   = float(config.entry_fee)
        payouts_cfg = config.payouts or []
        hmode       = config.handicap_mode
        npct        = config.net_percent
    except Exception:
        entry_fee   = 0.0
        payouts_cfg = []
        hmode       = HandicapMode.NET
        npct        = 100

    standings = low_net_round_standings(round_obj)

    return {
        'handicap_mode': hmode,
        'net_percent'  : npct,
        'entry_fee'    : entry_fee,
        'payouts'      : payouts_cfg,
        'results'      : [
            {
                'rank'        : s['rank'],
                'name'        : s['player_name'],
                'total_net'   : s['net_total'],
                'net_to_par'  : s['net_to_par'],
                'holes_played': s['holes_played'],
                'foursome_id' : s['foursome_id'],
                'excluded'    : s.get('excluded', False),
                'payout'      : s['payout'],
            }
            for s in standings
        ],
    }
