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
    Split *players* into groups, filling foursomes first and placing
    trailing threesomes at the end so no group is ever smaller than 3.

    Examples
    --------
    8  players → [4, 4]
    9  players → [3, 3, 3]
    10 players → [4, 3, 3]
    11 players → [4, 4, 3]
    12 players → [4, 4, 4]
    13 players → [4, 3, 3, 3]
    14 players → [4, 4, 3, 3]
    15 players → [4, 4, 4, 3]

    Edge case (n=2 or n=5): no valid split avoids a group smaller than 3;
    falls back to even distribution.
    """
    n = len(players)
    if n == 0:
        return []

    rem = n % max_size
    if rem == 0:
        return [players[i : i + max_size] for i in range(0, n, max_size)]

    # trailing threesomes: rem=3→1, rem=2→2, rem=1→3
    trailing  = {3: 1, 2: 2, 1: 3}[rem]
    min_needed = trailing * 3  # minimum n for a clean split with no group < 3

    if n < min_needed:
        # Unavoidable edge case (n=2 or n=5): fall back to even distribution
        num_groups = math.ceil(n / max_size)
        base   = n // num_groups
        extras = n % num_groups
        groups, idx = [], 0
        for i in range(num_groups):
            size = base + (1 if i < extras else 0)
            groups.append(players[idx : idx + size])
            idx += size
        return groups

    fours = (n - trailing * 3) // max_size
    groups, idx = [], 0
    for _ in range(fours):
        groups.append(players[idx : idx + max_size])
        idx += max_size
    for _ in range(trailing):
        groups.append(players[idx : idx + 3])
        idx += 3
    return groups


def _pink_ball_order(real_player_ids: list, num_holes: int = 18) -> list:
    """
    Simple round-robin rotation: player i carries the pink ball on
    holes where (hole_index % len(players)) == i.

    Returns a list of length *num_holes* containing player PKs.
    """
    n = len(real_player_ids)
    return [real_player_ids[i % n] for i in range(num_holes)]


def _get_or_create_phantom(account) -> Player:
    """
    Return the shared phantom player for *account*, creating it if needed.

    Phantom is a per-account singleton — see the design note on Player in
    core/models.py.  We scope the lookup by account so the NOT NULL
    constraint on Player.account (added in core.0004_account_fk) is
    satisfied and tenants don't share a single global phantom row.

    Phantom players get a high handicap index so they receive strokes on
    every hole — their scores are filler (par+1) and don't affect payouts.
    """
    phantom, _ = Player.objects.get_or_create(
        is_phantom=True,
        account=account,
        defaults={
            'name'           : 'Phantom',
            'handicap_index' : 36.0,
        },
    )
    return phantom


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

from core.models import Tee

@transaction.atomic
def setup_round(
    round_obj,
    players: list,
    handicap_allowance: float = 1.0,
    randomise: bool = True,
) -> list:
    """
    Create Foursomes and FoursomeMemberships for *round_obj*.

    Parameters
    ----------
    round_obj          : tournament.models.Round instance
    players            : list of dicts.  Required keys per entry:
                            player_id (int), tee_id (int).
                         Optional:
                            group_number (int) — explicit group assignment.
                         If *any* entry has group_number, ALL entries must;
                         we then build foursomes by group_number (1..N) and
                         skip the automatic 4-then-3 partition.  Groups can
                         be size 1–4, and groups smaller than 4 do NOT get
                         a phantom player (single-player groups are valid
                         for multi-foursome skins where each golfer keeps
                         their own card).
    handicap_allowance : fraction of course handicap applied as playing
                         handicap — 1.0 = full, 0.9 = 90 %, etc.
    randomise          : shuffle players before grouping (default True).
                         Ignored when explicit group_numbers are supplied.

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
    player_ids = [p['player_id'] for p in players]

    # Using filter does not preserve order, so we fetch and then sort them back
    # to the order requested in `player_ids`. This ensures Player 1 is preserved.
    fetched_objs = list(Player.objects.filter(pk__in=player_ids, is_phantom=False))
    obj_map = {p.id: p for p in fetched_objs}

    player_objs = [obj_map[pid] for pid in player_ids if pid in obj_map]

    if not player_objs:
        raise ValueError("No valid (non-phantom) players found for the supplied IDs.")

    tee_map = {p['player_id']: Tee.objects.get(pk=p['tee_id']) for p in players}

    # Detect explicit-grouping mode.  If any caller-supplied entry has a
    # group_number, every entry must — and we group by that instead of
    # using _group_players.
    explicit_groups = any('group_number' in p for p in players)
    if explicit_groups:
        missing = [p['player_id'] for p in players if 'group_number' not in p]
        if missing:
            raise ValueError(
                f"group_number is required for every player when any are "
                f"supplied; missing for {missing}"
            )
        group_map: dict = {}
        for p in players:
            pid = p['player_id']
            if pid in obj_map:
                group_map.setdefault(int(p['group_number']), []).append(
                    obj_map[pid]
                )
        # 1..N in order; empty group numbers between filled ones are fine
        # (we just don't create them).
        groups = [group_map[k] for k in sorted(group_map.keys())]
        for g in groups:
            if not (1 <= len(g) <= 4):
                raise ValueError(
                    f"Each group must have 1–4 players (got {len(g)})."
                )
    else:
        if randomise:
            # If randomise is true, we shuffle everything EXCEPT the first
            # player so the logged-in user remains player 1.
            if len(player_objs) > 1:
                first = player_objs[0]
                rest = player_objs[1:]
                random.shuffle(rest)
                player_objs = [first] + rest

        groups = _group_players(player_objs, max_size=4)

    # Wipe any previous setup for this round so re-running is safe
    Foursome.objects.filter(round=round_obj).delete()
    phantom = None
    created = []

    # Phantom padding is a tournament-only convenience for games that
    # require exactly 4 players (Pink Ball, Sixes, etc.).  Casual rounds
    # — with no parent Tournament — should always honour the user's
    # actual roster: a 3-player Stroke Play or Points 5-3-1 game would
    # be distorted by a phantom 4th.
    is_tournament_round = round_obj.tournament_id is not None

    for group_number, group in enumerate(groups, start=1):
        # Explicit groups can be any size 1–4 and DON'T get a phantom
        # (single-player and 2-player groups in multi-foursome skins are
        # valid; padding would distort the skins pool).  Tournament
        # auto-grouped foursomes keep the existing phantom-pad-to-4
        # behaviour; casual rounds never pad.
        needs_phantom = (
            not explicit_groups
            and is_tournament_round
            and len(group) < 4
        )

        if needs_phantom and phantom is None:
            phantom = _get_or_create_phantom(round_obj.account)

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
            tee = tee_map[player.id]
            course_hcp  = player.course_handicap(tee)
            playing_hcp = round(course_hcp * handicap_allowance)
            FoursomeMembership.objects.create(
                foursome        = foursome,
                player          = player,
                tee             = tee,
                course_handicap = course_hcp,
                playing_handicap= playing_hcp
            )

        # Phantom membership — always full handicap (36 strokes)
        if needs_phantom:
            # Pick a default tee from the first real player for the phantom
            phantom_tee = tee_map[group[0].id]
            FoursomeMembership.objects.create(
                foursome         = foursome,
                player           = phantom,
                tee              = phantom_tee,
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

    tee     = membership.tee
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
