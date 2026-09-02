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

A halved match plays on — it never splits (no presses, no card-offs)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Semi (round 1, holes 1–9):
    All square after nine and the match simply CONTINUES into the back nine,
    reading back from hole 10, until the first hole one of them takes
    outright. That hole ends the semi and names the opponent.
    ``finished_on_hole`` records it.

    **Nobody waits.** The pair whose semi already resolved tee off on 10 on
    schedule and their back-9 match is scored live against an opponent the
    bracket cannot name yet — labelled ``1 UP vs. TBD``, never "Pending".
    This is unambiguous rather than a guess: the pair still level can only
    HALVE the holes they play in overtime, because the first hole they do not
    halve is the hole that ends the semi. Their two nets are therefore one
    number, and the waiter's result is settled as it is entered.

    Concretely: while a semi is unresolved its two contenders are
    interchangeable for scoring the back-9 matches, so the round-2 match is
    assigned one of them and flagged TBD. Once the semi resolves, the real
    winner replaces it and holes 10..k re-score identically, because those
    holes were halved.

    This also removes the collision the old sudden-death rule created, where
    a semi borrowed hole 10 from the final and a semi that ran to 12 left the
    final six holes to settle a nine-hole match.

Final / 3rd Place (round 2, holes 10–18):
    Level after 18 and the match is HALVED. The money splits — 1st and 2nd
    are added together and shared; nobody is played off for cash.
    Where a single NAME is needed (the trophy, and the seat in the day-2
    champions' foursome) it goes to the LAST HOLE WON: read the card
    backwards to the most recent hole either golfer took outright. Stored on
    ``MatchPlayMatch.trophy_player``.
    A halved 3rd-place match simply splits — nothing depends on the order, so
    nothing needs breaking, and no trophy is read.
    If ALL nine holes were halved there is no last hole to read: a true dead
    heat, trophy_player stays null.

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
from core.handicap_math import round_half_up


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
# Display helpers — match summaries use the surname alone
# ---------------------------------------------------------------------------

def _surname(player) -> str:
    """
    ``Detomasi vs Gunst``, not ``Aldo Detomasi vs Alex Gun…``.

    A match summary row has about forty pixels a side. Six of eight first
    names in the test field start with A, so a truncated first name identifies
    nobody, while the surname fits, disambiguates better and reads the way
    golfers say it. Falls back to the short name, then the whole name.
    """
    name = (player.name or '').strip()
    if not name:
        return (player.short_name or '').strip()
    parts = name.split()
    return parts[-1] if len(parts) > 1 else name


def _feeding_semi_open(r1_matches, side: int) -> bool:
    """True when the semi feeding this side of a back-9 match is still level."""
    if side >= len(r1_matches):
        return False
    return r1_matches[side].status != 'complete'


def _match_line(match, hole_results, players_tbd, p1_display, p2_display) -> str:
    """
    The one-line state the board and the score-entry card render:

        Gunst 4&2                 closed out
        All square thru 11        level, still out there
        1 UP thru 11              scored against an opponent not yet named,
                                  read from the named golfer's side (1 DN when
                                  he is behind)

    Never "Pending — waiting for scores". The back-9 matches are real from the
    first tee shot on 10, which is the whole point of the playing-on rule.
    """
    if not hole_results:
        return 'Not started'

    thru   = hole_results[-1].hole_number
    margin = hole_results[-1].holes_up_after

    if match.status == 'complete':
        if match.result == 'halved':
            if match.trophy_player_id:
                return f'Halved — {_surname(match.trophy_player)} won the last hole'
            return 'Halved'
        winner = match.player1 if match.result == 'player1' else match.player2
        # "4&2" — the margin, and the holes that were left when it closed.
        last_hole = match.start_hole + 8
        remaining = last_hole - (match.finished_on_hole or last_hole)
        if remaining > 0:
            return f'{_surname(winner)} {abs(margin)}&{remaining}'
        return f'{_surname(winner)} {abs(margin)} UP'

    # Live.
    if margin == 0:
        return f'All square thru {thru}'

    if players_tbd:
        # Read from the named golfer's side — the other one has no name yet.
        p1_named = p1_display != 'TBD'
        ahead    = (margin > 0) if p1_named else (margin < 0)
        return f'{abs(margin)} {"UP" if ahead else "DN"} thru {thru}'

    holder = match.player1 if margin > 0 else match.player2
    return f'{_surname(holder)} {abs(margin)} UP thru {thru}'


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
    Score a 9-hole semi-final (holes 1–9). All square after nine and it PLAYS
    ON into the back nine rather than splitting or going to a card-off.

    Returns a tuple of:
        - list of unsaved MatchPlayHoleResult objects
        - final holes_up value (positive = player1 leading, negative = player2)

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

    # ── All square after nine: play on into the back nine ────────────────
    # These holes belong to the semi AND to the back-9 matches happening
    # alongside it — by design rather than by collision. The pair can only
    # halve them, so the first hole either takes outright ends the semi.
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
    Score a 9-hole back-9 match (holes 10–18). Used for the Final and the
    3rd-Place match.

    Level after 18 the match is HALVED and the money splits — 1st and 2nd are
    added together and shared. Where a single name is still needed (the
    trophy, and the seat in the day-2 champions' foursome) it goes to the LAST
    HOLE WON, recorded on ``match.trophy_player``; the RESULT stays 'halved'
    so the payout reducer splits rather than paying a winner.

    All nine halved is a true dead heat: there is no last hole to read, so
    trophy_player stays null.

    Returns a list of unsaved MatchPlayHoleResult objects.
    Mutates match.result, match.status, match.finished_on_hole,
    match.trophy_player.
    """
    holes_up            = 0
    results: list       = []
    last_winner_player  = None
    match.trophy_player = None

    for hole_num in range(10, 19):
        p1_net = score_index.get(match.player1_id, {}).get(hole_num)
        p2_net = score_index.get(match.player2_id, {}).get(hole_num)

        if p1_net is None or p2_net is None:
            match.status = 'in_progress' if results else 'pending'
            return results

        if p1_net < p2_net:
            winner, delta      = match.player1, 1
            last_winner_player = match.player1
        elif p2_net < p1_net:
            winner, delta      = match.player2, -1
            last_winner_player = match.player2
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
        # HALVED. The money splits; the result stays 'halved' so the payout
        # reducer adds the two places together and shares them. Only the
        # trophy and the next-stage seat need one name, and they are read off
        # the last hole won — null when every hole was halved.
        match.result        = 'halved'
        match.status        = 'complete'
        match.trophy_player = last_winner_player

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

    def _semi_sides(semi):
        """
        (winner_side, loser_side, is_tbd) for a semi.

        While a semi is still playing on, its two contenders are
        INTERCHANGEABLE for scoring the back-9 matches: they can only halve
        the overtime holes, because the first hole either takes outright is
        the hole that ends the semi. So both sides get a stand-in and the
        match is flagged TBD; when the semi resolves, the real names replace
        the stand-ins and holes 10..k re-score to exactly the same result.

        This is what lets the resolved pair tee off on 10 on schedule and
        carry a real, scored `1 UP vs. TBD` instead of an empty "Pending" card.
        """
        if semi.status == 'complete' and semi.result in ('player1', 'player2'):
            return _semi_winner(semi), _semi_loser(semi), False
        return semi.player1, semi.player2, True

    # ── Assign round-2 players ───────────────────────────────────────────
    # Nobody waits: the back-9 matches are assigned and scored from hole 10
    # whether or not both semis have resolved.
    r2_tbd = {}          # match id → True when its opponent is not yet named
    if len(r1_matches) == 2 and len(r2_matches) >= 1:
        s1, s2 = r1_matches[0], r1_matches[1]
        s1_win, s1_lose, s1_tbd = _semi_sides(s1)
        s2_win, s2_lose, s2_tbd = _semi_sides(s2)

        # r2_matches[0] = Final, r2_matches[1] = 3rd Place
        final = r2_matches[0]
        final.player1, final.player2 = s1_win, s2_win
        final.save(update_fields=['player1', 'player2'])
        r2_tbd[final.id] = s1_tbd or s2_tbd

        if len(r2_matches) >= 2:
            third = r2_matches[1]
            third.player1, third.player2 = s1_lose, s2_lose
            third.save(update_fields=['player1', 'player2'])
            r2_tbd[third.id] = s1_tbd or s2_tbd

    # ── Round 2: score back-9 matches ────────────────────────────────────
    # For SO mode each round-2 match needs a freshly-built pair index — the
    # player1/player2 were just assigned above.
    for match in r2_matches:
        idx = _index_for(match)
        results = _play_back9_match(match, idx)
        all_hole_results.extend(results)
        match.save(update_fields=['status', 'result', 'finished_on_hole',
                                  'trophy_player'])

    MatchPlayHoleResult.objects.bulk_create(all_hole_results)

    # ── Bracket status & overall winner ──────────────────────────────────
    all_matches  = r1_matches + r2_matches
    all_complete = all(m.status == 'complete' for m in all_matches)
    # Use full match list (including round-2) for any_started; r1_any_started
    # only covers round-1 semis.
    any_started  = any(m.status in ('in_progress', 'complete') for m in all_matches)

    if all_complete:
        bracket.status = 'complete'
        # Overall bracket winner = winner of the Final (r2_matches[0]). A
        # HALVED final splits the money but still has to produce one name for
        # the trophy and the day-2 seat, and that name is the last hole won.
        deciding = r2_matches[0] if r2_matches else (r1_matches[0] if r1_matches else None)
        if deciding:
            if deciding.result == 'player1':
                bracket.winner = deciding.player1
            elif deciding.result == 'player2':
                bracket.winner = deciding.player2
            elif deciding.result == 'halved':
                bracket.winner = deciding.trophy_player
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

    def _match_scorecard(match, tbd_p1=False, tbd_p2=False):
        """Per-match scoring detail: every hole in the 9-hole range (plus any
        overtime holes a semi played on into), with par, stroke index, each
        player's gross + prospective handicap strokes (per the bracket mode)
        and the hole winner id. Prospective — dots show before a hole is scored.

        A side whose semi has not resolved is TBD: the match RESULT against it
        is settled (the two still level halve every overtime hole, so their net
        is one number) but their GROSS is not — it belongs to one of two
        golfers. So the card names that side 'TBD' and leaves its cells empty
        rather than printing a stand-in's card as if it were the opponent's."""
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
                eff = round_half_up((m.playing_handicap or 0) * mp_npct / 100)
                return strokes_fn(eff, m.tee, hole)

        base = list(range(match.start_hole, match.start_hole + 9))
        hr_by_hole = {hr.hole_number: hr for hr in match.hole_results.all()}
        extra = sorted(h for h in hr_by_hole if h not in base)  # sudden death
        holes = []
        def _cell(pid, hole, tbd):
            if tbd:
                return {'player_id': None, 'gross': None, 'strokes': 0,
                        'tbd': True}
            return {'player_id': pid, 'gross': gross_by.get((pid, hole)),
                    'strokes': _strokes(pid, hole), 'tbd': False}

        for h in base + extra:
            hr = hr_by_hole.get(h)
            holes.append({
                'hole'         : h,
                'par'          : par_by.get(h),
                'stroke_index' : si_by.get(h),
                'winner_id'    : hr.winner_id if hr else None,
                'is_overtime'  : h not in base,
                'is_sd'        : h not in base,   # retired alias
                'scores'       : [_cell(p1id, h, tbd_p1),
                                  _cell(p2id, h, tbd_p2)],
            })

        def _side(pid, player, tbd):
            if tbd:
                return {'player_id': None, 'name': 'TBD', 'short_name': 'TBD',
                        'tbd': True}
            return {'player_id': pid, 'name': player.name,
                    'short_name': player.short_name,
                    'surname': _surname(player), 'tbd': False}

        return {
            'players': [_side(p1id, match.player1, tbd_p1),
                        _side(p2id, match.player2, tbd_p2)],
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
            # Not sudden death: the semi PLAYED ON into the back nine and the
            # first hole either golfer took outright ended it.
            if any(hr.hole_number > 9 for hr in hole_results):
                return 'played_on'
        elif match.round_number == 2 and match.result == 'halved':
            # Halved: the money splits. A trophy_player means one name was
            # still needed and was read off the last hole won.
            return 'last_hole_won' if match.trophy_player_id else 'dead_heat'
        return None

    # Whether all Round-1 semis are DECIDED. The Final / 3rd-Place carry a real
    # scored result either way — that is the whole point of the playing-on rule
    # — but their opponent is labelled TBD until the semi that feeds them ends.
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
                # The semi played ON into these holes. `is_sd` is the retired
                # sudden-death name, kept one release for older clients; the
                # SD badge is gone from the board.
                'is_overtime': r == 1 and hr.hole_number > 9,
                'is_sd'      : r == 1 and hr.hole_number > 9,
            }
            for hr in hole_results
        ]

        # A back-9 match whose feeding semi is still level plays against an
        # opponent the bracket cannot name yet. The match IS scored and IS
        # real — the two still level can only halve, so the result is settled
        # as it is entered — so the side reads "TBD", never "Pending".
        # Match summaries use the SURNAME ALONE: six of eight first names in
        # the test field start with A, so a truncated first name identifies
        # nobody.
        tbd_p1 = tbd_p2 = False
        if r == 2 and not r1_complete:
            tbd_p1 = _feeding_semi_open(r1_matches, 0)
            tbd_p2 = _feeding_semi_open(r1_matches, 1)
        if tbd_p1 or tbd_p2:
            players_tbd       = True
            players_tentative = False
            p1_display = 'TBD' if tbd_p1 else match.player1.name
            p2_display = 'TBD' if tbd_p2 else match.player2.name
            p1_short   = 'TBD' if tbd_p1 else _surname(match.player1)
            p2_short   = 'TBD' if tbd_p2 else _surname(match.player2)
        else:
            players_tbd       = False
            players_tentative = False
            p1_display        = match.player1.name
            p2_display        = match.player2.name
            p1_short          = match.player1.short_name
            p2_short          = match.player2.short_name

        # The line the board and the score-entry card show for this match —
        # "Gunst 4&2", "All square thru 11", "1 UP vs. TBD".
        match_line = _match_line(match, hole_results, players_tbd,
                                 p1_display, p2_display)

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
            # Match summaries read the surname alone.
            'pairing'          : (f'{p1_short} vs {p2_short}' if players_tbd
                                  else f'{_surname(match.player1)} vs '
                                       f'{_surname(match.player2)}'),
            'line'             : match_line,
            # A halved match splits the money. trophy_* names who takes the
            # trophy and the next-stage seat, by last hole won — the ONLY
            # thing last-hole-won decides.
            'trophy_player_id' : match.trophy_player_id,
            'trophy_player'    : (match.trophy_player.name
                                  if match.trophy_player_id else None),
            'tie_break'        : tie_break,
            'finished_hole'    : match.finished_on_hole,
            'holes'            : holes_out,
            # Scoring detail — always present. A back-9 match against a semi
            # still playing on is a real, scored match; only the unnamed
            # side's cells are blank.
            'scorecard'        : _match_scorecard(match, tbd_p1, tbd_p2),
        })

    # ── Money block ───────────────────────────────────────────────────────
    real_count  = foursome.memberships.filter(player__is_phantom=False).count()
    entry_fee   = float(bracket.entry_fee)
    prize_pool  = entry_fee * real_count
    payout_cfg  = bracket.payout_config or {}

    # Resolve who finished where (only when bracket is complete)
    final      = r2_matches[0] if len(r2_matches) >= 1 else None
    third_match = r2_matches[1] if len(r2_matches) >= 2 else None

    def _finishers(match):
        """
        (higher_place_player, lower_place_player) for a decided match, or
        (None, None) while it is unfinished.

        A HALVED match still fills both places — the money is split between
        them — so it returns both golfers rather than 'Halved' and a blank.
        The trophy_player is listed first because that is who takes the
        trophy and the next-stage seat; the order carries no extra money.
        """
        if match is None or match.status != 'complete':
            return None, None
        if match.result == 'player1':
            return match.player1, match.player2
        if match.result == 'player2':
            return match.player2, match.player1
        if match.trophy_player_id == match.player2_id:
            return match.player2, match.player1
        return match.player1, match.player2

    f_hi, f_lo = _finishers(final)
    t_hi, t_lo = _finishers(third_match)
    place_players = {
        '1st': f_hi.name if f_hi else None,
        '2nd': f_lo.name if f_lo else None,
        '3rd': t_hi.name if t_hi else None,
        '4th': t_lo.name if t_lo else None,
    }
    place_player_ids = {
        '1st': f_hi.id if f_hi else None,
        '2nd': f_lo.id if f_lo else None,
        '3rd': t_hi.id if t_hi else None,
        '4th': t_lo.id if t_lo else None,
    }

    # ── Halved matches split the two places they occupy ───────────────────
    # A halved final shares 1st and 2nd; a halved 3rd-place match shares 3rd
    # and 4th. Nobody is played off for cash — the trophy is the only thing
    # last-hole-won decides. `split_with` names the other golfer so the row
    # can read "1st/2nd — split, $X each".
    def _halved_pair(match, places):
        if match is None or match.status != 'complete' or match.result != 'halved':
            return None
        total = sum(float(payout_cfg.get(p, 0.00)) for p in places)
        return {
            'places' : list(places),
            'each'   : round(total / 2, 2),
            'players': [
                {'player_id': match.player1_id, 'name': match.player1.name},
                {'player_id': match.player2_id, 'name': match.player2.name},
            ],
            'trophy_player_id': match.trophy_player_id,
        }

    splits = [s for s in (_halved_pair(final, ('1st', '2nd')),
                          _halved_pair(third_match, ('3rd', '4th'))) if s]
    split_by_pid = {p['player_id']: s
                    for s in splits for p in s['players']}

    payouts_out = []
    for place in ('1st', '2nd', '3rd', '4th'):
        pid = place_player_ids.get(place)
        payouts_out.append({
            'place'    : place,
            'player'   : place_players.get(place),
            'player_id': pid,
            'amount'   : float(payout_cfg.get(place, 0.00)),
            # Every paid place names its recipient, and a split says so.
            'recipient': 'golfer',
            'split'    : split_by_pid.get(pid) is not None,
        })

    money = {
        'entry_fee'    : entry_fee,
        'prize_pool'   : prize_pool,
        'payout_config': {k: float(v) for k, v in payout_cfg.items()},
        'payouts'      : payouts_out,
        'splits'       : splits,
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
