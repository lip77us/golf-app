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


def stableford_summary(round_obj) -> list:
    """
    Return ranked Stableford results as a list of dicts.

    Each dict:
        {
            'rank'         : int,
            'player_name'  : str,
            'total_points' : int,
        }
    """
    return [
        {
            'rank'         : r.rank,
            'player_name'  : r.player.name,
            'total_points' : r.total_points,
        }
        for r in (
            StablefordResult.objects
            .filter(round=round_obj)
            .select_related('player')
            .order_by('rank')
        )
    ]
