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
from scoring.models import HoleScore
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

    # Pull ball-lost events (the only rows ever written to PinkBallHoleResult
    # during normal play), keyed by foursome pk → first hole lost.
    ball_lost_hole: dict = {}
    for hr in (PinkBallHoleResult.objects
               .filter(round=round_obj, ball_lost=True)
               .order_by('hole_number')):
        if hr.foursome_id not in ball_lost_hole:
            ball_lost_hole[hr.foursome_id] = hr.hole_number

    # Build hole-par lookup so we can rank by net-to-par, not raw net total.
    # (Raw totals are meaningless across groups on different holes.)
    from tournament.models import FoursomeMembership
    first_mem = (FoursomeMembership.objects
                 .filter(foursome__round=round_obj,
                         player__is_phantom=False,
                         tee__isnull=False)
                 .select_related('tee')
                 .first())
    hole_pars: dict = {}
    if first_mem:
        for h in first_mem.tee.holes:
            hole_pars[h['number']] = h['par']

    # Determine each foursome's status — query HoleScore per foursome so we
    # avoid any cross-foursome key-collision issues.
    statuses = []
    for foursome in foursomes:
        order     = foursome.pink_ball_order or []  # list of player PKs, 0-indexed
        lost_hole = ball_lost_hole.get(foursome.pk)  # None = alive / survived
        max_hole  = lost_hole if lost_hole is not None else 18

        # Build (player_id, hole_number) → net_score map for this foursome.
        # net_score may be NULL when Django's update_or_create() persists only
        # gross/handicap columns, so fall back to computing it.
        scores: dict = {}
        for hs in (HoleScore.objects
                   .filter(foursome=foursome, gross_score__isnull=False)
                   .values('player_id', 'hole_number',
                           'gross_score', 'handicap_strokes', 'net_score')):
            gs  = hs['gross_score']
            hcp = hs['handicap_strokes'] or 0
            ns  = hs['net_score'] if hs['net_score'] is not None else (gs - hcp)
            scores[(hs['player_id'], hs['hole_number'])] = ns

        net_total    = 0
        par_total    = 0
        holes_played = 0
        for h in range(1, max_hole + 1):
            if not order:
                break
            carrier_pk = order[(h - 1) % len(order)]
            ns = scores.get((carrier_pk, h))
            if ns is not None:
                net_total    += ns
                par_total    += hole_pars.get(h, 4)
                holes_played += 1
            elif lost_hole is None:
                # No score yet — don't count holes beyond what's been played.
                break

        statuses.append({
            'foursome'         : foursome,
            'eliminated_on'    : lost_hole,
            'total_net'        : net_total,
            'net_to_par'       : net_total - par_total,
            'holes_played'     : holes_played,
        })

    # Sort: survivors first, then by latest elimination hole.
    # Use net-to-par (not raw total) so groups on different holes compare fairly.
    # Ties broken by more holes played (further into the round = better position).
    def sort_key(s):
        if s['eliminated_on'] is None:
            return (0, s['net_to_par'], -s['holes_played'])
        else:
            return (1, -s['eliminated_on'], s['net_to_par'])

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
          'entry_fee'  : float,
          'payouts'    : [{'place': int, 'amount': float}, ...],
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
    # Round-level config (ball colour + entry_fee + payouts)
    try:
        config       = round_obj.pink_ball_config
        ball_color   = config.ball_color
        entry_fee    = float(config.entry_fee)
        payouts_list = config.payouts or []
    except PinkBallConfig.DoesNotExist:
        ball_color   = 'Pink'
        entry_fee    = 0.0
        payouts_list = []

    results = (
        PinkBallResult.objects
        .filter(round=round_obj)
        .select_related('foursome')
        .order_by('rank')
    )

    # Pool = entry_fee × number of real players in the round
    from tournament.models import FoursomeMembership
    num_players  = FoursomeMembership.objects.filter(
                       foursome__round=round_obj, player__is_phantom=False
                   ).count()
    pool         = round(entry_fee * num_players, 2)
    payouts_dict = {int(p['place']): float(p['amount']) for p in payouts_list}

    result_list = list(results)

    # Count groups at each paid rank so we can split tied payouts.
    count_at_rank = {}
    for r in result_list:
        if r.rank is not None and r.rank in payouts_dict:
            count_at_rank[r.rank] = count_at_rank.get(r.rank, 0) + 1

    def _payout_for(rank):
        if rank is None or rank not in payouts_dict:
            return 0.0
        n = count_at_rank.get(rank, 1)
        return round(payouts_dict[rank] / n, 2)

    # Build hole-par lookup from the first available member's tee.
    # All foursomes play the same course so one tee is sufficient for par.
    first_mem = (FoursomeMembership.objects
                 .filter(foursome__round=round_obj,
                         player__is_phantom=False,
                         tee__isnull=False)
                 .select_related('tee')
                 .first())
    hole_pars: dict = {}
    if first_mem:
        for h in first_mem.tee.holes:
            hole_pars[h['number']] = h['par']

    # Pre-load HoleScores (gross scored only) so we can compute net-to-par
    # and carrier net totals fresh — bypassing the stored total_net_score which
    # can be stale when Django's update_or_create() doesn't persist net_score.
    # Key: (foursome_id, player_id, hole_number) → net_score
    hs_lookup_summary: dict = {}
    for hs in (HoleScore.objects
               .filter(foursome__round=round_obj, gross_score__isnull=False)
               .values('foursome_id', 'player_id', 'hole_number',
                       'gross_score', 'handicap_strokes', 'net_score')):
        gs  = hs['gross_score']
        hcp = hs['handicap_strokes'] or 0
        ns  = hs['net_score'] if hs['net_score'] is not None else (gs - hcp)
        hs_lookup_summary[(hs['foursome_id'], hs['player_id'], hs['hole_number'])] = ns

    summary_rows = []
    for r in result_list:
        members = list(
            r.foursome.memberships.filter(player__is_phantom=False)
                                  .select_related('player')
                                  .order_by('player__name')
        )
        players   = ', '.join(m.player.name for m in members)
        n_players = len(members)
        status = (
            'Survived' if r.eliminated_on_hole is None
            else f'Lost on hole {r.eliminated_on_hole}'
        )

        # current_hole: highest hole where ALL non-phantom members of this
        # foursome have a gross score recorded.  PinkBallHoleResult rows are
        # only written when the ball is lost, so we derive progress from the
        # regular HoleScore table instead.
        player_ids = [m.player_id for m in members]
        current_hole = None
        if player_ids:
            for h in range(18, 0, -1):
                scored_count = HoleScore.objects.filter(
                    foursome=r.foursome,
                    hole_number=h,
                    player_id__in=player_ids,
                    gross_score__isnull=False,
                ).count()
                if scored_count >= len(player_ids):
                    current_hole = h
                    break

        # net_to_par: carrier's cumulative (net_score − par) across played holes.
        # Computed fresh from HoleScore so it is always accurate regardless of
        # what is stored in PinkBallResult.total_net_score.
        # When hole_pars is empty (no tee set up) fall back to None.
        net_to_par    = None
        carrier_net   = None   # fresh total for display
        order_list    = r.foursome.pink_ball_order or []
        if hole_pars and order_list:
            holes_max = (r.eliminated_on_hole if r.eliminated_on_hole is not None
                         else (current_hole or 0))
            net_sum = 0
            par_sum = 0
            for h in range(1, holes_max + 1):
                carrier_pk = order_list[(h - 1) % len(order_list)]
                ns = hs_lookup_summary.get((r.foursome_id, carrier_pk, h))
                if ns is not None:
                    net_sum += ns
                    par_sum += hole_pars.get(h, 4)
            if par_sum > 0 or net_sum != 0:
                net_to_par  = net_sum - par_sum
                carrier_net = net_sum

        group_payout = _payout_for(r.rank)
        summary_rows.append({
            'rank'              : r.rank,
            'group_number'      : r.foursome.group_number,
            'players'           : players,
            'n_players'         : n_players,
            'status'            : status,
            'eliminated_on_hole': r.eliminated_on_hole,
            'current_hole'      : current_hole,
            # Use freshly-computed carrier_net in preference to the stored
            # total_net_score which can lag when net_score isn't persisted.
            'total_net_score'   : carrier_net if carrier_net is not None else r.total_net_score,
            'net_to_par'        : net_to_par,
            'payout'            : group_payout,
            'per_person_payout' : round(group_payout / n_players, 2) if n_players else 0.0,
        })

    return {
        'ball_color' : ball_color,
        'entry_fee'  : entry_fee,
        'payouts'    : payouts_list,
        'pool'       : pool,
        'results'    : summary_rows,
    }
