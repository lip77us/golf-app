"""
services/cup_standings.py
-------------------------
Tournament-wide Ryder Cup standings — aggregates all cup-game results
(Nassau / Quota Nassau / Irish Rumble / Singles Nassau / 18-Hole Singles)
across every configured round in the tournament.

Cup point multipliers per game type
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    nassau          pv × 3   F9 + B9 + Overall, 1 four-ball match/foursome
    quota_nassau    pv × 3   Team F9 + B9 + Overall
    irish_rumble    pv × 1   1 overall winner per pairing (2 foursomes)
    singles_nassau  pv × 6   2 matches/foursome × F9/B9/Overall each
    singles_18      pv × 2   2 matches/foursome × 1 overall point each

Public API
~~~~~~~~~~
    summary  = cup_standings_summary(tournament)   — cumulative totals
    summary  = cup_round_live_summary(round_obj)   — live per-round view
"""

from core.models import GameType


# Points available per (unit × point_value) for each game type.
# "unit" = 1 foursome for nassau/quota/singles types;
#          1 pairing (2 foursomes) for irish_rumble.
GAME_MULTIPLIERS = {
    GameType.NASSAU:         3,
    GameType.QUOTA_NASSAU:   3,
    GameType.IRISH_RUMBLE:   1,
    GameType.SINGLES_NASSAU: 6,
    GameType.SINGLES_18:     2,
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _seg_result_pts(result, pv):
    """Convert a segment result string → (t1_pts, t2_pts)."""
    if result == 'team1':  return pv, 0.0
    if result == 'team2':  return 0.0, pv
    if result == 'halved': return pv / 2, pv / 2
    return 0.0, 0.0


def _mp_result_to_cup(result):
    """MatchPlayMatch.result ('player1'|'player2'|'halved') → cup perspective."""
    if result == 'player1': return 'team1'
    if result == 'player2': return 'team2'
    return result   # 'halved' or None pass through


def _declared_possible(rc, mul: float) -> float:
    """
    Compute total_possible from RyderCupRoundConfig.format_declarations.
    Returns 0.0 if no declarations are set.
    """
    decls = rc.format_declarations
    if not decls:
        return 0.0
    total = 0.0
    for d in decls:
        gtype = d.get('game_type', '')
        units = float(d.get('units', 0))
        pv    = float(d.get('point_value', 0)) * mul
        m     = GAME_MULTIPLIERS.get(gtype, 1)
        total += units * pv * m
    return total


def _planned_possible(round_obj) -> float:
    """
    Compute total_possible from Round.cup_group_counts + Round.game_point_values.
    Wizard-time plan used for rounds not yet configured through the setup screen.
    Irish Rumble: 2 foursomes = 1 pairing = pv x 1  (units = groups // 2)
    All others  : each foursome is its own contest   (units = groups)
    """
    from core.models import GameType
    counts = round_obj.cup_group_counts or {}
    pvs    = round_obj.game_point_values or {}
    if not counts:
        return 0.0
    total = 0.0
    for game_type_str, groups in counts.items():
        try:
            gtype = GameType(game_type_str)
        except ValueError:
            continue
        pv = float(pvs.get(game_type_str, 1.0))
        m  = GAME_MULTIPLIERS.get(gtype, 1)
        units = (groups // 2) if gtype == GameType.IRISH_RUMBLE else groups
        total += units * pv * m
    return total


# ---------------------------------------------------------------------------
# Tournament-wide cumulative standings
# ---------------------------------------------------------------------------

def cup_standings_summary(tournament) -> dict:
    """
    Aggregate all resolved cup points across ALL game types and ALL rounds in
    the tournament.  Only counts resolved segments (result is not None).

    Returns:
    {
        'team1_name'    : str,
        'team2_name'    : str,
        'team1_colour'  : str,   # e.g. "Red" / "Blue"
        'team2_colour'  : str,
        'team1_points'  : float,
        'team2_points'  : float,
        'total_possible': float,
        'to_win'        : float,
        'rounds'        : [
            {
                'round_number'  : int,
                'round_id'      : int,
                'team1_points'  : float,
                'team2_points'  : float,
                'total_possible': float,
            },
            ...
        ],
    }
    """
    from tournament.models import Round
    from core.models import GameType

    # All rounds for this tournament, in order.  We include rounds that have
    # not yet been configured (no ryder_cup_config) so their planned points
    # still count toward total_possible.
    all_rounds = list(
        Round.objects
        .filter(tournament=tournament)
        .order_by('round_number')
    )

    team1_name     = None
    team2_name     = None
    team1_colour   = ''
    team2_colour   = ''
    team1_total    = 0.0
    team2_total    = 0.0
    total_possible = 0.0
    rounds_out     = []

    for round_obj in all_rounds:
        # ── Rounds that have been fully configured ────────────────────────────
        has_config = hasattr(round_obj, 'ryder_cup_config') or (
            Round.objects.filter(pk=round_obj.pk, ryder_cup_config__isnull=False).exists()
        )

        r_t1       = 0.0
        r_t2       = 0.0
        r_possible = 0.0
        live_summary = None

        if has_config:
            live_summary = cup_round_live_summary(round_obj)
            if live_summary is not None:
                # Capture team names / colours from first configured round
                if team1_name is None:
                    team1_name   = live_summary.get('team1_name')
                    team2_name   = live_summary.get('team2_name')
                    team1_colour = live_summary.get('team1_colour', '')
                    team2_colour = live_summary.get('team2_colour', '')

                # Scored points always come from the live summary
                for match in live_summary.get('matches', []):
                    r_t1 += match.get('team1_points', 0.0)
                    r_t2 += match.get('team2_points', 0.0)

        # ── Total possible: always prefer wizard-time planned value ──────────
        # Using _planned_possible ensures total_possible stays stable as rounds
        # are started (live summary may differ from plan due to group count or
        # point-value discrepancies introduced by the setup screen).
        r_possible = _planned_possible(round_obj)

        # Fallback chain when no wizard-time data exists
        if r_possible == 0.0 and live_summary is not None:
            r_possible = live_summary.get('total_possible', 0.0)

        if r_possible == 0.0 and has_config:
            try:
                mul        = float(round_obj.ryder_cup_config.point_multiplier)
                r_possible = _declared_possible(round_obj.ryder_cup_config, mul)
            except Exception:
                pass

        if r_possible == 0.0:
            continue  # skip rounds with no planned format at all

        team1_total    += r_t1
        team2_total    += r_t2
        total_possible += r_possible
        rounds_out.append({
            'round_number'  : round_obj.round_number,
            'round_id'      : round_obj.id,
            'team1_points'  : round(r_t1, 2),
            'team2_points'  : round(r_t2, 2),
            'total_possible': round(r_possible, 2),
        })

    total_possible = round(total_possible, 2)
    to_win         = total_possible / 2 + 0.5

    return {
        'team1_name'    : team1_name    or 'Team 1',
        'team2_name'    : team2_name    or 'Team 2',
        'team1_colour'  : team1_colour  or 'Red',
        'team2_colour'  : team2_colour  or 'Blue',
        'team1_points'  : round(team1_total, 2),
        'team2_points'  : round(team2_total, 2),
        'total_possible': total_possible,
        'to_win'        : round(to_win, 2),
        'rounds'        : rounds_out,
    }


# ---------------------------------------------------------------------------
# Per-round live summary (read-only, always current)
# ---------------------------------------------------------------------------

def cup_round_live_summary(round_obj) -> dict | None:
    """
    Compute live Ryder Cup standings for a round directly from game models.
    No DB writes — always reflects the current state.

    Returns None when no RyderCupRoundConfig exists for this round.

    Shape
    -----
    {
        'team1_name'    : str,
        'team2_name'    : str,
        'team1_colour'  : str,   # colour field from TournamentTeam
        'team2_colour'  : str,
        'team1_points'  : float,
        'team2_points'  : float,
        'total_possible': float,
        'matches'       : [
            {
                'game_type'          : str,
                'game_label'         : str,
                'groups'             : [int],
                'team1_players'      : [str],
                'team2_players'      : [str],
                'point_value'        : float,
                'team1_points'       : float,
                'team2_points'       : float,
                'total_possible'     : float,
                # Nassau / IR: list of segment dicts
                'segments'           : [
                    {
                        'label'      : str,
                        'segment'    : str,
                        'result'     : str | None,   # None = in progress
                        't1_pts'     : float,
                        't2_pts'     : float,
                        'is_resolved': bool,
                        # IR only:
                        'a_score'    : int | None,   # team_a raw stroke total
                        'b_score'    : int | None,
                    }
                ],
                # Singles / Match Play: list of individual match dicts
                'individual_matches' : [
                    {
                        'player1'        : str,
                        'player2'        : str,
                        'result'         : str | None,
                        't1_pts'         : float,
                        't2_pts'         : float,
                        'status'         : str,
                        'holes_played'   : int,
                        'overall_holes_up': int,
                        'finished_on_hole': int | None,
                        'is_resolved'    : bool,
                    }
                ],
            },
            ...
        ],
    }
    """
    from tournament.models import RyderCupRoundConfig

    try:
        rc = round_obj.ryder_cup_config
    except RyderCupRoundConfig.DoesNotExist:
        return None

    mul          = float(rc.point_multiplier)
    team1_name   = None
    team2_name   = None
    team1_colour = ''
    team2_colour = ''
    team1_total  = 0.0
    team2_total  = 0.0
    total_all    = 0.0
    matches_out  = []

    def _set_names(t1, t2):
        nonlocal team1_name, team2_name, team1_colour, team2_colour
        if team1_name is None and t1:
            team1_name   = t1.name
            team1_colour = t1.colour or ''
        if team2_name is None and t2:
            team2_name   = t2.name
            team2_colour = t2.colour or ''

    # ── Per-foursome games (Nassau, Singles, Match Play) ──────────────────

    for fs_cfg in rc.foursome_configs.select_related(
        'foursome', 'team1', 'team2',
    ).prefetch_related(
        'foursome__memberships__player',
        'team1__players',
        'team2__players',
    ).order_by('foursome__group_number'):

        pv    = float(fs_cfg.point_value) * mul
        t1    = fs_cfg.team1
        t2    = fs_cfg.team2
        fs    = fs_cfg.foursome
        gtype = fs_cfg.game_type
        _set_names(t1, t2)

        # Players from each team that are in this foursome
        fs_pids = set(
            fs.memberships.filter(player__is_phantom=False)
            .values_list('player_id', flat=True)
        )
        t1_names = [p.short_name for p in (t1.players.all() if t1 else []) if p.pk in fs_pids]
        t2_names = [p.short_name for p in (t2.players.all() if t2 else []) if p.pk in fs_pids]

        if gtype == GameType.NASSAU:
            from services.nassau import nassau_summary as _ns
            try:
                ns = _ns(fs) or {}
            except Exception:
                ns = {}

            segments  = []
            t1_match  = 0.0
            t2_match  = 0.0
            for seg_key, seg_lab in [
                ('front9',  'Front 9'),
                ('back9',   'Back 9'),
                ('overall', 'Overall'),
            ]:
                seg_data = ns.get(seg_key) or {}
                result   = seg_data.get('result')
                margin   = seg_data.get('margin', 0)         # +ve = team1 up
                holes    = seg_data.get('holes_played', 0)
                t1p, t2p = _seg_result_pts(result, pv)
                t1_match += t1p
                t2_match += t2p
                segments.append({
                    'label'       : seg_lab,
                    'segment'     : seg_key,
                    'result'      : result,
                    't1_pts'      : t1p,
                    't2_pts'      : t2p,
                    'is_resolved' : result is not None,
                    'margin'      : margin,      # live holes-up margin
                    'holes_played': holes,
                })

            possible     = pv * GAME_MULTIPLIERS[GameType.NASSAU]
            total_all   += possible
            team1_total += t1_match
            team2_total += t2_match
            matches_out.append({
                'game_type'         : 'nassau',
                'game_label'        : 'Four Ball',
                'groups'            : [fs.group_number],
                'team1_players'     : t1_names,
                'team2_players'     : t2_names,
                'point_value'       : pv,
                'team1_points'      : round(t1_match, 2),
                'team2_points'      : round(t2_match, 2),
                'total_possible'    : possible,
                'segments'          : segments,
                'individual_matches': [],
            })

        elif gtype == GameType.QUOTA_NASSAU:
            from services.quota_nassau import quota_nassau_summary as _qns
            try:
                qns = _qns(fs) or {}
            except Exception:
                qns = {}

            qmatches    = qns.get('matches', [])
            possible    = float(pv) * 3          # 3 Nassau segments per team match

            # ── Aggregate TEAM stableford and quotas across all pairings ──────
            # Each pairing: player1 = T1, player2 = T2.
            # Per-pairing front9.result compares player1 vs player2 within that
            # pair — NOT the team result.  We must compute team results from the
            # combined team stableford vs combined team quota.
            t1_quota18 = t2_quota18 = 0
            t1_f9_stpl = t2_f9_stpl = 0
            t1_b9_stpl = t2_b9_stpl = 0
            t1_all_stpl = t2_all_stpl = 0
            max_hole    = 0
            all_holes_data = []

            individual  = []
            for qm in qmatches:
                p1         = qm.get('player1', {})
                p2         = qm.get('player2', {})
                holes_data = qm.get('holes', [])
                all_holes_data.extend(holes_data)
                t1_quota18 += p1.get('quota', 0)
                t2_quota18 += p2.get('quota', 0)
                for h in holes_data:
                    hn = h.get('hole', 0)
                    if hn > max_hole:
                        max_hole = hn
                    p1sf = h.get('p1_stableford', 0)
                    p2sf = h.get('p2_stableford', 0)
                    if hn <= 9:
                        t1_f9_stpl += p1sf
                        t2_f9_stpl += p2sf
                    else:
                        t1_b9_stpl += p1sf
                        t2_b9_stpl += p2sf
                    t1_all_stpl += p1sf
                    t2_all_stpl += p2sf

                individual.append({
                    'player1'         : p1.get('short_name', '?'),
                    'player2'         : p2.get('short_name', '?'),
                    'player1_quota'   : p1.get('quota', 0),
                    'player2_quota'   : p2.get('quota', 0),
                    'status'          : qm.get('status', 'pending'),
                    'holes_played'    : len(holes_data),
                    'is_resolved'     : max_hole >= 18,
                    # Raw stableford for live display (aggregated further below)
                    'p1_f9_pts'       : sum(h.get('p1_stableford', 0) for h in holes_data if h.get('hole', 0) <= 9),
                    'p2_f9_pts'       : sum(h.get('p2_stableford', 0) for h in holes_data if h.get('hole', 0) <= 9),
                    'p1_all_pts'      : sum(h.get('p1_stableford', 0) for h in holes_data),
                    'p2_all_pts'      : sum(h.get('p2_stableford', 0) for h in holes_data),
                })

            # ── Team-level Nassau results ─────────────────────────────────────
            # Compare (team stpl - team quota) for each segment.
            # The team with the higher vs-quota margin wins the segment.
            t1_f9_quota  = t1_quota18 // 2
            t2_f9_quota  = t2_quota18 // 2
            t1_b9_quota  = t1_quota18 - t1_f9_quota
            t2_b9_quota  = t2_quota18 - t2_f9_quota

            def _team_resolve(t1s, t1q, t2s, t2q):
                d1, d2 = t1s - t1q, t2s - t2q
                if d1 > d2:  return 'team1'
                if d2 > d1:  return 'team2'
                return 'halved'

            front_done   = max_hole >= 9
            back_done    = max_hole >= 18

            team_f9_res  = _team_resolve(t1_f9_stpl,  t1_f9_quota,  t2_f9_stpl,  t2_f9_quota)  if front_done else None
            team_b9_res  = _team_resolve(t1_b9_stpl,  t1_b9_quota,  t2_b9_stpl,  t2_b9_quota)  if back_done  else None
            team_ovr_res = _team_resolve(t1_all_stpl, t1_quota18,   t2_all_stpl, t2_quota18)    if back_done  else None

            f9_t1p,  f9_t2p  = _seg_result_pts(team_f9_res,  pv)
            b9_t1p,  b9_t2p  = _seg_result_pts(team_b9_res,  pv)
            ovr_t1p, ovr_t2p = _seg_result_pts(team_ovr_res, pv)

            t1_match = f9_t1p  + b9_t1p  + ovr_t1p
            t2_match = f9_t2p  + b9_t2p  + ovr_t2p

            # Store team result summary on each individual match so Flutter
            # can read it without re-aggregating.
            for im in individual:
                im['result']     = team_ovr_res
                im['t1_pts']     = round(t1_match, 2)
                im['t2_pts']     = round(t2_match, 2)
                im['f9_result']  = team_f9_res
                im['b9_result']  = team_b9_res

            possible     = pv * GAME_MULTIPLIERS[GameType.QUOTA_NASSAU]
            total_all   += possible
            team1_total += t1_match
            team2_total += t2_match
            matches_out.append({
                'game_type'         : 'quota_nassau',
                'game_label'        : 'Quota Nassau',
                'groups'            : [fs.group_number],
                'team1_players'     : t1_names,
                'team2_players'     : t2_names,
                'point_value'       : pv,
                'team1_points'      : round(t1_match, 2),
                'team2_points'      : round(t2_match, 2),
                'total_possible'    : possible,
                'segments'          : [],
                'individual_matches': individual,
            })

        elif gtype in (GameType.SINGLES_NASSAU, GameType.SINGLES_18):
            from games.models import MatchPlayBracket
            label = (
                'Singles Nassau'  if gtype == GameType.SINGLES_NASSAU
                else '18-Hole Singles'
            )
            try:
                bracket = MatchPlayBracket.objects.prefetch_related(
                    'matches__player1',
                    'matches__player2',
                    'matches__hole_results',
                ).get(foursome=fs)
            except MatchPlayBracket.DoesNotExist:
                matches_out.append({
                    'game_type'         : str(gtype),
                    'game_label'        : label,
                    'groups'            : [fs.group_number],
                    'team1_players'     : t1_names,
                    'team2_players'     : t2_names,
                    'point_value'       : pv,
                    'team1_points'      : 0.0,
                    'team2_points'      : 0.0,
                    'total_possible'    : 0.0,
                    'segments'          : [],
                    'individual_matches': [],
                    'note'              : 'Bracket not yet configured',
                })
                continue

            individual  = []
            t1_match    = 0.0
            t2_match    = 0.0
            possible    = 0.0
            # singles_nassau awards pv per segment (F9/B9/All) independently.
            # singles_18 awards pv for the single overall result.
            # possible is accumulated inside the loop.
            from services.cup_singles import _compute_sub_match

            for mp in bracket.matches.all():
                # Derive holes-played & current margin from hole results
                hole_results = sorted(
                    mp.hole_results.all(), key=lambda r: r.hole_number
                )
                holes_played     = len(hole_results)
                overall_holes_up = (
                    hole_results[-1].holes_up_after if hole_results else 0
                )

                holes_data = [
                    {'hole_number': r.hole_number,
                     'p1_net': r.p1_net, 'p2_net': r.p2_net}
                    for r in hole_results
                ]

                if gtype == GameType.SINGLES_NASSAU:
                    # Award pv per segment independently as each completes.
                    f9    = _compute_sub_match(holes_data, 1,  9)
                    b9    = _compute_sub_match(holes_data, 10, 18)
                    all18 = _compute_sub_match(holes_data, 1,  18)

                    f9_t1p,    f9_t2p    = _seg_result_pts(_mp_result_to_cup(f9['result']),    pv)
                    b9_t1p,    b9_t2p    = _seg_result_pts(_mp_result_to_cup(b9['result']),    pv)
                    all18_t1p, all18_t2p = _seg_result_pts(_mp_result_to_cup(all18['result']), pv)


                    t1p = f9_t1p + b9_t1p + all18_t1p
                    t2p = f9_t2p + b9_t2p + all18_t2p
                    possible += pv * 3

                    # Overall match result for display: use all-18 sub-match
                    ovr_result = _mp_result_to_cup(all18['result'])
                    ovr_holes_up = all18['holes_up'] if all18['holes_up'] is not None else overall_holes_up
                    finished_on  = all18['finished_on_hole']
                else:
                    # singles_18: single overall result
                    f9  = _compute_sub_match(holes_data, 1,  9)
                    b9  = _compute_sub_match(holes_data, 10, 18)
                    all18 = {'status': mp.status, 'result': mp.result,
                             'holes_up': None, 'finished_on_hole': mp.finished_on_hole}
                    ovr_result   = _mp_result_to_cup(mp.result)
                    t1p, t2p     = _seg_result_pts(ovr_result, pv)
                    ovr_holes_up = overall_holes_up
                    finished_on  = mp.finished_on_hole
                    possible    += pv

                t1_match += t1p
                t2_match += t2p

                individual.append({
                    'player1'            : mp.player1.short_name if mp.player1_id else '?',
                    'player2'            : mp.player2.short_name if mp.player2_id else '?',
                    'result'             : ovr_result,
                    't1_pts'             : t1p,
                    't2_pts'             : t2p,
                    'status'             : mp.status,
                    'holes_played'       : holes_played,
                    'overall_holes_up'   : ovr_holes_up,
                    'finished_on_hole'   : finished_on,
                    'is_resolved'        : ovr_result is not None,
                    # F9 sub-match
                    'f9_status'          : f9['status'],
                    'f9_result'          : f9['result'],
                    'f9_holes_up'        : f9['holes_up'],
                    'f9_finished_on_hole': f9['finished_on_hole'],
                    # B9 sub-match
                    'b9_status'          : b9['status'],
                    'b9_result'          : b9['result'],
                    'b9_holes_up'        : b9['holes_up'],
                    'b9_finished_on_hole': b9['finished_on_hole'],
                })

            total_all   += possible
            team1_total += t1_match
            team2_total += t2_match
            matches_out.append({
                'game_type'         : str(gtype),
                'game_label'        : label,
                'groups'            : [fs.group_number],
                'team1_players'     : t1_names,
                'team2_players'     : t2_names,
                'point_value'       : pv,
                'team1_points'      : round(t1_match, 2),
                'team2_points'      : round(t2_match, 2),
                'total_possible'    : possible,
                'segments'          : [],
                'individual_matches': individual,
            })

    # ── Irish Rumble cross-group pairings ──────────────────────────────────

    # Build IR score index, balls-by-hole, and hole-par lookup once
    ir_score_index   = None
    ir_balls_by_hole = {}
    ir_hole_pars     = {}
    from games.models import IrishRumbleConfig
    try:
        ir_cfg = round_obj.irish_rumble_config
        from services.irish_rumble import _build_ir_score_index
        ir_score_index = _build_ir_score_index(
            round_obj, ir_cfg.handicap_mode, ir_cfg.net_percent
        )
        for seg in ir_cfg.segments:
            for h in range(seg['start_hole'], seg['end_hole'] + 1):
                ir_balls_by_hole[h] = seg['balls_to_count']
    except IrishRumbleConfig.DoesNotExist:
        pass

    # Par per hole from the first tee with data
    from tournament.models import FoursomeMembership as _FM
    _first_mem = (
        _FM.objects
        .filter(foursome__round=round_obj, player__is_phantom=False, tee__isnull=False)
        .select_related('tee')
        .first()
    )
    if _first_mem:
        for _h in _first_mem.tee.holes:
            ir_hole_pars[_h['number']] = _h['par']

    def _ir_live(foursome):
        """
        Return live score for one foursome:
          holes_played – furthest hole with at least one score (skips gaps)
          score        – cumulative best-N-ball total through those holes
          vs_par       – score minus (par × balls) for the same holes
        Returns (0, None, None) when no holes are scored yet.
        """
        if ir_score_index is None:
            return 0, None, None
        fs_scores  = ir_score_index.get(foursome.pk, {})
        n_real     = foursome.memberships.filter(player__is_phantom=False).count()
        score_acc  = 0
        par_acc    = 0
        max_hole   = 0
        for h in range(1, 19):
            n      = min(ir_balls_by_hole.get(h, 1), n_real)
            scores = sorted([ph[h] for ph in fs_scores.values() if h in ph])
            if not scores:
                continue   # hole not yet scored — skip (mirrors irish_rumble.py)
            score_acc += sum(scores[:n])
            par_acc   += ir_hole_pars.get(h, 4) * n
            max_hole   = h
        if max_hole == 0:
            return 0, None, None
        return max_hole, score_acc, score_acc - par_acc

    def _ir_cumulative(foursome, max_hole):
        """Sum of best-N-balls per hole through max_hole for a foursome."""
        if ir_score_index is None:
            return None
        fs_scores = ir_score_index.get(foursome.pk, {})
        n_real    = foursome.memberships.filter(player__is_phantom=False).count()
        total     = 0
        for h in range(1, max_hole + 1):
            n      = min(ir_balls_by_hole.get(h, 1), n_real)
            scores = sorted([ph[h] for ph in fs_scores.values() if h in ph])
            if len(scores) < n:
                return None
            total += sum(scores[:n])
        return total

    def _resolve(a, b):
        if a is None or b is None: return None
        if a < b:  return 'team1'
        if b < a:  return 'team2'
        return 'halved'

    # Build the list of (fa, fb, team_a, team_b) to iterate over.
    # Three-tier discovery:
    #   1. Explicit RyderCupIrishRumblePairing records (most precise)
    #   2. foursome_configs with game_type == IRISH_RUMBLE, grouped by team
    #   3. Any round with 'irish_rumble' in active_games: group all foursomes
    #      by team via player membership, then pair one foursome per team.
    # Pre-load all IR foursome configs for this round, keyed by foursome_id.
    # Used by all tiers so point_value is always available regardless of how
    # the pairing was discovered.
    _ir_cfg_pv: dict = {
        cfg.foursome_id: float(cfg.point_value)
        for cfg in rc.foursome_configs.filter(game_type=GameType.IRISH_RUMBLE)
    }

    explicit_pairings = list(rc.irish_rumble_pairings.select_related(
        'foursome_a', 'foursome_b', 'team_a', 'team_b',
    ).prefetch_related(
        'foursome_a__memberships__player',
        'foursome_b__memberships__player',
    ).all())

    def _ir_pv(fa, fb):
        """Return per-foursome point_value if configured, else None (falls back to nassau_pv)."""
        return _ir_cfg_pv.get(fa.pk) or _ir_cfg_pv.get(fb.pk)

    if explicit_pairings:
        # Tier 1: explicit pairings
        ir_pairs = [
            (p.foursome_a, p.foursome_b, p.team_a, p.team_b,
             _ir_pv(p.foursome_a, p.foursome_b))
            for p in explicit_pairings
        ]
    else:
        # Tier 2: IR foursome_configs — carry the per-foursome point_value through
        ir_fs_cfgs = list(
            rc.foursome_configs
            .filter(game_type=GameType.IRISH_RUMBLE)
            .select_related('foursome', 'team1', 'team2')
            .prefetch_related('foursome__memberships__player')
        )
        by_team: dict = {}
        for cfg in ir_fs_cfgs:
            key = cfg.team1_id if cfg.team1_id else cfg.team2_id
            if key is not None:
                by_team.setdefault(key, []).append(cfg)
        team_keys = list(by_team.keys())
        ir_pairs = []
        if len(team_keys) >= 2:
            for a_cfg, b_cfg in zip(by_team[team_keys[0]], by_team[team_keys[1]]):
                ir_pairs.append((
                    a_cfg.foursome,
                    b_cfg.foursome,
                    a_cfg.team1 or a_cfg.team2,
                    b_cfg.team1 or b_cfg.team2,
                    float(a_cfg.point_value),   # per-foursome point_value overrides round default
                ))

        # Tier 3: if still nothing, detect from active_games + player→team membership
        if not ir_pairs and 'irish_rumble' in (round_obj.active_games or []):
            from tournament.models import TournamentTeam
            teams = list(
                TournamentTeam.objects
                .filter(tournament=rc.tournament)
                .prefetch_related('players')
            )
            if len(teams) >= 2:
                # Build player_id → team map
                pid_to_team: dict = {}
                for t in teams:
                    for p in t.players.all():
                        pid_to_team[p.pk] = t

                # Group foursomes by dominant team (majority of real players)
                from tournament.models import Foursome as _Foursome
                round_foursomes = list(
                    _Foursome.objects
                    .filter(round=round_obj)
                    .prefetch_related('memberships__player')
                    .order_by('group_number')
                )
                by_team_fs: dict = {}
                for fs in round_foursomes:
                    team_votes: dict = {}
                    for m in fs.memberships.all():
                        if m.player.is_phantom:
                            continue
                        t = pid_to_team.get(m.player_id)
                        if t:
                            team_votes[t.pk] = team_votes.get(t.pk, 0) + 1
                    if team_votes:
                        dominant = max(team_votes, key=lambda k: team_votes[k])
                        by_team_fs.setdefault(dominant, []).append(fs)

                fs_team_keys = list(by_team_fs.keys())
                if len(fs_team_keys) >= 2:
                    team_obj = {t.pk: t for t in teams}
                    for fa, fb in zip(
                        by_team_fs[fs_team_keys[0]],
                        by_team_fs[fs_team_keys[1]]
                    ):
                        ir_pairs.append((
                            fa, fb,
                            team_obj[fs_team_keys[0]],
                            team_obj[fs_team_keys[1]],
                            None,  # no per-foursome config; use round default
                        ))

    for fa, fb, team_a, team_b, _unused_pv in ir_pairs:
        # Look up point_value directly from the pre-built dict (keyed by foursome_id).
        # Fall back to the round-level nassau_point_value if not configured.
        pv = (_ir_cfg_pv.get(fa.pk) or _ir_cfg_pv.get(fb.pk) or float(rc.nassau_point_value)) * mul
        _set_names(team_a, team_b)

        # All real players in each foursome
        t1_names = [m.player.short_name for m in fa.memberships.all()
                    if not m.player.is_phantom]
        t2_names = [m.player.short_name for m in fb.memberships.all()
                    if not m.player.is_phantom]

        # Live scores — per-foursome holes played + vs-par
        a_holes, a_score, a_vs_par = _ir_live(fa)
        b_holes, b_score, b_vs_par = _ir_live(fb)

        # Final result: use full-18 totals (None until 18 holes scored)
        f18_a = _ir_cumulative(fa, 18)
        f18_b = _ir_cumulative(fb, 18)
        ovr_result     = _resolve(f18_a, f18_b)
        t1_match, t2_match = _seg_result_pts(ovr_result, pv)

        segments = [
            {
                'label'         : 'Overall',
                'segment'       : 'overall',
                'result'        : ovr_result,
                't1_pts'        : t1_match,
                't2_pts'        : t2_match,
                'a_score'       : a_score,
                'b_score'       : b_score,
                'a_vs_par'      : a_vs_par,
                'b_vs_par'      : b_vs_par,
                'a_holes_played': a_holes,
                'b_holes_played': b_holes,
                'is_resolved'   : ovr_result is not None,
            },
        ]

        possible     = pv * GAME_MULTIPLIERS[GameType.IRISH_RUMBLE]   # pv × 1
        total_all   += possible
        team1_total += t1_match
        team2_total += t2_match
        matches_out.append({
            'game_type'         : 'irish_rumble',
            'game_label'        : 'Irish Rumble',
            'groups'            : [fa.group_number, fb.group_number],
            'team1_players'     : t1_names,
            'team2_players'     : t2_names,
            'point_value'       : pv,
            'team1_points'      : round(t1_match, 2),
            'team2_points'      : round(t2_match, 2),
            'total_possible'    : possible,
            'segments'          : segments,
            'individual_matches': [],
        })

    return {
        'team1_name'    : team1_name    or 'Team 1',
        'team2_name'    : team2_name    or 'Team 2',
        'team1_colour'  : team1_colour  or 'Red',
        'team2_colour'  : team2_colour  or 'Blue',
        'team1_points'  : round(team1_total, 2),
        'team2_points'  : round(team2_total, 2),
        'total_possible': round(total_all, 2),
        'matches'       : matches_out,
    }
