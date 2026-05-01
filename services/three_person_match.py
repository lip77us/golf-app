"""
services/three_person_match.py
--------------------------------
Three-Person Match — tournament game for a 3-player group.

Structure
~~~~~~~~~
Nine holes of Points 5-3-1 scoring.  After hole 9, final standings are
determined by cumulative points.  1st, 2nd, and 3rd places go to the
players with the most, second-most, and fewest points respectively.

Tiebreak rules (applied when positions are tied after hole 9)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  • Clear 1st + clear 2nd → normal Phase 2 (no tiebreak needed).
  • 2-way tie for 1st + clear 3rd → the two tied players go directly to
    Phase 2 as leader/runner_up (no SD needed).
  • Clear 1st + 2-way tie for 2nd → sudden-death head-to-head between
    the two tied players on holes 10+.  First to uniquely win a hole
    (lower net score) becomes runner_up.  Phase 2 then calculates
    retroactively from hole 10.
  • 3-way tie → sudden death until one player uniquely wins a hole
    (lowest net vs both others) → that player becomes phase1_leader.
    The remaining two then play SD head-to-head until one wins a hole
    → runner_up.  Phase 2 calculates retroactively from hole 10.

Public API
~~~~~~~~~~
    game    = setup_three_person_match(foursome, handicap_mode, net_percent,
                                        entry_fee, payout_config)
    game    = calculate_three_person_match(foursome)
    summary = three_person_match_summary(foursome)
"""

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, Player
from games.models import (
    ThreePersonMatch,
    ThreePersonMatchP1HoleResult,
    ThreePersonMatchP2HoleResult,
)
from scoring.handicap import build_score_index
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Strokes-Off support (mirrored from points_531.py)
# ---------------------------------------------------------------------------

def _build_so_score_index(foursome: Foursome, net_percent: int = 100) -> dict:
    """
    Strokes-Off-Low score index: lowest playing handicap plays to 0;
    everyone else gets (own_phcp − low) × net_percent/100 strokes
    allocated by hole stroke_index.  Identical logic to the Points 5-3-1
    strokes-off helper so the two games are consistent.
    """
    score_index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)

    memberships = list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player__is_phantom=False)
    )
    if not memberships:
        return score_index

    phcps = [m.playing_handicap for m in memberships if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0

    for m in memberships:
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
            si = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = full_laps + (1 if si <= remainder else 0)
            if strokes:
                per_player[hole_num] = score - strokes

    return score_index


def _get_score_index(game: ThreePersonMatch, foursome: Foursome) -> dict:
    """Return the appropriate score index for the game's handicap policy."""
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_so_score_index(foursome, net_percent=game.net_percent)
    return build_score_index(
        foursome,
        handicap_mode=game.handicap_mode,
        net_percent=game.net_percent,
    )


# ---------------------------------------------------------------------------
# 5-3-1 points allocator (tie-splitting) — identical to points_531.py
# ---------------------------------------------------------------------------

_BASELINE_POINTS = (5, 3, 1)


def _allocate_hole_points(player_ids: list, scores_by_id: dict) -> dict:
    """
    Given player ids and their net scores, return {player_id: Decimal(points)}.
    Splits points evenly across tied positions so every hole pays 9 pts total.
    """
    if not player_ids:
        return {}

    order = sorted(player_ids, key=lambda pid: (scores_by_id[pid], pid))
    out: dict = {}
    pos = 0
    n = len(order)

    while pos < n:
        score = scores_by_id[order[pos]]
        end = pos + 1
        while end < n and scores_by_id[order[end]] == score:
            end += 1

        span_points = [
            _BASELINE_POINTS[i] if i < len(_BASELINE_POINTS) else 0
            for i in range(pos, end)
        ]
        share = Decimal(sum(span_points)) / Decimal(end - pos)
        for i in range(pos, end):
            out[order[i]] = share
        pos = end

    return out


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_three_person_match(
    foursome: Foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    entry_fee: float = 0.00,
    payout_config: dict | None = None,
) -> ThreePersonMatch:
    """
    Create (or replace) the Three-Person Match for a foursome.
    Safe to call repeatedly — existing state is wiped and rebuilt.
    """
    ThreePersonMatch.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))

    game = ThreePersonMatch.objects.create(
        foursome      = foursome,
        status        = 'pending',
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        entry_fee     = entry_fee,
        payout_config = payout_config or {},
    )
    return game


# ---------------------------------------------------------------------------
# Phase 2 / tiebreak helpers
# ---------------------------------------------------------------------------

def _do_phase2(game: ThreePersonMatch, score_index: dict) -> None:
    """
    Run Phase 2 match play (holes 10-18) for leader vs runner_up.

    Assumes game.phase1_leader and game.phase1_runner_up are already set.
    Writes ThreePersonMatchP2HoleResult rows with PHASE_PHASE2.
    Mutates game.status, game.phase2_start_hole, game.match_winner.
    Does NOT call game.save().
    """
    leader_id    = game.phase1_leader.pk
    runner_up_id = game.phase1_runner_up.pk
    game.phase2_start_hole = 10

    p2_rows:       list = []
    margin:        int  = 0
    phase2_scored: int  = 0
    match_decided: bool = False

    for hole_num in range(10, 19):
        leader_net = score_index.get(leader_id,    {}).get(hole_num)
        runner_net = score_index.get(runner_up_id, {}).get(hole_num)
        if leader_net is None or runner_net is None:
            break

        if leader_net < runner_net:
            leader_wins = True
            margin += 1
        elif leader_net > runner_net:
            leader_wins = False
            margin -= 1
        else:
            leader_wins = None  # halved

        phase2_scored  += 1
        holes_remaining = 18 - hole_num

        p2_rows.append(ThreePersonMatchP2HoleResult(
            game              = game,
            hole_number       = hole_num,
            phase             = ThreePersonMatchP2HoleResult.PHASE_PHASE2,
            main_leader_net   = leader_net,
            main_opp_net      = runner_net,
            main_leader_wins  = leader_wins,
            main_margin_after = margin,
        ))

        if abs(margin) > holes_remaining:
            match_decided = True
            break

    if p2_rows:
        ThreePersonMatchP2HoleResult.objects.bulk_create(p2_rows)

    if match_decided or phase2_scored == 9:
        game.status = 'complete'
        if margin > 0:
            game.match_winner = game.phase1_leader
        elif margin < 0:
            game.match_winner = game.phase1_runner_up
        # margin == 0 after 18 holes → all square, no match_winner
    else:
        game.status = 'phase2'


def _write_tiebreak_rows(game: ThreePersonMatch,
                          leader_id: int,
                          tb_holes: list) -> None:
    """
    Persist TIEBREAK phase rows for an in-progress SD.

    tb_holes: list of (hole_num, leader_net, a_net, b_net)
      where a_net / b_net are the two SD contestants' scores and
      leader_net is the phase1_leader's score (or a placeholder during
      the 3-way finding-leader phase).

    main_opp_net is set to min(a_net, b_net) — the best of the two
    contestants — so the leader's running Phase 2 margin can be estimated
    live before runner_up is confirmed.
    """
    db_rows:     list = []
    main_margin: int  = 0
    tb_margin:   int  = 0

    for hole_num, leader_net, a_net, b_net in tb_holes:
        opp_net = min(a_net, b_net)

        if leader_net < opp_net:
            mlw = True;  main_margin += 1
        elif leader_net > opp_net:
            mlw = False; main_margin -= 1
        else:
            mlw = None

        if a_net < b_net:
            taw = True;  tb_margin += 1
        elif b_net < a_net:
            taw = False; tb_margin -= 1
        else:
            taw = None

        db_rows.append(ThreePersonMatchP2HoleResult(
            game              = game,
            hole_number       = hole_num,
            phase             = ThreePersonMatchP2HoleResult.PHASE_TIEBREAK,
            main_leader_net   = leader_net,
            main_opp_net      = opp_net,
            main_leader_wins  = mlw,
            main_margin_after = main_margin,
            tb_a_net          = a_net,
            tb_b_net          = b_net,
            tb_a_wins         = taw,
            tb_margin_after   = tb_margin,
        ))

    if db_rows:
        ThreePersonMatchP2HoleResult.objects.bulk_create(db_rows)


def _do_tiebreak_23(game: ThreePersonMatch,
                     score_index: dict,
                     leader_id: int,
                     tb_a_id: int,
                     tb_b_id: int) -> None:
    """
    Tiebreak: clear 1st place, 2-way tie for 2nd/3rd.

    Runs sudden-death head-to-head between tb_a and tb_b starting at
    hole 10.  The first player to win a hole (lower net score) becomes
    runner_up.  Phase 2 is then calculated retroactively from hole 10.

    If the SD has not yet resolved (scores missing or all holes tied),
    PHASE_TIEBREAK rows are written for display.

    Assumes game.phase1_leader, game.phase1_tied_a, game.phase1_tied_b
    are already set on game.  Mutates game.status and game.phase1_runner_up;
    does NOT call game.save().
    """
    game.status = 'tiebreak'

    runner_up_id: int | None = None
    tb_holes: list            = []  # (hole_num, leader_net, a_net, b_net)

    for hole_num in range(10, 19):
        leader_net = score_index.get(leader_id, {}).get(hole_num)
        a_net      = score_index.get(tb_a_id,   {}).get(hole_num)
        b_net      = score_index.get(tb_b_id,   {}).get(hole_num)

        if any(x is None for x in [leader_net, a_net, b_net]):
            break

        tb_holes.append((hole_num, leader_net, a_net, b_net))

        if a_net < b_net:
            runner_up_id = tb_a_id
            break
        elif b_net < a_net:
            runner_up_id = tb_b_id
            break
        # else: halved hole — SD continues

    if runner_up_id is not None:
        # SD resolved — Phase 2 calculates retroactively from hole 10.
        game.phase1_runner_up = Player.objects.get(pk=runner_up_id)
        _do_phase2(game, score_index)
    else:
        # SD still in progress — persist TIEBREAK rows for live display.
        _write_tiebreak_rows(game, leader_id, tb_holes)


def _do_tiebreak_3way(game: ThreePersonMatch,
                       score_index: dict,
                       standings: list) -> None:
    """
    Tiebreak: 3-way tie after Phase 1.

    Step 1 — Find phase1_leader: walk holes 10-18 until one player
    uniquely wins a hole (lowest net vs both others).
    Step 2 — Find runner_up: run SD head-to-head between the remaining
    two players on the following holes.
    Step 3 — Phase 2: once both leader and runner_up are known, calculate
    match play retroactively from hole 10.

    If leader or runner_up are not yet resolved (missing scores), writes
    PHASE_TIEBREAK rows for whatever has been played.

    Mutates game fields; does NOT call game.save().
    """
    game.status = 'tiebreak'

    # ── Step 1: find phase1_leader ───────────────────────────────────────────
    phase1_leader_id:  int | None = None
    tb_a_id:           int | None = None
    tb_b_id:           int | None = None
    leader_found_hole: int | None = None

    # (hole_num, {pid: score}) for 3-way SD holes before leader emerges
    pre_leader_data: list = []

    for hole_num in range(10, 19):
        scores = {pid: score_index.get(pid, {}).get(hole_num) for pid in standings}
        if any(v is None for v in scores.values()):
            break

        min_score      = min(scores.values())
        unique_winners = [pid for pid, s in scores.items() if s == min_score]

        if len(unique_winners) == 1:
            # One player uniquely beat both others → phase1_leader found.
            phase1_leader_id  = unique_winners[0]
            others            = [pid for pid in standings if pid != phase1_leader_id]
            tb_a_id, tb_b_id  = others[0], others[1]
            leader_found_hole = hole_num
            break

        elif len(unique_winners) == 2:
            # Two players tied for best, both beating the third.
            # The SD is over — those two go directly to Phase 2.
            # Assign leader/runner_up in a deterministic order (lower pid first).
            w0, w1 = sorted(unique_winners)
            game.phase1_leader    = Player.objects.get(pk=w0)
            game.phase1_runner_up = Player.objects.get(pk=w1)
            _do_phase2(game, score_index)
            return

        else:
            # All three tied on this hole — SD continues.
            pre_leader_data.append((hole_num, dict(scores)))

    if phase1_leader_id is None:
        # Still in 3-way SD with no unique winner found yet.
        # Write display rows using a fixed ordering (standings[0] as stand-in
        # leader; [1]/[2] as tb_a/b — purely for UI display, recalculated
        # on every score submission once leader is determined).
        p0, p1, p2 = standings[0], standings[1], standings[2]
        _write_tiebreak_rows(
            game, p0,
            [(hn, scores[p0], scores[p1], scores[p2])
             for hn, scores in pre_leader_data]
        )
        return

    # ── Step 2: leader found — set model fields ──────────────────────────────
    game.phase1_leader = Player.objects.get(pk=phase1_leader_id)
    game.phase1_tied_a = Player.objects.get(pk=tb_a_id)
    game.phase1_tied_b = Player.objects.get(pk=tb_b_id)

    # ── Step 3: 2-way SD between tb_a and tb_b (holes after leader_found) ───
    runner_up_id:      int | None = None
    post_leader_holes: list       = []  # (hole_num, leader_net, a_net, b_net)

    for hole_num in range(leader_found_hole + 1, 19):
        leader_net = score_index.get(phase1_leader_id, {}).get(hole_num)
        a_net      = score_index.get(tb_a_id,          {}).get(hole_num)
        b_net      = score_index.get(tb_b_id,          {}).get(hole_num)

        if any(x is None for x in [leader_net, a_net, b_net]):
            break

        post_leader_holes.append((hole_num, leader_net, a_net, b_net))

        if a_net < b_net:
            runner_up_id = tb_a_id
            break
        elif b_net < a_net:
            runner_up_id = tb_b_id
            break
        # else: halved — SD continues

    if runner_up_id is not None:
        # Both leader and runner_up known — Phase 2 from hole 10.
        game.phase1_runner_up = Player.objects.get(pk=runner_up_id)
        _do_phase2(game, score_index)
        return

    # ── Runner-up SD still in progress — write all tiebreak rows ────────────
    # Now that we know leader/tb_a/tb_b, re-map the pre-leader 3-way holes
    # and combine with the post-leader 2-way holes.
    all_tb_holes: list = []

    for hole_num, score_map in pre_leader_data:
        all_tb_holes.append((
            hole_num,
            score_map[phase1_leader_id],
            score_map[tb_a_id],
            score_map[tb_b_id],
        ))

    # The hole where leader was found (include it; tb_a_wins=None since it's
    # the leader-resolution hole, not a head-to-head SD result).
    lf_scores = {pid: score_index.get(pid, {}).get(leader_found_hole)
                 for pid in standings}
    all_tb_holes.append((
        leader_found_hole,
        lf_scores[phase1_leader_id],
        lf_scores[tb_a_id],
        lf_scores[tb_b_id],
    ))

    # Post-leader 2-way SD holes (SD not yet broken).
    all_tb_holes.extend(post_leader_holes)

    _write_tiebreak_rows(game, phase1_leader_id, all_tb_holes)


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_three_person_match(foursome: Foursome) -> ThreePersonMatch | None:
    """
    Recalculate the Three-Person Match from raw HoleScore data.

    Idempotent — all derived rows are deleted and rebuilt on every call.
    Called automatically by api.views._recalculate_games after every score
    submission.

    Phase 1 (holes 1–9): 5-3-1 points.  Phase 2 (holes 10–18): match play
    between the 1st and 2nd place finishers from Phase 1.  Status progresses:
      pending     — no holes have been scored yet
      in_progress — 1–8 holes scored (Phase 1 in progress)
      tiebreak    — 9 holes scored; SD in progress to resolve tied positions
      phase2      — Phase 2 match play in progress or not started
      complete    — Phase 2 match resolved

    Returns the updated ThreePersonMatch, or None if none exists.
    """
    try:
        game = foursome.three_person_match
    except ThreePersonMatch.DoesNotExist:
        return None

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    real_ids = [m.player_id for m in real_members]

    if len(real_ids) != 3:
        # Game only makes sense with exactly 3 real players.
        game.status = 'pending'
        game.save(update_fields=['status'])
        return game

    # ── Wipe all prior computed state ────────────────────────────────────────
    ThreePersonMatchP1HoleResult.objects.filter(game=game).delete()
    ThreePersonMatchP2HoleResult.objects.filter(game=game).delete()

    # Reset all result fields.
    game.phase1_leader     = None
    game.phase1_runner_up  = None
    game.phase1_tied_a     = None
    game.phase1_tied_b     = None
    game.phase2_start_hole = None
    game.phase2_carryover  = 0
    game.match_winner      = None

    score_index = _get_score_index(game, foursome)

    # ── Score holes 1–9 with 5-3-1 ──────────────────────────────────────────
    p1_rows:      list = []
    cum_pts:      dict = {pid: Decimal('0') for pid in real_ids}
    holes_scored: int  = 0

    for hole_num in range(1, 10):  # Only holes 1–9
        scores: dict = {}
        for pid in real_ids:
            s = score_index.get(pid, {}).get(hole_num)
            if s is None:
                break
            scores[pid] = s

        if len(scores) < len(real_ids):
            # Missing at least one score; stop here.
            break

        pts_map = _allocate_hole_points(real_ids, scores)
        for pid, pts in pts_map.items():
            p1_rows.append(ThreePersonMatchP1HoleResult(
                game           = game,
                player_id      = pid,
                hole_number    = hole_num,
                net_score      = scores[pid],
                points_awarded = pts,
            ))
            cum_pts[pid] += pts

        holes_scored = hole_num

    if p1_rows:
        ThreePersonMatchP1HoleResult.objects.bulk_create(p1_rows)

    # ── Determine status ──────────────────────────────────────────────────────
    if holes_scored == 0:
        game.status = 'pending'
        game.save()
        return game

    if holes_scored < 9:
        game.status = 'in_progress'
        game.save()
        return game

    # ── All 9 holes scored — determine Phase 1 scenario ──────────────────────
    standings = sorted(real_ids, key=lambda pid: (-float(cum_pts[pid]), pid))
    p1_pts = float(cum_pts[standings[0]])
    p2_pts = float(cum_pts[standings[1]])
    p3_pts = float(cum_pts[standings[2]])

    tie_12 = (p1_pts == p2_pts)   # tie between places 1 and 2
    tie_23 = (p2_pts == p3_pts)   # tie between places 2 and 3

    if not tie_12 and not tie_23:
        # ── Scenario A: clear 1st and 2nd → normal Phase 2 ──────────────────
        game.phase1_leader    = Player.objects.get(pk=standings[0])
        game.phase1_runner_up = Player.objects.get(pk=standings[1])
        _do_phase2(game, score_index)

    elif tie_12 and not tie_23:
        # ── Scenario C: 2-way tie for 1st, clear 3rd ────────────────────────
        game.phase1_leader    = Player.objects.get(pk=standings[0])
        game.phase1_runner_up = Player.objects.get(pk=standings[1])
        _do_phase2(game, score_index)

    elif not tie_12 and tie_23:
        # ── Scenario B: clear 1st, 2-way tie for 2nd ────────────────────────
        game.phase1_leader = Player.objects.get(pk=standings[0])
        game.phase1_tied_a = Player.objects.get(pk=standings[1])
        game.phase1_tied_b = Player.objects.get(pk=standings[2])
        _do_tiebreak_23(game, score_index,
                         standings[0], standings[1], standings[2])

    else:
        # ── Scenario D: 3-way tie ────────────────────────────────────────────
        _do_tiebreak_3way(game, score_index, standings)

    game.save()
    return game


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def three_person_match_summary(foursome: Foursome) -> dict | None:
    """
    Return a JSON-serialisable summary for the UI and leaderboard.

    Returns None if no ThreePersonMatch exists for this foursome.

    Shape
    -----
    {
        'status'      : 'pending' | 'in_progress' | 'tiebreak' | 'phase2' | 'complete',
        'handicap'    : {'mode': str, 'net_percent': int},
        'holes_scored': int,
        'players'     : [
            {
                'player_id'    : int,
                'name'         : str,
                'short_name'   : str,
                'phase1_points': float,
                'phase1_place' : int,    # 1, 2, or 3 (ties share same place)
                'money'        : float,  # payout amount (split on ties)
            },
            ...
        ],
        'holes'       : [
            {
                'hole'   : int,
                'entries': [
                    {'player_id': int, 'short_name': str,
                     'name': str, 'net_score': int, 'points': float},
                    ...
                ],
            },
            ...
        ],
        'tiebreak'    : None | {
            'leader_found' : bool,
            'leader_id'    : int | None,
            'leader_name'  : str | None,
            'tied_a_id'    : int | None,
            'tied_a_name'  : str | None,
            'tied_b_id'    : int | None,
            'tied_b_name'  : str | None,
            'holes'        : [
                {
                    'hole'        : int,
                    'leader_net'  : int | None,
                    'opp_net'     : int | None,
                    'leader_wins' : bool | None,
                    'margin'      : int,
                    'tb_a_net'    : int | None,
                    'tb_b_net'    : int | None,
                    'tb_a_wins'   : bool | None,
                    'tb_margin'   : int,
                },
                ...
            ],
        },
        'phase2'      : None | { ... },
        'money'       : { ... },
    }
    """
    try:
        game = foursome.three_person_match
    except ThreePersonMatch.DoesNotExist:
        return None

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    pid_to_player = {m.player_id: m.player for m in real_members}
    real_ids      = list(pid_to_player.keys())

    # ── Phase 1 results ───────────────────────────────────────────────────────
    p1_results = list(
        game.phase1_results
        .select_related('player')
        .order_by('hole_number', 'player_id')
    )

    cum_pts: dict = {pid: Decimal('0') for pid in real_ids}
    for r in p1_results:
        cum_pts[r.player_id] = cum_pts.get(r.player_id, Decimal('0')) + r.points_awarded

    p1_by_hole: dict = {}
    for r in p1_results:
        p1_by_hole.setdefault(r.hole_number, []).append(r)

    holes_out = []
    for hn in sorted(p1_by_hole):
        entries = [
            {
                'player_id' : r.player_id,
                'name'      : r.player.name,
                'short_name': r.player.short_name,
                'net_score' : r.net_score,
                'points'    : float(r.points_awarded),
            }
            for r in p1_by_hole[hn]
        ]
        entries.sort(key=lambda e: (-e['points'], e['short_name']))
        holes_out.append({'hole': hn, 'entries': entries})

    # ── Player standings ──────────────────────────────────────────────────────
    standings = sorted(real_ids, key=lambda pid: (-float(cum_pts[pid]), pid))
    place_map: dict = {}
    for idx, pid in enumerate(standings):
        if idx == 0:
            place_map[pid] = 1
        else:
            prev = standings[idx - 1]
            place_map[pid] = (
                place_map[prev]
                if cum_pts[pid] == cum_pts[prev]
                else idx + 1
            )

    # ── Money / payouts ───────────────────────────────────────────────────────
    real_count = len(real_members)
    entry_fee  = float(game.entry_fee)
    prize_pool = entry_fee * real_count
    payout_cfg = game.payout_config or {}

    place_labels = {1: '1st', 2: '2nd', 3: '3rd'}
    place_amounts = {
        '1st': float(payout_cfg.get('1st', 0.0)),
        '2nd': float(payout_cfg.get('2nd', 0.0)),
        '3rd': float(payout_cfg.get('3rd', 0.0)),
    }

    # Group players by place, then split the combined payouts evenly.
    players_at_place: dict = {}
    for pid in real_ids:
        p = place_map[pid]
        players_at_place.setdefault(p, []).append(pid)

    payout_per_player: dict = {}
    for place, pids in players_at_place.items():
        n = len(pids)
        # Sum payouts for all places this group occupies.
        total = sum(
            place_amounts.get(place_labels.get(place + i, ''), 0.0)
            for i in range(n)
        )
        share = round(total / n, 2) if n > 0 else 0.0
        for pid in pids:
            payout_per_player[pid] = share

    # Build the payouts display list (only meaningful when complete).
    payouts_out = []
    for place_num in (1, 2, 3):
        label  = place_labels[place_num]
        amount = place_amounts[label]
        pids   = players_at_place.get(place_num, [])
        if pids:
            phase1_done = game.status in ('complete', 'phase2', 'tiebreak')
            player_name = ' / '.join(
                pid_to_player[p].short_name
                for p in pids
                if p in pid_to_player
            ) if phase1_done else None
        else:
            player_name = None
        payouts_out.append({
            'place'  : label,
            'player' : player_name,
            'amount' : amount,
        })

    money_block = {
        'entry_fee'    : entry_fee,
        'prize_pool'   : prize_pool,
        'payout_config': {k: float(v) for k, v in payout_cfg.items()},
        'payouts'      : payouts_out,
    }

    # ── Final place (used for leaderboard display) ────────────────────────────
    # When complete: winner = 1, both others = 2 (shown as T2).
    # When phase2:   leader = 1, runner_up = 2, eliminated = 3.
    # Otherwise: use phase1_place (points standings).
    final_place_map: dict = dict(place_map)  # start from phase1 standings
    if game.status == 'complete' and game.match_winner_id:
        for pid in standings:
            final_place_map[pid] = 1 if pid == game.match_winner_id else 2
    elif game.status == 'phase2':
        leader_pid    = game.phase1_leader_id
        runner_up_pid = game.phase1_runner_up_id
        for pid in standings:
            if pid == leader_pid:
                final_place_map[pid] = 1
            elif pid == runner_up_pid:
                final_place_map[pid] = 2
            else:
                final_place_map[pid] = 3

    # ── Players block ─────────────────────────────────────────────────────────
    players_out = []
    for pid in standings:
        player = pid_to_player.get(pid)
        if not player:
            continue
        players_out.append({
            'player_id'    : pid,
            'name'         : player.name,
            'short_name'   : player.short_name,
            'phase1_points': float(cum_pts[pid]),
            'phase1_place' : place_map[pid],
            'final_place'  : final_place_map[pid],
            'money'        : payout_per_player.get(pid, 0.0),
        })

    # ── Tiebreak block ────────────────────────────────────────────────────────
    tiebreak_block = None
    if game.status == 'tiebreak':
        tb_results = list(
            game.phase2_results
            .filter(phase=ThreePersonMatchP2HoleResult.PHASE_TIEBREAK)
            .order_by('hole_number')
        )

        leader_player = pid_to_player.get(game.phase1_leader.pk) if game.phase1_leader else None
        tied_a_player = pid_to_player.get(game.phase1_tied_a.pk) if game.phase1_tied_a else None
        tied_b_player = pid_to_player.get(game.phase1_tied_b.pk) if game.phase1_tied_b else None

        tb_holes_out = []
        for r in tb_results:
            tb_holes_out.append({
                'hole'        : r.hole_number,
                'leader_net'  : r.main_leader_net,
                'opp_net'     : r.main_opp_net,
                'leader_wins' : r.main_leader_wins,
                'margin'      : r.main_margin_after,
                'tb_a_net'    : r.tb_a_net,
                'tb_b_net'    : r.tb_b_net,
                'tb_a_wins'   : r.tb_a_wins,
                'tb_margin'   : r.tb_margin_after,
            })

        tiebreak_block = {
            'leader_found': game.phase1_leader is not None,
            'leader_id'   : game.phase1_leader.pk if game.phase1_leader else None,
            'leader_name' : leader_player.short_name if leader_player else None,
            'tied_a_id'   : game.phase1_tied_a.pk if game.phase1_tied_a else None,
            'tied_a_name' : tied_a_player.short_name if tied_a_player else None,
            'tied_b_id'   : game.phase1_tied_b.pk if game.phase1_tied_b else None,
            'tied_b_name' : tied_b_player.short_name if tied_b_player else None,
            'holes'       : tb_holes_out,
        }

    # ── Phase 2 block ─────────────────────────────────────────────────────────
    phase2_block = None
    if game.phase2_start_hole and game.phase1_leader and game.phase1_runner_up:
        p2_results = list(
            game.phase2_results
            .filter(phase=ThreePersonMatchP2HoleResult.PHASE_PHASE2)
            .order_by('hole_number')
        )

        p2_holes_out = []
        for r in p2_results:
            p2_holes_out.append({
                'hole'         : r.hole_number,
                'leader_net'   : r.main_leader_net,
                'runner_up_net': r.main_opp_net,
                'leader_wins'  : r.main_leader_wins,
                'margin'       : r.main_margin_after,
            })

        current_margin = p2_holes_out[-1]['margin'] if p2_holes_out else 0
        last_hole      = p2_holes_out[-1]['hole']   if p2_holes_out else None

        winner_name = None
        if game.match_winner_id:
            w = pid_to_player.get(game.match_winner_id)
            winner_name = w.short_name if w else None

        if game.status == 'complete' and p2_holes_out:
            p2_status = 'complete'
        elif p2_holes_out:
            p2_status = 'in_progress'
        else:
            p2_status = 'pending'

        phase2_block = {
            'status'        : p2_status,
            'leader_id'     : game.phase1_leader.pk,
            'leader_name'   : game.phase1_leader.short_name,
            'runner_up_id'  : game.phase1_runner_up.pk,
            'runner_up_name': game.phase1_runner_up.short_name,
            'margin'        : current_margin,
            'last_hole'     : last_hole,
            'winner_name'   : winner_name,
            'holes'         : p2_holes_out,
        }

    return {
        'status'      : game.status,
        'handicap'    : {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'holes_scored': len(p1_by_hole),
        'players'     : players_out,
        'holes'       : holes_out,
        'tiebreak'    : tiebreak_block,
        'phase2'      : phase2_block,
        'money'       : money_block,
    }
