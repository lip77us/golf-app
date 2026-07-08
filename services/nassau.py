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

from core.models import HandicapMode, MatchStatus
from games.models import NassauGame, NassauTeam, NassauHoleScore, NassauPress
from scoring.handicap import build_score_index
from scoring.models import HoleScore


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
        so = round(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
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
        so = round(max(0, eff_hcp - low) * net_percent / 100)
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


def _get_score_index(foursome, game) -> dict:
    """
    Return player_id → hole_number → adjusted_score based on game's handicap mode.

    Cup Nassau is always fourball (2v2 best-ball), so handicap is always
    strokes-off the lowest player in the group regardless of the stored
    handicap_mode.  Casual Nassau uses whatever mode was configured.
    """
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
    loss_cap             = None,
) -> NassauGame:
    """
    Create (or replace) the NassauGame and its two fixed teams.

    team1_ids / team2_ids: lists of Player PKs (1 or 2 each for head-to-head
    or 2v2).  Deleting the old NassauGame cascades to teams, hole scores, and
    all presses.

    variant: 'none' | 'tiebreak_2nd' | 'claremont'
    """
    NassauGame.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))
    if variant not in ('none', 'tiebreak_2nd', 'claremont'):
        variant = 'none'

    if loss_cap is not None:
        loss_cap = Decimal(str(loss_cap))
        if loss_cap < 0:
            loss_cap = None

    game = NassauGame.objects.create(
        foursome      = foursome,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        press_mode    = press_mode,
        press_unit    = press_unit,
        variant       = variant,
        play_front    = play_front,
        play_back     = play_back,
        play_overall  = play_overall,
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

def add_manual_press(foursome, start_hole: int) -> NassauPress:
    """
    Record a manual press called by the losing team.  The press starts on
    start_hole and runs to the end of the nine that contains start_hole.

    The winning team cannot decline — this function does not need an
    acceptance step; it immediately persists the press.

    Raises ValueError if:
      - No NassauGame exists for this foursome.
      - The game's press_mode does not allow manual presses.
      - start_hole is not a valid active nine hole (1–18).
      - A manual press already covers start_hole in the same nine.

    After creating the press row, recalculates the game so its running
    margin is populated immediately.
    """
    try:
        game = NassauGame.objects.get(foursome=foursome)
    except NassauGame.DoesNotExist:
        raise ValueError("No Nassau game set up for this foursome.")

    if game.press_mode not in ('manual', 'both'):
        raise ValueError(f"Press mode '{game.press_mode}' does not allow manual presses.")

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

    # Prevent duplicate manual presses with the same start_hole
    if NassauPress.objects.filter(
        game=game, press_type='manual', start_hole=start_hole
    ).exists():
        raise ValueError(f"A manual press already starts on hole {start_hole}.")

    # Cap gate (defends the API directly, mirroring nassau_summary.can_press):
    # a side that has hit the cap can't press — it would be a free option.
    if game.loss_cap is not None:
        s = nassau_summary(foursome)
        if s is not None:
            nine_margin = (s['front9']['margin'] if nine == 'front'
                           else s['back9']['margin'])
            if _press_blocked_by_cap(game, s['payouts']['total'], nine_margin):
                raise ValueError(
                    "That side has reached its loss cap — pressing is closed.")

    press = NassauPress.objects.create(
        game             = game,
        nine             = nine,
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
    calculate_nassau(foursome)
    return NassauPress.objects.get(game=game, press_type='manual', start_hole=start_hole)


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

@transaction.atomic
def calculate_nassau(foursome) -> NassauGame | None:
    """
    Recompute all NassauHoleScore rows, detect auto-presses, update manual
    press results, and resolve the three standard bets (and Claremont bottom
    bets when variant == 'claremont').

    Manual presses (press_type='manual', side='top') are preserved across
    calls — only their result / holes_up are updated.  Auto presses (top and
    bottom) are rebuilt from scratch each call.

    Returns the updated NassauGame, or None if no game exists.
    """
    try:
        game = NassauGame.objects.prefetch_related('teams__players').get(
            foursome=foursome
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
    half           = n // 2
    pos_of         = {h: i for i, h in enumerate(order)}
    front_last_pos = half - 1
    back_last_pos  = n - 1
    # Hole NUMBERS of each nine's last hole (for press end_hole display).
    front_end_hole = order[front_last_pos] if order else 9
    back_end_hole  = order[back_last_pos]  if order else 18

    is_claremont    = game.variant == 'claremont'
    is_tiebreak_2nd = game.variant == 'tiebreak_2nd'
    needs_2nd_ball  = is_claremont or is_tiebreak_2nd

    # ── Preserve top manual presses ───────────────────────────────────────
    manual_press_starts = list(
        NassauPress.objects.filter(game=game, press_type='manual', side='top')
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

def nassau_summary(foursome) -> dict | None:
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
    }
    """
    try:
        game = NassauGame.objects.prefetch_related('teams__players').get(
            foursome=foursome
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

    is_claremont    = game.variant == 'claremont'
    is_tiebreak_2nd = game.variant == 'tiebreak_2nd'

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

    # ── Standard bet payouts ─────────────────────────────────────────────��
    front9_pay  = _payout(game.front9_result)
    back9_pay   = _payout(game.back9_result)
    overall_pay = _payout(game.overall_result)

    bot_front9_pay  = _payout(game.bottom_front9_result)  if is_claremont else 0.0
    bot_back9_pay   = _payout(game.bottom_back9_result)   if is_claremont else 0.0
    bot_overall_pay = _payout(game.bottom_overall_result) if is_claremont else 0.0

    top_total = front9_pay + back9_pay + overall_pay + top_press_total
    bot_total = bot_front9_pay + bot_back9_pay + bot_overall_pay + bot_press_total

    # ── can_press: available when manual presses allowed and game active ──
    can_press = False
    press_available_nine = None
    if game.press_mode in ('manual', 'both') and game.status == MatchStatus.IN_PROGRESS:
        last_hole = holes_out[-1]['hole'] if holes_out else 0
        if last_hole < 9:
            if front9_margin != 0:
                can_press = True
                press_available_nine = 'front'
        elif last_hole < 18:
            if back9_margin != 0:
                can_press = True
                press_available_nine = 'back'
        # Cap gate: a side that has hit the cap can't press (it would be free).
        if can_press:
            nine_margin = (front9_margin if press_available_nine == 'front'
                           else back9_margin)
            if _press_blocked_by_cap(game, top_total + bot_total, nine_margin):
                can_press = False
                press_available_nine = None

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
    real_phcps = [
        m.playing_handicap or 0 for m in real_memberships
        if m.playing_handicap is not None
    ]
    low_phcp = min(real_phcps) if real_phcps else 0
    npct = game.net_percent or 100
    for m in real_memberships:
        phcp = m.playing_handicap or 0
        if effective_hcp_mode == 'gross':
            in_play = 0
        elif effective_hcp_mode == 'strokes_off':
            in_play = round(max(0, phcp - low_phcp) * npct / 100)
        else:   # net
            in_play = round(phcp * npct / 100)
        phcp_by_pid[m.player_id] = in_play

    def _team_players(team_num):
        if team_num not in teams:
            return []
        return [
            {
                'player_id'    : p.id,
                'name'         : p.name,
                'short_name'   : p.short_name,
                'phcp_in_play' : phcp_by_pid.get(p.id),
            }
            for p in teams[team_num].players.all()
        ]

    return {
        'status'        : game.status,
        'variant'       : game.variant,
        'handicap_mode' : effective_hcp_mode,
        'net_percent'   : game.net_percent,
        'press_mode'    : game.press_mode,
        'bet_unit'      : bet_unit,
        'press_unit'    : press_unit,
        'play_front'    : game.play_front,
        'play_back'     : game.play_back,
        'play_overall'  : game.play_overall,
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
                 if h['hole'] <= 9 and h['front9_margin'] is not None
                 and abs(h['front9_margin']) > 9 - h['hole']), None),
            'decided_remaining' : next(
                (9 - h['hole'] for h in holes_out
                 if h['hole'] <= 9 and h['front9_margin'] is not None
                 and abs(h['front9_margin']) > 9 - h['hole']), None),
        },
        'back9'   : {
            'result'            : game.back9_result,
            'margin'            : back9_margin,
            'holes_played'      : holes_back,
            'decided_margin'    : next(
                (h['back9_margin'] for h in holes_out
                 if h['hole'] > 9 and h['back9_margin'] is not None
                 and abs(h['back9_margin']) > 18 - h['hole']), None),
            'decided_remaining' : next(
                (18 - h['hole'] for h in holes_out
                 if h['hole'] > 9 and h['back9_margin'] is not None
                 and abs(h['back9_margin']) > 18 - h['hole']), None),
        },
        'overall' : {
            'result'            : game.overall_result,
            'margin'            : overall_margin,
            'holes_played'      : len(holes_out),
            'decided_margin'    : next(
                (h['overall_margin'] for h in holes_out
                 if h['overall_margin'] is not None
                 and abs(h['overall_margin']) > 18 - h['hole']), None),
            'decided_remaining' : next(
                (18 - h['hole'] for h in holes_out
                 if h['overall_margin'] is not None
                 and abs(h['overall_margin']) > 18 - h['hole']), None),
        },
        # ── Claremont bottom bets (null when variant != 'claremont') ──────
        'bottom_front9'  : {
            'result'  : game.bottom_front9_result,
            'margin'  : bot_front9_margin,
            'holes_played': holes_front,
        } if is_claremont else None,
        'bottom_back9'   : {
            'result'  : game.bottom_back9_result,
            'margin'  : bot_back9_margin,
            'holes_played': holes_back,
        } if is_claremont else None,
        'bottom_overall' : {
            'result'  : game.bottom_overall_result,
            'margin'  : bot_overall_margin,
            'holes_played': len(holes_out),
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
            # With 2 sides the cap is a clamp of the net total to ±cap (the
            # loser pays the winner the difference, capped). `total` is from
            # team1's perspective. None when uncapped.
            'loss_cap'       : float(game.loss_cap) if game.loss_cap is not None else None,
            'total_capped'   : _clamp_to_cap(top_total + bot_total, game.loss_cap),
        },
        'holes'               : holes_out,
        'can_press'           : can_press,
        'press_available_nine': press_available_nine,
        'phantom'             : _build_phantom_info(foursome, game.net_percent),
        'team1_colour'        : _team_colour(foursome, 1),
        'team2_colour'        : _team_colour(foursome, 2),
    }
