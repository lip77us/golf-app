"""
services/irish_rumble.py
------------------------
Irish Rumble calculator.

Rules
~~~~~
* All foursomes compete against each other (not within-foursome).
* The round is divided into segments (defined in IrishRumbleConfig.segments):
      Hole 1–6:   count best 1 net score per group
      Hole 7–12:  count best 2 net scores per group
      Hole 13–17: count best 3 net scores per group
      Hole 18:    count best 4 net scores (all) per group
  (Segments are fully configurable per round via IrishRumbleConfig.)
* For 3-some groups, balls_to_count is capped at real player count
  (phantom scores are excluded).
* Lowest total net score in a segment wins that segment.
* Overall winner = lowest cumulative net across all segments (or by
  segment wins — see note below).

Scoring note
~~~~~~~~~~~~
We store per-segment results and rank within each segment. Overall ranking
is by total net across ALL segments combined (lowest wins). The caller can
choose to rank by segment wins instead if preferred.

Public API
~~~~~~~~~~
    # Requires IrishRumbleConfig to exist for this round:
    results = calculate_irish_rumble(round_obj)
    summary = irish_rumble_summary(round_obj)
"""

from django.db import transaction

from games.models import IrishRumbleConfig, IrishRumbleSegmentResult
from scoring.models import HoleScore
from tournament.models import Foursome


@transaction.atomic
def calculate_irish_rumble(round_obj) -> list:
    """
    Calculate IrishRumbleSegmentResult rows for every foursome × segment.

    Requires an IrishRumbleConfig for this round (create one in admin first).
    Safe to call repeatedly — previous results are replaced.

    Returns a flat list of IrishRumbleSegmentResult instances.
    """
    try:
        config = round_obj.irish_rumble_config
    except IrishRumbleConfig.DoesNotExist:
        raise ValueError(
            f"No IrishRumbleConfig found for {round_obj}. "
            "Create one in admin under Games → Irish Rumble Config."
        )

    foursomes = list(Foursome.objects.filter(round=round_obj).order_by('group_number'))

    # Fetch all real-player net scores for this round
    hole_scores = (
        HoleScore.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .exclude(net_score=None)
        .values('foursome_id', 'hole_number', 'player_id', 'net_score')
    )

    # Index: foursome_id → hole_number → list of net scores
    score_index: dict = {}
    for hs in hole_scores:
        fid  = hs['foursome_id']
        hole = hs['hole_number']
        score_index.setdefault(fid, {}).setdefault(hole, []).append(hs['net_score'])

    # Real player counts (excluding phantom)
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

        seg_results = []

        for foursome in foursomes:
            player_count = player_counts[foursome.pk]
            balls        = min(configured, player_count)
            fs_scores    = score_index.get(foursome.pk, {})

            # Collect best N net scores across all holes in this segment
            hole_bests = []
            for hole_num in range(start_hole, end_hole + 1):
                scores_on_hole = fs_scores.get(hole_num, [])
                if scores_on_hole:
                    hole_bests.append(min(scores_on_hole))

            # Only score if all holes in segment have data
            if len(hole_bests) == (end_hole - start_hole + 1):
                # Sort all individual bests, take lowest N
                best_scores  = sorted(hole_bests)[:balls]
                total_net    = sum(best_scores)
            else:
                total_net = None   # incomplete segment

            seg_results.append({
                'foursome'    : foursome,
                'balls'       : balls,
                'total_net'   : total_net,
            })

        # Rank within segment (lowest net wins; None = unranked)
        completed = [r for r in seg_results if r['total_net'] is not None]
        completed.sort(key=lambda r: r['total_net'])
        rank_map: dict = {}
        rank = 1
        for i, r in enumerate(completed):
            if i > 0 and r['total_net'] > completed[i - 1]['total_net']:
                rank = i + 1
            rank_map[r['foursome'].pk] = rank

        for r in seg_results:
            result = IrishRumbleSegmentResult(
                round         = round_obj,
                foursome      = r['foursome'],
                segment_index = seg_idx,
                balls_counted = r['balls'],
                total_net_score = r['total_net'],
                rank          = rank_map.get(r['foursome'].pk),
            )
            saved.append(result)

    IrishRumbleSegmentResult.objects.bulk_create(saved)
    return saved


def irish_rumble_summary(round_obj) -> dict:
    """
    Return a dict with:
        'segments'  : list of segment dicts, each containing:
                        'label'   : str  e.g. "Holes 1-6 (best 1)"
                        'results' : list of { 'rank', 'group', 'score' }
        'overall'   : list of { 'rank', 'group', 'players', 'total_net' }
                      ranked by cumulative net across all segments
    """
    try:
        config = round_obj.irish_rumble_config
    except IrishRumbleConfig.DoesNotExist:
        return {'segments': [], 'overall': []}

    results = (
        IrishRumbleSegmentResult.objects
        .filter(round=round_obj)
        .select_related('foursome')
        .order_by('segment_index', 'rank')
    )

    # Group by segment
    by_seg: dict = {}
    for r in results:
        by_seg.setdefault(r.segment_index, []).append(r)

    segments = []
    for seg_idx, seg in enumerate(config.segments):
        seg_results = by_seg.get(seg_idx, [])
        label = (
            f"Holes {seg['start_hole']}–{seg['end_hole']} "
            f"(best {seg['balls_to_count']})"
        )
        segments.append({
            'label'  : label,
            'results': [
                {
                    'rank' : r.rank,
                    'group': f"Group {r.foursome.group_number}",
                    'score': r.total_net_score,
                }
                for r in seg_results
            ],
        })

    # Overall: sum all segment net scores per foursome
    totals: dict = {}
    for r in results:
        if r.total_net_score is not None:
            totals[r.foursome_id] = totals.get(r.foursome_id, 0) + r.total_net_score

    foursomes = {fs.pk: fs for fs in Foursome.objects.filter(round=round_obj)}
    overall = sorted(
        [
            {'foursome_id': fid, 'total_net': net}
            for fid, net in totals.items()
        ],
        key=lambda x: x['total_net'],
    )

    rank = 1
    overall_out = []
    for i, row in enumerate(overall):
        if i > 0 and row['total_net'] > overall[i - 1]['total_net']:
            rank = i + 1
        fs = foursomes[row['foursome_id']]
        players = ', '.join(
            m.player.name for m in
            fs.memberships.filter(player__is_phantom=False)
                          .select_related('player')
                          .order_by('player__name')
        )
        overall_out.append({
            'rank'      : rank,
            'group'     : f"Group {fs.group_number}",
            'players'   : players,
            'total_net' : row['total_net'],
        })

    return {'segments': segments, 'overall': overall_out}
