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
  • Level for 2nd (clear 1st + a 2-way tie for 2nd, or a 3-way tie) →
    **points play on**: 5-3-1 keeps scoring all three men from hole 10
    until 2nd is clear (`_second_is_clear`).  Nobody waits — the finals is
    scored from the 10th against whoever ends up in it, so the match is
    read back the moment 2nd is settled.  (This replaced a sudden-death
    card-off, Paul, 11 Nov 2026: `handoff-mini-singles-three-score-entry`,
    "the same rule as a halved semi".)

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
from core.handicap_math import round_half_up


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
        so = round_half_up(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
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
    handicap_mode: str = HandicapMode.STROKES_OFF,
    net_percent: int = 100,
    entry_fee: float = 0.00,
    payout_config: dict | None = None,
) -> ThreePersonMatch:
    """
    Create (or replace) the Three-Person Match for a foursome.
    Safe to call repeatedly — existing state is wiped and rebuilt.

    Defaults to Strokes-Off Low so the same convention applies to
    both casual and tournament setups (matches the mobile picker
    default + the Match Play bracket default).
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

def _second_is_clear(cum_pts: dict) -> bool:
    """2nd place is settled: the second-most points are strictly more than
    the third man's.  A tie for **1st** needs nothing — both are in the
    finals."""
    pts = sorted((float(v) for v in cum_pts.values()), reverse=True)
    return len(pts) == 3 and pts[1] > pts[2]


def _finals_index(game: ThreePersonMatch, foursome: Foursome,
                  a_id: int, b_id: int) -> dict:
    """The score index the FINALS is played on.

    Strokes-off in the finals are off the lower of the **two** finalists,
    not the lowest of the three: when the man who is out was the low man the
    two numbers differ, and a golfer would be given strokes against somebody
    who is not in the match.  Net and gross are per-player and need no
    adjustment.
    """
    if game.handicap_mode != HandicapMode.STROKES_OFF:
        return _get_score_index(game, foursome)
    index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)
    ms = list(foursome.memberships.select_related('tee')
              .filter(player_id__in=[a_id, b_id]))
    phcps = [m.playing_handicap for m in ms if m.playing_handicap is not None]
    if not phcps:
        return index
    low = min(phcps)
    for m in ms:
        if m.tee_id is None:
            continue
        so = round_half_up(max(0, (m.playing_handicap or 0) - low)
                           * game.net_percent / 100)
        per = index.get(m.player_id)
        if so <= 0 or not per:
            continue
        for hole_num, score in list(per.items()):
            si = m.tee.hole(hole_num).get('stroke_index', 18)
            n = so // 18 + (1 if si <= so % 18 else 0)
            if n:
                per[hole_num] = score - n
    return index


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

    # ── Score holes 1–9 with 5-3-1, then PLAY ON while 2nd is level ─────────
    p1_rows:      list = []
    cum_pts:      dict = {pid: Decimal('0') for pid in real_ids}
    holes_scored: int  = 0

    def _score_points_hole(hole_num: int) -> bool:
        scores: dict = {}
        for pid in real_ids:
            sc = score_index.get(pid, {}).get(hole_num)
            if sc is None:
                return False
            scores[pid] = sc
        for pid, pts in _allocate_hole_points(real_ids, scores).items():
            p1_rows.append(ThreePersonMatchP1HoleResult(
                game=game, player_id=pid, hole_number=hole_num,
                net_score=scores[pid], points_awarded=pts))
            cum_pts[pid] += pts
        return True

    for hole_num in range(1, 10):
        if not _score_points_hole(hole_num):
            break
        holes_scored = hole_num

    # Points play on from the 10th, all three, until 2nd is clear.
    if holes_scored == 9:
        while not _second_is_clear(cum_pts) and holes_scored < 18:
            if not _score_points_hole(holes_scored + 1):
                break
            holes_scored += 1

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

    standings = sorted(real_ids, key=lambda pid: (-float(cum_pts[pid]), pid))

    if _second_is_clear(cum_pts):
        # The top two play the finals, scored from the 10th — read back over
        # whatever points holes were played on while 2nd was level.
        game.phase1_leader    = Player.objects.get(pk=standings[0])
        game.phase1_runner_up = Player.objects.get(pk=standings[1])
        _do_phase2(game, _finals_index(
            game, foursome, standings[0], standings[1]))
    else:
        # Still level for 2nd and the next points hole is not in yet. A clear
        # 1st is named so the board can show the finals against either.
        game.status = 'tiebreak'
        if float(cum_pts[standings[0]]) > float(cum_pts[standings[1]]):
            game.phase1_leader = Player.objects.get(pk=standings[0])
            game.phase1_tied_a = Player.objects.get(pk=standings[1])
            game.phase1_tied_b = Player.objects.get(pk=standings[2])

    game.save()
    return game


# ---------------------------------------------------------------------------
# Scorecard block — gross, points and where the strokes fall
# ---------------------------------------------------------------------------

def _stroke_on_hole(tee, hole: int, so: int) -> int:
    if so <= 0 or tee is None:
        return 0
    si = tee.hole(hole).get('stroke_index', 18)
    return so // 18 + (1 if si <= so % 18 else 0)


def _scorecard_block(foursome, game, members, p1_by_hole, standings) -> dict:
    """The leaderboard card's scorecard, shaped for `HoleGridScorecard`
    (`showPoints`): every hole in play with par, stroke index, each golfer's
    gross, the points he took and the strokes that hole gives him.

    **Strokes are PROSPECTIVE and phase-aware**, the way Stableford's are:
    the dots are on holes nobody has played, so the plan is visible up front.
    Strokes-off is off the low man of the three in the points, and off the
    lower of the two finalists in the finals (nothing for the man who is
    out); net is each golfer's own allowance throughout.
    """
    from scoring.models import HoleScore
    from services.hole_plan import play_order

    order = play_order(foursome.round, foursome) or list(range(1, 19))
    gross = {(s.player_id, s.hole_number): s.gross_score
             for s in HoleScore.objects.filter(foursome=foursome)
             if s.gross_score is not None}
    by_pid = {m.player_id: m for m in members}
    through = max(p1_by_hole, default=0)
    p1_by_hole = {h: {r.player_id: r for r in rows}
                  for h, rows in p1_by_hole.items()}
    fa, fb = game.phase1_leader_id, game.phase1_runner_up_id
    finals_known = game.status in ('phase2', 'complete') and fa and fb

    pct = game.net_percent or 100
    mode = game.handicap_mode

    def allowance(pid, low):
        ph = by_pid[pid].playing_handicap or 0
        if mode == HandicapMode.GROSS:
            return 0
        if mode == HandicapMode.STROKES_OFF:
            return round_half_up(max(0, ph - low) * pct / 100)
        return round_half_up(ph * pct / 100)

    low_three = min((m.playing_handicap or 0) for m in members)
    low_two = min((by_pid[p].playing_handicap or 0) for p in (fa, fb)) \
        if finals_known else None
    so_points = {pid: allowance(pid, low_three) for pid in by_pid}
    so_finals = ({pid: allowance(pid, low_two) for pid in (fa, fb)}
                 if finals_known else {})

    holes = []
    for hn in order:
        in_finals = bool(finals_known) and hn > max(through, 9)
        tee = next((m.tee for m in members if m.tee_id), None)
        hd = tee.hole(hn) if tee else {}
        scores = []
        for pid, m in by_pid.items():
            if in_finals:
                n = _stroke_on_hole(m.tee, hn, so_finals.get(pid, 0))
            else:
                n = _stroke_on_hole(m.tee, hn, so_points[pid])
            e = p1_by_hole.get(hn, {}).get(pid)
            scores.append({
                'player_id': pid,
                'gross'    : gross.get((pid, hn)),
                'strokes'  : n,
                'points'   : float(e.points_awarded) if e is not None else None,
            })
        holes.append({'hole': hn, 'par': hd.get('par'),
                      'stroke_index': hd.get('stroke_index'),
                      'scores': scores})
    return {
        'players': [{'player_id': pid, 'name': m.player.name,
                     'short_name': m.player.short_name}
                    for pid, m in by_pid.items()],
        'holes': holes,
        'holes_in_play': order,
    }


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

    # **1st and 2nd come from the FINALS, 3rd from the points** once the match
    # is over (`handoff-mini-singles-three-score-entry`). A halved finals
    # leaves both finalists on 1st, so they split 1st and 2nd between them.
    # Until then the places are the points standings, with 1st and 2nd merged.
    #
    # **Before the finals, 1st and 2nd on points split the money** (Paul,
    # 11 Nov 2026): finishing first on points is no edge — both men play the
    # finals either way — so the two places are one and the pot for them is
    # shared. A man still in contention for 2nd is in that share until 2nd is
    # clear; the third man keeps 3rd.
    money_place = {pid: (1 if pl <= 2 else pl) for pid, pl in place_map.items()}
    if game.status == 'complete' and game.phase1_leader_id \
            and game.phase1_runner_up_id:
        fin = {game.phase1_leader_id, game.phase1_runner_up_id}
        for pid in real_ids:
            if pid not in fin:
                money_place[pid] = 3
        if game.match_winner_id:
            for pid in fin:
                money_place[pid] = 1 if pid == game.match_winner_id else 2
        else:
            for pid in fin:
                money_place[pid] = 1

    # Group players by place, then split the combined payouts evenly.
    players_at_place: dict = {}
    for pid in real_ids:
        p = money_place[pid]
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
        fin = {game.phase1_leader_id, game.phase1_runner_up_id}
        for pid in standings:
            final_place_map[pid] = (1 if pid == game.match_winner_id
                                    else 2 if pid in fin else 3)
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

    # ── Play-on block ─────────────────────────────────────────────────────────
    # **No sudden death any more.** While 2nd is level the points hole keeps
    # being played by all three, so the old `tiebreak` shape is kept only so
    # an installed client reads a sensible object (`holes` empty, the leader
    # named once 1st is clear) — what is happening is `play_on`.
    tiebreak_block = None
    play_on_block = None
    if game.status == 'tiebreak':
        leader_player = pid_to_player.get(game.phase1_leader.pk) if game.phase1_leader else None
        tied_a_player = pid_to_player.get(game.phase1_tied_a.pk) if game.phase1_tied_a else None
        tied_b_player = pid_to_player.get(game.phase1_tied_b.pk) if game.phase1_tied_b else None
        tiebreak_block = {
            'leader_found': game.phase1_leader is not None,
            'leader_id'   : game.phase1_leader.pk if game.phase1_leader else None,
            'leader_name' : leader_player.short_name if leader_player else None,
            'tied_a_id'   : game.phase1_tied_a.pk if game.phase1_tied_a else None,
            'tied_a_name' : tied_a_player.short_name if tied_a_player else None,
            'tied_b_id'   : game.phase1_tied_b.pk if game.phase1_tied_b else None,
            'tied_b_name' : tied_b_player.short_name if tied_b_player else None,
            'holes'       : [],
        }
        play_on_block = {
            'through'  : max(p1_by_hole) if p1_by_hole else 0,
            'leader_id': game.phase1_leader.pk if game.phase1_leader else None,
            'level_ids': [p.pk for p in (game.phase1_tied_a, game.phase1_tied_b)
                          if p is not None],
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

        # **The `M` in "3&2" ships from the server.** The client was computing
        # `18 - last_hole`, which the shotgun sweep rules out: only the server
        # knows the match's window, so only it can count what is left of one.
        #
        # NOTE the window itself is holes 10-18 by NUMBER (`phase2_start_hole`
        # is hardcoded to 10), so off a shotgun start this counts against a nine
        # the group may not be playing second. That is the SAME open rules
        # question the sweep flagged for `tournament_match_play` — is "the back
        # nine" holes 10-18, or the second nine played? — and it is a ruling, not
        # a patch. This field is faithful to the definition in force; correct the
        # definition and this follows it.
        p2_window        = list(range(game.phase2_start_hole, 19))
        holes_to_play    = (len(p2_window) - p2_window.index(last_hole) - 1
                            if last_hole in p2_window else None)

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
            # Holes left in the match's own window after `last_hole` — the `M`.
            'holes_to_play' : holes_to_play,
            'winner_name'   : winner_name,
            'holes'         : p2_holes_out,
        }

    scorecard_block = _scorecard_block(
        foursome, game, real_members, p1_by_hole, standings)

    return {
        'scorecard'   : scorecard_block,
        'status'      : game.status,
        'handicap'    : {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'holes_scored': len(p1_by_hole),
        'players'     : players_out,
        'holes'       : holes_out,
        'tiebreak'    : tiebreak_block,
        'play_on'     : play_on_block,
        'phase2'      : phase2_block,
        'money'       : money_block,
    }


# ---------------------------------------------------------------------------
# Score-entry card — `~/Downloads/handoff-mini-singles-three-score-entry`
# ---------------------------------------------------------------------------

def _pts_txt(v) -> str:
    v = float(v)
    return f'{v:g}'


def _place_texts(totals: dict) -> dict:
    """`1`, `T2`… by points, ties sharing a place."""
    order = sorted(totals, key=lambda pid: (-totals[pid], pid))
    place, out = 0, {}
    for i, pid in enumerate(order):
        if i == 0 or totals[pid] != totals[order[i - 1]]:
            place = i + 1
        out[pid] = place
    tied = {p for p in out.values() if list(out.values()).count(p) > 1}
    return {pid: (f'T{pl}' if pl in tied else str(pl))
            for pid, pl in out.items()}


def three_person_hole_card(foursome, hole: int) -> dict:
    """Everything the three-man Mini Singles score-entry screen draws for ONE
    hole (`handoff-mini-singles-three-score-entry`, 11 Nov 2026).

    **It renders `three_person_match_summary` and decides no golf.** The
    points, the play-on, the finalists, the finals margins and the money are
    the engine's; what this adds is the cut — the round AS OF this hole, so a
    tray reopened on the 4th does not report the 16th — and the sentences,
    each of which is a rule.

    Three phases of a hole: `points` (holes 1–9, and any hole points play on
    for), and `finals` (the two leaders, match play, scored from the 10th).
    Returns `{}` when there is no three-man match, so a caller can test the
    key.
    """
    from scoring.models import HoleScore as _HS
    from services.hole_plan import play_order
    from services.player_labels import first_names

    summary = three_person_match_summary(foursome)
    if not summary:
        return {}
    game = foursome.three_person_match
    members = [m for m in foursome.memberships.select_related('player', 'tee')
               if not m.player.is_phantom]
    if len(members) != 3 or not 1 <= hole <= 18:
        return {}
    order = play_order(foursome.round, foursome) or list(range(1, 19))
    if hole not in order:
        return {}
    pos = order.index(hole)
    ids = [m.player_id for m in members]
    mem = {m.player_id: m for m in members}
    first = first_names({pid: mem[pid].player for pid in ids})
    status = summary['status']

    # ── what the points round had done by this hole ────────────────────────
    by_hole = {h['hole']: {e['player_id']: e for e in h['entries']}
               for h in summary['holes']}
    through = max(by_hole, default=0)               # last points hole played
    total = {pid: 0.0 for pid in ids}
    for h in sorted(by_hole):
        if h <= hole:
            for pid, e in by_hole[h].items():
                total[pid] += e['points']

    # ── which phase is THIS hole ───────────────────────────────────────────
    finals_known = status in ('phase2', 'complete')
    if hole <= 9 or hole <= through:
        phase = 'points'
    elif status == 'tiebreak' and hole == through + 1:
        phase = 'points'
    elif finals_known:
        phase = 'finals'
    else:
        phase = 'points'
    play_on = phase == 'points' and hole > 9

    gross = {s.player_id: s.gross_score for s in _HS.objects.filter(
        foursome=foursome, hole_number=hole, player_id__in=ids)
        if s.gross_score is not None}
    base = _get_score_index(game, foursome)
    sc_hole = next((x for x in [mem[ids[0]].tee.hole(hole)]), {}) \
        if mem[ids[0]].tee_id else {}

    fa = fb = None
    if finals_known:
        fa, fb = game.phase1_leader_id, game.phase1_runner_up_id
    fin_idx = _finals_index(game, foursome, fa, fb) if fa and fb else None

    def strokes_in(index, pid):
        g, n = gross.get(pid), index.get(pid, {}).get(hole)
        return (g - n) if g is not None and n is not None else 0

    hole_pts = by_hole.get(hole, {})

    # ── players ────────────────────────────────────────────────────────────
    players = []
    for i, pid in enumerate(ids):
        m = mem[pid]
        row = {
            'player_id': pid, 'seat': i, 'name': m.player.name,
            'first': first[pid], 'short': m.player.short_name,
            'course_handicap': m.course_handicap,
            'gross': gross.get(pid), 'role': 'points',
            'pts': (_pts_txt(hole_pts[pid]['points'])
                    if pid in hole_pts else None),
            'net': None, 'strokes': 0,
        }
        if phase == 'finals':
            if pid in (fa, fb):
                row['role'] = 'finalist'
                idx = fin_idx
            else:
                row['role'] = 'third'
                idx = None
            if idx is not None:
                row['strokes'] = strokes_in(idx, pid)
                row['net'] = idx.get(pid, {}).get(hole) \
                    if pid in gross else None
        else:
            row['strokes'] = strokes_in(base, pid)
            row['net'] = base.get(pid, {}).get(hole) if pid in gross else None
        players.append(row)

    scored = sum(1 for p in players if p['gross'] is not None)
    complete = scored == 3

    # ── the points table, and what it says ─────────────────────────────────
    places = _place_texts(total)
    leader_pts = max(total.values())
    pts_sorted = sorted(ids, key=lambda p: (-total[p], p))
    clear_now = _second_is_clear({p: Decimal(str(v)) for p, v in total.items()})
    holes_in = len([h for h in by_hole if h <= hole])
    top_two = set(pts_sorted[:2])
    mint = (top_two if (holes_in >= 9 and clear_now)
            else ({pts_sorted[0]} if total[pts_sorted[0]] > total[pts_sorted[1]]
                  else set()))
    table = [{
        'player_id': pid, 'place': places[pid], 'name': mem[pid].player.name,
        'first': first[pid],
        'net': (base.get(pid, {}).get(hole) if pid in gross else None),
        'pts': (_pts_txt(hole_pts[pid]['points']) if pid in hole_pts else None),
        'total': _pts_txt(total[pid]),
        'mint': pid in mint,
    } for pid in pts_sorted]

    line = ''
    level_ids: list = []
    if phase == 'points':
        if holes_in < 9:
            line = (f'Thru {holes_in} of 9. The top two after nine play the '
                    'finals over the back nine.')
        elif clear_now:
            fin = [first[p] for p in pts_sorted[:2]]
            line = (f'{fin[0]} and {fin[1]} play the finals, scored from the '
                    f'10th. {first[pts_sorted[2]]} takes 3rd on points.')
        else:
            if total[pts_sorted[0]] > total[pts_sorted[1]]:
                level_ids = pts_sorted[1:]
                a, b = (first[p] for p in level_ids)
                line = (f'{a} and {b} are level for 2nd. Points play on until '
                        'one of them is clear. Nobody waits: the finals is '
                        'scored from the 10th against both.')
            else:
                line = ('All three are level. Points play on until 2nd is '
                        'clear. Nobody waits: the finals is scored from the '
                        '10th against whoever gets there.')

    # ── the finals, scored from the 10th ───────────────────────────────────
    def margin_of(a_id, b_id, index, upto):
        t = played = 0
        for h in range(10, min(upto, 18) + 1):
            x, y = index.get(a_id, {}).get(h), index.get(b_id, {}).get(h)
            if x is None or y is None:
                break
            played += 1
            t += (x < y) - (x > y)
        return t, played

    def up_text(t, a_name, b_name):
        return 'All square' if t == 0 else (
            f'{a_name} {abs(t)} UP' if t > 0 else f'{b_name} {abs(t)} UP')

    finals_cards = []
    if play_on and level_ids and game.phase1_leader_id is not None:
        lead = game.phase1_leader_id
        for x in level_ids:
            t, _ = margin_of(lead, x, _finals_index(game, foursome, lead, x),
                             hole)
            finals_cards.append({
                'names': f'{first[lead]} v {first[x]}',
                'text': up_text(t, first[lead], first[x])})

    finals = None
    p2 = summary.get('phase2') or {}
    if phase == 'finals' and fa and fb:
        rows = [h for h in (p2.get('holes') or []) if h['hole'] <= hole]
        margin = rows[-1]['margin'] if rows else 0
        played = len(rows)
        remaining = 9 - played
        closed = bool(rows) and abs(margin) > remaining and remaining >= 0 \
            and played < 9
        this = next((h for h in rows if h['hole'] == hole), None)
        winner = None
        if this is not None and this['leader_wins'] is not None:
            winner = fa if this['leader_wins'] else fb
        tiles = []
        by_h = {h['hole']: h for h in (p2.get('holes') or [])}
        for h in range(10, 19):
            r = by_h.get(h)
            if h > hole or r is None:
                tiles.append({'hole': h, 'state': 'x'})
            elif r['leader_wins'] is None:
                tiles.append({'hole': h, 'state': 'h'})
            else:
                tiles.append({'hole': h, 'state': 'a' if r['leader_wins'] else 'b'})
        lead_id = fa if margin >= 0 else fb
        if margin == 0:
            std = 'All square'
        elif closed:
            std = f'{abs(margin)}&{remaining}'
        else:
            std = f'{abs(margin)} UP'
        finals = {
            'a_id': fa, 'b_id': fb,
            'names': [first[fa], first[fb]],
            'nets': [fin_idx.get(fa, {}).get(hole) if fa in gross else None,
                     fin_idx.get(fb, {}).get(hole) if fb in gross else None],
            'winner_id': winner,
            'halved': this is not None and this['leader_wins'] is None,
            'leader_id': lead_id if margin else None,
            'leader': first[lead_id] if margin else '',
            'standing': std,
            'thru': played, 'to_play': remaining,
            'closed': closed,
            'tiles': tiles,
            'over_line': (f'Finals · {first[lead_id]} won {std} · hole '
                          f'{[t["hole"] for t in tiles if t["state"] == "x"][0]}'
                          ' is stroke play only') if closed and any(
                              t['state'] == 'x' for t in tiles) else '',
        }

    # ── the header pill ────────────────────────────────────────────────────
    if phase == 'finals' and finals:
        pill = {'text': ('Finals · ' + (f"{finals['leader']} {finals['standing']}"
                                        if finals['leader'] else 'All square')),
                'sub': f"{finals['to_play']} to play",
                'leader_id': finals['leader_id']}
    elif play_on:
        pill = {'text': 'Points play on',
                'sub': (', '.join(first[p] for p in level_ids)
                        + ' level for 2nd') if level_ids else 'All level',
                'leader_id': None}
    else:
        lead_p = pts_sorted[0]
        pill = {'text': (f'Points · {first[lead_p]} {_pts_txt(total[lead_p])}'
                         if total[lead_p] > total[pts_sorted[1]] or holes_in
                         else 'Points'),
                'sub': f'thru {min(holes_in, 9)} of 9', 'leader_id': None}

    # ── what comes after hole 9 ────────────────────────────────────────────
    nxt = None
    if hole == 9 and complete:
        if clear_now:
            nxt = {'title': f'Finals {first[pts_sorted[0]]} v {first[pts_sorted[1]]}',
                   'line': line}
        else:
            nxt = {'title': 'Points play on from 10', 'line': line}

    # ── money, on the last hole ────────────────────────────────────────────
    entry = float(game.entry_fee or 0)
    pot = entry * 3
    last = pos == len(order) - 1
    round_over = complete and last
    result = None
    winner_card = None
    if round_over and status == 'complete':
        places = {p['player_id']: p for p in summary['players']}
        ordered = sorted(summary['players'], key=lambda p: (
            p['final_place'], -p['phase1_points']))
        rows = []
        for p in ordered:
            fp = p['final_place']
            rows.append({'player_id': p['player_id'], 'name': p['name'],
                         'place': {1: '1st', 2: '2nd', 3: '3rd'}.get(fp, '3rd'),
                         'net': round(p['money'] - entry, 2) if pot else None})
        result = {'rows': rows, 'pot': pot, 'entry': entry,
                  'note': ''}
        if p2.get('winner_name'):
            w = next(p for p in summary['players']
                     if p['short_name'] == p2['winner_name'])
            winner_card = {
                'player_id': w['player_id'], 'name': w['name'],
                'text': (f"{first[w['player_id']]} wins the finals "
                         f"{finals['standing'] if finals else ''} and goes "
                         "through to the champions’ foursome on day 2.")
                        if finals else '',
            }

    return {
        'hole': hole, 'par': sc_hole.get('par'),
        'stroke_index': sc_hole.get('stroke_index'),
        'phase': phase, 'play_on': play_on, 'thru': pos + 1,
        'title': 'Mini Singles', 'pot': pot, 'entry': entry,
        'players': players, 'scored': scored, 'hole_complete': complete,
        'pill': pill,
        'totals': [{'player_id': p, 'first': first[p],
                    'total': _pts_txt(total[p])} for p in ids],
        'table': table, 'line': line,
        'finals_cards': finals_cards, 'finals': finals, 'next': nxt,
        'winner': winner_card, 'result': result,
        'round_over': round_over,
        'next_hole': order[pos + 1] if pos + 1 < len(order) else None,
    }
