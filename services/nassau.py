"""
services/nassau.py
------------------
Nassau calculator — 9-9-18 fixed-team best-ball match play.

Rules
~~~~~
* Two fixed teams (1 or 2 players each) play all 18 holes.
* Three simultaneous bets each worth Round.bet_unit:
      Front 9   (holes  1–9)   — tied front = push
      Back 9    (holes 10–18)  — tied back  = push
      Overall   (holes  1–18)  — tied overall = push
* Scoring: best-ball per hole using per-player adjusted scores.
  Lower team best-ball wins the hole; equal = halved.
* Handicap modes: net (% allowance), gross, strokes_off_low.

Variants
~~~~~~~~
none         — standard Nassau (default)
tiebreak_2nd — when best balls are tied, compare 2nd best balls to decide
               the hole winner; useful for foursomes to eliminate pushes.
               2-player matches always halve ties (no 2nd ball available).
claremont    — adds a simultaneous 2-point-per-hole "bottom" bet running
               alongside the standard Nassau ("top") bet:
                 Bottom Point 1 = best ball  (same comparison as top)
                 Bottom Point 2 = 2nd best ball
               Bottom tracks its own F9/B9/Overall bets and its own independent
               auto-press series: fires at ±4 bottom-POINTS down in a nine
               ("2-down" = 2 holes equivalent = 4 pts, since 2 pts/hole).
               Manual presses (V1): apply to top only.

Press rules
~~~~~~~~~~~
* Press bets are worth NassauGame.press_unit (explicit dollar amount).
* press_mode controls which types of presses can occur:
    none   – no presses
    manual – losing team calls a press at any point; winning team must accept.
             Recorded via add_manual_press().  Top only (V1).
    auto   – automatic presses.  Top fires at ±2 holes-down; bottom (Claremont
             only) fires independently at ±4 bottom-points-down (= 2 holes equiv).
    both   – manual (top) AND auto (top + bottom) presses both active.
* Each press covers the remaining holes of the nine in which it fires.
* NassauPress.side distinguishes top ('top') from bottom ('bottom') presses.

Public API
~~~~~~~~~~
    game    = setup_nassau(foursome, team1_ids, team2_ids,
                           handicap_mode, net_percent, press_mode, press_unit,
                           variant)
    result  = calculate_nassau(foursome)
    summary = nassau_summary(foursome)
    press   = add_manual_press(foursome, start_hole)   # losing team calls top press
"""

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus, GameType
from games.models import NassauGame, NassauTeam, NassauHoleScore, NassauPress
from scoring.handicap import build_score_index, _strokes_on_hole
from scoring.models import HoleScore
from core.handicap_math import round_half_up


# ---------------------------------------------------------------------------
# Settlement helpers
# ---------------------------------------------------------------------------

def _clamp_to_cap(total: float, cap) -> float:
    """Clamp a 2-side net total to ±cap (the per-side loss cap).

    With only two sides every settlement model reduces to 'the loser pays the
    winner the difference', so the cap is just a symmetric clamp. ``cap=None``
    → unchanged. ``total`` is from team1's perspective (>0 = team1 collects).
    """
    if cap is None:
        return total
    c = abs(float(cap))
    return max(-c, min(c, total))


def _press_blocked_by_cap(game, concluded_net: float, nine_margin: int) -> bool:
    """True when the side that is DOWN on a nine (the one who would press) has
    already locked in losses ≥ the cap — so pressing would be a free option
    and must be blocked.

    Uses CONCLUDED bets only (the non-aggressive rule): a side is only cut off
    once its settled losses reach the cap, not on projected/live-nine position.
    ``concluded_net`` is team1's net from settled bets (>0 = team1 ahead);
    ``nine_margin`` > 0 = team1 up on this nine (team2 is down and presses),
    < 0 = team1 down (team1 presses).
    """
    if game.loss_cap is None or nine_margin == 0:
        return False
    down_side_loss = concluded_net if nine_margin > 0 else -concluded_net
    return down_side_loss >= float(game.loss_cap)


# ---------------------------------------------------------------------------
# Score index helpers
# ---------------------------------------------------------------------------

def _build_so_score_index(foursome, net_percent: int = 100) -> dict:
    """
    Strokes-Off-Low score index for Nassau.
    Lowest playing handicap plays to 0; each other player gets
    (own_phcp - low) strokes allocated by stroke index (SI).
    Mirrors the same helper in services/skins.py and services/points_531.py.

    SI comes from m.tee.hole(hole_num) — NOT from HoleScore (which stores
    no stroke_index column).

    For Four Ball phantoms (cross_foursome_rotation algorithm), the phantom
    IS included so their donated scores count towards best-ball, and each hole
    is scored as a real 4-some that includes THAT hole's rotating donor — the
    low (and everyone's strokes) recompute hole-by-hole.  See
    services/triple_cup._whs_so_net_index for the matching implementation.
    """
    # Determine whether this foursome has a cross-foursome phantom
    from scoring.phantom import CROSS_FOURSOME_ALGORITHM_ID
    has_cross_phantom = (
        foursome.has_phantom
        and foursome.memberships.filter(
            player__is_phantom=True,
            phantom_algorithm=CROSS_FOURSOME_ALGORITHM_ID,
        ).exists()
    )

    # Include phantom scores in gross index only for cross-foursome phantoms
    score_index = build_score_index(
        foursome,
        handicap_mode=HandicapMode.GROSS,
        include_phantom=has_cross_phantom,
    )

    real_memberships = list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player__is_phantom=False)
    )
    phantom_m = None
    if has_cross_phantom:
        phantom_m = foursome.memberships.filter(
            player__is_phantom=True
        ).select_related('player', 'tee').first()

    if not real_memberships and phantom_m is None:
        return score_index

    # Cross-foursome phantom (Four Ball): per-hole donor strokes-off.  The
    # phantom plays AS that hole's donor, so low = min(real low, donor index)
    # is recomputed each hole and EVERY player (incl. the phantom at the
    # donor's index) gets (index − low) strokes.
    if has_cross_phantom and phantom_m is not None:
        _apply_per_hole_donor_so(
            score_index, real_memberships, phantom_m, net_percent,
        )
        return score_index

    # ----- Standard strokes-off-low (no cross-foursome phantom) -----------
    # Lowest playing handicap plays to 0; everyone else gets (own − low)
    # strokes allocated by SI (full laps + remainder for very high deltas).
    phcps = [m.playing_handicap for m in real_memberships
             if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0

    for m in real_memberships:
        if m.tee_id is None:
            continue
        so = round_half_up(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
        if so <= 0:
            continue

        per_player = score_index.get(m.player_id)
        if not per_player:
            continue

        full_laps = so // 18
        remainder = so % 18

        for hole_num, score in list(per_player.items()):
            si      = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = full_laps + (1 if si <= remainder else 0)
            if strokes:
                per_player[hole_num] = score - strokes

    return score_index


def _apply_per_hole_donor_so(score_index, real_memberships, phantom_m,
                             net_percent: int) -> None:
    """Mutate *score_index* in place for a cross-foursome Four Ball phantom:
    recompute strokes-off treating the phantom as the rotating donor on each
    hole.  On hole h the 4-some is {real players, that hole's donor}; low =
    min(real low, donor index); every player gets (index − low) strokes by SI.

    Mirrors services/triple_cup._whs_so_net_index (kept in lock-step; a shared
    helper is the obvious future DRY).  Caps at two laps like that one — fine
    for any realistic handicap delta.
    """
    from scoring.phantom import get_algorithm
    algo = get_algorithm(phantom_m.phantom_algorithm)
    cfg  = phantom_m.phantom_config or {}

    real_hcps = [m.playing_handicap for m in real_memberships
                 if m.playing_handicap is not None]
    low_real = min(real_hcps) if real_hcps else 0

    def _strokes(eff_hcp, low, si):
        so = round_half_up(max(0, eff_hcp - low) * net_percent / 100)
        if si <= so:
            return 1 + (1 if si + 18 <= so else 0)
        return 0

    # Real players — per-hole low driven by that hole's donor index.
    for m in real_memberships:
        if m.tee_id is None:
            continue
        per_player = score_index.get(m.player_id)
        if not per_player:
            continue
        base_hcp = m.playing_handicap or 0
        for hole_num, score in list(per_player.items()):
            donor_hcp = algo.donor_handicap(hole_num, cfg)
            low = min(low_real, donor_hcp) if donor_hcp is not None else low_real
            si  = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = _strokes(base_hcp, low, si)
            if strokes:
                per_player[hole_num] = score - strokes

    # Phantom — plays AS the donor (its gross IS the donor's gross).
    if phantom_m.tee_id is not None:
        per_player = score_index.get(phantom_m.player_id)
        if per_player:
            for hole_num, score in list(per_player.items()):
                donor_hcp = algo.donor_handicap(hole_num, cfg)
                if donor_hcp is None:
                    continue
                low = min(low_real, donor_hcp)
                si  = phantom_m.tee.hole(hole_num).get('stroke_index', 18)
                strokes = _strokes(donor_hcp, low, si)
                if strokes:
                    per_player[hole_num] = score - strokes


def _is_cup_nassau(foursome) -> bool:
    """Return True when this foursome's Nassau is part of a Ryder/Bandon Cup round."""
    try:
        from tournament.models import RyderCupRoundConfig
        RyderCupRoundConfig.objects.get(round=foursome.round)
        return True
    except Exception:
        return False


TRIPLE_CHILD_SLUGS = ('triple_1', 'triple_2', 'triple_3')


def _pair_player_ids(game) -> list:
    """The two player ids of a 1v1 (Triple Nassau child) game — team1's player
    then team2's player."""
    out = []
    for t in game.teams.all().order_by('team_number'):
        ids = list(t.players.values_list('id', flat=True))
        if ids:
            out.append(ids[0])
    return out


def _build_pair_so_index(foursome, game) -> dict:
    """Strokes-Off index for a single 1v1 PAIR (a Triple Nassau child).

    The lower playing handicap of the TWO match players plays to 0; the higher
    gets the pairwise difference allocated on the lowest stroke indexes.  Unlike
    the field-wide `_build_so_score_index` (low = min over all three players),
    the low here is the pair's own low — so the same player can receive a
    different number of strokes in each of their two matches (e.g. 10 vs Paul but
    5 vs Dave), both starting at SI 1.
    """
    score_index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)
    pair_ids    = _pair_player_ids(game)
    memberships = list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player_id__in=pair_ids)
    )
    phcps = [m.playing_handicap for m in memberships
             if m.playing_handicap is not None]
    if not phcps:
        return score_index
    low = min(phcps)

    for m in memberships:
        if m.tee_id is None:
            continue
        so = round_half_up(max(0, (m.playing_handicap or 0) - low) * game.net_percent / 100)
        if so <= 0:
            continue
        per_player = score_index.get(m.player_id)
        if not per_player:
            continue
        full_laps = so // 18
        remainder = so % 18
        for hole_num, score in list(per_player.items()):
            si      = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = full_laps + (1 if si <= remainder else 0)
            if strokes:
                per_player[hole_num] = score - strokes
    return score_index


def _get_score_index(foursome, game) -> dict:
    """
    Return player_id → hole_number → adjusted_score based on game's handicap mode.

    Cup Nassau is always fourball (2v2 best-ball), so handicap is always
    strokes-off the lowest player in the group regardless of the stored
    handicap_mode.  Casual Nassau uses whatever mode was configured.

    A Triple Nassau child (game_type triple_1/2/3) is a 1v1 handicapped on its
    OWN pair — strokes-off the lower of the two match players, not the field —
    so it routes through `_build_pair_so_index`.  (Net / Gross are per-player and
    need no field-relative adjustment, so they use the standard index.)
    """
    if game.game_type in TRIPLE_CHILD_SLUGS:
        if game.handicap_mode == HandicapMode.STROKES_OFF:
            return _build_pair_so_index(foursome, game)
        return build_score_index(foursome, game.handicap_mode, game.net_percent)
    if game.handicap_mode == HandicapMode.STROKES_OFF or _is_cup_nassau(foursome):
        return _build_so_score_index(foursome, net_percent=game.net_percent)
    return build_score_index(foursome, game.handicap_mode, game.net_percent)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_nassau(
    foursome,
    team1_ids:     list,
    team2_ids:     list,
    handicap_mode: str   = HandicapMode.NET,
    net_percent:   int   = 100,
    press_mode:    str   = 'none',
    press_unit:    float = 0.00,
    variant:       str   = 'none',
    play_front:    bool  = True,
    play_back:     bool  = True,
    play_overall:  bool  = True,
    single_match:  bool  = False,
    loss_cap             = None,
    game_type:     str   = None,
) -> NassauGame:
    """
    Create (or replace) THIS foursome's Nassau match of `game_type` and its two
    fixed teams.

    game_type: 'nassau' (team Nassau, default), 'nassau_nine' (single-segment
    partial-round match), or 'match_18' (1-v-1 Overall-only Singles Match).
    A foursome can hold one row per game_type at once, so replacing (say) the
    Nassau leaves a coexisting Singles Match untouched — only the SAME game_type
    is deleted first.  When omitted it's derived from single_match for backward
    compatibility.

    team1_ids / team2_ids: lists of Player PKs (1 or 2 each for head-to-head
    or 2v2).  Deleting the old NassauGame cascades to teams, hole scores, and
    all presses.

    variant: 'none' | 'tiebreak_2nd' | 'claremont'
    """
    if game_type is None:
        game_type = GameType.NASSAU_NINE if single_match else GameType.NASSAU
    NassauGame.objects.filter(foursome=foursome, game_type=game_type).delete()

    net_percent = max(0, min(200, int(net_percent)))
    if variant not in ('none', 'tiebreak_2nd', 'claremont'):
        variant = 'none'

    if loss_cap is not None:
        loss_cap = Decimal(str(loss_cap))
        if loss_cap < 0:
            loss_cap = None

    # Nassau Nine: one match over all played holes. The match rides the 'front'
    # bet (the engine puts every hole in the front segment); back/overall are off.
    if single_match:
        play_front, play_back, play_overall = True, False, False

    game = NassauGame.objects.create(
        foursome      = foursome,
        game_type     = game_type,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        press_mode    = press_mode,
        press_unit    = press_unit,
        variant       = variant,
        play_front    = play_front,
        play_back     = play_back,
        play_overall  = play_overall,
        single_match  = single_match,
        loss_cap      = loss_cap,
        status        = MatchStatus.PENDING,
    )

    t1 = NassauTeam.objects.create(game=game, team_number=1)
    t1.players.set(team1_ids)

    t2 = NassauTeam.objects.create(game=game, team_number=2)
    t2.players.set(team2_ids)

    return game


# ---------------------------------------------------------------------------
# Manual press
# ---------------------------------------------------------------------------

def add_manual_press(foursome, start_hole: int,
                     game_type: str = None,
                     side: str = 'top') -> NassauPress:
    """
    Record a manual press called by the losing team.  The press starts on
    start_hole and runs to the end of the nine that contains start_hole.

    The winning team cannot decline — this function does not need an
    acceptance step; it immediately persists the press.

    **`side` is a whole bet, not a flavour.** Claremont is two games at once
    — the top at 1 point a hole and the bottom at 2 (low ball plus high) —
    and each presses itself.  `'bottom'` is refused outside Claremont,
    where that game does not exist.

    Raises ValueError if:
      - No NassauGame exists for this foursome.
      - The game's press_mode does not allow manual presses.
      - start_hole is not a valid active nine hole (1–18).
      - A manual press already covers start_hole on the same side and nine.
      - `side` is 'bottom' and this is not a Claremont game.

    After creating the press row, recalculates the game so its running
    margin is populated immediately.
    """
    game_type = resolve_nassau_game_type(foursome, game_type)
    try:
        game = NassauGame.objects.get(foursome=foursome, game_type=game_type)
    except NassauGame.DoesNotExist:
        raise ValueError("No Nassau game set up for this foursome.")

    if game.press_mode not in ('manual', 'both'):
        raise ValueError(f"Press mode '{game.press_mode}' does not allow manual presses.")

    if side not in ('top', 'bottom'):
        raise ValueError(f"side must be 'top' or 'bottom', got {side!r}.")
    if side == 'bottom' and _effective_variant(game) != 'claremont':
        raise ValueError('Only a Claremont game has a bottom bet to press.')

    if not (1 <= start_hole <= 18):
        raise ValueError(f"start_hole must be 1–18, got {start_hole}.")

    # Determine the nine by POSITION in the group's play order (shotgun-aware),
    # and the nine's last hole NUMBER for the press's end_hole. Normal round
    # (start 1) → front = holes 1-9 (end 9), back = 10-18 (end 18), unchanged.
    from services.hole_plan import play_order as _play_order
    _order = _play_order(foursome.round, foursome)
    _half  = (len(_order) or 18) // 2
    _pos   = _order.index(start_hole) if start_hole in _order else (start_hole - 1)
    nine     = 'front' if _pos < _half else 'back'
    _last    = (_half - 1) if nine == 'front' else (len(_order) - 1)
    end_hole = _order[_last] if _order else (9 if nine == 'front' else 18)

    # Prevent duplicate manual presses with the same start_hole ON THIS SIDE.
    # The two games are pressed separately, so the same hole can legitimately
    # start one of each.
    if NassauPress.objects.filter(
        game=game, press_type='manual', side=side, start_hole=start_hole
    ).exists():
        raise ValueError(f"A manual press already starts on hole {start_hole}.")

    # Cap gate (defends the API directly, mirroring nassau_summary.can_press):
    # a side that has hit the cap can't press — it would be a free option.
    if game.loss_cap is not None:
        s = nassau_summary(foursome, game_type)
        if s is not None:
            nine_margin = (s['front9']['margin'] if nine == 'front'
                           else s['back9']['margin'])
            if _press_blocked_by_cap(game, s['payouts']['total'], nine_margin):
                raise ValueError(
                    "That side has reached its loss cap — pressing is closed.")

    press = NassauPress.objects.create(
        game             = game,
        nine             = nine,
        side             = side,
        press_type       = 'manual',
        triggered_on_hole = start_hole - 1,
        start_hole       = start_hole,
        end_hole         = end_hole,
        result           = None,
        holes_up         = None,
    )

    # Recalculate so this press's running margin is filled in (if the start
    # hole has already been scored) or the untriggered press is re-persisted.
    # calculate_nassau() deletes and recreates ALL press rows, so the original
    # `press` PK no longer exists — re-fetch by business key instead.
    # Recalculate THIS match. A bare call resolves to the foursome's primary
    # Nassau, so a press in a Triple Nassau or Annandale Friday child used to
    # recalculate a different game (or none) and leave its own press unscored —
    # and the cap check above read the wrong match the same way.
    calculate_nassau(foursome, game_type)
    return NassauPress.objects.get(game=game, press_type='manual', side=side,
                                   start_hole=start_hole)


# ---------------------------------------------------------------------------
# Calculator helpers
# ---------------------------------------------------------------------------

def _best_ball(team: NassauTeam, hole_num: int, score_index: dict) -> int | None:
    """Lowest adjusted score from any player on this team for hole_num."""
    player_ids = list(team.players.values_list('id', flat=True))
    nets = [
        score_index[pid][hole_num]
        for pid in player_ids
        if pid in score_index and hole_num in score_index[pid]
    ]
    return min(nets) if nets else None


def _second_ball(team: NassauTeam, hole_num: int, score_index: dict) -> int | None:
    """
    Second-lowest adjusted score from this team for hole_num.
    Returns None when the team has only one player (no 2nd ball exists).
    """
    player_ids = list(team.players.values_list('id', flat=True))
    nets = sorted([
        score_index[pid][hole_num]
        for pid in player_ids
        if pid in score_index and hole_num in score_index[pid]
    ])
    return nets[1] if len(nets) >= 2 else None


def _resolve(holes_up: int) -> str:
    """Convert final holes_up margin → result string."""
    if holes_up > 0:  return 'team1'
    if holes_up < 0:  return 'team2'
    return 'halved'


# ---------------------------------------------------------------------------
# Main calculator
# ---------------------------------------------------------------------------

def _effective_variant(game) -> str:
    """The Nassau variant that actually applies.

    Claremont and 2nd-ball tiebreak both need a real 2-v-2 (two balls per side),
    so on a 1-v-1 (or any non-2v2) they can't run.  Ignore a stale `claremont` /
    `tiebreak_2nd` that a pre-gating client may have saved so it neither scores
    nor renders on a two-person match (docs/parallel-games.md).
    """
    if game.variant not in ('claremont', 'tiebreak_2nd'):
        return game.variant
    teams = {t.team_number: t for t in game.teams.all()}
    t1n = len(teams[1].players.all()) if 1 in teams else 0
    t2n = len(teams[2].players.all()) if 2 in teams else 0
    return game.variant if (t1n == 2 and t2n == 2) else 'none'


def nassau_game_types_for(foursome) -> list:
    """
    The game_type slugs this foursome has a Nassau-family match configured for
    (0, 1, or 2 of 'nassau' / 'nassau_nine' / 'match_18').
    """
    return list(
        NassauGame.objects.filter(foursome=foursome)
        .values_list('game_type', flat=True)
    )


def calculate_all_nassau(foursome) -> None:
    """Recompute every Nassau-family match on this foursome."""
    for gt in nassau_game_types_for(foursome):
        calculate_nassau(foursome, gt)


def resolve_nassau_game_type(foursome, requested=None) -> str:
    """
    Read-path resolver.  Returns `requested` when given; otherwise the
    foursome's PRIMARY Nassau-family match — the team Nassau / Nassau Nine
    before a Singles Match.  This keeps callers (and legacy clients) that don't
    name a game_type working: on a Nassau-Nine-only round the bare read still
    finds the row, and on a Larry round it finds the team Nassau.
    """
    if requested:
        return requested
    types = set(nassau_game_types_for(foursome))
    for t in (GameType.NASSAU, GameType.NASSAU_NINE, GameType.MATCH_18):
        if t in types:
            return t
    return GameType.NASSAU


@transaction.atomic
def calculate_nassau(foursome, game_type: str = None) -> NassauGame | None:
    """
    Recompute all NassauHoleScore rows, detect auto-presses, update manual
    press results, and resolve the three standard bets (and Claremont bottom
    bets when variant == 'claremont').

    Manual presses (press_type='manual', side='top') are preserved across
    calls — only their result / holes_up are updated.  Auto presses (top and
    bottom) are rebuilt from scratch each call.

    Returns the updated NassauGame, or None if no game of `game_type` exists.
    """
    game_type = resolve_nassau_game_type(foursome, game_type)
    try:
        game = NassauGame.objects.prefetch_related('teams__players').get(
            foursome=foursome, game_type=game_type
        )
    except NassauGame.DoesNotExist:
        return None

    teams = list(game.teams.all())
    t1 = next(t for t in teams if t.team_number == 1)
    t2 = next(t for t in teams if t.team_number == 2)

    score_index = _get_score_index(foursome, game)

    # Play-order scaffolding (shotgun-aware): the "front" nine is the first 9
    # holes this group PLAYS and the "back" nine the last 9, split by POSITION in
    # play order — not by absolute hole number. For a normal round (start hole 1)
    # this is holes 1-9 / 10-18 and every position equals hole_num - 1, so the
    # math below is byte-identical. Nassau is 18-hole only (gated off partial
    # rounds), so n == 18 and half == 9.
    from services.hole_plan import play_order as _play_order
    order          = _play_order(foursome.round, foursome)
    n              = len(order) or 18
    # Nassau Nine: the whole played round is ONE segment (all holes "front"), so
    # the single match + its presses run over every hole rather than a nine.
    half           = n if game.single_match else n // 2
    pos_of         = {h: i for i, h in enumerate(order)}
    front_last_pos = half - 1
    back_last_pos  = n - 1
    # Hole NUMBERS of each nine's last hole (for press end_hole display).
    front_end_hole = order[front_last_pos] if order else 9
    back_end_hole  = order[back_last_pos]  if order else 18

    effective_variant = _effective_variant(game)
    is_claremont    = effective_variant == 'claremont'
    is_tiebreak_2nd = effective_variant == 'tiebreak_2nd'
    needs_2nd_ball  = is_claremont or is_tiebreak_2nd

    # ── Preserve manual presses, per SIDE ─────────────────────────────────
    # Claremont's two games press separately — the top at 2 holes down, the
    # bottom at 4 points — so a manual press belongs to one of them and the
    # two lists cannot be merged.
    manual_press_starts = list(
        NassauPress.objects.filter(game=game, press_type='manual', side='top')
        .values_list('start_hole', flat=True)
    )
    bot_manual_press_starts = list(
        NassauPress.objects.filter(game=game, press_type='manual', side='bottom')
        .values_list('start_hole', flat=True)
    )

    NassauHoleScore.objects.filter(game=game).delete()
    NassauPress.objects.filter(game=game).delete()

    # ── Running state — TOP ───────────────────────────────────────────────
    front9_up  = 0
    back9_up   = 0
    overall_up = 0

    front9_decided_margin    = None
    front9_decided_remaining = None
    back9_decided_margin     = None
    back9_decided_remaining  = None
    overall_decided_margin    = None
    overall_decided_remaining = None

    # Top press trackers  {'nine', 'press_type', 'side', 'trigger_hole', 'start', 'end', 'margin'}
    top_active_presses:    list = []
    top_completed_presses: list = []

    front_holes = set(order[:half])       # first 9 played (play order)
    back_holes  = set(order[half:])        # last 9 played

    manual_front = sorted([s for s in manual_press_starts if s in front_holes])
    manual_back  = sorted([s for s in manual_press_starts if s in back_holes])

    bot_manual_front = sorted(
        [s for s in bot_manual_press_starts if s in front_holes])
    bot_manual_back  = sorted(
        [s for s in bot_manual_press_starts if s in back_holes])

    AUTO_TOP_THRESHOLDS = frozenset({2, 4, 6, 8, -2, -4, -6, -8})
    top_front9_thresholds_fired: set = set()
    top_back9_thresholds_fired:  set = set()

    # ── Running state — BOTTOM (Claremont only) ───────────────────────────
    bot_front9_up  = 0
    bot_back9_up   = 0
    bot_overall_up = 0

    bot_front9_decided_margin    = None
    bot_front9_decided_remaining = None
    bot_back9_decided_margin     = None
    bot_back9_decided_remaining  = None
    bot_overall_decided_margin    = None
    bot_overall_decided_remaining = None

    # Bottom press trackers — same dict shape as top; margin is in points (max ±2/hole)
    bot_active_presses:    list = []
    bot_completed_presses: list = []

    # Bottom auto-press fires on reaching ±4, ±8, ±12, ±16 points (see the
    # trigger below). "2-down" in Claremont = 2 holes equivalent = 4 points
    # (2 pts/hole); each further 4 points down fires the next press.
    bot_front9_thresholds_fired: set = set()
    bot_back9_thresholds_fired:  set = set()

    hole_score_objs = []
    auto_enabled   = game.press_mode in ('auto', 'both')
    manual_enabled = game.press_mode in ('manual', 'both')

    # ── Cap gate for AUTO presses ─────────────────────────────────────────
    # A side that has hit the cap can't auto-press (it would be a free option).
    # Concluded (locked-in) net in dollars, team1's perspective — only DECIDED
    # main + bottom bets and COMPLETED presses count; live/contested bets don't.
    # Re-evaluated at each fire so a later concluded win can re-open pressing
    # (concluded loss isn't monotonic — winning a bet later reduces it).
    cap_bet_unit   = float(foursome.round.bet_unit)
    cap_press_unit = float(game.press_unit)

    def _decided_dollars(margin):
        if not margin:                 # None or 0 (push) → no money
            return 0.0
        return cap_bet_unit if margin > 0 else -cap_bet_unit

    def _concluded_net():
        net = (_decided_dollars(front9_decided_margin)
               + _decided_dollars(back9_decided_margin)
               + _decided_dollars(overall_decided_margin))
        if is_claremont:
            net += (_decided_dollars(bot_front9_decided_margin)
                    + _decided_dollars(bot_back9_decided_margin)
                    + _decided_dollars(bot_overall_decided_margin))
        for p in top_completed_presses + bot_completed_presses:
            if p['margin'] > 0:
                net += cap_press_unit
            elif p['margin'] < 0:
                net -= cap_press_unit
        return net

    def _auto_press_blocked(nine_margin):
        return (game.loss_cap is not None
                and _press_blocked_by_cap(game, _concluded_net(), nine_margin))

    for pos, hole_num in enumerate(order):
        t1_net = _best_ball(t1, hole_num, score_index)
        t2_net = _best_ball(t2, hole_num, score_index)

        if t1_net is None or t2_net is None:
            break  # stop at first incomplete hole (in play order)

        # ── 2nd ball scores ───────────────────────────────────────────────
        t1_2nd: int | None = None
        t2_2nd: int | None = None
        if needs_2nd_ball:
            t1_2nd = _second_ball(t1, hole_num, score_index)
            t2_2nd = _second_ball(t2, hole_num, score_index)

        # ── Top hole winner ───────────────────────────────────────────────
        if t1_net < t2_net:
            winner, delta = 'team1',  1
        elif t2_net < t1_net:
            winner, delta = 'team2', -1
        else:
            # tiebreak_2nd: break ties using 2nd ball (foursomes only)
            if is_tiebreak_2nd and t1_2nd is not None and t2_2nd is not None:
                if t1_2nd < t2_2nd:
                    winner, delta = 'team1',  1
                elif t2_2nd < t1_2nd:
                    winner, delta = 'team2', -1
                else:
                    winner, delta = 'halved', 0
            else:
                winner, delta = 'halved', 0

        overall_up += delta

        if pos < half:
            nine_key = 'front'
            front9_up += delta
            top_nine_margin = front9_up
            nine_end        = front_end_hole      # hole NUMBER of front's last hole
            nine_last_pos   = front_last_pos
            if front9_decided_margin is None:
                _rem = front_last_pos - pos        # holes left in the front nine
                if abs(front9_up) > _rem:
                    front9_decided_margin    = front9_up
                    front9_decided_remaining = _rem
        else:
            nine_key = 'back'
            back9_up += delta
            top_nine_margin = back9_up
            nine_end        = back_end_hole
            nine_last_pos   = back_last_pos
            if back9_decided_margin is None:
                _rem = back_last_pos - pos         # holes left in the back nine
                if abs(back9_up) > _rem:
                    back9_decided_margin    = back9_up
                    back9_decided_remaining = _rem

        if overall_decided_margin is None:
            _ov_rem = (n - 1) - pos
            if abs(overall_up) > _ov_rem:
                overall_decided_margin    = overall_up
                overall_decided_remaining = _ov_rem

        # ── Advance TOP active presses ────────────────────────────────────
        still_top = []
        for press in top_active_presses:
            if press['nine'] != nine_key:
                still_top.append(press)
                continue
            press['margin'] += delta
            holes_left = press['end_pos'] - pos
            if pos >= press['end_pos'] or abs(press['margin']) > holes_left:
                press['is_active'] = False   # definitively closed
                top_completed_presses.append(press)
            else:
                still_top.append(press)
        top_active_presses = still_top

        # ── Trigger top manual press ──────────────────────────────────────
        if manual_enabled:
            for ms in (manual_front if nine_key == 'front' else manual_back):
                if ms == hole_num:
                    already = any(
                        p['press_type'] == 'manual' and p['nine'] == nine_key and p['start'] == ms
                        for p in top_active_presses + top_completed_presses
                    )
                    if not already:
                        top_active_presses.append({
                            'nine': nine_key, 'press_type': 'manual', 'side': 'top',
                            'trigger_hole': hole_num - 1, 'start': hole_num,
                            'end': nine_end, 'end_pos': nine_last_pos, 'margin': delta,
                            'is_active': True,
                        })

        # ── Trigger top auto-press ────────────────────────────────────────
        if auto_enabled:
            holes_left_in_nine = nine_last_pos - pos
            if holes_left_in_nine > 0 and top_nine_margin in AUTO_TOP_THRESHOLDS:
                tf = top_front9_thresholds_fired if nine_key == 'front' else top_back9_thresholds_fired
                # Suppress (without marking fired, so it can re-open) when the
                # side that would press has already hit the cap.
                if top_nine_margin not in tf and not _auto_press_blocked(top_nine_margin):
                    tf.add(top_nine_margin)
                    top_active_presses.append({
                        'nine': nine_key, 'press_type': 'auto', 'side': 'top',
                        'trigger_hole': hole_num,
                        'start': order[pos + 1] if pos + 1 < n else hole_num,
                        'end': nine_end, 'end_pos': nine_last_pos, 'margin': 0,
                        'is_active': True,
                    })

        # ── Claremont bottom ──────────────────────────────────────────────
        bot_delta_val       = None
        bot_front9_up_val   = None
        bot_back9_up_val    = None
        bot_overall_up_val  = None

        if is_claremont:
            # Point 1: best ball (+1/0/−1)
            p1 = 1 if t1_net < t2_net else (-1 if t2_net < t1_net else 0)
            # Point 2: 2nd best ball (+1/0/−1); treat as 0 if either team has no 2nd ball
            if t1_2nd is not None and t2_2nd is not None:
                p2 = 1 if t1_2nd < t2_2nd else (-1 if t2_2nd < t1_2nd else 0)
            else:
                p2 = 0
            bot_delta_val  = p1 + p2
            bot_overall_up += bot_delta_val

            if pos < half:
                bot_front9_up   += bot_delta_val
                bot_nine_margin  = bot_front9_up
                bot_front9_up_val = bot_front9_up
                if bot_front9_decided_margin is None:
                    _rem = front_last_pos - pos
                    # Remaining potential swing = _rem * 2 (max 2 pts/hole)
                    if abs(bot_front9_up) > _rem * 2:
                        bot_front9_decided_margin    = bot_front9_up
                        bot_front9_decided_remaining = _rem
            else:
                bot_back9_up    += bot_delta_val
                bot_nine_margin  = bot_back9_up
                bot_back9_up_val = bot_back9_up
                if bot_back9_decided_margin is None:
                    _rem = back_last_pos - pos
                    if abs(bot_back9_up) > _rem * 2:
                        bot_back9_decided_margin    = bot_back9_up
                        bot_back9_decided_remaining = _rem

            if bot_overall_decided_margin is None:
                _ov_rem = (n - 1) - pos
                if abs(bot_overall_up) > _ov_rem * 2:
                    bot_overall_decided_margin    = bot_overall_up
                    bot_overall_decided_remaining = _ov_rem

            bot_overall_up_val = bot_overall_up

            # ── Advance BOTTOM active presses ─────────────────────────────
            still_bot = []
            for press in bot_active_presses:
                if press['nine'] != nine_key:
                    still_bot.append(press)
                    continue
                press['margin'] += bot_delta_val
                pts_left = (press['end_pos'] - pos) * 2  # max bottom swing remaining
                if pos >= press['end_pos'] or abs(press['margin']) > pts_left:
                    press['is_active'] = False   # definitively closed
                    bot_completed_presses.append(press)
                else:
                    still_bot.append(press)
            bot_active_presses = still_bot

            # ── Trigger bottom manual press ───────────────────────────────
            if manual_enabled:
                for ms in (bot_manual_front if nine_key == 'front'
                           else bot_manual_back):
                    if ms == hole_num:
                        already = any(
                            p['press_type'] == 'manual'
                            and p['nine'] == nine_key and p['start'] == ms
                            for p in bot_active_presses + bot_completed_presses
                        )
                        if not already:
                            bot_active_presses.append({
                                'nine': nine_key, 'press_type': 'manual',
                                'side': 'bottom',
                                'trigger_hole': hole_num - 1, 'start': hole_num,
                                'end': nine_end, 'end_pos': nine_last_pos,
                                'margin': bot_delta_val, 'is_active': True,
                            })

            # ── Trigger bottom auto-press ─────────────────────────────────
            # Fire on REACHING/CROSSING a 4-point band (±4, ±8, …), not on an
            # exact-margin match: the bottom margin moves up to ±2 per hole
            # (best ball + 2nd ball), so an odd margin can leap over the exact
            # threshold — e.g. −3 → −5 skips −4 — and no press would ever fire.
            # Thresholds are 4 apart and the step is ≤2, so at most one new band
            # is crossed per hole.  `bf` tracks the signed band level already
            # pressed so a recovery-then-relapse doesn't re-press the same band.
            if auto_enabled:
                pts_left_in_nine = (nine_last_pos - pos) * 2
                if pts_left_in_nine > 0 and abs(bot_nine_margin) >= 4:
                    bf = bot_front9_thresholds_fired if nine_key == 'front' else bot_back9_thresholds_fired
                    sign        = 1 if bot_nine_margin > 0 else -1
                    band_level  = sign * ((abs(bot_nine_margin) // 4) * 4)  # ±4/±8/…
                    if band_level not in bf and not _auto_press_blocked(band_level):
                        bf.add(band_level)
                        bot_active_presses.append({
                            'nine': nine_key, 'press_type': 'auto', 'side': 'bottom',
                            'trigger_hole': hole_num,
                            'start': order[pos + 1] if pos + 1 < n else hole_num,
                            'end': nine_end, 'end_pos': nine_last_pos, 'margin': 0,
                            'is_active': True,
                        })

        hole_score_objs.append(NassauHoleScore(
            game                    = game,
            hole_number             = hole_num,
            team1_best_net          = t1_net,
            team2_best_net          = t2_net,
            winner                  = winner,
            front9_up_after         = front9_up  if hole_num in front_holes else None,
            back9_up_after          = back9_up   if hole_num in back_holes  else None,
            overall_up_after        = overall_up,
            # 2nd-ball (tiebreak_2nd + claremont)
            team1_2nd_net           = t1_2nd,
            team2_2nd_net           = t2_2nd,
            # Claremont bottom
            bottom_delta            = bot_delta_val,
            bottom_front9_up_after  = bot_front9_up_val,
            bottom_back9_up_after   = bot_back9_up_val,
            bottom_overall_up_after = bot_overall_up_val,
        ))

    # Flush any open presses
    top_completed_presses.extend(top_active_presses)
    bot_completed_presses.extend(bot_active_presses)

    NassauHoleScore.objects.bulk_create(hole_score_objs)

    # ── Persist TOP press rows ────────────────────────────────────────────
    # Presses still marked is_active=True are open/in-progress — save with
    # result=None so the UI shows "In progress" rather than a stale winner.
    press_objs = [
        NassauPress(
            game              = game,
            nine              = p['nine'],
            side              = 'top',
            press_type        = p['press_type'],
            triggered_on_hole = p['trigger_hole'],
            start_hole        = p['start'],
            end_hole          = p['end'],
            result            = None if p.get('is_active') else _resolve(p['margin']),
            holes_up          = p['margin'],
        )
        for p in top_completed_presses
    ]

    # Recreate top manual presses not yet triggered
    triggered_manual_starts = {
        p['start'] for p in top_completed_presses if p['press_type'] == 'manual'
    }
    for ms in manual_press_starts:
        if ms not in triggered_manual_starts:
            ms_pos      = pos_of.get(ms)
            ms_nine     = 'front' if (ms_pos is not None and ms_pos < half) else 'back'
            ms_end_hole = front_end_hole if ms_nine == 'front' else back_end_hole
            press_objs.append(NassauPress(
                game              = game,
                nine              = ms_nine,
                side              = 'top',
                press_type        = 'manual',
                triggered_on_hole = order[ms_pos - 1] if ms_pos else max(ms - 1, 0),
                start_hole        = ms,
                end_hole          = ms_end_hole,
                result            = None,
                holes_up          = None,
            ))

    # ── Persist BOTTOM press rows (Claremont only) ────────────────────────
    if is_claremont:
        press_objs += [
            NassauPress(
                game              = game,
                nine              = p['nine'],
                side              = 'bottom',
                press_type        = p['press_type'],
                triggered_on_hole = p['trigger_hole'],
                start_hole        = p['start'],
                end_hole          = p['end'],
                result            = None if p.get('is_active') else _resolve(p['margin']),
                holes_up          = p['margin'],
            )
            for p in bot_completed_presses
        ]
        # …and the ones whose first hole has not been played yet, exactly as
        # the top side does: a press called on the 5th is a row from the
        # moment it is called, not from the moment it starts counting.
        bot_triggered = {
            p['start'] for p in bot_completed_presses
            if p['press_type'] == 'manual'
        }
        for ms in bot_manual_press_starts:
            if ms not in bot_triggered:
                ms_pos      = pos_of.get(ms)
                ms_nine     = ('front' if (ms_pos is not None and ms_pos < half)
                               else 'back')
                ms_end_hole = (front_end_hole if ms_nine == 'front'
                               else back_end_hole)
                press_objs.append(NassauPress(
                    game              = game,
                    nine              = ms_nine,
                    side              = 'bottom',
                    press_type        = 'manual',
                    triggered_on_hole = (order[ms_pos - 1] if ms_pos
                                         else max(ms - 1, 0)),
                    start_hole        = ms,
                    end_hole          = ms_end_hole,
                    result            = None,
                    holes_up          = None,
                ))

    NassauPress.objects.bulk_create(press_objs)

    # ── Resolve TOP standard bets ─────────────────────────────────────────
    holes_played    = len(hole_score_objs)
    front_complete  = holes_played >= 9  or front9_decided_margin  is not None
    back_complete   = holes_played >= 18 or back9_decided_margin   is not None
    overall_complete = holes_played >= 18 or overall_decided_margin is not None

    # Only the live segments resolve — an inactive bet (e.g. Front/Back off for
    # an Overall-only 18-hole match) stays None so it never settles or shows.
    game.front9_result  = (_resolve(front9_decided_margin  if front9_decided_margin  is not None else front9_up)  if front_complete  else None) if game.play_front   else None
    game.back9_result   = (_resolve(back9_decided_margin   if back9_decided_margin   is not None else back9_up)   if back_complete   else None) if game.play_back    else None
    game.overall_result = (_resolve(overall_decided_margin if overall_decided_margin is not None else overall_up) if overall_complete else None) if game.play_overall else None

    # ── Resolve BOTTOM standard bets (Claremont) ──────────────────────────
    if is_claremont:
        bot_front_complete   = holes_played >= 9  or bot_front9_decided_margin  is not None
        bot_back_complete    = holes_played >= 18 or bot_back9_decided_margin   is not None
        bot_overall_complete = holes_played >= 18 or bot_overall_decided_margin is not None

        game.bottom_front9_result  = _resolve(bot_front9_decided_margin  if bot_front9_decided_margin  is not None else bot_front9_up)  if bot_front_complete  else None
        game.bottom_back9_result   = _resolve(bot_back9_decided_margin   if bot_back9_decided_margin   is not None else bot_back9_up)   if bot_back_complete   else None
        game.bottom_overall_result = _resolve(bot_overall_decided_margin if bot_overall_decided_margin is not None else bot_overall_up) if bot_overall_complete else None
    else:
        game.bottom_front9_result  = None
        game.bottom_back9_result   = None
        game.bottom_overall_result = None

    if overall_complete:
        game.status = MatchStatus.COMPLETE
    elif holes_played > 0:
        game.status = MatchStatus.IN_PROGRESS
    else:
        game.status = MatchStatus.PENDING

    game.save()
    return game


# ---------------------------------------------------------------------------
# Phantom helpers
# ---------------------------------------------------------------------------

def _team_colour(foursome, team_num: int) -> str:
    """Return the cup team colour string for team 1 or 2, defaulting to Red/Blue."""
    try:
        cfg = foursome.ryder_cup_foursome_config
        team = cfg.team1 if team_num == 1 else cfg.team2
        return (team.colour or ('Red' if team_num == 1 else 'Blue')) if team else ('Red' if team_num == 1 else 'Blue')
    except Exception:
        return 'Red' if team_num == 1 else 'Blue'


def _build_phantom_info(foursome, net_percent: int = 100) -> 'dict | None':
    """Thin wrapper around the shared helper — kept so existing
    in-module callers don't need to change.  Identical output."""
    from scoring.phantom import build_phantom_info
    return build_phantom_info(foursome, net_percent)


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def nassau_summary(foursome, game_type: str = None) -> dict | None:
    """
    Return a full JSON summary for the UI and leaderboard.

    Shape:
    {
        'status'       : 'pending' | 'in_progress' | 'complete',
        'handicap_mode': str,
        'net_percent'  : int,
        'press_mode'   : str,
        'bet_unit'     : float,
        'press_unit'   : float,
        'teams'        : {
            'team1': [{'player_id': int, 'name': str, 'short_name': str}, ...],
            'team2': [...],
        },
        'front9'  : {'result': str|None, 'margin': int, 'holes_played': int},
        'back9'   : {'result': str|None, 'margin': int, 'holes_played': int},
        'overall' : {'result': str|None, 'margin': int, 'holes_played': int},
        'presses' : [
            {
                'nine'      : 'front'|'back',
                'press_type': 'manual'|'auto',
                'start_hole': int,
                'end_hole'  : int,
                'result'    : str|None,
                'margin'    : int|None,
            },
            ...
        ],
        'payouts'  : {
            'front9'  : float,   # +ve = team1 wins (in dollars)
            'back9'   : float,
            'overall' : float,
            'presses' : float,
            'total'   : float,
        },
        'holes'    : [
            {
                'hole'          : int,
                'winner'        : str|None,
                't1_net'        : int,
                't2_net'        : int,
                'front9_margin' : int|None,
                'back9_margin'  : int|None,
                'overall_margin': int,
            },
            ...
        ],
        'can_press'    : bool,  # True when manual press is currently available
        'press_available_nine': str|None,  # 'front'|'back' if can_press, else None
        'bottom_can_press'           : bool,       # Claremont bottom game
        'bottom_press_available_nine': str|None,
    }
    """
    game_type = resolve_nassau_game_type(foursome, game_type)
    try:
        game = NassauGame.objects.prefetch_related('teams__players').get(
            foursome=foursome, game_type=game_type
        )
    except NassauGame.DoesNotExist:
        return None

    teams = {t.team_number: t for t in game.teams.all()}
    bet_unit   = float(foursome.round.bet_unit)
    press_unit = float(game.press_unit)

    # ── Payout helpers ────────────────────────────────────────────────────
    def _payout(result: str | None) -> float:
        if result == 'team1': return  bet_unit
        if result == 'team2': return -bet_unit
        return 0.0

    def _press_payout(result: str | None) -> float:
        if result == 'team1': return  press_unit
        if result == 'team2': return -press_unit
        return 0.0

    effective_variant = _effective_variant(game)
    is_claremont    = effective_variant == 'claremont'
    is_tiebreak_2nd = effective_variant == 'tiebreak_2nd'

    # ── Per-player gross + par lookups (for the progress grid) ──────────
    # Gross scores come from HoleScore directly so the summary can render
    # the same hole-by-hole grid that the score-entry screen shows.
    # Strokes = gross - net (whichever handicap mode the game is set to —
    # build_score_index handles cup-nassau strokes-off-low automatically).
    real_member_ids = [
        m.player_id for m in foursome.memberships.filter(player__is_phantom=False)
    ]
    gross_index: dict = {}
    for r in (
        HoleScore.objects
        .filter(foursome=foursome, player_id__in=real_member_ids)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    ):
        gross_index.setdefault(r['player_id'], {})[r['hole_number']] = r['gross_score']

    # Net scores via the same index the calculator uses so dot counts on
    # the spectator progress grid line up with what the score-entry
    # screen draws.  _get_score_index honours the game's handicap mode
    # (and the cup-nassau strokes-off override).
    score_index = _get_score_index(foursome, game)

    sample_tee = next(
        (m.tee for m in foursome.memberships.select_related('tee').all()
         if m.tee_id is not None),
        None,
    )
    par_by_hole: dict = {}
    si_by_hole:  dict = {}
    if sample_tee is not None:
        for h in range(1, 19):
            hd = sample_tee.hole(h)
            par_by_hole[h] = hd.get('par')
            si_by_hole[h]  = hd.get('stroke_index')

    # ── Holes ─────────────────────────────────────────────────────────────
    holes_qs = NassauHoleScore.objects.filter(game=game).order_by('hole_number')
    holes_out = []
    for h in holes_qs:
        scores_row = []
        for pid in real_member_ids:
            gross = gross_index.get(pid, {}).get(h.hole_number)
            if gross is None:
                continue
            net     = score_index.get(pid, {}).get(h.hole_number)
            strokes = max(0, gross - net) if net is not None else 0
            scores_row.append({
                'player_id': pid,
                'gross'    : gross,
                'strokes'  : strokes,
            })
        holes_out.append({
            'hole'                  : h.hole_number,
            'par'                   : par_by_hole.get(h.hole_number),
            'stroke_index'          : si_by_hole.get(h.hole_number),
            'scores'                : scores_row,
            'winner'                : h.winner,
            't1_net'                : h.team1_best_net,
            't2_net'                : h.team2_best_net,
            't1_2nd_net'            : h.team1_2nd_net,
            't2_2nd_net'            : h.team2_2nd_net,
            'front9_margin'         : h.front9_up_after,
            'back9_margin'          : h.back9_up_after,
            'overall_margin'        : h.overall_up_after,
            'bottom_delta'          : h.bottom_delta,
            'bottom_front9_margin'  : h.bottom_front9_up_after,
            'bottom_back9_margin'   : h.bottom_back9_up_after,
            'bottom_overall_margin' : h.bottom_overall_up_after,
        })

    # Running margins from last scored hole
    front9_margin = next(
        (h['front9_margin'] for h in reversed(holes_out)
         if h['front9_margin'] is not None), 0
    )
    back9_margin = next(
        (h['back9_margin'] for h in reversed(holes_out)
         if h['back9_margin'] is not None), 0
    )
    overall_margin = next(
        (h['overall_margin'] for h in reversed(holes_out)
         if h['overall_margin'] is not None), 0
    )
    bot_front9_margin = next(
        (h['bottom_front9_margin'] for h in reversed(holes_out)
         if h['bottom_front9_margin'] is not None), 0
    )
    bot_back9_margin = next(
        (h['bottom_back9_margin'] for h in reversed(holes_out)
         if h['bottom_back9_margin'] is not None), 0
    )
    bot_overall_margin = next(
        (h['bottom_overall_margin'] for h in reversed(holes_out)
         if h['bottom_overall_margin'] is not None), 0
    )

    # Count each nine by its per-hole marker (play-order correct for a shotgun),
    # not by hole number — front9_margin/back9_margin is set only on that nine.
    holes_front = sum(1 for h in holes_out if h['front9_margin'] is not None)
    holes_back  = sum(1 for h in holes_out if h['back9_margin'] is not None)

    # ── Presses ───────────────────────────────────────────────────────────
    winner_by_hole = {h['hole']: h['winner'] for h in holes_out}
    bot_delta_by_hole = {h['hole']: (h['bottom_delta'] or 0) for h in holes_out}

    # Play-order scaffolding so a press's "holes remaining" replay follows the
    # group's actual sequence (a shotgun nine wraps, e.g. 17,18,1..7), not a
    # contiguous hole-number range. Normal round (start 1) → identical.
    from services.hole_plan import play_order as _play_order
    _order  = _play_order(foursome.round, foursome)
    _half   = (len(_order) or 18) // 2
    _pos_of = {h: i for i, h in enumerate(_order)}

    def _rem_after(hole: int) -> int:
        """Holes still to play after [hole], in PLAY ORDER.

        **Not `18 - hole`.** The two are the same integer only off the 1st
        tee: a group starting on the 13th plays 13..18,1..12, so hole 18 is
        the sixth it plays and six remain after it. This decides when a
        match is CLOSED OUT and the `&M` in `3&2` — the shotgun sweep fixed
        this shape in six other services and left the Nassau engine, where
        the play order was already in scope two lines up.
        """
        pos = _pos_of.get(hole)
        if pos is None or not _order:
            return max(0, 18 - hole)
        return len(_order) - 1 - pos

    def _rem_in_front(hole: int) -> int:
        """The same, bounded by the FIRST half — a front-nine bet is decided
        against the holes left in its own nine, not in the round."""
        pos = _pos_of.get(hole)
        if pos is None or not _order:
            return max(0, 9 - hole)
        return max(0, _half - 1 - pos)

    def _press_hole_seq(p) -> list:
        """The holes a press covers, in play order: from its start hole to the
        end of its nine."""
        if not _order:
            return list(range(p.start_hole, p.end_hole + 1))
        start_pos = _pos_of.get(p.start_hole)
        if start_pos is None:
            return []
        last_pos = (_half - 1) if start_pos < _half else (len(_order) - 1)
        return _order[start_pos:last_pos + 1]

    def _top_press_holes_remaining(p) -> int:
        """Replay top press margin → holes remaining when it closed."""
        seq = _press_hole_seq(p)
        press_margin = 0
        for i, h in enumerate(seq):
            w = winner_by_hole.get(h)
            if w is None:
                return 0
            if w == 'team1':
                press_margin += 1
            elif w == 'team2':
                press_margin -= 1
            holes_left = len(seq) - 1 - i
            if i >= len(seq) - 1 or abs(press_margin) > holes_left:
                return holes_left
        return 0

    def _bot_press_holes_remaining(p) -> int:
        """Replay bottom press points margin → holes remaining when it closed."""
        seq = _press_hole_seq(p)
        press_margin = 0
        for i, h in enumerate(seq):
            d = bot_delta_by_hole.get(h)
            if d is None:
                return 0
            press_margin += d
            holes_left = len(seq) - 1 - i
            pts_left = holes_left * 2
            if i >= len(seq) - 1 or abs(press_margin) > pts_left:
                return holes_left
        return 0

    all_presses_qs = NassauPress.objects.filter(game=game).order_by('side', 'triggered_on_hole')

    top_presses_out = []
    bot_presses_out = []
    for p in all_presses_qs:
        row = {
            'nine'            : p.nine,
            'press_type'      : p.press_type,
            'start_hole'      : p.start_hole,
            'end_hole'        : p.end_hole,
            'result'          : p.result,
            'margin'          : p.holes_up,
            'holes_remaining' : (
                _top_press_holes_remaining(p) if p.side == 'top'
                else _bot_press_holes_remaining(p)
            ),
        }
        if p.side == 'bottom':
            bot_presses_out.append(row)
        else:
            top_presses_out.append(row)

    top_press_total = sum(_press_payout(p['result']) for p in top_presses_out)
    bot_press_total = sum(_press_payout(p['result']) for p in bot_presses_out)

    # ── LIVE money: what changes hands if the match ended right now ───────
    #
    # The settled figures above read a stored `result`, which is only
    # written once a bet closes. So a match 2 UP on the front and 2 UP
    # overall reported `All square · now $0` — a board whose whole headline
    # is the money, saying nothing at all for most of a round (Design, 28
    # Oct 2026).
    #
    # A bet with a live margin counts to whoever is ahead; a bet that has
    # not started counts nothing, which is what keeps a not-yet-played back
    # nine out of the figure rather than guessing at it.
    def _live(result, margin, holes_played, unit) -> float:
        if result:
            return unit if result == 'team1' else (-unit if result == 'team2'
                                                   else 0.0)
        if not holes_played or not margin:
            return 0.0
        return unit if margin > 0 else -unit

    def _live_press(rows) -> float:
        return sum(_live(r['result'], r['margin'] or 0,
                         # A press with a margin has been played; its own
                         # holes are the only ones that count toward it.
                         1 if r['margin'] is not None else 0, press_unit)
                   for r in rows)

    # ── Standard bet payouts ─────────────────────────────────────────────��
    front9_pay  = _payout(game.front9_result)
    back9_pay   = _payout(game.back9_result)
    overall_pay = _payout(game.overall_result)

    bot_front9_pay  = _payout(game.bottom_front9_result)  if is_claremont else 0.0
    bot_back9_pay   = _payout(game.bottom_back9_result)   if is_claremont else 0.0
    bot_overall_pay = _payout(game.bottom_overall_result) if is_claremont else 0.0

    top_total = front9_pay + back9_pay + overall_pay + top_press_total
    bot_total = bot_front9_pay + bot_back9_pay + bot_overall_pay + bot_press_total

    # ── can_press ─────────────────────────────────────────────────────────
    #
    # **A manual press is offered while you are down but not yet down far
    # enough for that bet's AUTO press.** One rule, two numbers, because
    # the two numbers follow from what each bet is worth a hole (Paul, 8
    # Nov 2026):
    #
    #   top    — 1 point a hole, auto at 2 down  → offered at exactly 1 down
    #   bottom — 2 points a hole, auto at 4      → offered at 1, 2 or 3 down
    #
    # And never while anything is level: not the bet itself ("a side that is
    # even"), and not a press already running on it ("a press that is even").
    # A press you have just called has no holes yet, so it is even by
    # definition — which is what stops a second one being stacked on it.
    #
    # This replaces `margin != 0` alone, under which a side five down still
    # saw the button and a level match never did.
    AUTO_BAND = {'top': 2, 'bottom': 4}

    # **The nine by POSITION, not by hole number.** Off a shotgun from the
    # 10th the first hole played is 10, and `last_hole < 9` read that as the
    # BACK nine — the shotgun shape the sweep fixed in six other services.
    _played_pos = [_pos_of[h['hole']] for h in holes_out
                   if h['hole'] in _pos_of]
    _last_pos   = max(_played_pos) if _played_pos else -1
    _n_order    = len(_order) or 18

    def _manual_press_state(side, front_margin, back_margin, press_rows):
        """`(can_press, nine)` for one side of the match."""
        if game.press_mode not in ('manual', 'both'):
            return False, None
        if game.status != MatchStatus.IN_PROGRESS:
            return False, None
        # Belt-and-braces: a non-Claremont game has no bottom margins, so
        # the `margin == 0` test below already refuses — but that is an
        # invariant two hundred lines away, and this is the only local
        # statement of the rule. A mutation of this line passes; do not
        # take that as proof it is dead.
        if side == 'bottom' and not is_claremont:
            return False, None
        # A press cannot start after the last hole of its nine.
        if _last_pos < _half - 1:
            nine, margin = 'front', front_margin
        elif _last_pos < _n_order - 1:
            nine, margin = 'back', back_margin
        else:
            return False, None
        margin = margin or 0
        if margin == 0 or abs(margin) >= AUTO_BAND[side]:
            return False, None
        # An existing press on this nine that is still level — including one
        # called and not yet started, whose margin is None.
        for r in press_rows:
            if r['nine'] == nine and not r['result'] and not (r['margin'] or 0):
                return False, None
        if _press_blocked_by_cap(game, top_total + bot_total, margin):
            return False, None
        return True, nine

    can_press, press_available_nine = _manual_press_state(
        'top', front9_margin, back9_margin, top_presses_out)
    bot_can_press, bot_press_available_nine = _manual_press_state(
        'bottom', bot_front9_margin, bot_back9_margin, bot_presses_out)

    # ── LIVE money, split into the two Claremont games ────────────────────
    # One writer for both: `live_total` is their sum (clamped), and the
    # score-entry card's `top +$20 · bottom +$20` note is the two halves.
    # Computing either separately would be a second opinion about what a
    # live bet is worth.
    live_top = (
        _live(game.front9_result, front9_margin, holes_front, bet_unit)
        + _live(game.back9_result, back9_margin, holes_back, bet_unit)
        + _live(game.overall_result, overall_margin, len(holes_out), bet_unit)
        + _live_press(top_presses_out))
    live_bot = (
        _live(game.bottom_front9_result, bot_front9_margin, holes_front,
              bet_unit)
        + _live(game.bottom_back9_result, bot_back9_margin, holes_back,
                bet_unit)
        + _live(game.bottom_overall_result, bot_overall_margin, len(holes_out),
                bet_unit)
        + _live_press(bot_presses_out)) if is_claremont else 0.0

    # ── Team display ──────────────────────────────────────────────────────
    # Cup nassau always uses strokes-off-low regardless of stored handicap_mode.
    # Report the effective mode so the client UI draws dots correctly.
    effective_hcp_mode = (
        'strokes_off'
        if (game.handicap_mode != 'strokes_off' and _is_cup_nassau(foursome))
        else game.handicap_mode
    )

    # Net strokes actually in play for each player — drives the "(N)"
    # label next to each name on the spectator progress grid.  Mirrors
    # the arithmetic _build_so_score_index / build_score_index already
    # use, so the displayed number matches the per-hole stroke dots.
    phcp_by_pid: dict = {}
    real_memberships = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    # **CH and the index, beside the effective handicap.** Three different
    # numbers: the index is who a golfer is, the CH is what he plays off
    # today, and `phcp_in_play` is what THIS game gives him after its own
    # allowance. The board showed none of them (Paul, 31 Oct 2026).
    ch_of  = {m.player_id: m.course_handicap for m in real_memberships}
    idx_of = {m.player_id: str(m.player.handicap_index or '')
              for m in real_memberships}
    real_phcps = [
        m.playing_handicap or 0 for m in real_memberships
        if m.playing_handicap is not None
    ]
    low_phcp = min(real_phcps) if real_phcps else 0
    # Triple Nassau child: the "gets N" is a PAIRWISE difference (the lower of the
    # two match players plays to 0), matching _build_pair_so_index — not the
    # field low over all three players.
    if game.game_type in TRIPLE_CHILD_SLUGS:
        _pair_ids = set(_pair_player_ids(game))
        _pair_phcps = [m.playing_handicap or 0 for m in real_memberships
                       if m.player_id in _pair_ids
                       and m.playing_handicap is not None]
        if _pair_phcps:
            low_phcp = min(_pair_phcps)
    npct = game.net_percent or 100
    for m in real_memberships:
        phcp = m.playing_handicap or 0
        if effective_hcp_mode == 'gross':
            in_play = 0
        elif effective_hcp_mode == 'strokes_off':
            in_play = round_half_up(max(0, phcp - low_phcp) * npct / 100)
        else:   # net
            in_play = round_half_up(phcp * npct / 100)
        phcp_by_pid[m.player_id] = in_play

    # **In CARD order**, because `Team.players` has none of its own — see
    # `player_labels.card_order`, which is the one place that rule lives.
    from services.player_labels import card_order, in_card_order
    _mem_rank = card_order(foursome)

    def _team_players(team_num):
        if team_num not in teams:
            return []
        return [
            {
                'player_id'    : p.id,
                'name'         : p.name,
                'short_name'   : p.short_name,
                'phcp_in_play' : phcp_by_pid.get(p.id),
                'course_handicap': ch_of.get(p.id),
                'handicap_index' : idx_of.get(p.id, ''),
            }
            for p in in_card_order(teams[team_num].players.all(), _mem_rank)
        ]

    # Scorecard grid for the leaderboard card (Nassau has no scorecard otherwise).
    # Every hole in play (play order) carries par + stroke index so an observer
    # can see which holes get strokes in strokes-off, plus per-player gross +
    # strokes for the dots. score_index already honours the game's handicap mode,
    # so gross − net is the real per-hole allocation. Dots are retrospective (on
    # scored holes); the Index row conveys the whole-round stroke plan.
    from services.hole_plan import play_order as _play_order
    holes_in_play = _play_order(foursome.round, foursome) or list(range(1, 19))
    # Per-hole winner by NET best ball (lower team best net wins; a tie is
    # halved). Lets the scorecard tint the winning team's cells so you can see
    # who won each hole.
    winner_by_hole: dict = {}
    for h in holes_out:
        t1n, t2n = h.get('t1_net'), h.get('t2_net')
        if t1n is None or t2n is None:
            continue
        if t1n < t2n:
            winner_by_hole[h['hole']] = 1
        elif t2n < t1n:
            winner_by_hole[h['hole']] = 2
    team_of: dict = {}
    for _tnum, _tm in teams.items():
        for _p in _tm.players.all():
            team_of[_p.id] = _tnum
    # Only the game's PARTICIPANTS (team members) belong on this Nassau's
    # scorecard grid — for a subset side Nassau the other foursome members
    # aren't in the bet (docs/parallel-games.md). For a full 2v2 this is all
    # four, unchanged.
    participant_memberships = [
        m for m in real_memberships if m.player_id in team_of
    ]
    scorecard_players = [
        {'player_id': m.player_id, 'name': m.player.name,
         'short_name': m.player.short_name,
         'phcp_in_play': phcp_by_pid.get(m.player_id),
         'team': team_of.get(m.player_id)}
        for m in participant_memberships
    ]
    scorecard_holes = []
    for hn in holes_in_play:
        row_scores = []
        for m in participant_memberships:
            pid = m.player_id
            g   = gross_index.get(pid, {}).get(hn)
            # Prospective strokes: allocate the player's in-play handicap by
            # stroke index so the scorecard shows the FULL stroke plan (dots on
            # every hole a stroke falls, not just holes already played).  On a
            # played hole this equals gross − net.
            si      = si_by_hole.get(hn) or 18
            strokes = _strokes_on_hole(phcp_by_pid.get(pid, 0), si)
            row_scores.append({'player_id': pid, 'gross': g, 'strokes': strokes})
        scorecard_holes.append({
            'hole'         : hn,
            'par'          : par_by_hole.get(hn),
            'stroke_index' : si_by_hole.get(hn),
            'winner_id'    : None,
            'winner_team'  : winner_by_hole.get(hn),
            'scores'       : row_scores,
        })

    return {
        'scorecard'     : {
            'players'      : scorecard_players,
            'holes'        : scorecard_holes,
            'holes_in_play': holes_in_play,
        },
        'status'        : game.status,
        'game_type'     : game.game_type,
        'variant'       : effective_variant,
        'handicap_mode' : effective_hcp_mode,
        'net_percent'   : game.net_percent,
        'press_mode'    : game.press_mode,
        'bet_unit'      : bet_unit,
        'press_unit'    : press_unit,
        'play_front'    : game.play_front,
        'play_back'     : game.play_back,
        'play_overall'  : game.play_overall,
        'single_match'  : game.single_match,
        'variant'       : effective_variant,
        'teams'         : {
            'team1': _team_players(1),
            'team2': _team_players(2),
        },
        # ── Top (standard Nassau) bets ────────────────────────────────────
        'front9'  : {
            'result'            : game.front9_result,
            'margin'            : front9_margin,
            'holes_played'      : holes_front,
            'decided_margin'    : next(
                (h['front9_margin'] for h in holes_out
                 if h['front9_margin'] is not None
                 and abs(h['front9_margin']) > _rem_in_front(h['hole'])), None),
            'decided_remaining' : next(
                (_rem_in_front(h['hole']) for h in holes_out
                 if h['front9_margin'] is not None
                 and abs(h['front9_margin']) > _rem_in_front(h['hole'])), None),
        },
        'back9'   : {
            'result'            : game.back9_result,
            'margin'            : back9_margin,
            'holes_played'      : holes_back,
            'decided_margin'    : next(
                (h['back9_margin'] for h in holes_out
                 if h['back9_margin'] is not None
                 and abs(h['back9_margin']) > _rem_after(h['hole'])), None),
            'decided_remaining' : next(
                (_rem_after(h['hole']) for h in holes_out
                 if h['back9_margin'] is not None
                 and abs(h['back9_margin']) > _rem_after(h['hole'])), None),
        },
        'overall' : {
            'result'            : game.overall_result,
            'margin'            : overall_margin,
            'holes_played'      : len(holes_out),
            'decided_margin'    : next(
                (h['overall_margin'] for h in holes_out
                 if h['overall_margin'] is not None
                 and abs(h['overall_margin']) > _rem_after(h['hole'])), None),
            'decided_remaining' : next(
                (_rem_after(h['hole']) for h in holes_out
                 if h['overall_margin'] is not None
                 and abs(h['overall_margin']) > _rem_after(h['hole'])), None),
        },
        # ── Claremont bottom bets (null when variant != 'claremont') ──────
        # A bottom bet is a MATCH, not a points tally: it is 2 points a hole
        # (best ball + 2nd ball), so it is decided the moment the margin
        # exceeds the swing still available -- `2 x holes remaining`, where
        # the top bets need only `1 x`.  The engine has always known this
        # (`calculate_nassau` sets bot_*_decided_remaining off
        # `abs(up) > _rem * 2`) and the MONEY has always used it through
        # `_decided_dollars`.  It simply never reached the payload, so a
        # bottom bet could be won, paid, and still read "thru 7" on a board.
        'bottom_front9'  : {
            'result'  : game.bottom_front9_result,
            'margin'  : bot_front9_margin,
            'holes_played': holes_front,
            'decided_margin'    : next(
                (h['bottom_front9_margin'] for h in holes_out
                 if h.get('bottom_front9_margin') is not None
                 and abs(h['bottom_front9_margin']) > (_rem_in_front(h['hole'])) * 2), None),
            'decided_remaining' : next(
                (_rem_in_front(h['hole']) for h in holes_out
                 if h.get('bottom_front9_margin') is not None
                 and abs(h['bottom_front9_margin']) > (_rem_in_front(h['hole'])) * 2), None),
        } if is_claremont else None,
        'bottom_back9'   : {
            'result'  : game.bottom_back9_result,
            'margin'  : bot_back9_margin,
            'holes_played': holes_back,
            'decided_margin'    : next(
                (h['bottom_back9_margin'] for h in holes_out
                 if h.get('bottom_back9_margin') is not None
                 and abs(h['bottom_back9_margin']) > _rem_after(h['hole']) * 2), None),
            'decided_remaining' : next(
                (_rem_after(h['hole']) for h in holes_out
                 if h.get('bottom_back9_margin') is not None
                 and abs(h['bottom_back9_margin']) > _rem_after(h['hole']) * 2), None),
        } if is_claremont else None,
        'bottom_overall' : {
            'result'  : game.bottom_overall_result,
            'margin'  : bot_overall_margin,
            'holes_played': len(holes_out),
            'decided_margin'    : next(
                (h['bottom_overall_margin'] for h in holes_out
                 if h.get('bottom_overall_margin') is not None
                 and abs(h['bottom_overall_margin']) > _rem_after(h['hole']) * 2), None),
            'decided_remaining' : next(
                (_rem_after(h['hole']) for h in holes_out
                 if h.get('bottom_overall_margin') is not None
                 and abs(h['bottom_overall_margin']) > _rem_after(h['hole']) * 2), None),
        } if is_claremont else None,
        # ── Presses ───────────────────────────────────────────────────────
        'presses'        : top_presses_out,
        'bottom_presses' : bot_presses_out if is_claremont else [],
        # ── Payouts ───────────────────────────────────────────────────────
        'payouts' : {
            'front9'         : front9_pay,
            'back9'          : back9_pay,
            'overall'        : overall_pay,
            'presses'        : top_press_total,
            'top_total'      : top_total,
            'bottom_front9'  : bot_front9_pay,
            'bottom_back9'   : bot_back9_pay,
            'bottom_overall' : bot_overall_pay,
            'bottom_presses' : bot_press_total,
            'bottom_total'   : bot_total,
            'total'          : top_total + bot_total,
            # The same arithmetic over LIVE standings. `total` is the money
            # already banked; this is the money on the table.
            'live_total'     : _clamp_to_cap(live_top + live_bot,
                                             game.loss_cap),
            # The two halves of that figure, for a Claremont card that
            # splits it. **Unclamped**, so a reader can tell when the cap
            # has bitten: the halves no longer sum to `live_total`, which
            # is exactly when a split stops being a split.
            'live_top_total'   : live_top,
            'live_bottom_total': live_bot,
            # With 2 sides the cap is a clamp of the net total to ±cap (the
            # loser pays the winner the difference, capped). `total` is from
            # team1's perspective. None when uncapped.
            'loss_cap'       : float(game.loss_cap) if game.loss_cap is not None else None,
            'total_capped'   : _clamp_to_cap(top_total + bot_total, game.loss_cap),
        },
        'holes'               : holes_out,
        'can_press'           : can_press,
        'press_available_nine': press_available_nine,
        # The Claremont bottom game presses itself, at its own band.
        'bottom_can_press'           : bot_can_press,
        'bottom_press_available_nine': bot_press_available_nine,
        'phantom'             : _build_phantom_info(foursome, game.net_percent),
        'team1_colour'        : _team_colour(foursome, 1),
        'team2_colour'        : _team_colour(foursome, 2),
    }


# ---------------------------------------------------------------------------
# Singles Match score-entry card
# — `~/Downloads/handoff-singles-match-score-entry`
# ---------------------------------------------------------------------------

def singles_hole_card(foursome, hole: int) -> dict:
    """Everything the Singles Match score-entry screen draws for ONE hole.

    **The Fourball card with one golfer a side**, which is what the handoff
    asks for — the same dict, so the same Flutter tray draws both. The
    differences it carries are `kind` (`net` rather than `best ball`) and
    each side's `sub` line, which here is that golfer's handicap and what he
    gets on the hole rather than whose ball counted.

    Singles Match is an Overall-only Nassau (`game_type='match_18'`), so the
    match state, the close-out and the `&M` are `nassau_summary`'s — and the
    close-out is now read from the play order rather than `18 - hole`, which
    is a fix this card needed and every Nassau board had been living without.

    Returns `{}` when no Singles Match is set up.
    """
    from services.hole_plan import play_order
    from services.player_labels import first_names

    summary = nassau_summary(foursome, game_type='match_18')
    if not summary:
        return {}
    teams = summary.get('teams') or {}
    sides_in = {1: teams.get('team1') or [], 2: teams.get('team2') or []}
    if not sides_in[1] or not sides_in[2]:
        return {}

    order = play_order(foursome.round, foursome) or list(range(1, 19))
    if hole not in order:
        return {}
    pos = order.index(hole)

    card = summary.get('scorecard') or {}
    by_hole = {h['hole']: h for h in (card.get('holes') or [])}
    row = by_hole.get(hole) or {}
    score_of = {s['player_id']: s for s in (row.get('scores') or [])}
    # **The course handicap is on the TEAMS block**, not the scorecard's —
    # that one carries `phcp_in_play`, which is a different number.
    ch_of = {p['player_id']: p.get('course_handicap')
             for side in sides_in.values() for p in side}

    members = {m.player_id: m.player
               for m in foursome.memberships.select_related('player')
               if not m.player.is_phantom}
    label = first_names(
        {p['player_id']: members[p['player_id']]
         for side in sides_in.values() for p in side
         if p['player_id'] in members})

    per_hole = {h['hole']: h for h in (summary.get('holes') or [])}
    entry    = per_hole.get(hole) or {}
    winner   = entry.get('winner')

    overall = summary.get('overall') or {}
    # **The close-out is the engine's**, and its own `decided_remaining` is
    # holes left in PLAY ORDER — so the hole it happened on comes straight
    # back out of it rather than from a second comparison here.
    rem_at_close = overall.get('decided_remaining')
    closed_pos = (len(order) - 1 - rem_at_close
                  if rem_at_close is not None else None)
    if closed_pos is not None and not (0 <= closed_pos < len(order)):
        closed_pos = None                     # pragma: no cover - defensive
    finished_on = order[closed_pos] if closed_pos is not None else None
    # A match decided on the LAST hole is not a close-out: no holes stop
    # counting, and it takes `1 UP` rather than `1&0`. (The Fourball card
    # learnt this the same day.)
    closed_out = closed_pos is not None and closed_pos < len(order) - 1
    counts_for_card = closed_out and pos > closed_pos

    rows = []
    for n in (1, 2):
        for p in sides_in[n]:
            pid = p['player_id']
            sc  = score_of.get(pid) or {}
            gross = sc.get('gross')
            strokes = sc.get('strokes') or 0
            rows.append({
                'player_id'      : pid,
                'name'           : p.get('name') or '',
                'short'          : p.get('short_name') or '',
                'first'          : label.get(pid, ''),
                'course_handicap': ch_of.get(pid),
                'strokes'        : strokes,
                'gross'          : gross,
                'net'            : (gross - strokes) if gross is not None
                                   else None,
                'side'           : n,
                # There is no best ball to be, so nothing is ever marked.
                'counted'        : False,
            })

    sides = []
    for n in (1, 2):
        p = sides_in[n][0]
        pid = p['player_id']
        r = next(x for x in rows if x['player_id'] == pid)
        result = None
        if winner == 'halved':
            result = 'halved'
        elif winner in ('team1', 'team2'):
            result = 'won' if winner == f'team{n}' else 'lost'
        if counts_for_card:
            result = None
        ch = r['course_handicap']
        strokes = r['strokes']
        bits = []
        if ch is not None:
            bits.append(f'CH {ch}')
        bits.append('no stroke' if strokes == 0
                    else f'{strokes} stroke' + ('' if strokes == 1 else 's'))
        sides.append({
            'side'      : n,
            'label'     : label.get(pid, ''),
            'player_ids': [pid],
            'best'      : r['net'],
            'sub'       : ' · '.join(bits),
            'result'    : result,
        })

    scored = sum(1 for r in rows if r['gross'] is not None)
    hole_complete = scored == len(rows)

    # ── The match card ──────────────────────────────────────────────────────
    holes_up = entry.get('overall_margin')
    if holes_up is None:
        prior = [per_hole[h] for h in order[:pos] if h in per_hole]
        holes_up = next((p['overall_margin'] for p in reversed(prior)
                         if p.get('overall_margin') is not None), 0)
    leader = 1 if holes_up > 0 else (2 if holes_up < 0 else None)
    margin = abs(holes_up)
    played = len([h for h in order[:pos + 1] if h in per_hole])
    to_play = len(order) - 1 - pos
    lead_label = sides[leader - 1]['label'] if leader else ''

    if closed_out and pos >= closed_pos:
        to_play_at_close = overall.get('decided_remaining') or 0
        decided = abs(overall.get('decided_margin') or margin)
        figure = (f'{decided}&{to_play_at_close}' if to_play_at_close
                  else f'{decided} UP')
        # **Singular verbs** — one golfer, not a pair.
        headline = f'{lead_label} won' if counts_for_card \
            else f'{lead_label} wins'
        after = list(order[closed_pos + 1:])
        if counts_for_card:
            line = (f'Closed out on {finished_on}. '
                    'Scores here go on the card only.')
        elif after:
            span = (f'{after[0]}–{after[-1]}' if len(after) > 1
                    else f'{after[0]}')
            line = f'Closed out on {finished_on}. Holes {span} don’t count.'
        else:                                 # pragma: no cover - defensive
            line = f'Closed out on {finished_on}.'
    elif pos == len(order) - 1 and hole in per_hole:
        if leader is None:
            headline, figure = 'Match halved', 'AS'
            line = 'Level after 18 · a push'
        else:
            headline, figure = f'{lead_label} wins', f'{margin} UP'
            line = f'Final after {len(order)}'
    elif leader is None:
        headline, figure = 'All square', 'AS'
        line = f'thru {played} · {to_play} to play'
    else:
        headline, figure = lead_label, f'{margin} UP'
        line = f'thru {played} · {to_play} to play'

    if closed_out and pos >= closed_pos:
        state = f'{headline} {figure}'
    elif leader is None:
        state = 'All square'
    else:
        state = f'{lead_label} {margin} UP'

    block = (pos // 9) * 9
    strip = []
    for i, h in enumerate(order[block:block + 9], start=block):
        e = per_hole.get(h)
        res = None
        if e and e.get('winner'):
            res = {'team1': 'T1', 'team2': 'T2'}.get(e['winner'], 'Halved')
        strip.append({
            'hole'   : h,
            'result' : res,
            'played' : bool(e and e.get('winner')),
            'dead'   : bool(closed_out and i > closed_pos),
        })

    bet = float(summary.get('bet_unit') or 0)
    money = []
    if bet:
        for n in (1, 2):
            amount = 0.0 if leader is None else (bet if n == leader else -bet)
            money.append({'side': n, 'label': sides[n - 1]['label'],
                          'amount': amount})
        money.sort(key=lambda e: -e['amount'])

    return {
        'hole'        : hole,
        'par'         : row.get('par'),
        'stroke_index': row.get('stroke_index'),
        'yards'       : None,
        'nine'        : 'front nine' if hole <= 9 else 'back nine',
        'thru'        : pos + 1,
        'stake'       : bet,
        'kind'        : 'net',
        'players'     : rows,
        'sides'       : sides,
        'scored'      : scored,
        'hole_complete': hole_complete,
        'counts_for_card': counts_for_card,
        'closed_out'  : closed_out,
        'finished_on_hole': finished_on if closed_out else None,
        'match'       : {
            'leader'  : leader,
            'margin'  : margin,
            'headline': headline,
            'figure'  : figure,
            'line'    : line,
            'state'   : state,
            'is_final': (pos == len(order) - 1 and hole in per_hole)
                        or (closed_out and pos >= closed_pos),
        },
        'strip'       : strip,
        'money'       : money,
        'round_over'  : hole_complete and pos == len(order) - 1,
        'next_hole'   : order[pos + 1] if pos + 1 < len(order) else None,
    }


# ---------------------------------------------------------------------------
# Nassau score-entry card — `~/Downloads/handoff-nassau-score-entry`
# ---------------------------------------------------------------------------

def _bet_chip(bet, label, *, points=False, stake=None):
    """One bet's chip: what it says, and whether it is live or over.

    `decided_remaining` is the engine's and is now play-order aware, so the
    `&M` here is the same number every other surface shows.
    """
    played = bet.get('holes_played') or 0
    margin = bet.get('margin') or 0
    rem    = bet.get('decided_remaining')
    if bet.get('result') or rem is not None:
        decided = abs(bet.get('decided_margin') or margin)
        if bet.get('result') == 'halved' or (decided == 0 and rem is None):
            text = 'Push'
        elif rem:
            text = f'{decided}&{rem}'
        elif points:
            text = f'+{decided}'
        else:
            text = f'{decided} UP'
        leader = 1 if (bet.get('decided_margin') or margin) > 0 else (
            2 if (bet.get('decided_margin') or margin) < 0 else None)
        return {'text': text, 'state': 'final', 'leader': leader,
                'manual': False}
    if played == 0:
        return None            # not started — the caller says when it does
    if margin == 0:
        return {'text': f'{label} E' if points else f'{label} AS',
                'state': 'live', 'leader': None, 'manual': False}
    sign = '+' if margin > 0 else '−'
    body = (f'{sign}{abs(margin)}' if points else f'{abs(margin)} UP')
    return {'text': f'{label} {body}', 'state': 'live',
            'leader': 1 if margin > 0 else 2, 'manual': False}


def nassau_hole_card(foursome, hole: int) -> dict:
    """Everything the Nassau score-entry screen draws for ONE hole.

    **Every bet, press and figure is the engine's.** The press rules are the
    sharpest case in the app: a press starts at 2 down on the LATEST bet in
    a nine (4 down on a Claremont bottom bet, which is two points a hole),
    runs to the end of that nine, and closes out against its own holes left.
    `calculate_nassau` has all of that and `nassau_summary` reports it, so
    this composes CHIPS out of those numbers and derives no rule of its own.

    Returns `{}` when no Nassau is set up for this foursome.
    """
    from services.hole_plan import play_order
    from services.player_labels import first_names

    summary = nassau_summary(foursome)
    if not summary:
        return {}
    teams = summary.get('teams') or {}
    sides_in = {1: teams.get('team1') or [], 2: teams.get('team2') or []}
    if not sides_in[1] or not sides_in[2]:
        return {}

    order = play_order(foursome.round, foursome) or list(range(1, 19))
    if hole not in order:
        return {}
    pos = order.index(hole)
    half = len(order) // 2

    members = {m.player_id: m.player
               for m in foursome.memberships.select_related('player')
               if not m.player.is_phantom}
    label = first_names({p['player_id']: members[p['player_id']]
                         for side in sides_in.values() for p in side
                         if p['player_id'] in members})

    card = summary.get('scorecard') or {}
    by_hole = {h['hole']: h for h in (card.get('holes') or [])}
    row = by_hole.get(hole) or {}
    score_of = {s['player_id']: s for s in (row.get('scores') or [])}
    ch_of = {p['player_id']: p.get('course_handicap')
             for side in sides_in.values() for p in side}

    per_hole = {h['hole']: h for h in (summary.get('holes') or [])}
    entry    = per_hole.get(hole) or {}
    played   = [h for h in order[:pos + 1] if h in per_hole]

    rows = []
    for n in (1, 2):
        for p in sides_in[n]:
            pid = p['player_id']
            sc  = score_of.get(pid) or {}
            gross, strokes = sc.get('gross'), (sc.get('strokes') or 0)
            rows.append({
                'player_id'      : pid,
                'name'           : p.get('name') or '',
                'short'          : p.get('short_name') or '',
                'first'          : label.get(pid, ''),
                'course_handicap': ch_of.get(pid),
                'strokes'        : strokes,
                'gross'          : gross,
                'net'            : (gross - strokes) if gross is not None
                                   else None,
                'side'           : n,
                'counted'        : False,
            })

    nets = {1: entry.get('t1_net'), 2: entry.get('t2_net')}
    seconds = {1: entry.get('t1_2nd_net'), 2: entry.get('t2_2nd_net')}
    winner = entry.get('winner')
    for n in (1, 2):
        if nets[n] is None:
            continue
        for r in rows:
            if r['side'] == n and r['net'] == nets[n] and not winner is None:
                r['counted'] = True

    singles = len(sides_in[1]) == 1 and len(sides_in[2]) == 1
    sides = []
    for n in (1, 2):
        ids = [p['player_id'] for p in sides_in[n]]
        if singles:
            pid = ids[0]
            r = next(x for x in rows if x['player_id'] == pid)
            strokes = r['strokes']
            bits = []
            if r['course_handicap'] is not None:
                bits.append(f"CH {r['course_handicap']}")
            bits.append('no stroke' if strokes == 0
                        else f'{strokes} stroke' + ('' if strokes == 1 else 's'))
            sub = ' · '.join(bits)
        else:
            counted = [r['first'] for r in rows
                       if r['side'] == n and r['counted']]
            sub = ('counts: ' + ' · '.join(counted)) if counted else ''
        result = None
        if winner == 'halved':
            result = 'halved'
        elif winner in ('team1', 'team2'):
            result = 'won' if winner == f'team{n}' else 'lost'
        sides.append({
            'side'      : n,
            'label'     : ' + '.join(label.get(p, '') for p in ids),
            'player_ids': ids,
            'best'      : nets[n],
            'sub'       : sub,
            'result'    : result,
        })

    # **Why the hole went the way it did.** `2nd ball` is not a second rule
    # here: equal best nets with a winner can only BE the 2nd-ball tiebreak,
    # which is the engine's own option.
    reason = ''
    if winner == 'halved':
        reason = (f'net {nets[1]} v {nets[2]}'
                  if nets[1] is not None else '')
    elif winner in ('team1', 'team2'):
        if nets[1] == nets[2] and seconds[1] is not None:
            reason = f'2nd ball {seconds[1]} v {seconds[2]}'
        else:
            reason = f'net {nets[1]} v {nets[2]}'

    scored = sum(1 for r in rows if r['gross'] is not None)
    hole_complete = scored == len(rows)

    # ── The bet lines ──────────────────────────────────────────────────────
    # **The bottom game keeps its own presses.** `presses` is the TOP
    # game's; Claremont's bottom presses are `bottom_presses`, and they
    # press at 4 down rather than 2 — so reading one list for both would
    # draw the top game's presses under the bottom game's lines.
    press_rows = {
        '': summary.get('presses') or [],
        'bottom_': summary.get('bottom_presses') or [],
    }
    last_played = played[-1] if played else None

    def _press_chips(nine, prefix='', points=False):
        out = []
        for i, p in enumerate((x for x in press_rows[prefix]
                               if x.get('nine') == nine), start=1):
            name = f'P{i} manual' if p.get('press_type') == 'manual' \
                else f'P{i}'
            start = p.get('start_hole')
            # **A press that has not started yet.** It is called on one hole
            # and runs from the NEXT, so until that hole is played it is a
            # promise rather than a bet.
            if start is not None and (last_played is None
                                      or order.index(start) > order.index(
                                          last_played)):
                out.append({'text': f'{name} starts {start}',
                            'state': 'pending', 'leader': None,
                            'manual': p.get('press_type') == 'manual'})
                continue
            m = p.get('margin') or 0
            rem = p.get('holes_remaining')
            if p.get('result') or (rem is not None and rem > 0
                                   and abs(m) > rem * (2 if points else 1)):
                if m == 0:
                    text = 'Push'
                elif rem:
                    text = f'{abs(m)}&{rem}'
                elif points:
                    text = f'{name} {"+" if m > 0 else "−"}{abs(m)}'
                else:
                    text = f'{abs(m)} UP'
                out.append({'text': text, 'state': 'final',
                            'leader': 1 if m > 0 else (2 if m < 0 else None),
                            'manual': p.get('press_type') == 'manual'})
                continue
            if m == 0:
                body = 'E' if points else 'AS'
            else:
                body = (f'{"+" if m > 0 else "−"}{abs(m)}' if points
                        else f'{abs(m)} UP')
            out.append({'text': f'{name} {body}', 'state': 'live',
                        'leader': 1 if m > 0 else (2 if m < 0 else None),
                        'manual': p.get('press_type') == 'manual'})
        return out

    def _lines(prefix, points=False):
        out = []
        for key, name, nine in (('front', 'Front', 'front'),
                                ('back', 'Back', 'back'),
                                ('overall', 'Overall', None)):
            bet = summary.get(f'{prefix}{key}9' if key != 'overall'
                              else f'{prefix}overall') or {}
            chip = _bet_chip(bet, name, points=points)
            chips = []
            if chip is None:
                # Not started. The back nine says WHEN, because a group
                # on the 7th wants to know it has not been forgotten.
                start = order[half] if key == 'back' and len(order) > half \
                    else None
                chips.append({
                    'text': f'{name} starts {start}' if start
                            else f'{name} not started',
                    'state': 'pending', 'leader': None, 'manual': False})
            else:
                chips.append(chip)
            if nine:
                chips.extend(_press_chips(nine, prefix=prefix,
                                          points=points))
            out.append({'key': key, 'label': name.upper(), 'chips': chips})
        return out

    claremont = (summary.get('variant') == 'claremont')
    top_lines = _lines('')
    bottom = None
    if claremont:
        balls = []
        delta = entry.get('bottom_delta')
        for n in (1, 2):
            other = 2 if n == 1 else 1
            lo, hi = nets[n], seconds[n]
            balls.append({
                'side' : n,
                'label': sides[n - 1]['label'],
                'low'  : lo,
                'high' : hi,
                'low_won' : lo is not None and nets[other] is not None
                            and lo < nets[other],
                'high_won': hi is not None and seconds[other] is not None
                            and hi < seconds[other],
            })
        bottom = {
            'balls' : balls,
            'points': delta,
            'lines' : _lines('bottom_', points=True),
        }

    # ── Money ──────────────────────────────────────────────────────────────
    pay = summary.get('payouts') or {}
    bet_unit = float(summary.get('bet_unit') or 0)
    # **Live, as if the match ended here** — which is what `Each · now`
    # means, and what the board's own `live_total` already is. Once every
    # bet has closed `live_total` IS the settled figure, so the tray does
    # not need a second number for `Final, each`.
    amount = float(pay.get('live_total') or 0)
    money = []
    if bet_unit:
        for n in (1, 2):
            money.append({'side': n, 'label': sides[n - 1]['label'],
                          'amount': amount if n == 1 else -amount})
        money.sort(key=lambda e: -e['amount'])
    # **The note splits the figure above it, so it has to be the same
    # figure** — the LIVE one. `top_total` / `bottom_total` are the money
    # already banked, which mid-round reads `top +$0 · bottom +$0` under a
    # headline of +$40. And it is drawn only when the halves still SUM to
    # the headline: the cap clamps the total and not the parts, so once it
    # bites a split is no longer a split.
    money_note = ''
    if claremont and money:
        top = float(pay.get('live_top_total') or 0)
        bot = float(pay.get('live_bottom_total') or 0)
        if abs(top + bot - amount) < 0.005:
            lead = money[0]['side']
            sign = 1 if lead == 1 else -1
            money_note = (
                f'top {_signed_money(top * sign)} · '
                f'bottom {_signed_money(bot * sign)}, for '
                f"{sides[lead - 1]['label']}")

    # **No bet pill.** The handoff puts the nine's standing on the hole
    # card; the screen's own standing ribbon has carried it since Nassau
    # shipped (`utils/nassau_standing.dart` → `_nassauRibbon`), at the top,
    # visible while scores are being entered rather than only once the tray
    # is up. A second copy is a second thing to keep in step.
    this_nine = 'front' if pos < half else 'back'

    return {
        'hole'        : hole,
        'par'         : row.get('par'),
        'stroke_index': row.get('stroke_index'),
        'yards'       : None,
        'nine'        : 'front nine' if this_nine == 'front' else 'back nine',
        'thru'        : pos + 1,
        'stake'       : bet_unit,
        'press_stake' : float(summary.get('press_unit') or 0),
        'kind'        : 'nassau',
        'singles'     : singles,
        'claremont'   : claremont,
        'players'     : rows,
        'sides'       : sides,
        'winner'      : winner,
        'reason'      : reason,
        'scored'      : scored,
        'hole_complete': hole_complete,
        'lines'       : top_lines,
        'bottom'      : bottom,
        'can_press'   : bool(summary.get('can_press')),
        'press_nine'  : summary.get('press_available_nine'),
        'can_press_bottom' : bool(summary.get('bottom_can_press')),
        'press_nine_bottom': summary.get('bottom_press_available_nine'),
        'money'       : money,
        'money_note'  : money_note,
        'round_over'  : hole_complete and pos == len(order) - 1,
        'next_hole'   : order[pos + 1] if pos + 1 < len(order) else None,
    }


def _signed_money(v: float) -> str:
    sign = '+' if v > 0 else ('−' if v < 0 else '')
    a = abs(v)
    body = f'{a:g}' if a == int(a) else f'{a:.2f}'
    return f'{sign}${body}'
