"""
services/round_setup.py
-----------------------
Handles everything needed to go from "we have a list of players" to
"the round is fully configured and ready for score entry".

Public API
~~~~~~~~~~
    foursomes = setup_round(round_obj, player_ids)
    create_phantom_hole_scores(foursome)

Typical call sequence
~~~~~~~~~~~~~~~~~~~~~
    from services.round_setup import setup_round, create_phantom_hole_scores

    foursomes = setup_round(round_obj, player_ids, handicap_allowance=1.0)
    for fs in foursomes:
        if fs.has_phantom:
            create_phantom_hole_scores(fs)
"""

import math
import random

from django.db import transaction

from core.models import Player
from tournament.models import Foursome, FoursomeMembership


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _group_players(players: list, max_size: int = 4) -> list:
    """
    Split *players* into groups as evenly as possible, each group no
    larger than *max_size*.

    Examples
    --------
    8 players → [4, 4]
    9 players → [3, 3, 3]
    7 players → [4, 3]
    5 players → [3, 2]
    """
    n = len(players)
    if n == 0:
        return []
    num_groups = math.ceil(n / max_size)
    base       = n // num_groups
    extras     = n % num_groups   # first `extras` groups get one extra player

    groups, idx = [], 0
    for i in range(num_groups):
        size = base + (1 if i < extras else 0)
        groups.append(players[idx : idx + size])
        idx += size
    return groups


def _pink_ball_order(real_player_ids: list, num_holes: int = 18) -> list:
    """
    Simple round-robin rotation: player i carries the pink ball on
    holes where (hole_index % len(players)) == i.

    Returns a list of length *num_holes* containing player PKs.
    """
    n = len(real_player_ids)
    return [real_player_ids[i % n] for i in range(num_holes)]


def _get_or_create_phantom() -> Player:
    """
    Return the single shared phantom player, creating it if necessary.
    Phantom players get a high handicap index so they receive strokes on
    every hole — their scores are filler (par+1) and don't affect payouts.
    """
    phantom, _ = Player.objects.get_or_create(
        is_phantom=True,
        defaults={
            'name'           : 'Phantom',
            'handicap_index' : 36.0,
        },
    )
    return phantom


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_round(
    round_obj,
    player_ids: list,
    handicap_allowance: float = 1.0,
    randomise: bool = True,
) -> list:
    """
    Create Foursomes and FoursomeMemberships for *round_obj*.

    Parameters
    ----------
    round_obj          : tournament.models.Round instance
    player_ids         : list of Player PKs to include (phantoms excluded)
    handicap_allowance : fraction of course handicap applied as playing
                         handicap — 1.0 = full, 0.9 = 90 %, etc.
    randomise          : shuffle players before grouping (default True)

    Returns
    -------
    List of created Foursome instances, ordered by group_number.

    Notes
    -----
    * Any existing Foursomes/Memberships for this Round are deleted first
      so the function is safely re-callable if you need to redo the draw.
    * Phantom hole scores are NOT created here — call
      create_phantom_hole_scores(foursome) separately after this returns.
    """
    tee     = round_obj.course
    players = list(Player.objects.filter(pk__in=player_ids, is_phantom=False))

    if not players:
        raise ValueError("No valid (non-phantom) players found for the supplied IDs.")

    if randomise:
        random.shuffle(players)

    # Wipe any previous setup for this round so re-running is safe
    Foursome.objects.filter(round=round_obj).delete()

    groups  = _group_players(players, max_size=4)
    phantom = None
    created = []

    for group_number, group in enumerate(groups, start=1):
        needs_phantom = len(group) < 4   # pad any group smaller than 4

        if needs_phantom and phantom is None:
            phantom = _get_or_create_phantom()

        real_ids   = [p.pk for p in group]
        pink_order = _pink_ball_order(real_ids)

        foursome = Foursome.objects.create(
            round           = round_obj,
            group_number    = group_number,
            pink_ball_order = pink_order,
            has_phantom     = needs_phantom,
        )

        # Real player memberships
        for player in group:
            course_hcp  = player.course_handicap(tee)
            playing_hcp = round(course_hcp * handicap_allowance)
            FoursomeMembership.objects.create(
                foursome        = foursome,
                player          = player,
                course_handicap = course_hcp,
                playing_handicap= playing_hcp
            )

        # Phantom membership — always full handicap (36 strokes)
        if needs_phantom:
            FoursomeMembership.objects.create(
                foursome         = foursome,
                player           = phantom,
                course_handicap  = 36,
                playing_handicap = 36,
            )

        created.append(foursome)

    return created


def create_phantom_hole_scores(foursome) -> None:
    """
    Pre-populate HoleScore rows for the phantom player in *foursome*.

    Phantom gross score = hole par + 1 (bogey) on every hole.
    Net score and Stableford points are auto-calculated by HoleScore.save().

    Safe to call multiple times — existing phantom scores are deleted first.
    """
    from scoring.models import HoleScore   # local import avoids circular deps

    if not foursome.has_phantom:
        return

    membership = (
        foursome.memberships
        .filter(player__is_phantom=True)
        .select_related('player')
        .first()
    )
    if not membership:
        return

    tee     = foursome.round.course
    phantom = membership.player

    # Clear any previously created phantom scores for this foursome
    HoleScore.objects.filter(foursome=foursome, player=phantom).delete()

    for hole_data in tee.holes:
        hole_number = hole_data['number']
        hole_par    = hole_data['par']
        stroke_idx  = hole_data['stroke_index']

        gross   = hole_par + 1   # bogey
        strokes = membership.handicap_strokes_on_hole(stroke_idx)

        HoleScore.objects.create(
            foursome         = foursome,
            player           = phantom,
            hole_number      = hole_number,
            gross_score      = gross,
            handicap_strokes = strokes,
            # net_score + stableford_points auto-calculated in HoleScore.save()
        )
