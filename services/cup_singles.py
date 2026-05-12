"""
services/cup_singles.py
-----------------------
Cup Singles Match Play calculator.

Used in Ryder Cup / Bandon Cup when individual players from opposing teams
are paired 1-v-1 over a full 18-hole match.

Format
~~~~~~
* Each singles foursome has 2 or 4 real players (1 or 2 per team).
* Setup creates one MatchPlayMatch per pairing, bracket_type='cup_singles'.
* Each match runs holes 1-18 with normal dormie close (lead > remaining).
* Results expose F9 status (after hole 9), B9 status (holes 10-18),
  and overall result.
* Cup scoring (in ryder_cup.py): 1 point for winning overall, 0.5 for halve.

Public API
~~~~~~~~~~
    bracket = setup_cup_singles(foursome, team1, team2)
    bracket = calculate_cup_singles(foursome)
    summary = cup_singles_summary(foursome)
"""

from django.db import transaction

from games.models import MatchPlayBracket, MatchPlayMatch, MatchPlayHoleResult
from scoring.handicap import build_match_play_score_index
from tournament.models import FoursomeMembership


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_cup_singles(foursome, team1, team2, singles_matchups=None):
    """
    Create a MatchPlayBracket (bracket_type='cup_singles') with one match
    per cross-team pairing.

    If `singles_matchups` is provided (list of {'player1_id': int,
    'player2_id': int} dicts), those explicit pairs are used directly.

    Otherwise falls back to pairing by playing_handicap order within each team,
    and as a last resort pairs by alternating position in the foursome.

    Returns the new MatchPlayBracket.
    """
    from core.models import Player

    # Real players in this foursome
    all_memberships = list(
        FoursomeMembership.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .select_related('player')
        .order_by('id')
    )
    member_by_id = {m.player_id: m.player for m in all_memberships}

    # ── Explicit matchups supplied by the client ────────────────────────────
    if singles_matchups:
        pairs = []
        for mu in singles_matchups:
            p1_id = mu.get('player1_id')
            p2_id = mu.get('player2_id')
            p1 = member_by_id.get(p1_id)
            p2 = member_by_id.get(p2_id)
            if p1 and p2:
                pairs.append((p1, p2))
        if pairs:
            return _create_bracket(foursome, pairs)

    # ── Fall back: pair by team membership ──────────────────────────────────
    team1_ids = set(team1.players.values_list('id', flat=True)) if team1 else set()
    team2_ids = set(team2.players.values_list('id', flat=True)) if team2 else set()

    t1_members = sorted(
        [m for m in all_memberships if m.player_id in team1_ids],
        key=lambda m: m.course_handicap or 0,
    )
    t2_members = sorted(
        [m for m in all_memberships if m.player_id in team2_ids],
        key=lambda m: m.course_handicap or 0,
    )

    if t1_members and t2_members:
        # When teams are unequal (1v2 or 2v1), the solo player plays one match
        # against EACH opponent — do NOT use zip() which silently drops extras.
        pairs = []
        longer, shorter = (
            (t1_members, t2_members) if len(t1_members) >= len(t2_members)
            else (t2_members, t1_members)
        )
        for i, m_long in enumerate(longer):
            m_short = shorter[i % len(shorter)]
            # Preserve convention: team1 player is player1, team2 is player2
            if longer is t1_members:
                pairs.append((m_long.player, m_short.player))
            else:
                pairs.append((m_short.player, m_long.player))
        return _create_bracket(foursome, pairs)

    # ── Last resort: alternate positions (p0 vs p1, p2 vs p3, …) ────────────
    if len(all_memberships) >= 2:
        pairs = [
            (all_memberships[i].player, all_memberships[i + 1].player)
            for i in range(0, len(all_memberships) - 1, 2)
        ]
        return _create_bracket(foursome, pairs)

    raise ValueError(
        "Cup singles setup requires at least one real player from each team."
    )


def _create_bracket(foursome, pairs):
    """Create and return a cup_singles MatchPlayBracket for the given pairs.

    `pairs` is a list of (player1, player2) Player instances.
    """
    MatchPlayBracket.objects.filter(foursome=foursome).delete()

    bracket = MatchPlayBracket.objects.create(
        foursome      = foursome,
        bracket_type  = 'cup_singles',
        status        = 'pending',
        entry_fee     = 0,
        payout_config = {},
    )

    for p1, p2 in pairs:
        MatchPlayMatch.objects.create(
            bracket      = bracket,
            round_number = 1,
            start_hole   = 1,
            player1      = p1,
            player2      = p2,
            status       = 'pending',
        )

    return bracket


# ---------------------------------------------------------------------------
# Calculation
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_cup_singles(foursome):
    """
    Score all cup singles matches over 18 holes.

    Safe to call repeatedly — hole results are deleted and rebuilt from the
    current HoleScore data each time.

    Returns the updated MatchPlayBracket, or None if none exists.
    """
    try:
        bracket = (
            MatchPlayBracket.objects
            .select_for_update()
            .prefetch_related('matches')
            .get(foursome=foursome, bracket_type='cup_singles')
        )
    except MatchPlayBracket.DoesNotExist:
        return None

    # Rebuild all hole results from scratch
    MatchPlayHoleResult.objects.filter(match__bracket=bracket).delete()

    all_hole_results: list = []
    all_complete = True

    for match in bracket.matches.select_related('player1', 'player2').all():
        # Match-play handicap: lower of the two gets 0 strokes, higher gets
        # the differential.  Build a fresh score index per match because each
        # pairing may have a different differential.
        score_index = build_match_play_score_index(
            foursome, match.player1_id, match.player2_id
        )
        results = _play_18_hole_match(match, score_index)
        all_hole_results.extend(results)
        if match.status != 'complete':
            all_complete = False
        match.save(update_fields=['status', 'result', 'finished_on_hole'])

    MatchPlayHoleResult.objects.bulk_create(all_hole_results)

    bracket.status = 'complete' if all_complete else (
        'in_progress' if any(
            len([r for r in all_hole_results if r.match == m]) > 0
            for m in bracket.matches.all()
        ) else 'pending'
    )
    bracket.save(update_fields=['status'])

    return bracket


def _play_18_hole_match(match: MatchPlayMatch, score_index: dict) -> list:
    """
    Score a single 18-hole 1-v-1 match play match.

    Updates match.status, match.result, match.finished_on_hole in place.
    Returns a list of unsaved MatchPlayHoleResult objects (always up to 18
    entries as long as scores exist, even when the overall match closes early
    by dormie).

    IMPORTANT: we continue recording hole results after the overall match is
    decided by dormie so that Nassau sub-match calculations (_compute_sub_match
    for F9 / B9) have the full 18-hole dataset.  In practice golfers play out
    all remaining holes for the side bets even after the overall match is over.
    """
    p1 = match.player1
    p2 = match.player2
    p1_scores = score_index.get(p1.pk, {})
    p2_scores = score_index.get(p2.pk, {})

    holes_up        = 0      # positive = p1 leading
    results: list   = []
    match_decided   = False  # True once overall match result is locked in

    match.status          = 'in_progress'
    match.result          = None
    match.finished_on_hole = None

    for hole_num in range(1, 19):
        p1_net = p1_scores.get(hole_num)
        p2_net = p2_scores.get(hole_num)

        if p1_net is None or p2_net is None:
            break  # score not yet entered for this hole

        if p1_net < p2_net:
            winner = p1
            holes_up += 1
        elif p2_net < p1_net:
            winner = p2
            holes_up -= 1
        else:
            winner = None  # halved hole

        results.append(MatchPlayHoleResult(
            match          = match,
            hole_number    = hole_num,
            p1_net         = p1_net,
            p2_net         = p2_net,
            winner         = winner,
            holes_up_after = holes_up,
        ))

        # Dormie: overall match decided when lead > holes remaining.
        # Lock in the overall result but keep looping so all scored holes are
        # captured for Nassau sub-match (B9) accounting.
        remaining = 18 - hole_num
        if not match_decided and abs(holes_up) > remaining:
            match.result          = 'player1' if holes_up > 0 else 'player2'
            match.status          = 'complete'
            match.finished_on_hole = hole_num
            match_decided         = True

    # All 18 holes scored and match wasn't already decided by dormie
    if len(results) == 18 and not match_decided:
        if holes_up > 0:
            match.result = 'player1'
        elif holes_up < 0:
            match.result = 'player2'
        else:
            match.result = 'halved'
        match.status = 'complete'

    return results


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def _compute_sub_match(holes_data: list, start_hole: int, end_hole: int) -> dict:
    """
    Compute a Nassau sub-match result for holes [start_hole..end_hole].

    Each sub-match is tracked independently: the margin starts at 0 for the
    first hole of the range, and dormie is checked against holes remaining
    *within this range*.

    Returns a dict:
        status           – 'pending' | 'in_progress' | 'complete'
        result           – 'player1' | 'player2' | 'halved' | None
        holes_up         – int (positive = p1 ahead) | None when pending
        finished_on_hole – hole number where sub-match closed, or None
        holes_played     – count of scored holes in this range
    """
    total    = end_hole - start_hole + 1
    relevant = sorted(
        [h for h in holes_data if start_hole <= h['hole_number'] <= end_hole],
        key=lambda h: h['hole_number'],
    )

    if not relevant:
        return {
            'status': 'pending', 'result': None,
            'holes_up': None, 'finished_on_hole': None, 'holes_played': 0,
        }

    margin = 0
    for idx, h in enumerate(relevant):
        if h['p1_net'] < h['p2_net']:
            margin += 1
        elif h['p2_net'] < h['p1_net']:
            margin -= 1

        remaining = end_hole - h['hole_number']
        if abs(margin) > remaining:
            # Dormie — sub-match over
            return {
                'status'          : 'complete',
                'result'          : 'player1' if margin > 0 else 'player2',
                'holes_up'        : margin,
                'finished_on_hole': h['hole_number'],
                'holes_played'    : idx + 1,
            }

    holes_played = len(relevant)
    if holes_played < total:
        # Scores not yet entered for all holes in the range
        return {
            'status': 'in_progress', 'result': None,
            'holes_up': margin, 'finished_on_hole': None,
            'holes_played': holes_played,
        }

    # All holes played, no dormie close
    return {
        'status'          : 'complete',
        'result'          : ('player1' if margin > 0
                             else 'player2' if margin < 0
                             else 'halved'),
        'holes_up'        : margin,
        'finished_on_hole': end_hole,
        'holes_played'    : holes_played,
    }


def cup_singles_summary(foursome) -> dict | None:
    """
    Return a serialisable dict for the cup singles leaderboard / score entry.

    Shape:
    {
      "bracket_type": "cup_singles",
      "status": "in_progress",
      "matches": [
        {
          "match_id": 1,
          "player1": "Paul",   "player1_id": 123,
          "player2": "Rob",    "player2_id": 456,
          "status": "in_progress",
          "result": null,
          "f9_holes_up":       1,     # positive = player1 up after hole 9
          "b9_holes_up":       -1,    # positive = player1 up on holes 10-18
          "overall_holes_up":  0,
          "holes_played":      18,
          "finished_on_hole":  null,
          "holes": [
            {"hole_number": 1, "p1_net": 4, "p2_net": 5, "holes_up_after": 1},
            ...
          ]
        }
      ]
    }
    """
    try:
        bracket = (
            MatchPlayBracket.objects
            .prefetch_related(
                'matches__hole_results',
                'matches__player1',
                'matches__player2',
            )
            .get(foursome=foursome, bracket_type='cup_singles')
        )
    except MatchPlayBracket.DoesNotExist:
        return None

    matches_out = []
    for match in bracket.matches.order_by('id'):
        holes = list(
            match.hole_results
            .order_by('hole_number')
            .values('hole_number', 'p1_net', 'p2_net', 'holes_up_after')
        )

        # Compute each Nassau sub-match independently.
        f9  = _compute_sub_match(holes, 1,  9)
        b9  = _compute_sub_match(holes, 10, 18)
        all18 = _compute_sub_match(holes, 1, 18)

        matches_out.append({
            'match_id'   : match.id,
            'player1'    : match.player1.short_name,
            'player1_id' : match.player1_id,
            'player2'    : match.player2.short_name,
            'player2_id' : match.player2_id,

            # Overall 18-hole match (from backend match record)
            'status'          : match.status,
            'result'          : match.result,
            'overall_holes_up': all18['holes_up'] or 0,
            'finished_on_hole': match.finished_on_hole,
            'holes_played'    : len(holes),

            # F9 sub-match (holes 1-9)
            'f9_status'          : f9['status'],
            'f9_result'          : f9['result'],
            'f9_holes_up'        : f9['holes_up'],
            'f9_finished_on_hole': f9['finished_on_hole'],

            # B9 sub-match (holes 10-18)
            'b9_status'          : b9['status'],
            'b9_result'          : b9['result'],
            'b9_holes_up'        : b9['holes_up'],
            'b9_finished_on_hole': b9['finished_on_hole'],

            'holes': holes,
        })

    # Pull team colours from the cup config if available.
    # Default to Red/Blue (matching the cup-live endpoint) so the leaderboard
    # always has a colour to display even when the field is left blank.
    t1_colour = 'Red'
    t2_colour = 'Blue'
    try:
        cup_cfg   = foursome.ryder_cup_foursome_config
        t1_colour = (cup_cfg.team1.colour or 'Red')  if cup_cfg.team1 else 'Red'
        t2_colour = (cup_cfg.team2.colour or 'Blue') if cup_cfg.team2 else 'Blue'
    except Exception:
        pass

    return {
        'bracket_type'  : 'cup_singles',
        'status'        : bracket.status,
        'matches'       : matches_out,
        'team1_colour'  : t1_colour,
        'team2_colour'  : t2_colour,
    }
