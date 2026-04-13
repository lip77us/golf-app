"""
services/skins.py
-----------------
Skins calculator — played within a foursome, net scores.

Rules
~~~~~
* Each hole is worth 1 skin (× round bet_unit in dollars).
* The player with the LOWEST net score on a hole wins that skin outright.
* If two or more players tie for the lowest net score, the hole is tied
  and the skin carries over to the next hole, accumulating until
  someone wins a hole outright.
* Phantom players are excluded from skins competition.
* Any skins still in the pot after hole 18 (final hole tied) go unclaimed.

Public API
~~~~~~~~~~
    results = calculate_skins(foursome)
    summary = skins_summary(foursome)
"""

from django.db import transaction

from scoring.models import HoleScore, SkinsResult


# ---------------------------------------------------------------------------
# Main calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_skins(foursome) -> list:
    """
    Calculate skins for *foursome* and persist SkinsResult rows.

    Can be called multiple times safely — previous results are deleted first,
    so it re-calculates correctly as scores are entered hole by hole.

    Parameters
    ----------
    foursome : tournament.models.Foursome

    Returns
    -------
    List of SkinsResult instances (saved), one per hole 1-18.
    Holes with no scores yet are skipped (not created).
    """
    # Pull all real-player net scores for this foursome in one query
    hole_scores = (
        HoleScore.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .exclude(net_score=None)
        .select_related('player')
        .order_by('hole_number')
    )

    # Index by hole number → list of HoleScore
    by_hole: dict = {}
    for hs in hole_scores:
        by_hole.setdefault(hs.hole_number, []).append(hs)

    # Wipe previous results
    SkinsResult.objects.filter(foursome=foursome).delete()

    pot      = 0   # skins accumulated (including current hole)
    to_save  = []

    for hole_number in range(1, 19):
        scores = by_hole.get(hole_number)
        if scores is None:
            # Score not yet entered — stop here (holes must be sequential)
            break

        pot += 1   # this hole adds 1 skin to the pot

        min_net = min(hs.net_score for hs in scores)
        leaders = [hs for hs in scores if hs.net_score == min_net]

        if len(leaders) == 1:
            # Outright winner — collects everything in the pot
            to_save.append(SkinsResult(
                foursome    = foursome,
                hole_number = hole_number,
                winner      = leaders[0].player,
                skins_value = pot,
                is_carryover= False,
            ))
            pot = 0   # reset after a win
        else:
            # Tied — record the tie and carry the pot forward
            to_save.append(SkinsResult(
                foursome    = foursome,
                hole_number = hole_number,
                winner      = None,
                skins_value = pot,
                is_carryover= True,
            ))
            # pot keeps accumulating

    SkinsResult.objects.bulk_create(to_save)
    return to_save

@transaction.atomic
def calculate_skins_no_carryover(foursome) -> list:
    """
    Calculate skins for *foursome* and persist SkinsResult rows.

    Can be called multiple times safely — previous results are deleted first,
    so it re-calculates correctly as scores are entered hole by hole.

    Parameters
    ----------
    foursome : tournament.models.Foursome

    Returns
    -------
    List of SkinsResult instances (saved), one per hole 1-18.
    Holes with no scores yet are skipped (not created).
    """
    # Pull all real-player net scores for this foursome in one query
    hole_scores = (
        HoleScore.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .exclude(net_score=None)
        .select_related('player')
        .order_by('hole_number')
    )

    # Index by hole number → list of HoleScore
    by_hole: dict = {}
    for hs in hole_scores:
        by_hole.setdefault(hs.hole_number, []).append(hs)

    # Wipe previous results
    SkinsResult.objects.filter(foursome=foursome).delete()

    pot      = 1   # skins accumulated (including current hole)
    to_save  = []

    for hole_number in range(1, 19):
        scores = by_hole.get(hole_number)
        if scores is None:
            # Score not yet entered — stop here (holes must be sequential)
            break


        min_net = min(hs.net_score for hs in scores)
        leaders = [hs for hs in scores if hs.net_score == min_net]

        if len(leaders) == 1:
            # Outright winner — collects everything in the pot
            to_save.append(SkinsResult(
                foursome    = foursome,
                hole_number = hole_number,
                winner      = leaders[0].player,
                skins_value = pot,
                is_carryover= False,
            ))
            pot = 0   # reset after a win
        else:
            # Tied — record the tie and carry the pot forward
            to_save.append(SkinsResult(
                foursome    = foursome,
                hole_number = hole_number,
                winner      = None,
                skins_value = pot,
                is_carryover= False,
            ))
            # pot keeps accumulating

    SkinsResultNoCarryover.objects.bulk_create(to_save)
    return to_save

# ---------------------------------------------------------------------------
# Summary helper
# ---------------------------------------------------------------------------

def skins_summary(foursome) -> list:
    """
    Return a list of dicts summarising skins won per player, sorted by
    skins won descending.

    Each dict:
        {
            'player'      : str (player name),
            'skins_won'   : int,
            'dollar_value': float  (skins_won × round.bet_unit),
        }

    Players with zero skins are included so the caller can render a
    complete leaderboard.
    """
    from decimal import Decimal
    from tournament.models import FoursomeMembership

    bet_unit = foursome.round.bet_unit

    # All real players in this foursome
    memberships = (
        FoursomeMembership.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .select_related('player')
    )

    # Tally wins from SkinsResult
    wins: dict = {m.player_id: 0 for m in memberships}
    for result in SkinsResult.objects.filter(foursome=foursome, winner__isnull=False):
        if result.winner_id in wins:
            wins[result.winner_id] += result.skins_value

    summary = []
    for m in memberships:
        skins = wins[m.player_id]
        summary.append({
            'player'      : m.player.name,
            'skins_won'   : skins,
            'dollar_value': float(Decimal(skins) * bet_unit),
        })

    summary.sort(key=lambda x: x['skins_won'], reverse=True)
    return summary
