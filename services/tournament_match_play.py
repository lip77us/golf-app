"""
services/tournament_match_play.py
----------------------------------
Tournament match play — individual head-to-head within a foursome.

Structure (4 real players)
~~~~~~~~~~~~~~~~~~~~~~~~~~
Round 1 (holes 1–9)  — two simultaneous semi-final matches:
    Semi 1: seed 1 (lowest hcp) vs seed 4 (highest hcp)
    Semi 2: seed 2 vs seed 3

Round 2 (holes 10–18) — two simultaneous back-9 matches:
    Final:      Semi 1 winner vs Semi 2 winner  → 1st / 2nd place
    3rd Place:  Semi 1 loser  vs Semi 2 loser   → 3rd / 4th place

Scoring
~~~~~~~
Individual adjusted scores (lower wins the hole). Ties = halved.
A match closes early when margin > holes remaining ("dormie" close).
Handicap mode (net / gross / strokes_off) and net_percent are read from
foursome.round — the same values used for all other games in the round.

Tie-break rules (no presses)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Semi (round 1, holes 1–9):
    If tied after hole 9 → sudden death on holes 10, 11 ... 18 using
    the same scores already entered for the round.  The match stays
    in_progress while the score for the deciding hole is not yet entered.
    finished_on_hole records which hole broke the tie.
    If all 18 holes are halved → result = 'halved' (extreme edge case).

Final / 3rd Place (round 2, holes 10–18):
    If tied after hole 18 → last-hole-won:
        Walk back from hole 18 to find the most recent hole with a winner;
        that player wins.
    If ALL 9 holes were halved → result = 'halved' (true dead heat).

Prize pool
~~~~~~~~~~
entry_fee and payout_config live on MatchPlayBracket.
prize_pool = entry_fee × real player count.
Payouts are declared up-front by the coordinator and settled once the
bracket status = 'complete' (i.e. after the day-2 final resolves).

Based on the Nassau scoring engine (build_score_index, individual scoring).
No presses, no teams.

Public API
~~~~~~~~~~
    bracket = setup_tournament_match_play(foursome, entry_fee, payout_config)
    bracket = calculate_tournament_match_play(foursome)
    summary = tournament_match_play_summary(foursome)
"""

from django.db import transaction

from games.models import MatchPlayBracket, MatchPlayMatch, MatchPlayHoleResult
from scoring.handicap import (
    build_score_index, build_match_play_score_index,
    make_strokes_fn, _strokes_on_hole,
)
from scoring.models import HoleScore
from tournament.models import FoursomeMembership


# ---------------------------------------------------------------------------
# Match labels — keyed by (round_number, match_index_within_round)
# ---------------------------------------------------------------------------
_MATCH_LABELS = {
    (1, 0): 'Semi 1',
    (1, 1): 'Semi 2',
    (2, 0): 'Final',
    (2, 1): '3rd Place',
}


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_tournament_match_play(
    foursome,
    entry_fee: float = 0.00,
    payout_config: dict | None = None,
    seed_order: list | None = None,
    handicap_mode: str | None = None,
    net_percent: int | None = None,
) -> MatchPlayBracket:
    """
    Create a MatchPlayBracket and MatchPlayMatch stubs for this foursome.

    By default, players are seeded by ascending playing_handicap:
        seed 1 (lowest) vs seed 4 (highest) — Semi 1
        seed 2          vs seed 3            — Semi 2

    seed_order      — optional list of player PKs in explicit seed order
                      (index 0 = seed 1, index 1 = seed 2, etc.).  If
                      omitted or None, the automatic handicap seeding is used.

    Round-2 stubs (Final + 3rd Place) are created with placeholder players;
    the real players are filled in by calculate_tournament_match_play()
    once both semis resolve.

    entry_fee       — per-player buy-in (stored on the bracket).
    payout_config   — dict mapping place label to dollar amount, e.g.:
                      {"1st": 48.00, "2nd": 24.00, "3rd": 8.00, "4th": 0.00}
                      Defaults to an empty dict (to be configured later).

    Returns the new MatchPlayBracket.
    Raises ValueError if the foursome has fewer than 2 real players.
    """
    MatchPlayBracket.objects.filter(foursome=foursome).delete()

    memberships = list(
        FoursomeMembership.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .select_related('player')
        .order_by('playing_handicap')
    )
    real_count = len(memberships)

    # Apply manual seed order if provided
    if seed_order:
        mem_map     = {m.player.pk: m for m in memberships}
        reordered   = [mem_map[pk] for pk in seed_order if pk in mem_map]
        # Append any players not mentioned in seed_order at the end
        assigned    = {m.player.pk for m in reordered}
        reordered  += [m for m in memberships if m.player.pk not in assigned]
        memberships = reordered

    if real_count < 2:
        raise ValueError(
            f"Match play requires at least 2 real players; found {real_count}."
        )

    # Per-bracket handicap mode — defaults to Strokes-Off Low because
    # per-pair SO (lower plays scratch, higher gets the differential) is
    # the standard match-play convention and matches what the score-entry
    # bubble shows.  Casual and tournament both follow this default;
    # callers can pass an explicit handicap_mode to override.  Net percent
    # falls back to the round's value since it's a round-level allowance.
    round_obj = foursome.round
    bracket_handicap_mode = handicap_mode or 'strokes_off'
    bracket_net_percent   = net_percent if net_percent is not None else round_obj.net_percent

    bracket = MatchPlayBracket.objects.create(
        foursome      = foursome,
        bracket_type  = 'single_elim',
        status        = 'pending',
        entry_fee     = entry_fee,
        payout_config = payout_config or {},
        handicap_mode = bracket_handicap_mode,
        net_percent   = bracket_net_percent,
    )

    p = [m.player for m in memberships]

    if real_count >= 4:
        # Round 1: two semis on holes 1–9
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=1, start_hole=1,
            player1=p[0], player2=p[3], status='pending',
        )
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=1, start_hole=1,
            player1=p[1], player2=p[2], status='pending',
        )
        # Round 2: Final + 3rd Place stubs on holes 10–18
        # (players filled in after semis resolve)
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=2, start_hole=10,
            player1=p[0], player2=p[1], status='pending',  # Final placeholder
        )
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=2, start_hole=10,
            player1=p[2], player2=p[3], status='pending',  # 3rd Place placeholder
        )

    elif real_count == 3:
        # 3-player: two semis (round-robin style), one final, no 3rd place
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=1, start_hole=1,
            player1=p[0], player2=p[2], status='pending',
        )
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=1, start_hole=1,
            player1=p[0], player2=p[1], status='pending',
        )
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=2, start_hole=10,
            player1=p[0], player2=p[1], status='pending',  # Final placeholder
        )

    else:
        # 2 players: one 9-hole match, no round 2
        MatchPlayMatch.objects.create(
            bracket=bracket, round_number=1, start_hole=1,
            player1=p[0], player2=p[1], status='pending',
        )

    return bracket


# ---------------------------------------------------------------------------
# Scoring helpers
# ---------------------------------------------------------------------------

def _play_semi(match: MatchPlayMatch, score_index: dict) -> tuple[list, int]:
    """
    Score a 9-hole semi-final (holes 1–9) with sudden-death tie-break.

    If tied after hole 9, continues scoring holes 10 ... 18 until the
    first hole where one player wins.  Records the deciding hole in
    match.finished_on_hole.

    Returns a tuple of:
        - list of unsaved MatchPlayHoleResult objects
        - final holes_up value (positive = player1 leading, negative = player2)
          This lets the caller derive the tentative leader even during SD.

    Mutates match.result, match.status, match.finished_on_hole.
    """
    holes_up = 0
    results: list = []

    # ── Scheduled holes 1–9 ──────────────────────────────────────────────
    for hole_num in range(1, 10):
        p1_net = score_index.get(match.player1_id, {}).get(hole_num)
        p2_net = score_index.get(match.player2_id, {}).get(hole_num)

        if p1_net is None or p2_net is None:
            match.status = 'in_progress' if results else 'pending'
            return results, holes_up

        if p1_net < p2_net:
            winner, delta = match.player1, 1
        elif p2_net < p1_net:
            winner, delta = match.player2, -1
        else:
            winner, delta = None, 0

        holes_up += delta
        results.append(MatchPlayHoleResult(
            match=match, hole_number=hole_num,
            p1_net=p1_net, p2_net=p2_net,
            winner=winner, holes_up_after=holes_up,
        ))

        holes_remaining = 9 - hole_num
        if abs(holes_up) > holes_remaining:
            match.finished_on_hole = hole_num
            match.result = 'player1' if holes_up > 0 else 'player2'
            match.status = 'complete'
            return results, holes_up

    # ── All 9 holes scored ───────────────────────────────────────────────
    if holes_up != 0:
        match.result = 'player1' if holes_up > 0 else 'player2'
        match.status = 'complete'
        return results, holes_up

    # ── Sudden death: tied after hole 9 ─────────────────────────────────
    for hole_num in range(10, 19):
        p1_net = score_index.get(match.player1_id, {}).get(hole_num)
        p2_net = score_index.get(match.player2_id, {}).get(hole_num)

        if p1_net is None or p2_net is None:
            match.status = 'in_progress'
            return results, holes_up

        if p1_net < p2_net:
            winner, delta = match.player1, 1
        elif p2_net < p1_net:
            winner, delta = match.player2, -1
        else:
            winner, delta = None, 0

        holes_up += delta
        results.append(MatchPlayHoleResult(
            match=match, hole_number=hole_num,
            p1_net=p1_net, p2_net=p2_net,
            winner=winner, holes_up_after=holes_up,
        ))

        if holes_up != 0:
            match.result           = 'player1' if holes_up > 0 else 'player2'
            match.status           = 'complete'
            match.finished_on_hole = hole_num
            return results, holes_up

    # All 18 holes halved — extreme edge case.
    match.result = 'halved'
    match.status = 'complete'
    return results, holes_up


def _play_back9_match(match: MatchPlayMatch, score_index: dict) -> list:
    """
    Score a 9-hole back-9 match (holes 10–18) with last-hole-won tie-break.
    Used for both the Final and the 3rd Place match.

    If tied after hole 18 → the player who won the most recent hole wins.
    If ALL 9 holes were halved → result = 'halved'.

    Returns a list of unsaved MatchPlayHoleResult objects.
    Mutates match.result, match.status, match.finished_on_hole.
    """
    holes_up           = 0
    results: list      = []
    last_winner_result = None

    for hole_num in range(10, 19):
        p1_net = score_index.get(match.player1_id, {}).get(hole_num)
        p2_net = score_index.get(match.player2_id, {}).get(hole_num)

        if p1_net is None or p2_net is None:
            match.status = 'in_progress' if results else 'pending'
            return results

        if p1_net < p2_net:
            winner, delta      = match.player1, 1
            last_winner_result = 'player1'
        elif p2_net < p1_net:
            winner, delta      = match.player2, -1
            last_winner_result = 'player2'
        else:
            winner, delta      = None, 0

        holes_up += delta
        results.append(MatchPlayHoleResult(
            match=match, hole_number=hole_num,
            p1_net=p1_net, p2_net=p2_net,
            winner=winner, holes_up_after=holes_up,
        ))

        holes_remaining = 18 - hole_num
        if abs(holes_up) > holes_remaining:
            match.finished_on_hole = hole_num
            match.result = 'player1' if holes_up > 0 else 'player2'
            match.status = 'complete'
            return results

    # ── All 9 holes scored ───────────────────────────────────────────────
    if holes_up > 0:
        match.result = 'player1'
        match.status = 'complete'
    elif holes_up < 0:
        match.result = 'player2'
        match.status = 'complete'
    else:
        # Last-hole-won tie-break.
        match.result = last_winner_result if last_winner_result else 'halved'
        match.status = 'complete'

    return results


# ---------------------------------------------------------------------------
# Main calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_tournament_match_play(foursome) -> MatchPlayBracket | None:
    """
    Recalculate all match play results for this foursome's bracket.

    Safe to call repeatedly as scores come in — all hole results are
    deleted and rebuilt from the current HoleScore data each call.

    Flow:
      1. Score round-1 semis (with sudden-death tie-break as needed).
      2. Once both semis complete, assign Final + 3rd Place players.
      3. Score round-2 back-9 matches (last-hole-won tie-break).
      4. Update bracket status and overall winner.

    Returns the updated MatchPlayBracket, or None if none exists.
    """
    try:
        bracket = (
            MatchPlayBracket.objects
            # select_for_update serialises concurrent recalculations for the
            # same bracket — prevents UniqueViolation when a score-submit and
            # a polling GET both trigger calculate at the same instant.
            .select_for_update()
            .prefetch_related('matches')
            .get(foursome=foursome)
        )
    except MatchPlayBracket.DoesNotExist:
        return None

    # Prefer the per-bracket handicap_mode/net_percent so a match-play side
    # game can use Strokes-Off-Low inside the foursome while the round-wide
    # mode (used by Stroke Play, etc.) stays Net.  Brackets created before
    # this field existed default to round.handicap_mode in setup, so the
    # fallback below is just belt-and-suspenders for legacy rows.
    round_obj     = foursome.round
    handicap_mode = bracket.handicap_mode or round_obj.handicap_mode
    net_percent   = bracket.net_percent   if bracket.net_percent is not None else round_obj.net_percent

    # In Strokes-Off-Low mode each match uses PER-PAIR SO: the lower-handicap
    # player in the match plays scratch and the higher gets (their HCP −
    # opponent HCP) strokes allocated by stroke index.  This matches what
    # the score-entry screen shows in the per-player bubble.  The global
    # build_score_index('strokes_off') call without segments degrades to
    # round-level NET (full handicap), which gave the higher player more
    # strokes than the per-opponent SO display promised — leading to net
    # mismatches like "Bill 5 / Gary 6-1=5" being scored as Bill wins.
    so_mode = (handicap_mode == 'strokes_off')

    def _index_for(match):
        if so_mode:
            return build_match_play_score_index(
                foursome, match.player1_id, match.player2_id,
            )
        return build_score_index(foursome, handicap_mode, net_percent)

    # NET / GROSS modes share one global score index across all matches.
    # SO mode builds one per match below (the per-pair calc reads HCPs of
    # only the two players involved).
    score_index = (
        build_score_index(foursome, handicap_mode, net_percent)
        if not so_mode else {}
    )

    MatchPlayHoleResult.objects.filter(match__bracket=bracket).delete()

    matches    = list(
        bracket.matches
        .select_related('player1', 'player2')
        .order_by('round_number', 'id')
    )
    r1_matches = [m for m in matches if m.round_number == 1]
    r2_matches = [m for m in matches if m.round_number == 2]

    all_hole_results: list = []

    # ── Round 1: score semis ─────────────────────────────────────────────
    for match in r1_matches:
        idx = _index_for(match)
        results, _holes_up = _play_semi(match, idx)
        all_hole_results.extend(results)
        match.save(update_fields=['status', 'result', 'finished_on_hole'])

    MatchPlayHoleResult.objects.bulk_create(all_hole_results)
    all_hole_results = []

    r1_complete = all(m.status == 'complete' for m in r1_matches)

    def _semi_winner(semi):
        return semi.player1 if semi.result == 'player1' else semi.player2

    def _semi_loser(semi):
        return semi.player2 if semi.result == 'player1' else semi.player1

    # ── Assign round-2 players ───────────────────────────────────────────
    # The Final / 3rd-Place only begin once BOTH semis are DECIDED (complete).
    # A semi tied after hole 9 goes to sudden death on holes 10+, which share
    # the back-9 holes the Final would use — so assigning finalists (or scoring
    # the back 9) while a semi is still in SD starts the Final before the
    # bracket is settled. Waiting for r1_complete keeps "begins after both
    # semis resolve" literally true.
    if r1_complete and len(r1_matches) == 2 and len(r2_matches) >= 1:
        s1, s2 = r1_matches[0], r1_matches[1]

        s1_winner = _semi_winner(s1)
        s2_winner = _semi_winner(s2)
        s1_loser  = _semi_loser(s1)
        s2_loser  = _semi_loser(s2)

        # r2_matches[0] = Final, r2_matches[1] = 3rd Place
        final = r2_matches[0]
        final.player1 = s1_winner
        final.player2 = s2_winner
        final.save(update_fields=['player1', 'player2'])

        if len(r2_matches) >= 2:
            third = r2_matches[1]
            third.player1 = s1_loser
            third.player2 = s2_loser
            third.save(update_fields=['player1', 'player2'])

    # ── Round 2: score back-9 matches ────────────────────────────────────
    # For SO mode each round-2 match needs a freshly-built pair index —
    # the player1/player2 just got assigned above. Only score once both semis
    # are decided (see above), so a tied semi's SD holes never leak into the
    # Final before its players are known.
    for match in r2_matches:
        if r1_complete:
            idx = _index_for(match)
            results = _play_back9_match(match, idx)
            all_hole_results.extend(results)
            match.save(update_fields=['status', 'result', 'finished_on_hole'])

    MatchPlayHoleResult.objects.bulk_create(all_hole_results)

    # ── Bracket status & overall winner ──────────────────────────────────
    all_matches  = r1_matches + r2_matches
    all_complete = all(m.status == 'complete' for m in all_matches)
    # Use full match list (including round-2) for any_started; r1_any_started
    # only covers round-1 semis.
    any_started  = any(m.status in ('in_progress', 'complete') for m in all_matches)

    if all_complete:
        bracket.status = 'complete'
        # Overall bracket winner = winner of the Final (r2_matches[0])
        deciding = r2_matches[0] if r2_matches else (r1_matches[0] if r1_matches else None)
        if deciding:
            if deciding.result == 'player1':
                bracket.winner = deciding.player1
            elif deciding.result == 'player2':
                bracket.winner = deciding.player2
        bracket.save(update_fields=['status', 'winner'])
    elif any_started:
        bracket.status = 'in_progress'
        bracket.save(update_fields=['status'])

    return bracket


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def tournament_match_play_summary(foursome) -> dict | None:
    """
    Return a serialisable summary of the match play bracket for the UI
    and the round leaderboard.

    Shape
    -----
    {
        'status'  : 'pending' | 'in_progress' | 'complete',
        'winner'  : str | None,
        'money'   : {
            'entry_fee'   : float,
            'prize_pool'  : float,
            'payout_config': { '1st': float, '2nd': float, ... },
            'payouts'     : [
                {'place': '1st', 'player': str|None, 'amount': float},
                {'place': '2nd', 'player': str|None, 'amount': float},
                {'place': '3rd', 'player': str|None, 'amount': float},
                {'place': '4th', 'player': str|None, 'amount': float},
            ],
        },
        'matches' : [
            {
                'id'            : int,
                'round'         : int,
                'label'         : str,   # 'Semi 1', 'Semi 2', 'Final', '3rd Place'
                'player1'       : str,
                'player2'       : str,
                'status'        : str,
                'result'        : 'player1'|'player2'|'halved'|None,
                'winner_name'   : str | None,
                'tie_break'     : 'sudden_death'|'last_hole_won'|None,
                'finished_hole' : int | None,
                'holes' : [
                    {
                        'hole'   : int,
                        'p1_net' : int,
                        'p2_net' : int,
                        'winner' : str | None,
                        'margin' : int,
                        'is_sd'  : bool,
                    },
                ],
            },
            ...
        ],
    }
    """
    try:
        bracket = (
            MatchPlayBracket.objects
            .select_related('winner')
            .prefetch_related(
                'matches__player1',
                'matches__player2',
                'matches__hole_results__winner',
            )
            .get(foursome=foursome)
        )
    except MatchPlayBracket.DoesNotExist:
        return None

    # All real players with handicaps (for the setup screen seed picker)
    all_memberships = list(
        FoursomeMembership.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .select_related('player')
        .order_by('playing_handicap')
    )
    players_out = [
        {
            'player_id'       : m.player.id,
            'name'            : m.player.name,
            'playing_handicap': m.playing_handicap,
        }
        for m in all_memberships
    ]

    matches    = list(bracket.matches.order_by('round_number', 'id'))
    r1_matches = [m for m in matches if m.round_number == 1]
    r2_matches = [m for m in matches if m.round_number == 2]

    # ── Scoring-detail scaffolding (par / SI / gross / prospective strokes) ──
    # The stroke dots follow the bracket's handicap mode, matching how the
    # bracket is actually scored: gross, full-net, or Strokes-Off-Low (per-pair
    # — the lower handicap in the match plays scratch, exactly as
    # build_match_play_score_index and the score-entry "gets" bubble do).
    round_obj = foursome.round
    mp_mode = bracket.handicap_mode or round_obj.handicap_mode
    mp_npct = (bracket.net_percent if bracket.net_percent is not None
               else round_obj.net_percent) or 100
    sc_members = list(
        foursome.memberships.select_related('player', 'tee')
        .filter(player__is_phantom=False))
    member_by_pid = {m.player_id: m for m in sc_members}
    sample_tee = next((m.tee for m in sc_members if m.tee_id is not None), None)
    par_by, si_by = {}, {}
    if sample_tee is not None:
        for h in range(1, 19):
            hd = sample_tee.hole(h)
            par_by[h] = hd.get('par')
            si_by[h]  = hd.get('stroke_index')
    gross_by = {}
    for hs in (
        HoleScore.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    ):
        gross_by[(hs['player_id'], hs['hole_number'])] = hs['gross_score']
    strokes_fn = make_strokes_fn(foursome)

    def _match_scorecard(match):
        """Per-match scoring detail: every hole in the 9-hole range (plus any
        sudden-death holes), with par, stroke index, each player's gross +
        prospective handicap strokes (per the bracket mode) and the hole
        winner id. Prospective — dots show before a hole is scored."""
        p1id, p2id = match.player1_id, match.player2_id
        m1, m2 = member_by_pid.get(p1id), member_by_pid.get(p2id)

        if mp_mode == 'gross':
            def _strokes(pid, hole):
                return 0
        elif mp_mode == 'strokes_off':
            h1 = (m1.playing_handicap or 0) if m1 else 0
            h2 = (m2.playing_handicap or 0) if m2 else 0
            low, hcp_by = min(h1, h2), {p1id: h1, p2id: h2}

            def _strokes(pid, hole):
                m = member_by_pid.get(pid)
                if m is None or m.tee_id is None:
                    return 0
                so = max(0, hcp_by.get(pid, 0) - low)   # per-pair, 100%
                if so <= 0:
                    return 0
                si = m.tee.hole(hole).get('stroke_index', 18)
                return _strokes_on_hole(so, si)
        else:  # net — each player's full playing handicap × net%.
            def _strokes(pid, hole):
                m = member_by_pid.get(pid)
                if m is None or m.tee_id is None:
                    return 0
                eff = round((m.playing_handicap or 0) * mp_npct / 100)
                return strokes_fn(eff, m.tee, hole)

        base = list(range(match.start_hole, match.start_hole + 9))
        hr_by_hole = {hr.hole_number: hr for hr in match.hole_results.all()}
        extra = sorted(h for h in hr_by_hole if h not in base)  # sudden death
        holes = []
        for h in base + extra:
            hr = hr_by_hole.get(h)
            holes.append({
                'hole'         : h,
                'par'          : par_by.get(h),
                'stroke_index' : si_by.get(h),
                'winner_id'    : hr.winner_id if hr else None,
                'is_sd'        : h not in base,
                'scores'       : [
                    {'player_id': p1id, 'gross': gross_by.get((p1id, h)),
                     'strokes': _strokes(p1id, h)},
                    {'player_id': p2id, 'gross': gross_by.get((p2id, h)),
                     'strokes': _strokes(p2id, h)},
                ],
            })
        return {
            'players': [
                {'player_id': p1id, 'name': match.player1.name,
                 'short_name': match.player1.short_name},
                {'player_id': p2id, 'name': match.player2.name,
                 'short_name': match.player2.short_name},
            ],
            'holes'        : holes,
            'holes_in_play': base + extra,
        }

    # Derive current seed order from the round-1 match stubs.
    #
    # 4-player single-elim layout:
    #   semi1: p1=seed1 vs p2=seed4
    #   semi2: p1=seed2 vs p2=seed3
    #
    # 3-player round-robin layout (seed1 plays both semis):
    #   semi1: p1=seed1 vs p2=seed3
    #   semi2: p1=seed1 vs p2=seed2
    #   → both semis share the same player1, so detect by comparing player1 IDs.
    if len(r1_matches) >= 2:
        if r1_matches[0].player1_id == r1_matches[1].player1_id:
            # 3-player round-robin
            seed_order_out = [
                r1_matches[0].player1_id,  # seed 1 (shared across both semis)
                r1_matches[1].player2_id,  # seed 2
                r1_matches[0].player2_id,  # seed 3
            ]
        else:
            # 4-player single elimination
            seed_order_out = [
                r1_matches[0].player1_id,  # seed 1
                r1_matches[1].player1_id,  # seed 2
                r1_matches[1].player2_id,  # seed 3
                r1_matches[0].player2_id,  # seed 4
            ]
    elif len(r1_matches) == 1:
        seed_order_out = [r1_matches[0].player1_id, r1_matches[0].player2_id]
    else:
        seed_order_out = []

    def _winner_name(match):
        if match.result == 'player1': return match.player1.name
        if match.result == 'player2': return match.player2.name
        if match.result == 'halved':  return 'Halved'
        return None

    def _winner_short(match):
        if match.result == 'player1': return match.player1.short_name
        if match.result == 'player2': return match.player2.short_name
        if match.result == 'halved':  return 'Halved'
        return None

    def _loser_name(match):
        if match.result == 'player1': return match.player2.name
        if match.result == 'player2': return match.player1.name
        return None

    def _winner_id(match):
        if match.result == 'player1': return match.player1_id
        if match.result == 'player2': return match.player2_id
        return None

    def _loser_id(match):
        if match.result == 'player1': return match.player2_id
        if match.result == 'player2': return match.player1_id
        return None

    def _tie_break_type(match, hole_results):
        if match.status != 'complete':
            return None
        if match.round_number == 1:
            if any(hr.hole_number > 9 for hr in hole_results):
                return 'sudden_death'
        elif match.round_number == 2:
            if match.finished_on_hole is None and len(hole_results) == 9:
                h18 = next((hr for hr in hole_results if hr.hole_number == 18), None)
                if h18 and h18.holes_up_after == 0 and match.result != 'halved':
                    return 'last_hole_won'
        return None

    # Whether all Round-1 semis are DECIDED. The Final / 3rd-Place stay "TBD"
    # (Semi N Winner) until this is true — a semi tied after 9 is still in
    # sudden death and its winner isn't known, so the back-9 matches haven't
    # really started (mirrors calculate_tournament_match_play's r1_complete gate).
    r1_complete = all(m.status == 'complete' for m in r1_matches) if r1_matches else True

    matches_out = []
    r2_idx = 0
    for match in r1_matches + r2_matches:
        r = match.round_number
        if r == 1:
            idx = r1_matches.index(match)
        else:
            idx = r2_idx
            r2_idx += 1

        label        = _MATCH_LABELS.get((r, idx), f'Round {r} Match {idx + 1}')
        hole_results = sorted(match.hole_results.all(), key=lambda h: h.hole_number)
        tie_break    = _tie_break_type(match, hole_results)

        holes_out = [
            {
                'hole'   : hr.hole_number,
                'p1_net' : hr.p1_net,
                'p2_net' : hr.p2_net,
                'winner' : hr.winner.name if hr.winner else None,
                'margin' : hr.holes_up_after,
                'is_sd'  : r == 1 and hr.hole_number > 9,
            }
            for hr in hole_results
        ]

        # players_tbd: the semis aren't all decided yet — show "Semi 1 Winner /
        #   Semi 2 Winner" so the Final/3rd-Place don't appear to have started
        #   while a semi is still in sudden death.
        if r == 2 and not r1_complete:
            players_tbd       = True
            players_tentative = False
            if idx == 0:   # Final
                p1_display = 'Semi 1 Winner'
                p2_display = 'Semi 2 Winner'
                p1_short   = 'S1 W'
                p2_short   = 'S2 W'
            else:          # 3rd Place
                p1_display = 'Semi 1 Loser'
                p2_display = 'Semi 2 Loser'
                p1_short   = 'S1 L'
                p2_short   = 'S2 L'
        else:
            players_tbd       = False
            players_tentative = False   # no tentative tracking — see r1_complete
            p1_display        = match.player1.name
            p2_display        = match.player2.name
            p1_short          = match.player1.short_name
            p2_short          = match.player2.short_name

        matches_out.append({
            'id'               : match.id,
            'round'            : r,
            'label'            : label,
            'player1'          : p1_display,
            'player1_short'    : p1_short,
            'player1_id'       : match.player1.id,
            'player2'          : p2_display,
            'player2_short'    : p2_short,
            'player2_id'       : match.player2.id,
            'players_tbd'      : players_tbd,
            'players_tentative': players_tentative,
            'status'           : match.status,
            'result'           : match.result,
            'winner_name'      : _winner_name(match),
            'winner_short'     : _winner_short(match),
            'tie_break'        : tie_break,
            'finished_hole'    : match.finished_on_hole,
            'holes'            : holes_out,
            # Scoring detail — present once the match's players are known
            # (semis always; final/consolation after both semis resolve).
            'scorecard'        : None if players_tbd else _match_scorecard(match),
        })

    # ── Money block ───────────────────────────────────────────────────────
    real_count  = foursome.memberships.filter(player__is_phantom=False).count()
    entry_fee   = float(bracket.entry_fee)
    prize_pool  = entry_fee * real_count
    payout_cfg  = bracket.payout_config or {}

    # Resolve who finished where (only when bracket is complete)
    final      = r2_matches[0] if len(r2_matches) >= 1 else None
    third_match = r2_matches[1] if len(r2_matches) >= 2 else None

    place_players = {
        '1st': _winner_name(final)       if final and final.status == 'complete' else None,
        '2nd': _loser_name(final)        if final and final.status == 'complete' else None,
        '3rd': _winner_name(third_match) if third_match and third_match.status == 'complete' else None,
        '4th': _loser_name(third_match)  if third_match and third_match.status == 'complete' else None,
    }
    place_player_ids = {
        '1st': _winner_id(final)       if final and final.status == 'complete' else None,
        '2nd': _loser_id(final)        if final and final.status == 'complete' else None,
        '3rd': _winner_id(third_match) if third_match and third_match.status == 'complete' else None,
        '4th': _loser_id(third_match)  if third_match and third_match.status == 'complete' else None,
    }

    payouts_out = [
        {
            'place'    : place,
            'player'   : place_players.get(place),
            'player_id': place_player_ids.get(place),
            'amount'   : float(payout_cfg.get(place, 0.00)),
        }
        for place in ('1st', '2nd', '3rd', '4th')
    ]

    money = {
        'entry_fee'    : entry_fee,
        'prize_pool'   : prize_pool,
        'payout_config': {k: float(v) for k, v in payout_cfg.items()},
        'payouts'      : payouts_out,
    }

    return {
        'status'      : bracket.status,
        'winner'      : bracket.winner.name if bracket.winner else None,
        # foursome_id lets the mobile client tell which group this
        # payload belongs to — guards against stale rp.matchPlayData
        # leaking into another foursome's score-entry bottom bar.
        'foursome_id' : foursome.id,
        # bracket_type drives mobile branching (single_elim vs cup_singles
        # vs legacy three_player_points) so e.g. the score-entry per-
        # opponent SO display knows which calculator to use.
        'bracket_type': bracket.bracket_type,
        # Expose the bracket's handicap config so the setup screen can
        # pre-populate the picker on re-entry and the leaderboard can
        # display the active mode alongside the bracket.
        'handicap'    : {
            'mode'       : bracket.handicap_mode,
            'net_percent': bracket.net_percent,
        },
        'players'   : players_out,
        'seed_order': seed_order_out,
        'money'     : money,
        'matches'   : matches_out,
    }
