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
  Gross: raw scores compared directly.
  Net: playing_handicap × (net_percent / 100) allocated by stroke index.
  Strokes-off: low playing handicap plays to 0; others get the difference.

Press rules
~~~~~~~~~~~
* Press bets are worth NassauGame.press_unit (explicit dollar amount).
* press_mode controls which types of presses can occur:
    none   – no presses
    manual – losing team calls a press at any point; winning team must accept
             (they cannot decline).  Recorded via add_manual_press().
    auto   – automatic press when the losing team goes 2-down within a nine
    both   – manual AND auto presses both active
* Each press covers the remaining holes of the nine in which it fires
  (not the full nine from scratch, not the overall bet).
* Multiple presses per nine are possible.
* Manual presses are stored as NassauPress rows with press_type='manual'.
  They survive calculate_nassau() calls (only auto presses are rebuilt).

Public API
~~~~~~~~~~
    game    = setup_nassau(foursome, team1_ids, team2_ids,
                           handicap_mode, net_percent, press_mode, press_unit)
    result  = calculate_nassau(foursome)
    summary = nassau_summary(foursome)
    press   = add_manual_press(foursome, start_hole)   # losing team calls press
"""

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import NassauGame, NassauTeam, NassauHoleScore, NassauPress
from scoring.handicap import build_score_index


# ---------------------------------------------------------------------------
# Score index helpers
# ---------------------------------------------------------------------------

def _build_so_score_index(foursome) -> dict:
    """
    Strokes-Off-Low score index for Nassau.
    Lowest playing handicap plays to 0; each other player gets
    (own_phcp - low) strokes allocated by stroke index (SI).
    Mirrors the same helper in services/skins.py and services/points_531.py.

    SI comes from m.tee.hole(hole_num) — NOT from HoleScore (which stores
    no stroke_index column).
    """
    score_index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)

    memberships = list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player__is_phantom=False)
    )
    if not memberships:
        return score_index

    phcps = [m.playing_handicap for m in memberships
             if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0

    for m in memberships:
        if m.tee_id is None:
            continue
        so = max(0, (m.playing_handicap or 0) - low)
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
    """Return player_id → hole_number → adjusted_score based on game's handicap mode."""
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_so_score_index(foursome)
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
) -> NassauGame:
    """
    Create (or replace) the NassauGame and its two fixed teams.

    team1_ids / team2_ids: lists of Player PKs (1 or 2 each for head-to-head
    or 2v2).  Deleting the old NassauGame cascades to teams, hole scores, and
    all presses.
    """
    NassauGame.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))

    game = NassauGame.objects.create(
        foursome      = foursome,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        press_mode    = press_mode,
        press_unit    = press_unit,
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

    nine     = 'front' if start_hole <= 9 else 'back'
    end_hole = 9       if nine == 'front' else 18

    # Prevent duplicate manual presses with the same start_hole
    if NassauPress.objects.filter(
        game=game, press_type='manual', start_hole=start_hole
    ).exists():
        raise ValueError(f"A manual press already starts on hole {start_hole}.")

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
    press results, and resolve the three standard bets.

    Manual presses (press_type='manual') are preserved across calls —
    only their result / holes_up are updated.  Auto presses are rebuilt
    from scratch each call.

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

    # ── Preserve manual presses ───────────────────────────────────────────
    # Save their start_hole / nine before we touch anything, so we can
    # re-process them in the calculation loop.
    manual_press_starts = list(
        NassauPress.objects.filter(game=game, press_type='manual')
        .values_list('start_hole', flat=True)
    )

    # Delete all NassauHoleScore rows and ALL press rows.
    # Manual presses will be recreated below with fresh results.
    NassauHoleScore.objects.filter(game=game).delete()
    NassauPress.objects.filter(game=game).delete()

    # ── Running state ─────────────────────────────────────────────────────
    front9_up  = 0
    back9_up   = 0
    overall_up = 0

    # Record the margin and holes remaining at the FIRST moment each bet is
    # decided (so we can freeze the display at "5&4" rather than letting it
    # drift to "6&3" when play continues after the bet is settled).
    front9_decided_margin    = None   # e.g. +5 means T1 5-up when decided
    front9_decided_remaining = None   # holes left at that moment (e.g. 4)
    back9_decided_margin     = None
    back9_decided_remaining  = None
    overall_decided_margin    = None
    overall_decided_remaining = None

    # Active presses: list of dicts tracking running margin
    # {'nine', 'press_type', 'trigger_hole', 'start', 'end', 'margin'}
    active_presses:    list = []
    completed_presses: list = []

    front_holes = set(range(1, 10))
    back_holes  = set(range(10, 19))

    # Index manual press starts by nine so we can trigger them at the right hole
    manual_front = sorted([s for s in manual_press_starts if s in front_holes])
    manual_back  = sorted([s for s in manual_press_starts if s in back_holes])

    # Auto-press threshold tracking.
    # Signed nine margin values at which an auto-press has already fired:
    #   positive value  = T1 up by that amount (T2 was N-down)
    #   negative value  = T2 up by that amount (T1 was N-down)
    # Each threshold fires at most once per nine, regardless of whether the
    # margin later recovers and returns to the same level.
    # Thresholds that can trigger a press: ±2, ±4, ±6, ±8.
    AUTO_PRESS_THRESHOLDS = frozenset({2, 4, 6, 8, -2, -4, -6, -8})
    front9_thresholds_fired: set = set()
    back9_thresholds_fired:  set = set()

    hole_score_objs = []
    auto_enabled   = game.press_mode in ('auto', 'both')
    manual_enabled = game.press_mode in ('manual', 'both')

    for hole_num in range(1, 19):
        t1_net = _best_ball(t1, hole_num, score_index)
        t2_net = _best_ball(t2, hole_num, score_index)

        if t1_net is None or t2_net is None:
            break  # stop at first incomplete hole

        # Hole winner
        if t1_net < t2_net:
            winner, delta = 'team1',  1
        elif t2_net < t1_net:
            winner, delta = 'team2', -1
        else:
            winner, delta = 'halved', 0

        overall_up += delta

        if hole_num in front_holes:
            nine_key = 'front'
            front9_up += delta
            nine_margin = front9_up
            nine_end    = 9
            # First moment the front nine is mathematically decided.
            if front9_decided_margin is None:
                _remaining = 9 - hole_num
                if abs(front9_up) > _remaining:
                    front9_decided_margin    = front9_up
                    front9_decided_remaining = _remaining
        else:
            nine_key = 'back'
            back9_up += delta
            nine_margin = back9_up
            nine_end    = 18
            # First moment the back nine is mathematically decided.
            if back9_decided_margin is None:
                _remaining = 18 - hole_num
                if abs(back9_up) > _remaining:
                    back9_decided_margin    = back9_up
                    back9_decided_remaining = _remaining

        # First moment the OVERALL match is mathematically decided.
        if overall_decided_margin is None:
            _ov_remaining = 18 - hole_num
            if abs(overall_up) > _ov_remaining:
                overall_decided_margin    = overall_up
                overall_decided_remaining = _ov_remaining

        # ── Advance active presses for this nine ──────────────────────────
        still_active = []
        for press in active_presses:
            if press['nine'] != nine_key:
                still_active.append(press)
                continue
            press['margin'] += delta
            holes_left = press['end'] - hole_num
            # Press ends when: last hole of nine reached, OR the trailing side
            # has been closed out (margin > remaining holes — impossible to
            # overturn even if they win every hole left).
            if hole_num >= press['end'] or abs(press['margin']) > holes_left:
                completed_presses.append(press)
            else:
                still_active.append(press)
        active_presses = still_active

        # ── Trigger manual press if start_hole == this hole ───────────────
        if manual_enabled:
            for ms in (manual_front if nine_key == 'front' else manual_back):
                if ms == hole_num:
                    already = any(
                        p['press_type'] == 'manual'
                        and p['nine'] == nine_key
                        and p['start'] == ms
                        for p in active_presses + completed_presses
                    )
                    if not already:
                        active_presses.append({
                            'nine'       : nine_key,
                            'press_type' : 'manual',
                            'trigger_hole': hole_num - 1,
                            'start'      : hole_num,
                            'end'        : nine_end,
                            'margin'     : delta,  # this hole counts in the press
                        })

        # ── Auto-press trigger (threshold-based on nine margin) ─────────────
        # A new auto-press fires each time the nine's cumulative margin reaches
        # a new even threshold: ±2, ±4, ±6, ±8.  Positive = T1 up (T2 down),
        # negative = T2 up (T1 down).  Each signed threshold fires at most once
        # per nine — if the margin recovers and later returns to the same level
        # it does NOT fire again.  The press starts the following hole and runs
        # to the end of the nine.
        if auto_enabled:
            holes_left_in_nine = nine_end - hole_num
            if holes_left_in_nine > 0 and nine_margin in AUTO_PRESS_THRESHOLDS:
                thresholds_fired = (
                    front9_thresholds_fired if nine_key == 'front'
                    else back9_thresholds_fired
                )
                if nine_margin not in thresholds_fired:
                    thresholds_fired.add(nine_margin)
                    active_presses.append({
                        'nine'        : nine_key,
                        'press_type'  : 'auto',
                        'trigger_hole': hole_num,
                        'start'       : hole_num + 1,
                        'end'         : nine_end,
                        'margin'      : 0,
                    })

        hole_score_objs.append(NassauHoleScore(
            game            = game,
            hole_number     = hole_num,
            team1_best_net  = t1_net,
            team2_best_net  = t2_net,
            winner          = winner,
            front9_up_after  = front9_up   if hole_num in front_holes else None,
            back9_up_after   = back9_up    if hole_num in back_holes  else None,
            overall_up_after = overall_up,
        ))

    # Any press still open when scoring ran out is also done
    completed_presses.extend(active_presses)

    NassauHoleScore.objects.bulk_create(hole_score_objs)

    # ── Persist press rows ────────────────────────────────────────────────
    # Triggered / completed presses (have a known result or running margin).
    press_objs = [
        NassauPress(
            game              = game,
            nine              = p['nine'],
            press_type        = p['press_type'],
            triggered_on_hole = p['trigger_hole'],
            start_hole        = p['start'],
            end_hole          = p['end'],
            result            = _resolve(p['margin']),
            holes_up          = p['margin'],
        )
        for p in completed_presses
    ]

    # Manual presses whose start_hole hasn't been reached yet (future holes).
    # These were saved in manual_press_starts before we wiped the table; we
    # must recreate them so they survive the recalculation.
    triggered_manual_starts = {
        p['start'] for p in completed_presses if p['press_type'] == 'manual'
    }
    for ms in manual_press_starts:
        if ms not in triggered_manual_starts:
            ms_nine     = 'front' if ms <= 9 else 'back'
            ms_end_hole = 9       if ms_nine == 'front' else 18
            press_objs.append(NassauPress(
                game              = game,
                nine              = ms_nine,
                press_type        = 'manual',
                triggered_on_hole = ms - 1,
                start_hole        = ms,
                end_hole          = ms_end_hole,
                result            = None,
                holes_up          = None,
            ))

    NassauPress.objects.bulk_create(press_objs)

    # ── Resolve standard bets ─────────────────────────────────────────────
    holes_played      = len(hole_score_objs)
    # A nine is considered complete (and its result locked in) as soon as it
    # is mathematically decided (margin > remaining holes), even if play
    # continues.  The decided-at margin (not the current margin) determines
    # the result so the winner can't change after the nine is settled.
    front_complete    = holes_played >= 9  or front9_decided_margin   is not None
    back_complete     = holes_played >= 18 or back9_decided_margin    is not None
    overall_complete  = holes_played >= 18 or overall_decided_margin  is not None

    game.front9_result  = _resolve(front9_decided_margin   if front9_decided_margin   is not None else front9_up)   \
                          if front_complete   else None
    game.back9_result   = _resolve(back9_decided_margin    if back9_decided_margin    is not None else back9_up)    \
                          if back_complete    else None
    game.overall_result = _resolve(overall_decided_margin  if overall_decided_margin  is not None else overall_up)  \
                          if overall_complete else None

    if overall_complete:
        game.status = MatchStatus.COMPLETE
    elif holes_played > 0:
        game.status = MatchStatus.IN_PROGRESS
    else:
        game.status = MatchStatus.PENDING

    game.save()
    return game


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

    # ── Holes ─────────────────────────────────────────────────────────────
    holes_qs = NassauHoleScore.objects.filter(game=game).order_by('hole_number')
    holes_out = [
        {
            'hole'          : h.hole_number,
            'winner'        : h.winner,
            't1_net'        : h.team1_best_net,
            't2_net'        : h.team2_best_net,
            'front9_margin' : h.front9_up_after,
            'back9_margin'  : h.back9_up_after,
            'overall_margin': h.overall_up_after,
        }
        for h in holes_qs
    ]

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

    holes_front = sum(1 for h in holes_out if h['hole'] <= 9)
    holes_back  = sum(1 for h in holes_out if h['hole'] > 9)

    # ── Presses ───────────────────────────────────────────────────────────
    # Build a hole-winner lookup from the scored hole data so we can replay
    # each press's running margin and discover how many holes were remaining
    # when it closed — needed for the match-play "4&3" notation in the UI.
    winner_by_hole = {h['hole']: h['winner'] for h in holes_out}

    def _press_holes_remaining(p) -> int:
        """Replay the press margin and return holes left when it closed."""
        press_margin = 0
        for h in range(p.start_hole, p.end_hole + 1):
            w = winner_by_hole.get(h)
            if w is None:
                return 0   # hole not yet scored — press still open
            if w == 'team1':
                press_margin += 1
            elif w == 'team2':
                press_margin -= 1
            holes_left = p.end_hole - h
            if h >= p.end_hole or abs(press_margin) > holes_left:
                return holes_left
        return 0

    presses_qs = NassauPress.objects.filter(game=game).order_by('triggered_on_hole')
    presses_out = [
        {
            'nine'            : p.nine,
            'press_type'      : p.press_type,
            'start_hole'      : p.start_hole,
            'end_hole'        : p.end_hole,
            'result'          : p.result,
            'margin'          : p.holes_up,
            'holes_remaining' : _press_holes_remaining(p),
        }
        for p in presses_qs
    ]
    press_total = sum(_press_payout(p['result']) for p in presses_out)

    # ── Standard bet payouts ──────────────────────────────────────────────
    front9_pay  = _payout(game.front9_result)
    back9_pay   = _payout(game.back9_result)
    overall_pay = _payout(game.overall_result)

    # ── can_press: available when manual presses allowed and game active ──
    # The losing team can press any time there are holes remaining in a nine.
    can_press = False
    press_available_nine = None
    if game.press_mode in ('manual', 'both') and game.status == MatchStatus.IN_PROGRESS:
        # Determine which nine is currently active
        last_hole = holes_out[-1]['hole'] if holes_out else 0
        if last_hole < 9:
            # Still in front nine — can press if currently losing
            if front9_margin != 0:
                can_press = True
                press_available_nine = 'front'
        elif last_hole < 18:
            # In back nine (or transitioning) — can press on back nine if losing
            if back9_margin != 0:
                can_press = True
                press_available_nine = 'back'

    # ── Team display ──────────────────────────────────────────────────────
    def _team_players(team_num):
        if team_num not in teams:
            return []
        return [
            {
                'player_id' : p.id,
                'name'      : p.name,
                'short_name': p.short_name,
            }
            for p in teams[team_num].players.all()
        ]

    return {
        'status'        : game.status,
        'handicap_mode' : game.handicap_mode,
        'net_percent'   : game.net_percent,
        'press_mode'    : game.press_mode,
        'bet_unit'      : bet_unit,
        'press_unit'    : press_unit,
        'teams'         : {
            'team1': _team_players(1),
            'team2': _team_players(2),
        },
        # decided_margin / decided_remaining: the frozen score at the moment the
        # nine was first mathematically decided (e.g. decided_margin=5,
        # decided_remaining=4 → display "5&4").  Both None when the nine ran to
        # its natural end or hasn't been decided yet.
        'front9'  : {
            'result'            : game.front9_result,
            'margin'            : front9_margin,
            'holes_played'      : holes_front,
            'decided_margin'    : next(
                (h['front9_margin']  for h in holes_out
                 if h['hole'] <= 9
                 and h['front9_margin'] is not None
                 and abs(h['front9_margin']) > 9  - h['hole']), None),
            'decided_remaining' : next(
                (9  - h['hole'] for h in holes_out
                 if h['hole'] <= 9
                 and h['front9_margin'] is not None
                 and abs(h['front9_margin']) > 9  - h['hole']), None),
        },
        'back9'   : {
            'result'            : game.back9_result,
            'margin'            : back9_margin,
            'holes_played'      : holes_back,
            'decided_margin'    : next(
                (h['back9_margin']  for h in holes_out
                 if h['hole'] > 9
                 and h['back9_margin'] is not None
                 and abs(h['back9_margin']) > 18 - h['hole']), None),
            'decided_remaining' : next(
                (18 - h['hole'] for h in holes_out
                 if h['hole'] > 9
                 and h['back9_margin'] is not None
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
        'presses' : presses_out,
        'payouts' : {
            'front9'  : front9_pay,
            'back9'   : back9_pay,
            'overall' : overall_pay,
            'presses' : press_total,
            'total'   : front9_pay + back9_pay + overall_pay + press_total,
        },
        'holes'         : holes_out,
        'can_press'     : can_press,
        'press_available_nine': press_available_nine,
    }
