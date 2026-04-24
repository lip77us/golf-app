"""
services/irish_rumble.py
------------------------
Irish Rumble calculator.

Rules
~~~~~
* All foursomes in the round compete against each other as teams.
* The round is divided into segments (defined in IrishRumbleConfig.segments):
      Hole 1–6:   count best 1 score per group
      Hole 7–12:  count best 2 scores per group
      Hole 13–17: count best 3 scores per group
      Hole 18:    count best 4 scores (all) per group
  (Segments are fully configurable per round via IrishRumbleConfig.)
* For 3-some groups, balls_to_count is capped at real player count.
* Lowest total score in a segment wins that segment.
* Overall winner = lowest cumulative score across all segments.

Scoring
~~~~~~~
* Each player's per-hole score is adjusted for handicap per IrishRumbleConfig:
    - 'net'         : gross − strokes (playing_handicap × net_percent / 100)
    - 'gross'       : raw gross score
    - 'strokes_off' : gross − max(0, own_handicap − tournament_low_handicap),
                      strokes allocated by hole stroke_index.
  The reference for strokes_off is the lowest playing_handicap across ALL
  foursomes in the round (not just within each group).
* A double-bogey cap is applied after handicap adjustment:
    effective = min(adjusted, par + 2)
  This is the Stableford-style damage limiter that prevents a single blowup
  hole from tanking a team's score.
* Reported as net-to-par (sum of counting scores minus sum of hole pars).

Public API
~~~~~~~~~~
    results = calculate_irish_rumble(round_obj)
    summary = irish_rumble_summary(round_obj)
"""

from django.db import transaction

from core.models import HandicapMode
from games.models import IrishRumbleConfig, IrishRumbleSegmentResult
from scoring.models import HoleScore
from scoring.handicap import _effective_hcp, _strokes_on_hole
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _build_ir_score_index(round_obj, handicap_mode, net_percent):
    """
    Build {foursome_id: {player_id: {hole_number: capped_score}}} for all
    real players in the round.

    Applies the handicap adjustment and the double-bogey cap (par + 2 max).
    For strokes_off mode, SO strokes are relative to the lowest playing_handicap
    across ALL foursomes in the round.
    """
    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee')
    )

    # Build membership lookup: {foursome_id: {player_id: membership}}
    membership_index = {}
    for fs in foursomes:
        membership_index[fs.pk] = {
            m.player_id: m
            for m in fs.memberships.all()
            if not m.player.is_phantom
        }

    # Build par lookup: {foursome_id: {hole_number: par}}
    # Use the first tee found for each foursome (par is the same across tees
    # at the same course for the purposes of the cap).
    par_index = {}
    for fs in foursomes:
        first_m = next(
            (m for m in fs.memberships.all() if m.tee_id is not None), None
        )
        if first_m:
            par_index[fs.pk] = {h['number']: h['par'] for h in first_m.tee.holes}

    # For strokes_off: tournament-wide lowest playing_handicap (real players only)
    low_hcp = 0
    if handicap_mode == HandicapMode.STROKES_OFF:
        all_hcps = [
            m.playing_handicap
            for ms in membership_index.values()
            for m in ms.values()
        ]
        low_hcp = min(all_hcps) if all_hcps else 0

    # Fetch all relevant hole scores in one query
    qs = (
        HoleScore.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .exclude(gross_score=None)
        .values('foursome_id', 'player_id', 'hole_number',
                'gross_score', 'net_score')
    )

    result = {}
    for hs in qs:
        fid  = hs['foursome_id']
        pid  = hs['player_id']
        hole = hs['hole_number']

        membership = membership_index.get(fid, {}).get(pid)
        if membership is None:
            continue

        # ── Handicap adjustment ─────────────────────────────────────────────
        if handicap_mode == HandicapMode.GROSS:
            adjusted = hs['gross_score']

        elif handicap_mode == HandicapMode.NET:
            if net_percent == 100 and hs['net_score'] is not None:
                # Re-use stored value — fast path
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

        result.setdefault(fid, {}).setdefault(pid, {})[hole] = capped

    return result


def _par_index_for_round(round_obj):
    """
    Return {hole_number: par} using the first tee found in the round.
    Used for computing net-to-par totals in the summary.
    """
    fs = Foursome.objects.filter(round=round_obj).prefetch_related(
        'memberships__tee'
    ).first()
    if fs is None:
        return {}
    first_m = next(
        (m for m in fs.memberships.all() if m.tee_id is not None), None
    )
    if first_m is None:
        return {}
    return {h['number']: h['par'] for h in first_m.tee.holes}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_irish_rumble(round_obj) -> list:
    """
    Calculate IrishRumbleSegmentResult rows for every foursome × segment.

    Requires an IrishRumbleConfig for this round. Safe to call repeatedly —
    previous results are replaced.

    Returns a flat list of IrishRumbleSegmentResult instances.
    """
    try:
        config = round_obj.irish_rumble_config
    except IrishRumbleConfig.DoesNotExist:
        raise ValueError(
            f"No IrishRumbleConfig found for {round_obj}. "
            "Create one in admin under Games → Irish Rumble Config."
        )

    handicap_mode = config.handicap_mode
    net_percent   = config.net_percent

    foursomes = list(Foursome.objects.filter(round=round_obj).order_by('group_number'))

    # Build the capped score index for the whole round
    score_index = _build_ir_score_index(round_obj, handicap_mode, net_percent)

    # Real player counts per foursome
    player_counts = {
        fs.pk: fs.memberships.filter(player__is_phantom=False).count()
        for fs in foursomes
    }

    IrishRumbleSegmentResult.objects.filter(round=round_obj).delete()
    saved = []

    for seg_idx, seg in enumerate(config.segments):
        start_hole = seg['start_hole']
        end_hole   = seg['end_hole']
        configured = seg['balls_to_count']
        holes_in_seg = list(range(start_hole, end_hole + 1))

        seg_results = []

        for foursome in foursomes:
            player_count = player_counts[foursome.pk]
            balls        = min(configured, player_count)
            fs_scores    = score_index.get(foursome.pk, {})

            # For each hole in the segment, take the N best (lowest) scores
            # from the group and sum them.  The segment total is the sum of
            # those per-hole N-best amounts across all holes in the segment.
            hole_totals = []
            all_holes_present = True
            for hole_num in holes_in_seg:
                scores_on_hole = sorted([
                    player_holes[hole_num]
                    for player_holes in fs_scores.values()
                    if hole_num in player_holes
                ])
                if scores_on_hole:
                    hole_totals.append(sum(scores_on_hole[:balls]))
                else:
                    all_holes_present = False
                    break

            if all_holes_present and len(hole_totals) == len(holes_in_seg):
                total = sum(hole_totals)
            else:
                total = None  # segment incomplete

            seg_results.append({
                'foursome' : foursome,
                'balls'    : balls,
                'total'    : total,
            })

        # Rank within this segment (lowest wins; None = unranked)
        completed = sorted(
            [r for r in seg_results if r['total'] is not None],
            key=lambda r: r['total'],
        )
        rank_map: dict = {}
        rank = 1
        for i, r in enumerate(completed):
            if i > 0 and r['total'] > completed[i - 1]['total']:
                rank = i + 1
            rank_map[r['foursome'].pk] = rank

        for r in seg_results:
            saved.append(IrishRumbleSegmentResult(
                round           = round_obj,
                foursome        = r['foursome'],
                segment_index   = seg_idx,
                balls_counted   = r['balls'],
                total_net_score = r['total'],
                rank            = rank_map.get(r['foursome'].pk),
            ))

    IrishRumbleSegmentResult.objects.bulk_create(saved)
    return saved


def irish_rumble_summary(round_obj) -> dict:
    """
    Return a serialisable dict:
        {
          'handicap_mode': str,
          'net_percent'  : int,
          'bet_unit'     : float,
          'segments'     : [
              {
                'label'  : "Holes 1-6 (best 1)",
                'results': [{'rank', 'group', 'score', 'net_to_par'}, ...]
              }, ...
          ],
          'overall': [
              {'rank', 'group', 'players', 'total_score', 'net_to_par'}, ...
          ]
        }
    """
    try:
        config = round_obj.irish_rumble_config
    except IrishRumbleConfig.DoesNotExist:
        return {'segments': [], 'overall': []}

    par_by_hole = _par_index_for_round(round_obj)

    results = (
        IrishRumbleSegmentResult.objects
        .filter(round=round_obj)
        .select_related('foursome')
        .order_by('segment_index', 'rank')
    )

    by_seg: dict = {}
    for r in results:
        by_seg.setdefault(r.segment_index, []).append(r)

    segments_out = []
    for seg_idx, seg in enumerate(config.segments):
        seg_results  = by_seg.get(seg_idx, [])
        holes_in_seg = list(range(seg['start_hole'], seg['end_hole'] + 1))
        seg_par      = sum(par_by_hole.get(h, 4) for h in holes_in_seg)
        label        = (
            f"Holes {seg['start_hole']}-{seg['end_hole']} "
            f"(best {seg['balls_to_count']})"
        )
        segments_out.append({
            'label'  : label,
            'results': [
                {
                    'rank'      : r.rank,
                    'group'     : f"Group {r.foursome.group_number}",
                    'score'     : r.total_net_score,
                    'net_to_par': (
                        r.total_net_score - seg_par
                        if r.total_net_score is not None else None
                    ),
                }
                for r in seg_results
            ],
        })

    # ── Overall: running totals built directly from per-hole scores ───────────
    # Correct Irish Rumble scoring:
    #   For each hole played, take the N best (lowest) net scores from the
    #   group (N = balls_to_count for that hole's segment).  Sum those across
    #   all holes played to get the running total.  net_to_par is compared
    #   against the par contribution for the same holes (balls × hole_par).
    #
    # This means the leaderboard is live from hole 1 — no need to wait for
    # a full segment to complete.

    foursomes = {fs.pk: fs for fs in Foursome.objects.filter(round=round_obj)}

    # player count per foursome (caps balls on 3-somes)
    player_counts_dict = {
        fs.pk: fs.memberships.filter(player__is_phantom=False).count()
        for fs in foursomes.values()
    }

    # hole → balls_to_count (from config segments)
    balls_by_hole: dict = {}
    for seg in config.segments:
        n = seg['balls_to_count']
        for h in range(seg['start_hole'], seg['end_hole'] + 1):
            balls_by_hole[h] = n

    # Build capped per-hole score index for the whole round
    score_index = _build_ir_score_index(
        round_obj, config.handicap_mode, config.net_percent
    )

    # Current (furthest) hole scored per foursome
    from django.db.models import Max
    hole_progress = {
        row['foursome_id']: row['max_hole']
        for row in (
            HoleScore.objects
            .filter(foursome__round=round_obj)
            .exclude(gross_score=None)
            .values('foursome_id')
            .annotate(max_hole=Max('hole_number'))
        )
    }

    # Compute running total for every foursome
    running: dict = {}  # fid → {'score': int, 'par': int}
    for fid in foursomes:
        fs_scores = score_index.get(fid, {})
        n_players = player_counts_dict.get(fid, 4)
        score_acc = 0
        par_acc   = 0
        has_any   = False
        for hole_num in range(1, 19):
            configured_n = balls_by_hole.get(hole_num, 1)
            balls        = min(configured_n, n_players)
            scores_on_hole = sorted([
                ph[hole_num]
                for ph in fs_scores.values()
                if hole_num in ph
            ])
            if not scores_on_hole:
                continue  # not yet scored
            score_acc += sum(scores_on_hole[:balls])
            par_acc   += par_by_hole.get(hole_num, 4) * balls
            has_any    = True
        if has_any:
            running[fid] = {'score': score_acc, 'par': par_acc}

    # Payout: winner-take-all pool; split evenly on ties.
    num_groups = len(foursomes)
    pool       = round(float(config.bet_unit) * num_groups, 2)

    # Sort: teams with scores first (lowest net-to-par wins), then unstarted
    def _ntp(fid):
        if fid not in running:
            return None
        r = running[fid]
        return r['score'] - r['par']

    scored   = sorted(
        [fid for fid in foursomes if fid in running],
        key=lambda fid: _ntp(fid),
    )
    unscored = [fid for fid in foursomes if fid not in running]

    rank = 1
    ranked_rows = []
    for i, fid in enumerate(scored):
        if i > 0 and _ntp(fid) > _ntp(scored[i - 1]):
            rank = i + 1
        ranked_rows.append({'foursome_id': fid, 'rank': rank})
    for fid in unscored:
        ranked_rows.append({'foursome_id': fid, 'rank': None})

    # Split pool among co-leaders (rank == 1)
    leaders = [r for r in ranked_rows if r['rank'] == 1]
    payout_each = round(pool / len(leaders), 2) if leaders else 0.0

    overall_out = []
    for row in ranked_rows:
        fid     = row['foursome_id']
        fs      = foursomes[fid]
        r       = running.get(fid)
        ntp     = (r['score'] - r['par']) if r else None
        players = ', '.join(
            m.player.name
            for m in fs.memberships.filter(player__is_phantom=False)
                                   .select_related('player')
                                   .order_by('player__name')
        )
        overall_out.append({
            'rank'        : row['rank'],
            'group'       : f"Group {fs.group_number}",
            'players'     : players,
            'total_score' : r['score'] if r else None,
            'net_to_par'  : ntp,
            'current_hole': hole_progress.get(fid),
            'payout'      : payout_each if row['rank'] == 1 else 0.0,
        })

    return {
        'handicap_mode': config.handicap_mode,
        'net_percent'  : config.net_percent,
        'bet_unit'     : float(config.bet_unit),
        'pool'         : pool,
        'segments'     : segments_out,
        'overall'      : overall_out,
    }
