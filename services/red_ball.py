"""
services/red_ball.py
--------------------
Red Ball / Pink Ball survivor pool calculator.

Rules
~~~~~
* Each foursome carries one physical red ball for the round.
* The ball rotates through the players on a fixed schedule stored in
  Foursome.pink_ball_order (a list of player PKs).
* If the designated player loses the physical ball on their hole
  (OB, water, unplayable and not recovered), that foursome is eliminated.
* The last foursome with the ball survives and wins.

The rotation follows POSITION IN THE ROUND, not hole number
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Ruled 25 Sep 2026. The first golfer in ``pink_ball_order`` carries the ball on
the group's FIRST TEE, whichever hole that is — so a shotgun group off the 13th
has him on the 13th, not on the 1st.

This module read ``order[(hole_number - 1) % len(order)]`` throughout, which is
the same thing only when the round starts on the 1st. Off a shotgun start it
handed the ball to the wrong golfer on every hole, and since the carrier's net
IS the ball's score, the group was ranked on scores nobody shot.

Everything downstream follows from the same correction, because every one of
these questions is about position and none of them is about a hole number:

* which holes the ball has covered (walk the play order, not ``range(1, 19)``);
* where the round ENDS (the last hole in play order, not hole 18);
* **latest death wins** — later in the group's own round, so a ball lost on the
  3rd played 16th beats one lost on the 15th played 3rd;
* the ball stops counting at the position it died, not at every hole numbered
  below it;
* ``thru`` is a COUNT of holes played (RULINGS §9), which on a shotgun is not
  the number of the hole just finished.

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
from services.hole_plan import play_order
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Position, not hole number
# ---------------------------------------------------------------------------

def carrier_at(order: list, position: int):
    """The player PK carrying the ball at 0-based ``position`` in the round.

    The ONE place the rotation rule lives. ``order`` is usually as long as the
    round, but the modulo is kept so a short order (or a re-drawn one) still
    rotates rather than raising.
    """
    return order[position % len(order)] if order else None


def carrier_on_hole(order: list, holes: list, hole_number: int):
    """The carrier on ``hole_number``, resolved through the group's play order.

    Returns None when the hole is not one the group plays — better than the old
    arithmetic, which silently answered for a hole outside the round.
    """
    if hole_number not in holes:
        return None
    return carrier_at(order, holes.index(hole_number))


# ---------------------------------------------------------------------------
# Record a single hole
# ---------------------------------------------------------------------------

def record_hole(round_obj, foursome, hole_number: int,
                net_score: int | None, ball_lost: bool = False) -> PinkBallHoleResult:
    """
    Create or update the PinkBallHoleResult for one foursome on one hole.

    Automatically identifies the designated player from
    Foursome.pink_ball_order by the hole's POSITION in this group's play order
    — index 0 is the group's first tee, which on a shotgun is not hole 1.

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

    holes = play_order(round_obj, foursome)
    player_pk = carrier_on_hole(order, holes, hole_number)
    if player_pk is None:
        raise ValueError(
            f"Hole {hole_number} is not in {foursome}'s play order {holes}.")

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
        order     = foursome.pink_ball_order or []  # player PKs, by POSITION
        holes     = play_order(round_obj, foursome)
        lost_hole = ball_lost_hole.get(foursome.pk)  # None = alive / survived
        # **How far the ball got, counted in POSITIONS.** The ball stops at the
        # hole it died on, and "the holes before it" means earlier in this
        # group's round — not every hole with a smaller number. Off the 13th a
        # ball lost on the 2nd has covered seven holes, and `range(1, 3)` would
        # have counted two.
        lost_pos  = holes.index(lost_hole) if lost_hole in holes else None
        last_pos  = lost_pos if lost_pos is not None else len(holes) - 1

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
        for pos in range(last_pos + 1):
            if not order:
                break
            h = holes[pos]
            carrier_pk = carrier_at(order, pos)
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
            # The POSITION it died at, which is what "latest death" compares.
            # Kept beside the hole number rather than replacing it: the hole
            # number is what a golfer is told, the position is what ranks him.
            'eliminated_at_pos': lost_pos,
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
        # By POSITION, not by hole number: off a shotgun the 3rd can be the
        # 16th hole played, and a ball carried that far beat one lost on the
        # 15th three holes in.
        return (1, -(s['eliminated_at_pos'] or 0), s['net_to_par'])

    statuses.sort(key=sort_key)

    # Groups that cannot be separated share a rank and split the places they
    # occupy — no countback. Two survivors on the same ball net are level; two
    # groups that lost it on the same hole are level unless their ball nets
    # differ.
    def tie_key(s):
        if s['eliminated_on'] is None:
            return (0, s['net_to_par'])
        return (1, -(s['eliminated_at_pos'] or 0), s['net_to_par'])

    shared_rank = []
    rank = 1
    for i, s in enumerate(statuses):
        if i > 0 and tie_key(s) != tie_key(statuses[i - 1]):
            rank = i + 1
        shared_rank.append(rank)

    # Mark the winner's last hole result
    PinkBallHoleResult.objects.filter(round=round_obj, is_winner=True).update(is_winner=False)
    if statuses and statuses[0]['eliminated_on'] is None:
        # Winner survived — mark their LAST hole, which is the last one in their
        # own play order. Hardcoding 18 marked nothing on a back-nine round and
        # the wrong hole on a shotgun.
        winner_fs = statuses[0]['foursome']
        winner_holes = play_order(round_obj, winner_fs)
        if winner_holes:
            (PinkBallHoleResult.objects
             .filter(round=round_obj, foursome=winner_fs,
                     hole_number=winner_holes[-1])
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
        fs_holes            = play_order(round_obj, r.foursome)
        lost_by_short_name  = None
        if r.eliminated_on_hole is not None and order_list_for_lost:
            carrier_pk = carrier_on_hole(
                order_list_for_lost, fs_holes, r.eliminated_on_hole)
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
        # **Walked BACKWARDS ALONG THE PLAY ORDER**, not down from 18. The last
        # hole a group finished is the last one in its own sequence; off the
        # 13th the highest NUMBER it has scored is 18 after six holes, which
        # reads as a round almost done.
        player_ids   = [m.player_id for m in members]
        current_hole = None
        current_pos  = None          # 0-based; None = nothing complete yet
        if player_ids:
            for pos in range(len(fs_holes) - 1, -1, -1):
                h = fs_holes[pos]
                scored_count = HoleScore.objects.filter(
                    foursome=r.foursome,
                    hole_number=h,
                    player_id__in=player_ids,
                    gross_score__isnull=False,
                ).count()
                if scored_count >= len(player_ids):
                    current_hole = h
                    current_pos  = pos
                    break

        # net_to_par: carrier's cumulative (net_score − par) across played holes.
        # Computed fresh from HoleScore so it is always accurate regardless of
        # what is stored in PinkBallResult.total_net_score.
        # When hole_pars is empty (no tee set up) fall back to None.
        net_to_par    = None
        carrier_net   = None   # fresh total for display
        order_list    = r.foursome.pink_ball_order or []
        if hole_pars and order_list:
            # In POSITIONS, like the calculator: how far the ball got in this
            # group's own round.
            if r.eliminated_on_hole is not None and r.eliminated_on_hole in fs_holes:
                last_pos = fs_holes.index(r.eliminated_on_hole)
            else:
                last_pos = current_pos if current_pos is not None else -1
            net_sum = 0
            par_sum = 0
            for pos in range(last_pos + 1):
                h = fs_holes[pos]
                carrier_pk = carrier_at(order_list, pos)
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
        if alive and order_list and fs_holes:
            # The NEXT hole in the group's own order — and it stays on the last
            # one when the round is done rather than inventing a 19th.
            next_pos     = min((current_pos + 1) if current_pos is not None else 0,
                               len(fs_holes) - 1)
            carrier_hole = fs_holes[next_pos]
            carrier_pk   = carrier_at(order_list, next_pos)
            carrier = next((m.player.name for m in members
                            if m.player_id == carrier_pk), None)

        group_payout = rank_payout.get(r.rank, 0.0)
        # `display_thru` is what spectator pages render in the Thru
        # column.  After the ball is lost, freeze at the elimination
        # hole so the row reads e.g. "Thru 8 · Lost by RyanL" instead
        # of advancing along with later side-game scoring.
        #
        # **A COUNT of holes played, not a hole number** (RULINGS §9). The two
        # are the same integer on a round starting on the 1st, which is why this
        # read as a hole number for so long; off the 13th a group six holes in
        # has scored up to hole 18 and the column said `Thru 18`.
        if r.eliminated_on_hole is not None and r.eliminated_on_hole in fs_holes:
            display_thru = fs_holes.index(r.eliminated_on_hole) + 1
        elif r.eliminated_on_hole is not None:
            display_thru = None       # a hole this group does not play
        else:
            display_thru = (current_pos + 1) if current_pos is not None else None
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
