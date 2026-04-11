"""
services/match_play.py
----------------------
Match play calculator — individual head-to-head within a foursome.

Rules
~~~~~
* Played as a secondary game within a foursome.
* 4-player foursome: 2 semi-final matches on the front 9, winners
  play a final on the back 9.  Losers play a consolation on the back 9.
  bracket_type = 'single_elim'
* 3-player foursome (one phantom): 3 parallel 9-hole round-robin matches.
  Points (2 win, 1 halve, 0 loss). Top 2 by points play a 9-hole final.
  bracket_type = 'three_player_points'
* Scoring: individual net scores. Lower net wins the hole. Tie = halved.
* A match concludes early when one player leads by more holes than remain.
* holes_up_after: running margin (positive = player1 leading).

Public API
~~~~~~~~~~
    bracket = setup_match_play(foursome)
    results = calculate_match_play(foursome)
    summary = match_play_summary(foursome)
"""

from django.db import transaction

from games.models import MatchPlayBracket, MatchPlayMatch, MatchPlayHoleResult
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_match_play(foursome) -> MatchPlayBracket:
    """
    Create MatchPlayBracket and MatchPlayMatch stubs for this foursome.

    For a 4-some: 2 semi-final matches (holes 1-9) + 1 final + 1 consolation
    (holes 10-18).  Seeding is by playing handicap (lowest vs highest,
    second-lowest vs second-highest) — caller may override after creation.

    For a 3-some: 3 round-robin matches on holes 1-9, then final on 10-18.

    Returns the MatchPlayBracket.  Does NOT set MatchPlayMatch.player1/player2
    for finals — those are set by calculate_match_play after semi results.
    """
    MatchPlayBracket.objects.filter(foursome=foursome).delete()

    memberships = list(
        FoursomeMembership.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .select_related('player')
        .order_by('playing_handicap')   # ascending = lowest hcp first
    )
    real_count = len(memberships)

    if real_count == 4:
        bracket_type = 'single_elim'
    else:
        bracket_type = 'three_player_points'

    bracket = MatchPlayBracket.objects.create(
        foursome     = foursome,
        bracket_type = bracket_type,
        status       = 'pending',
    )

    if real_count == 4:
        # Seeding: lowest hcp vs highest, middle two vs each other
        p = [m.player for m in memberships]   # sorted by handicap
        # Semi 1: seed 1 (low hcp) vs seed 4 (high hcp)
        MatchPlayMatch.objects.create(
            bracket      = bracket,
            round_number = 1,
            start_hole   = 1,
            player1      = p[0],
            player2      = p[3],
            status       = 'pending',
        )
        # Semi 2: seed 2 vs seed 3
        MatchPlayMatch.objects.create(
            bracket      = bracket,
            round_number = 1,
            start_hole   = 1,
            player1      = p[1],
            player2      = p[2],
            status       = 'pending',
        )
        # Final and consolation stubs (players set after semis resolve)
        MatchPlayMatch.objects.create(
            bracket      = bracket,
            round_number = 2,
            start_hole   = 10,
            player1      = p[0],   # placeholder
            player2      = p[1],   # placeholder
            status       = 'pending',
        )
        MatchPlayMatch.objects.create(
            bracket      = bracket,
            round_number = 2,
            start_hole   = 10,
            player1      = p[2],   # placeholder (consolation)
            player2      = p[3],
            status       = 'pending',
        )

    else:
        # 3-player round robin (holes 1-9)
        p = [m.player for m in memberships]
        pairs = [(p[0], p[1]), (p[0], p[2]), (p[1], p[2])]
        for p1, p2 in pairs:
            MatchPlayMatch.objects.create(
                bracket      = bracket,
                round_number = 1,
                start_hole   = 1,
                player1      = p1,
                player2      = p2,
                status       = 'pending',
            )
        # Final stub
        MatchPlayMatch.objects.create(
            bracket      = bracket,
            round_number = 2,
            start_hole   = 10,
            player1      = p[0],
            player2      = p[1],
            status       = 'pending',
        )

    return bracket


# ---------------------------------------------------------------------------
# Calculator helpers
# ---------------------------------------------------------------------------

def _play_match(match: MatchPlayMatch, score_index: dict) -> list:
    """
    Calculate MatchPlayHoleResult rows for one match.
    Returns a list of unsaved MatchPlayHoleResult objects.
    Mutates match.result / match.status / match.finished_on_hole.
    """
    end_hole = match.start_hole + 8    # 9-hole match
    holes_up = 0
    results  = []

    for hole_num in range(match.start_hole, end_hole + 1):
        p1_net = score_index.get(match.player1_id, {}).get(hole_num)
        p2_net = score_index.get(match.player2_id, {}).get(hole_num)

        if p1_net is None or p2_net is None:
            break  # incomplete

        if p1_net < p2_net:
            winner = match.player1
            holes_up += 1
        elif p2_net < p1_net:
            winner = match.player2
            holes_up -= 1
        else:
            winner = None   # halved

        results.append(MatchPlayHoleResult(
            match          = match,
            hole_number    = hole_num,
            p1_net         = p1_net,
            p2_net         = p2_net,
            winner         = winner,
            holes_up_after = holes_up,
        ))

        # Early finish check
        holes_remaining = end_hole - hole_num
        if abs(holes_up) > holes_remaining:
            match.finished_on_hole = hole_num
            break

    # Resolve match
    holes_played  = len(results)
    holes_in_match = 9

    if holes_played == 0:
        match.status = 'pending'
    elif holes_played < holes_in_match and match.finished_on_hole is None:
        match.status = 'in_progress'
    else:
        match.status = 'complete'
        if holes_up > 0:
            match.result = 'player1'
        elif holes_up < 0:
            match.result = 'player2'
        else:
            match.result = 'halved'

    return results


# ---------------------------------------------------------------------------
# Main calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_match_play(foursome) -> MatchPlayBracket | None:
    """
    Calculate MatchPlayHoleResult rows for all matches in this foursome's
    bracket, resolve semi results, set final/consolation players, and
    update bracket status.

    Safe to call repeatedly — hole results are replaced each call.

    Returns the MatchPlayBracket, or None if none exists.
    """
    try:
        bracket = (
            MatchPlayBracket.objects
            .prefetch_related('matches')
            .get(foursome=foursome)
        )
    except MatchPlayBracket.DoesNotExist:
        return None

    # Build score index
    hole_scores = (
        HoleScore.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .exclude(net_score=None)
        .values('player_id', 'hole_number', 'net_score')
    )
    score_index: dict = {}
    for hs in hole_scores:
        score_index.setdefault(hs['player_id'], {})[hs['hole_number']] = hs['net_score']

    # Delete existing hole results
    MatchPlayHoleResult.objects.filter(match__bracket=bracket).delete()

    matches = list(bracket.matches.select_related('player1', 'player2').order_by('round_number'))
    r1_matches = [m for m in matches if m.round_number == 1]
    r2_matches = [m for m in matches if m.round_number == 2]

    all_hole_results = []

    # ---- Round 1 ----
    for match in r1_matches:
        results = _play_match(match, score_index)
        all_hole_results.extend(results)
        match.save(update_fields=['status', 'result', 'finished_on_hole'])

    MatchPlayHoleResult.objects.bulk_create(all_hole_results)
    all_hole_results = []

    # ---- Set round-2 player assignments after round-1 is complete ----
    if bracket.bracket_type == 'single_elim':
        r1_complete = all(m.status == 'complete' for m in r1_matches)
        if r1_complete and len(r2_matches) == 2:
            # Semi 1 winner vs semi 2 winner in final
            s1_winner = (r1_matches[0].player1
                         if r1_matches[0].result == 'player1'
                         else r1_matches[0].player2)
            s2_winner = (r1_matches[1].player1
                         if r1_matches[1].result == 'player1'
                         else r1_matches[1].player2)
            s1_loser  = (r1_matches[0].player2
                         if r1_matches[0].result == 'player1'
                         else r1_matches[0].player1)
            s2_loser  = (r1_matches[1].player2
                         if r1_matches[1].result == 'player1'
                         else r1_matches[1].player1)

            final, consolation = r2_matches[0], r2_matches[1]
            final.player1 = s1_winner
            final.player2 = s2_winner
            final.save(update_fields=['player1', 'player2'])

            consolation.player1 = s1_loser
            consolation.player2 = s2_loser
            consolation.save(update_fields=['player1', 'player2'])

    elif bracket.bracket_type == 'three_player_points':
        r1_complete = all(m.status == 'complete' for m in r1_matches)
        if r1_complete and r2_matches:
            # Points: 2 for win, 1 for halve, 0 for loss
            points: dict = {}
            for m in r1_matches:
                if m.result == 'player1':
                    points[m.player1_id] = points.get(m.player1_id, 0) + 2
                elif m.result == 'player2':
                    points[m.player2_id] = points.get(m.player2_id, 0) + 2
                else:
                    points[m.player1_id] = points.get(m.player1_id, 0) + 1
                    points[m.player2_id] = points.get(m.player2_id, 0) + 1

            sorted_players = sorted(points.keys(), key=lambda pid: points[pid], reverse=True)
            if len(sorted_players) >= 2:
                from core.models import Player
                final = r2_matches[0]
                final.player1 = Player.objects.get(pk=sorted_players[0])
                final.player2 = Player.objects.get(pk=sorted_players[1])
                final.save(update_fields=['player1', 'player2'])

    # ---- Round 2 ----
    for match in r2_matches:
        results = _play_match(match, score_index)
        all_hole_results.extend(results)
        match.save(update_fields=['status', 'result', 'finished_on_hole'])

    MatchPlayHoleResult.objects.bulk_create(all_hole_results)

    # ---- Bracket status ----
    all_complete = all(m.status == 'complete' for m in matches)
    any_started  = any(m.status in ('in_progress', 'complete') for m in matches)

    if all_complete:
        bracket.status = 'complete'
        # Set overall bracket winner (final match winner)
        finals = [m for m in r2_matches if bracket.bracket_type == 'single_elim']
        if finals:
            final = finals[0]
            if final.result == 'player1':
                bracket.winner = final.player1
            elif final.result == 'player2':
                bracket.winner = final.player2
        bracket.save(update_fields=['status', 'winner'])
    elif any_started:
        bracket.status = 'in_progress'
        bracket.save(update_fields=['status'])

    return bracket


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def match_play_summary(foursome) -> dict | None:
    """
    Return a summary of the match play bracket:

    {
        'bracket_type' : 'single_elim' | 'three_player_points',
        'status'       : str,
        'winner'       : str | None,   # player name
        'matches'      : [
            {
                'round'         : int,
                'label'         : 'Semi 1' | 'Semi 2' | 'Final' | 'Consolation' | str,
                'player1'       : str,
                'player2'       : str,
                'status'        : str,
                'result'        : 'player1' | 'player2' | 'halved' | None,
                'winner_name'   : str | None,
                'holes'         : [{'hole': n, 'p1_net': x, 'p2_net': y,
                                    'winner': name|None, 'margin': n}],
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
                'matches__player1', 'matches__player2',
                'matches__hole_results__winner',
            )
            .get(foursome=foursome)
        )
    except MatchPlayBracket.DoesNotExist:
        return None

    matches = list(bracket.matches.order_by('round_number', 'id'))
    r1 = [m for m in matches if m.round_number == 1]
    r2 = [m for m in matches if m.round_number == 2]

    def _label(match, idx, total_r1, round_num):
        if round_num == 1:
            if total_r1 == 2:
                return f"Semi {idx + 1}"
            return f"Round-Robin Match {idx + 1}"
        else:
            if idx == 0:
                return "Final"
            return "Consolation"

    def _winner_name(match):
        if match.result == 'player1':
            return match.player1.name
        if match.result == 'player2':
            return match.player2.name
        if match.result == 'halved':
            return 'Halved'
        return None

    matches_out = []
    for i, m in enumerate(r1):
        holes_out = [
            {
                'hole'   : hr.hole_number,
                'p1_net' : hr.p1_net,
                'p2_net' : hr.p2_net,
                'winner' : hr.winner.name if hr.winner else 'Halved',
                'margin' : hr.holes_up_after,
            }
            for hr in m.hole_results.all()
        ]
        matches_out.append({
            'round'       : 1,
            'label'       : _label(m, i, len(r1), 1),
            'player1'     : m.player1.name,
            'player2'     : m.player2.name,
            'status'      : m.status,
            'result'      : m.result,
            'winner_name' : _winner_name(m),
            'holes'       : holes_out,
        })

    for i, m in enumerate(r2):
        holes_out = [
            {
                'hole'   : hr.hole_number,
                'p1_net' : hr.p1_net,
                'p2_net' : hr.p2_net,
                'winner' : hr.winner.name if hr.winner else 'Halved',
                'margin' : hr.holes_up_after,
            }
            for hr in m.hole_results.all()
        ]
        matches_out.append({
            'round'       : 2,
            'label'       : _label(m, i, len(r1), 2),
            'player1'     : m.player1.name,
            'player2'     : m.player2.name,
            'status'      : m.status,
            'result'      : m.result,
            'winner_name' : _winner_name(m),
            'holes'       : holes_out,
        })

    return {
        'bracket_type' : bracket.bracket_type,
        'status'       : bracket.status,
        'winner'       : bracket.winner.name if bracket.winner else None,
        'matches'      : matches_out,
    }
