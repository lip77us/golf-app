"""
services/red_ball.py
--------------------
Red Ball / Pink Ball survivor pool calculator.

Rules
~~~~~
* Each foursome carries one physical red ball for the round.
* The ball rotates through the players on a fixed schedule stored in
  Foursome.pink_ball_order (a list of player PKs, one per hole).
* If the designated player loses the physical ball on their hole
  (OB, water, unplayable and not recovered), that foursome is eliminated.
* The last foursome with the ball survives and wins.

Ranking
~~~~~~~
1. Survivors (ball intact after hole 18) — ranked by lowest cumulative
   net score across all 18 holes.
2. Eliminated foursomes — ranked by which hole they were eliminated on
   (later hole = better finish). Ties on elimination hole broken by
   lower cumulative net score up to and including that hole.

Public API
~~~~~~~~~~
    # Record scores / ball-lost status hole by hole:
    record_hole(round_obj, foursome, hole_number, net_score, ball_lost=False)

    # Recalculate standings after any update:
    results = calculate_red_ball(round_obj)

    # Formatted summary:
    summary = red_ball_summary(round_obj)
"""

from django.db import transaction

from games.models import PinkBallConfig, PinkBallHoleResult, PinkBallResult
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Record a single hole
# ---------------------------------------------------------------------------

def record_hole(round_obj, foursome, hole_number: int,
                net_score: int | None, ball_lost: bool = False) -> PinkBallHoleResult:
    """
    Create or update the PinkBallHoleResult for one foursome on one hole.

    Automatically identifies the designated player from
    Foursome.pink_ball_order (0-indexed list → hole 1 = index 0).

    Parameters
    ----------
    round_obj   : Round
    foursome    : Foursome
    hole_number : 1–18
    net_score   : the designated player's net score, or None if ball lost
    ball_lost   : True if the physical ball was lost on this hole

    Returns the saved PinkBallHoleResult instance.
    """
    order = foursome.pink_ball_order   # list of player PKs
    if not order:
        raise ValueError(f"Foursome {foursome} has no pink_ball_order set.")

    player_pk = order[(hole_number - 1) % len(order)]

    result, _ = PinkBallHoleResult.objects.update_or_create(
        round       = round_obj,
        foursome    = foursome,
        hole_number = hole_number,
        defaults    = {
            'pink_ball_player_id': player_pk,
            'net_score'          : net_score,
            'ball_lost'          : ball_lost,
            'is_winner'          : False,   # recalculated in calculate_red_ball
        },
    )
    return result


# ---------------------------------------------------------------------------
# Main calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_red_ball(round_obj) -> list:
    """
    Recalculate PinkBallResult standings for the entire round.

    Safe to call after each hole is recorded — previous PinkBallResult rows
    are replaced on every call.

    Returns a list of PinkBallResult instances ordered by rank.
    """
    foursomes = list(
        Foursome.objects.filter(round=round_obj).order_by('group_number')
    )

    # Pull all hole results for this round, keyed by foursome pk
    hole_results: dict = {fs.pk: [] for fs in foursomes}
    for hr in (PinkBallHoleResult.objects
               .filter(round=round_obj)
               .order_by('hole_number')):
        if hr.foursome_id in hole_results:
            hole_results[hr.foursome_id].append(hr)

    # Determine each foursome's status
    statuses = []
    for foursome in foursomes:
        results    = hole_results[foursome.pk]
        lost_hole  = None
        net_total  = 0

        for hr in results:
            if hr.net_score is not None:
                net_total += hr.net_score
            if hr.ball_lost and lost_hole is None:
                lost_hole = hr.hole_number
                break   # stop counting net after elimination

        statuses.append({
            'foursome'         : foursome,
            'eliminated_on'    : lost_hole,       # None = still alive / survived
            'total_net'        : net_total,
        })

    # Sort: survivors first (eliminated_on=None), then by latest elimination,
    # then by lower net as tiebreaker.
    def sort_key(s):
        if s['eliminated_on'] is None:
            # Survivor: primary = 0 (beats all eliminated), secondary = net score
            return (0, s['total_net'])
        else:
            # Eliminated: primary = hole lost (negated so later = better rank)
            return (1, -s['eliminated_on'], s['total_net'])

    statuses.sort(key=sort_key)

    # Mark the winner's last hole result
    PinkBallHoleResult.objects.filter(round=round_obj, is_winner=True).update(is_winner=False)
    if statuses and statuses[0]['eliminated_on'] is None:
        # Winner survived — mark their hole 18 result
        winner_fs = statuses[0]['foursome']
        (PinkBallHoleResult.objects
         .filter(round=round_obj, foursome=winner_fs, hole_number=18)
         .update(is_winner=True))

    # Persist PinkBallResult rows
    PinkBallResult.objects.filter(round=round_obj).delete()
    saved = []
    for rank, status in enumerate(statuses, start=1):
        pbr = PinkBallResult.objects.create(
            round              = round_obj,
            foursome           = status['foursome'],
            eliminated_on_hole = status['eliminated_on'],
            total_net_score    = status['total_net'],
            rank               = rank,
        )
        saved.append(pbr)

    return saved


# ---------------------------------------------------------------------------
# Summary helper
# ---------------------------------------------------------------------------

def red_ball_summary(round_obj) -> dict:
    """
    Return a serialisable dict:
        {
          'ball_color' : str,
          'bet_unit'   : float,
          'pool'       : float,
          'results'    : [
              {
                'rank'           : int,
                'group_number'   : int,
                'players'        : str,
                'status'         : str,   # 'Survived' | 'Lost on hole N'
                'total_net_score': int | None,
                'payout'         : float,
              }, ...
          ]
        }
    """
    # Round-level config (ball colour + bet unit + places paid)
    try:
        config      = round_obj.pink_ball_config
        ball_color  = config.ball_color
        bet_unit    = float(config.bet_unit)
        places_paid = config.places_paid
    except PinkBallConfig.DoesNotExist:
        ball_color  = 'Pink'
        bet_unit    = 0.0
        places_paid = 1

    results = (
        PinkBallResult.objects
        .filter(round=round_obj)
        .select_related('foursome')
        .order_by('rank')
    )

    # Pool = bet_unit × number of foursomes in the round
    num_groups = Foursome.objects.filter(round=round_obj).count()
    pool       = round(bet_unit * num_groups, 2)

    # Split pool equally among paid places; within each place, split among tied groups.
    # pot_per_place = pool / places_paid (integer-limited to actual paid places).
    result_list    = list(results)
    paid_ranks     = sorted(set(r.rank for r in result_list if r.rank is not None))[:places_paid]
    pot_per_place  = round(pool / places_paid, 2) if places_paid and pool else 0.0

    # Count groups at each paid rank so we can split pot_per_place among ties.
    count_at_rank  = {}
    for r in result_list:
        if r.rank in paid_ranks:
            count_at_rank[r.rank] = count_at_rank.get(r.rank, 0) + 1

    def _payout_for(rank):
        if rank not in paid_ranks:
            return 0.0
        n = count_at_rank.get(rank, 1)
        return round(pot_per_place / n, 2)

    summary_rows = []
    for r in result_list:
        players = ', '.join(
            m.player.name for m in
            r.foursome.memberships.filter(player__is_phantom=False)
                                  .select_related('player')
                                  .order_by('player__name')
        )
        status = (
            'Survived' if r.eliminated_on_hole is None
            else f'Lost on hole {r.eliminated_on_hole}'
        )
        summary_rows.append({
            'rank'            : r.rank,
            'group_number'    : r.foursome.group_number,
            'players'         : players,
            'status'          : status,
            'total_net_score' : r.total_net_score,
            'payout'          : _payout_for(r.rank),
        })

    return {
        'ball_color' : ball_color,
        'bet_unit'   : bet_unit,
        'places_paid': places_paid,
        'pool'       : pool,
        'results'    : summary_rows,
    }
