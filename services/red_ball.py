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

Ranking — by SURVIVAL, not by score
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The last group still holding the ball wins, so ball status IS the ranking:

1. Still alive at 18 — top of the board. If more than one survives, the
   **ball's own net** separates them: the carrier's net against par, not a
   four-man aggregate, because the ball is what the group was protecting.
2. Lost — ranked by the hole the ball died on, **latest first**. Lost on 14
   beats lost on 6 no matter how either group scored.

Ball net is therefore shown only for groups still alive. A ball lost on 5
covers four holes and a ball that survives covers eighteen, so printing both
in one column would rank the worst group best; an eliminated group reads a
dash on the board and its real total stays on its card.

Tied groups SHARE a rank and split the money for the places they occupy —
there is no countback anywhere in this spec.

See docs/design-review/handoff-individual-play/SPEC.md §6.

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

    # Survival first, and only then score. Net-to-par (not the raw total) so
    # groups on different holes compare fairly; among the eliminated, the
    # LATEST death wins, and net is the tiebreak within a single hole.
    def sort_key(s):
        if s['eliminated_on'] is None:
            return (0, s['net_to_par'], -s['holes_played'])
        return (1, -s['eliminated_on'], s['net_to_par'])

    statuses.sort(key=sort_key)

    # Groups that cannot be separated share a rank and split the places they
    # occupy — no countback. Two survivors on the same ball net are level; two
    # groups that lost it on the same hole are level unless their ball nets
    # differ.
    def tie_key(s):
        if s['eliminated_on'] is None:
            return (0, s['net_to_par'])
        return (1, -s['eliminated_on'], s['net_to_par'])

    shared_rank = []
    rank = 1
    for i, s in enumerate(statuses):
        if i > 0 and tie_key(s) != tie_key(statuses[i - 1]):
            rank = i + 1
        shared_rank.append(rank)

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
    for rank, status in zip(shared_rank, statuses):
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
          'game_name'  : str,     # what the TD called it — every surface reads this
          'entry_fee'  : float,
          'payouts'    : [{'place': int, 'amount': float}, ...],
          'pool'       : float,
          'results'    : [
              {
                'rank'           : int,
                'group_number'   : int,
                'players'        : str,
                'status'         : str,   # 'Survived' | 'Lost on hole N'
                'alive'          : bool,
                'carrier'        : str | None,   # who has it, and on which hole
                'carrier_hole'   : int | None,
                'ball_net_to_par': int | None,   # None once the ball is gone
                'payout'         : float,
              }, ...
          ]
        }
    """
    # Round-level config (the TD's name for the game + entry_fee + payouts)
    try:
        config       = round_obj.pink_ball_config
        game_name    = config.display_name
        entry_fee    = float(config.entry_fee)
        payouts_list = config.payouts or []
    except PinkBallConfig.DoesNotExist:
        game_name    = 'Pink Ball'
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

    result_list = list(results)

    # Tied groups split the money for the PLACES THEY OCCUPY, not a halved
    # single place — see services/payout.py. No countback.
    from services.payout import (payouts_by_place, per_person_share,
                                 split_tied_places)
    rank_payout = split_tied_places(
        payouts_by_place(payouts_list), [r.rank for r in result_list])

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
        players       = ', '.join(m.player.name for m in members)
        short_names   = ' / '.join(m.player.short_name or m.player.name
                                   for m in members)
        n_players = len(members)

        # When the ball is lost, identify the carrier at the moment of
        # loss so the spectator page can read "Lost by RyanL" instead of
        # a generic hole number.
        order_list_for_lost = r.foursome.pink_ball_order or []
        lost_by_short_name  = None
        if r.eliminated_on_hole is not None and order_list_for_lost:
            carrier_pk = order_list_for_lost[
                (r.eliminated_on_hole - 1) % len(order_list_for_lost)
            ]
            for m in members:
                if m.player_id == carrier_pk:
                    lost_by_short_name = (
                        m.player.short_name or m.player.name
                    )
                    break

        if r.eliminated_on_hole is None:
            status = 'Survived'
        elif lost_by_short_name:
            status = f'Lost by {lost_by_short_name}'
        else:
            status = f'Lost on hole {r.eliminated_on_hole}'

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

        # Who has the ball right now, and on which hole. Anyone not in that
        # group is otherwise watching a number with no story.
        alive        = r.eliminated_on_hole is None
        carrier      = None
        carrier_hole = None
        if alive and order_list:
            carrier_hole = min((current_hole or 0) + 1, 18)
            carrier_pk   = order_list[(carrier_hole - 1) % len(order_list)]
            carrier = next((m.player.name for m in members
                            if m.player_id == carrier_pk), None)

        group_payout = rank_payout.get(r.rank, 0.0)
        # `display_thru` is what spectator pages render in the Thru
        # column.  After the ball is lost, freeze at the elimination
        # hole so the row reads e.g. "Thru 8 · Lost by RyanL" instead
        # of advancing along with later side-game scoring.
        display_thru = (
            r.eliminated_on_hole
            if r.eliminated_on_hole is not None
            else current_hole
        )
        summary_rows.append({
            'rank'              : r.rank,
            'group_number'      : r.foursome.group_number,
            'players'           : players,
            'short_names'       : short_names,
            'n_players'         : n_players,
            'status'            : status,
            'alive'             : alive,
            'carrier'           : carrier,
            'carrier_hole'      : carrier_hole,
            'lost_by'           : lost_by_short_name,
            'eliminated_on_hole': r.eliminated_on_hole,
            'current_hole'      : current_hole,
            'display_thru'      : display_thru,
            # Use freshly-computed carrier_net in preference to the stored
            # total_net_score which can lag when net_score isn't persisted.
            'total_net_score'   : carrier_net if carrier_net is not None else r.total_net_score,
            'net_to_par'        : net_to_par,
            # The RANKING column. Shown only while the ball is alive: a ball
            # lost on 5 covers four holes and a ball that survives covers
            # eighteen, so putting both in one column would rank the worst
            # group best. An eliminated group reads a dash; its real total is
            # still on the card above.
            'ball_net_to_par'   : net_to_par if alive else None,
            'payout'            : group_payout,
            # The place pays the GROUP and splits among its real golfers — the
            # borrowed 4th is not a person and cannot be paid.
            'per_person_payout' : per_person_share(group_payout, n_players),
            'split_ways'        : n_players,
        })

    return {
        'game_name'  : game_name,
        'entry_fee'  : entry_fee,
        'payouts'    : payouts_list,
        'pool'       : pool,
        'results'    : summary_rows,
    }
