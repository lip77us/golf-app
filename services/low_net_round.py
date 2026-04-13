"""
services/low_net_round.py
-------------------------
Low Net (Round) calculator — individual game, single round.

Each player's total net score (sum of gross - handicap strokes across all
18 holes) is ranked lowest-to-highest. Lowest net wins.

This is always a secondary/tertiary game so results are returned as data
rather than persisted to a separate model. Use low_net_round_summary() for
display and low_net_round_standings() for raw data.

Public API
~~~~~~~~~~
    standings = low_net_round_standings(round_obj)
    summary   = low_net_round_summary(round_obj)
"""

from scoring.models import HoleScore


def low_net_round_standings(round_obj) -> list:
    """
    Calculate net totals for all real players in the round.

    Returns a list of dicts ordered by net total (lowest first), with ties
    sharing the same rank:
        {
            'rank'      : int,
            'player'    : Player,
            'net_total' : int,
            'holes_played': int,   # for partial rounds
        }
    """
    from django.db.models import Sum, Count

    rows = (
        HoleScore.objects
        .filter(
            foursome__round    = round_obj,
            player__is_phantom = False,
        )
        .exclude(net_score=None)
        .values('player_id', 'player__name')
        .annotate(
            net_total    = Sum('net_score'),
            holes_played = Count('hole_number'),
        )
        .order_by('net_total')
    )

    standings = []
    rank = 1
    for i, row in enumerate(rows):
        if i > 0 and row['net_total'] > rows[i - 1]['net_total']:
            rank = i + 1
        standings.append({
            'rank'        : rank,
            'player_id'   : row['player_id'],
            'player_name' : row['player__name'],
            'net_total'   : row['net_total'],
            'holes_played': row['holes_played'],
        })

    return standings


def low_net_round_summary(round_obj) -> list:
    """
    Return ranked low-net results as a list of serializable dicts.

    Each dict:
        {
            'rank'        : int,
            'name'        : str  (player name),
            'total_net'   : int,
            'holes_played': int,
        }
    """
    # low_net_round_standings already returns primitive-only dicts
    # (player_id, player_name, net_total, holes_played) — just reshape.
    standings = low_net_round_standings(round_obj)
    return [
        {
            'rank'        : s['rank'],
            'name'        : s['player_name'],
            'total_net'   : s['net_total'],
            'holes_played': s['holes_played'],
        }
        for s in standings
    ]
