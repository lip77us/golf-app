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
from scoring.handicap import build_score_index
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

    bracket = MatchPlayBracket.objects.create(
        foursome      = foursome,
        bracket_type  = 'single_elim',
        status        = 'pending',
        entry_fee     = entry_fee,
        payout_config = payout_config or {},
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

    round_obj     = foursome.round
    handicap_mode = round_obj.handicap_mode
    net_percent   = round_obj.net_percent
    score_index   = build_score_index(foursome, handicap_mode, net_percent)

    MatchPlayHoleResult.objects.filter(match__bracket=bracket).delete()

    matches    = list(
        bracket.matches
        .select_related('player1', 'player2')
        .order_by('round_number', 'id')
    )
    r1_matches = [m for m in matches if m.round_number == 1]
    r2_matches = [m for m in matches if m.round_number == 2]

    all_hole_results: list = []
    # holes_up and result lists per semi — used for tentative leader and
    # detecting whether each semi has entered SD (hole > 9 scored).
    semi_holes_up: dict[int, int]  = {}
    semi_results:  dict[int, list] = {}

    # ── Round 1: score semis ─────────────────────────────────────────────
    for match in r1_matches:
        results, holes_up = _play_semi(match, score_index)
        semi_holes_up[match.id] = holes_up
        semi_results[match.id]  = results
        all_hole_results.extend(results)
        match.save(update_fields=['status', 'result', 'finished_on_hole'])

    MatchPlayHoleResult.objects.bulk_create(all_hole_results)
    all_hole_results = []

    r1_complete     = all(m.status == 'complete' for m in r1_matches)

    # A semi is "past the front 9" when it is either complete (outright winner)
    # OR actively in sudden death (has scored at least one hole beyond hole 9).
    # A semi that is merely tied after hole 9 with no SD holes yet entered is
    # NOT past the front 9.  semi_results captures the in-memory result list
    # from each _play_semi() call so we don't need an extra DB query here.

    def _semi_past_front_9(match, result_list: list) -> bool:
        """True if the semi has a confirmed winner OR is actively in SD."""
        if match.status == 'complete':
            return True
        return any(r.hole_number > 9 for r in result_list)

    def _tentative_winner(semi, holes_up: int):
        """Return the confirmed winner, or the current SD leader (player1 on tie)."""
        if semi.result == 'player1': return semi.player1
        if semi.result == 'player2': return semi.player2
        return semi.player1 if holes_up >= 0 else semi.player2

    def _tentative_loser(semi, holes_up: int):
        winner = _tentative_winner(semi, holes_up)
        return semi.player2 if winner.id == semi.player1_id else semi.player1

    # Back-9 tracking only starts when ALL semis are past the front 9.
    # This prevents prematurely assigning finalists when one semi is still
    # tied at hole 9 with no SD holes played yet.
    r1_ready = all(
        _semi_past_front_9(m, semi_results.get(m.id, []))
        for m in r1_matches
    )

    # ── Assign round-2 players ───────────────────────────────────────────
    # Assign as soon as all semis are past hole 9.  If any semi is still in
    # sudden death, the unresolved side uses the current SD leader as a
    # tentative assignment — corrected automatically on the next recalculation
    # once the SD resolves.
    if r1_ready and len(r1_matches) == 2 and len(r2_matches) >= 1:
        s1, s2 = r1_matches[0], r1_matches[1]
        hu1, hu2 = semi_holes_up.get(s1.id, 0), semi_holes_up.get(s2.id, 0)

        s1_winner = _tentative_winner(s1, hu1)
        s2_winner = _tentative_winner(s2, hu2)
        s1_loser  = _tentative_loser(s1, hu1)
        s2_loser  = _tentative_loser(s2, hu2)

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
    for match in r2_matches:
        if r1_ready:
            results = _play_back9_match(match, score_index)
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

    def _loser_name(match):
        if match.result == 'player1': return match.player2.name
        if match.result == 'player2': return match.player1.name
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

    # Whether all Round-1 semis are decided.
    r1_complete = all(m.status == 'complete' for m in r1_matches) if r1_matches else True

    # Back-9 tracking is active when ALL semis are past the front 9 —
    # i.e. each semi is either complete OR has at least one SD hole scored.
    # We use the prefetched hole_results to avoid extra queries.
    def _semi_past_front_9_summary(match) -> bool:
        if match.status == 'complete':
            return True
        return any(hr.hole_number > 9 for hr in match.hole_results.all())

    r1_ready = all(_semi_past_front_9_summary(m) for m in r1_matches) if r1_matches else True

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

        # players_tbd: not all semis are past hole 9 yet (e.g. one semi tied at
        #   hole 9 with no SD holes entered) — show "Semi 1 Winner / Semi 2 Winner".
        # players_tentative: all semis past hole 9 but not all complete (SD
        #   still active) — show real names with a "tracking live" note.
        if r == 2 and not r1_ready:
            players_tbd       = True
            players_tentative = False
            if idx == 0:   # Final
                p1_display = 'Semi 1 Winner'
                p2_display = 'Semi 2 Winner'
            else:          # 3rd Place
                p1_display = 'Semi 1 Loser'
                p2_display = 'Semi 2 Loser'
        else:
            players_tbd       = False
            players_tentative = r == 2 and not r1_complete
            p1_display        = match.player1.name
            p2_display        = match.player2.name

        matches_out.append({
            'id'               : match.id,
            'round'            : r,
            'label'            : label,
            'player1'          : p1_display,
            'player1_id'       : match.player1.id,
            'player2'          : p2_display,
            'player2_id'       : match.player2.id,
            'players_tbd'      : players_tbd,
            'players_tentative': players_tentative,
            'status'           : match.status,
            'result'           : match.result,
            'winner_name'      : _winner_name(match),
            'tie_break'        : tie_break,
            'finished_hole'    : match.finished_on_hole,
            'holes'            : holes_out,
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

    payouts_out = [
        {
            'place'  : place,
            'player' : place_players.get(place),
            'amount' : float(payout_cfg.get(place, 0.00)),
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
        'status'    : bracket.status,
        'winner'    : bracket.winner.name if bracket.winner else None,
        'players'   : players_out,
        'seed_order': seed_order_out,
        'money'     : money,
        'matches'   : matches_out,
    }
