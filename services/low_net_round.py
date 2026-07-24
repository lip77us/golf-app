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
* Net-double-bogey cap: when Round.net_max_double_bogey is on, every
  per-hole effective score is capped at par + 2 (net par + 2 in gross
  terms).  When the flag is off, raw adjusted scores feed the total.

Public API
~~~~~~~~~~
    standings = low_net_round_standings(round_obj)
    summary   = low_net_round_summary(round_obj)
"""

from core.models import HandicapMode
from scoring.models import HoleScore
from scoring.handicap import _effective_hcp, _strokes_on_hole, make_strokes_fn
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Internal helper
# ---------------------------------------------------------------------------

def _build_ln_player_totals(round_obj, handicap_mode, net_percent,
                            participant_ids=None):
    """
    Return {player_id: {'name': str, 'total': int, 'holes_played': int}}
    for all real players in the round, with handicap adjustment and the
    optional net-double-bogey cap applied per Round.net_max_double_bogey.

    `participant_ids` restricts the game to a SUBSET of the foursome — a subset
    side game (docs/parallel-games.md). None = all real players. ONLY the casual
    `low_net_round_standings` passes this from the round config; the Championship
    never does, so its scoring is unaffected.
    """
    _subset = set(participant_ids) if participant_ids else None
    # The net-double-bogey cap only applies at full Net (100%). It's meaningless
    # for Gross and gets weird with a reduced allowance or Strokes-Off, so it's
    # ignored outside Net-100% regardless of the stored round flag.
    cap_enabled = (bool(round_obj.net_max_double_bogey)
                   and handicap_mode == HandicapMode.NET
                   and net_percent == 100)

    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee')
    )

    # membership lookup: {player_id: membership}  (across all foursomes)
    membership_map = {}
    for fs in foursomes:
        for m in fs.memberships.all():
            if not m.player.is_phantom and (
                    _subset is None or m.player_id in _subset):
                membership_map[m.player_id] = m

    # par lookup: {foursome_id: {hole_number: par}}
    par_index = {}
    for fs in foursomes:
        first_m = next(
            (m for m in fs.memberships.all() if m.tee_id is not None), None
        )
        if first_m:
            par_index[fs.pk] = {h['number']: h['par'] for h in first_m.tee.holes}

    # Partial-round-aware per-hole stroke allocators (scale + re-rank on a
    # 9-hole / back-9 round); a full round reduces to the standard allocation.
    strokes_fns = {fs.pk: make_strokes_fn(fs) for fs in foursomes}

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

    # ── Seed every real player with a PROSPECTIVE stroke plan ────────────────
    # So the Stroke Play scorecard shows where each player's handicap strokes
    # fall over the WHOLE round — including before the round starts / on holes
    # not yet played. Gross/net fill in per hole from the scores below.
    from services.hole_plan import holes_in_play as _holes_in_play
    in_play_by_fs = {}
    for fs in foursomes:
        hs_set = _holes_in_play(round_obj, fs)
        in_play_by_fs[fs.pk] = sorted(hs_set) if hs_set else list(range(1, 19))
    for fs in foursomes:
        holes_fs = in_play_by_fs.get(fs.pk) or list(range(1, 19))
        for m in fs.memberships.all():
            if m.player.is_phantom or m.player_id in totals:
                continue
            # Subset side game: don't seed a prospective plan for non-participants.
            if _subset is not None and m.player_id not in _subset:
                continue
            plan = {}
            if handicap_mode != HandicapMode.GROSS and m.tee_id is not None:
                for hole in holes_fs:
                    if handicap_mode == HandicapMode.NET:
                        eff = _effective_hcp(m.playing_handicap, net_percent)
                        s = strokes_fns[fs.pk](eff, m.tee, hole)
                    else:  # STROKES_OFF
                        si = m.tee.hole(hole).get('stroke_index', 18)
                        so_diff = round(
                            max(0, m.playing_handicap - low_hcp) * net_percent / 100)
                        s = _strokes_on_hole(so_diff, si)
                    if s > 0:
                        plan[hole] = s
            totals[m.player_id] = {
                'name'         : m.player.name,
                'total'        : 0,
                'holes_played' : 0,
                'par_played'   : 0,
                'foursome_id'  : fs.pk,
                'handicap'     : m.playing_handicap,
                'holes'        : {},
                'stroke_plan'  : plan,
                'total_strokes': sum(plan.values()),
            }

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
                eff = _effective_hcp(membership.playing_handicap, net_percent)
                adjusted = hs['gross_score'] - strokes_fns[fid](
                    eff, membership.tee, hole)

        else:  # STROKES_OFF
            if membership.tee_id is None:
                continue
            si       = membership.tee.hole(hole).get('stroke_index', 18)
            # Scale the strokes-off differential by net_percent, matching the
            # app-wide SO allowance (nassau.py / multi_skins.py / points_531.py).
            so       = round(
                max(0, membership.playing_handicap - low_hcp) * net_percent / 100)
            adjusted = hs['gross_score'] - _strokes_on_hole(so, si)

        # ── Net-double-bogey cap (round-level toggle) ───────────────────────
        par    = par_index.get(fid, {}).get(hole, 4)
        capped = min(adjusted, par + 2) if cap_enabled else adjusted

        strokes_given = hs['gross_score'] - adjusted  # positive = strokes received

        entry = totals.setdefault(pid, {
            'name'        : hs['player__name'],
            'total'       : 0,
            'holes_played': 0,
            'par_played'  : 0,
            'foursome_id' : fid,
            'handicap'    : membership.playing_handicap,
            'holes'       : {},   # {hole_number: {par, gross, net_adj, capped}}
        })
        entry['total']        += capped
        entry['holes_played'] += 1
        entry['par_played']   += par
        # Pull stroke index off the player's own tee so women's tees
        # (which can have a different SI ordering than men's) show
        # correctly on the scorecard.
        si_for_hole = None
        if membership.tee_id is not None:
            si_for_hole = membership.tee.hole(hole).get('stroke_index')
        entry['holes'][hole]   = {
            'par'         : par,
            'gross'       : hs['gross_score'],
            'strokes'     : strokes_given,
            'net'         : adjusted,
            'capped'      : capped,
            'stroke_index': si_for_hole,
        }

    return totals


def _rank_standings(player_totals, payouts_cfg, excluded_ids) -> list:
    """
    Rank a pre-built ``{player_id: totals}`` map into the standings list.

    Split out of ``low_net_round_standings`` so the identical ranking / tie /
    prize logic can be reused for each display mode (Gross / Net / Strokes-off)
    in the 12A selector — see docs/features/12a-scorecard-display-modes.md.
    Pass an empty ``payouts_cfg`` for a display-only mode (no prize money):
    only the round's actually-configured mode carries payouts.
    """
    from collections import defaultdict

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
    # Only players who have actually scored compete for prizes — the roster is
    # now seeded with not-yet-started players (so their prospective scorecard
    # shows), and those must not be handed money.
    eligible_rows = [(pid, data) for pid, data in rows
                     if pid not in excluded_ids and data['holes_played'] > 0]

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
            'handicap'    : data.get('handicap', 0),  # raw playing handicap
            'holes'       : data.get('holes', {}),   # {hole_number: hole_data}
            # Prospective full-round stroke allocation (all holes in play) +
            # the total strokes this player receives — drives the scorecard
            # dots that show before/independent of scores.
            'stroke_plan'    : data.get('stroke_plan', {}),
            'total_strokes'  : data.get('total_strokes', 0),
        })

    return standings


def _serialize_results(standings) -> list:
    """Shape a standings list into the wire ``results`` payload (one row per
    player). Shared by the configured-mode ``results`` and every entry in the
    12A ``modes`` block so all three modes carry an identical row shape."""
    return [
        {
            'rank'        : s['rank'],
            'player_id'   : s['player_id'],
            'name'        : s['player_name'],
            'total_net'   : s['net_total'],
            'net_to_par'  : s['net_to_par'],
            'holes_played': s['holes_played'],
            'foursome_id' : s['foursome_id'],
            'excluded'    : s.get('excluded', False),
            'payout'      : s['payout'],
            'handicap'    : s.get('handicap', 0),
            'holes'       : [
                {'hole': h, **v}
                for h, v in sorted(s.get('holes', {}).items())
            ],
            'stroke_plan'  : s.get('stroke_plan', {}),
            'total_strokes': s.get('total_strokes', 0),
        }
        for s in standings
    ]


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
        # Subset side game: restrict scoring/ranking/payouts to these players.
        participant_ids = config.participant_player_ids or None
    except Exception:
        handicap_mode = HandicapMode.NET
        net_percent   = 100
        payouts_cfg   = {}
        excluded_ids  = set()
        participant_ids = None

    player_totals = _build_ln_player_totals(
        round_obj, handicap_mode, net_percent, participant_ids=participant_ids)

    return _rank_standings(player_totals, payouts_cfg, excluded_ids)


def low_net_round_summary(round_obj) -> dict:
    """
    Return serialisable summary dict:
        {
          'handicap_mode': str,          # the round's CONFIGURED mode
          'net_percent'  : int,
          'entry_fee'    : float,
          'payouts'      : [{'place': int, 'amount': float}, ...],
          'results'      : [ ... configured-mode rows ... ],   # backward-compat
          'primary_mode' : str,          # 12A: the mode `results` is ranked by
          'modes'        : {             # 12A: all three, independently ranked
              'gross':       {'net_percent': int, 'results': [...]},
              'net':         {'net_percent': int, 'results': [...]},
              'strokes_off': {'net_percent': int, 'results': [...]},
          },
        }

    The `modes` block (design 12A — docs/features/12a-scorecard-display-modes.md)
    lets the client re-rank the Stroke Play tab between Gross / Net / Strokes-off
    WITHOUT refetching. Only the configured mode carries payouts; the other two
    are display-only views. SO is relative-to-low AND scaled by net %, matching
    the app-wide SO allowance (nassau / multi_skins / points_531). `results`
    mirrors the configured mode for older clients that don't read `modes`.
    """
    try:
        config          = round_obj.low_net_config
        entry_fee       = float(config.entry_fee)
        payouts_cfg     = config.payouts or []
        hmode           = config.handicap_mode
        npct            = config.net_percent
        excluded_ids    = set(config.excluded_player_ids or [])
        participant_ids = config.participant_player_ids or None
    except Exception:
        entry_fee       = 0.0
        payouts_cfg     = []
        hmode           = HandicapMode.NET
        npct            = 100
        excluded_ids    = set()
        participant_ids = None

    payouts_map = {p['place']: float(p['amount']) for p in payouts_cfg}

    # ── Per-mode standings (12A) ──────────────────────────────────────────────
    # Each mode is built with the app's existing per-mode engine, so nothing
    # about scoring semantics changes — this only SURFACES the three views.
    # Payouts belong to the configured mode only (the round is settled in one
    # mode); the others are display-only, so they get an empty payout map.
    mode_specs = [
        ('gross',       HandicapMode.GROSS,       100),
        ('net',         HandicapMode.NET,         npct),
        ('strokes_off', HandicapMode.STROKES_OFF, npct),
    ]
    primary_key = ('gross' if hmode == HandicapMode.GROSS
                   else 'strokes_off' if hmode == HandicapMode.STROKES_OFF
                   else 'net')

    modes: dict = {}
    for key, m_mode, m_npct in mode_specs:
        totals = _build_ln_player_totals(
            round_obj, m_mode, m_npct, participant_ids=participant_ids)
        pmap   = payouts_map if key == primary_key else {}
        modes[key] = {
            'net_percent': m_npct,
            'results'    : _serialize_results(
                _rank_standings(totals, pmap, excluded_ids)),
        }

    # The holes this round actually plays (see services/hole_plan) + a
    # representative par per hole, so the client can render the FULL scorecard
    # strip — including not-yet-played holes as blanks — instead of only the
    # holes that happen to have scores. For a normal round this is 1..18.
    from services.hole_plan import holes_in_play as _holes_in_play
    in_play = sorted(_holes_in_play(round_obj))
    rep_tee = None
    for fs in round_obj.foursomes.all():
        m = fs.memberships.exclude(tee__isnull=True).first()
        if m is not None:
            rep_tee = m.tee
            break
    hole_pars: dict = {}
    hole_si: dict = {}   # 12A two-row scorecard: SI row needs every hole's index
    if rep_tee is not None:
        for h in in_play:
            try:
                hole_pars[h] = rep_tee.hole(h).get('par')
                hole_si[h]   = rep_tee.hole(h).get('stroke_index')
            except StopIteration:
                pass

    return {
        'handicap_mode': hmode,
        'net_percent'  : npct,
        'entry_fee'    : entry_fee,
        'payouts'      : payouts_cfg,
        'holes_in_play': in_play,
        'hole_pars'    : hole_pars,
        'hole_stroke_index': hole_si,
        # Backward-compat: `results` is the configured mode, reused from `modes`
        # so it can never drift from the selector's version of the same view.
        'results'      : modes[primary_key]['results'],
        'primary_mode' : primary_key,
        'modes'        : modes,
    }
