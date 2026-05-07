"""
services/quota_nassau.py
------------------------
Quota Nassau calculator — two-player Stableford-vs-quota match, Nassau style.

Quota definition
~~~~~~~~~~~~~~~~
    quota = 36 − course_handicap_index

A player with a quota of 18 is expected to earn 18 Stableford points over
18 holes (one point per hole on average ≈ bogey golf when net par = 2 pts).
Being above quota is equivalent to being under par in match-play terms;
below quota = over par.

Stableford points per hole (from HoleScore.stableford_points)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Albatross or better (net ≥ +3)  →  5 pts
    Eagle               (net +2)     →  4 pts
    Birdie              (net +1)     →  3 pts
    Par                 (net  0)     →  2 pts
    Bogey               (net −1)     →  1 pt
    Double bogey+       (net ≤ −2)   →  0 pts

Nassau segments (no presses)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Front 9:  compare (p1_f9_pts − quota/2) vs (p2_f9_pts − quota/2)
    Back 9:   compare (p1_b9_pts − quota/2) vs (p2_b9_pts − quota/2)
    Overall:  compare (p1_18_pts − quota)   vs (p2_18_pts − quota)
    Higher score-vs-quota wins; equal = halved.

Live progress display
~~~~~~~~~~~~~~~~~~~~~
After hole H the running score-vs-quota for a player is:
    stableford_cumulative − (quota × H / 18)
This pro-rated value gives a "against par" reading on every hole so the UI
can show live progress as the group moves through the course.

Multiple matches per foursome
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A standard Ryder Cup foursome (2 players per team) produces 2 QuotaNassauMatch
rows per QuotaNassauGame.  setup_quota_nassau() accepts a list of pairings so
it works for any group size.

Public API
~~~~~~~~~~
    game    = setup_quota_nassau(foursome, pairings)
    game    = calculate_quota_nassau(foursome)
    summary = quota_nassau_summary(foursome)
"""

from decimal import Decimal

from django.db import transaction

from core.models import MatchStatus
from games.models import (
    QuotaNassauGame,
    QuotaNassauMatch,
    QuotaNassauHoleResult,
)
from scoring.models import HoleScore


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _resolve(margin: Decimal) -> str:
    """Convert a numeric margin to a result string (player1 = positive)."""
    if margin > 0:
        return 'player1'
    if margin < 0:
        return 'player2'
    return 'halved'


def _stableford_index(foursome) -> dict:
    """
    Build {player_id: {hole_number: gross_stableford_points}} for all real
    players in this foursome.

    Quota Nassau uses GROSS Stableford (no handicap adjustment):
        gross_stableford = max(0, 2 + par - gross_score)

    Par is read from each player's tee so mixed-tee foursomes are correct.
    """
    # Build per-player par lookup: {player_id: {hole_number: par}}
    par_index: dict = {}
    for mem in (
        foursome.memberships
        .filter(player__is_phantom=False)
        .select_related('tee', 'player')
    ):
        tee = mem.tee
        if tee is None:
            tee = foursome.round.course.tees.first()
        if tee is None:
            continue
        par_index[mem.player_id] = {
            h: tee.hole(h)['par']
            for h in range(1, 19)
        }

    result: dict = {}
    qs = (
        HoleScore.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    )
    for row in qs:
        pid  = row['player_id']
        hole = row['hole_number']
        par  = (par_index.get(pid) or {}).get(hole, 4)
        result.setdefault(pid, {})[hole] = max(0, 2 + par - row['gross_score'])
    return result


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_quota_nassau(foursome, pairings: list) -> QuotaNassauGame:
    """
    Create (or replace) the QuotaNassauGame and its QuotaNassauMatch rows.

    Parameters
    ----------
    foursome : Foursome
    pairings : list of dicts, each containing:
        {
            'player1_id'    : int,   # PK of Player
            'player2_id'    : int,
            'player1_quota' : int,   # 36 − player1's course handicap index
            'player2_quota' : int,
        }

    Typically 2 pairings for a standard 2v2 Ryder Cup foursome, but any
    number is accepted (1v1 single, 3 cross-matches in a scramble variant, …).

    Deleting the existing QuotaNassauGame cascades to all its matches and
    hole results, so this is safe to call repeatedly during setup.
    """
    QuotaNassauGame.objects.filter(foursome=foursome).delete()

    game = QuotaNassauGame.objects.create(
        foursome=foursome,
        status=MatchStatus.PENDING,
    )

    for p in pairings:
        QuotaNassauMatch.objects.create(
            game          =game,
            player1_id    =p['player1_id'],
            player2_id    =p['player2_id'],
            player1_quota =int(p['player1_quota']),
            player2_quota =int(p['player2_quota']),
            status        =MatchStatus.PENDING,
        )

    return game


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_quota_nassau(foursome) -> 'QuotaNassauGame | None':
    """
    Recompute all QuotaNassauHoleResult rows and segment results for every
    QuotaNassauMatch in this foursome.  Safe to call repeatedly — previous
    hole result rows are deleted and rebuilt on each call.

    Returns the updated QuotaNassauGame, or None if none exists.
    """
    try:
        game = QuotaNassauGame.objects.prefetch_related(
            'matches__player1', 'matches__player2'
        ).get(foursome=foursome)
    except QuotaNassauGame.DoesNotExist:
        return None

    pts_index = _stableford_index(foursome)
    any_complete   = False
    any_in_progress = False

    for match in game.matches.all():
        QuotaNassauHoleResult.objects.filter(match=match).delete()

        q1 = Decimal(match.player1_quota)
        q2 = Decimal(match.player2_quota)
        p1_pts = pts_index.get(match.player1_id, {})
        p2_pts = pts_index.get(match.player2_id, {})

        # ── Running accumulators ───────────────────────────────────────────
        p1_total = p2_total = Decimal(0)   # cumulative stableford
        p1_f9    = p2_f9    = Decimal(0)   # front-9 stableford
        p1_b9    = p2_b9    = Decimal(0)   # back-9 stableford

        # Running segment margins: (p1_vs_quota − p2_vs_quota)
        f9_margin = b9_margin = overall_margin = Decimal(0)

        hole_result_objs = []
        holes_played = 0

        for hole_num in range(1, 19):
            h1 = p1_pts.get(hole_num)
            h2 = p2_pts.get(hole_num)
            if h1 is None or h2 is None:
                break   # stop at first incomplete hole — no partial-hole results

            holes_played = hole_num
            h1, h2 = Decimal(h1), Decimal(h2)

            p1_total += h1
            p2_total += h2

            # Pro-rated quota through hole H:  quota × H / 18
            p1_vs_q_overall = p1_total - q1 * hole_num / 18
            p2_vs_q_overall = p2_total - q2 * hole_num / 18
            overall_margin  = p1_vs_q_overall - p2_vs_q_overall

            f9m = b9m = None

            if hole_num <= 9:
                p1_f9 += h1
                p2_f9 += h2
                # Pro-rated quota within front 9: quota × hole / 18
                # (so after hole 9, quota thru = quota × 9/18 = quota/2 ✓)
                p1_f9_vs_q = p1_f9 - q1 * hole_num / 18
                p2_f9_vs_q = p2_f9 - q2 * hole_num / 18
                f9_margin  = p1_f9_vs_q - p2_f9_vs_q
                f9m        = f9_margin
            else:
                back_hole = hole_num - 9           # 1-based within back 9
                p1_b9 += h1
                p2_b9 += h2
                # Pro-rated quota within back 9: same scale as front (quota × k/18)
                p1_b9_vs_q = p1_b9 - q1 * back_hole / 18
                p2_b9_vs_q = p2_b9 - q2 * back_hole / 18
                b9_margin  = p1_b9_vs_q - p2_b9_vs_q
                b9m        = b9_margin

            hole_result_objs.append(QuotaNassauHoleResult(
                match                = match,
                hole_number          = hole_num,
                p1_stableford        = int(h1),
                p2_stableford        = int(h2),
                p1_score_vs_quota    = p1_vs_q_overall,
                p2_score_vs_quota    = p2_vs_q_overall,
                front9_margin_after  = f9m,
                back9_margin_after   = b9m,
                overall_margin_after = overall_margin,
            ))

        QuotaNassauHoleResult.objects.bulk_create(hole_result_objs)

        # ── Resolve segment results ────────────────────────────────────────
        front_done   = holes_played >= 9
        back_done    = holes_played >= 18
        overall_done = back_done

        match.front9_result  = _resolve(f9_margin)    if front_done   else None
        match.back9_result   = _resolve(b9_margin)    if back_done    else None
        match.overall_result = _resolve(overall_margin) if overall_done else None

        if overall_done:
            match.status = MatchStatus.COMPLETE
            any_complete = True
        elif holes_played > 0:
            match.status = MatchStatus.IN_PROGRESS
            any_in_progress = True
        else:
            match.status = MatchStatus.PENDING

        match.save()

    # ── Roll up game status ────────────────────────────────────────────────
    if any_complete:
        game.status = MatchStatus.COMPLETE
    elif any_in_progress or pts_index:
        game.status = MatchStatus.IN_PROGRESS

    game.save()
    return game


# ---------------------------------------------------------------------------
# Summary (for UI and leaderboard)
# ---------------------------------------------------------------------------

def quota_nassau_summary(foursome) -> 'dict | None':
    """
    Return a serialisable summary dict for the UI and Ryder Cup leaderboard.

    Shape
    -----
    {
        'status': 'pending' | 'in_progress' | 'complete',
        'matches': [
            {
                'player1': {
                    'player_id' : int,
                    'name'      : str,
                    'short_name': str,
                    'quota'     : int,        # 36 − course_handicap_index
                },
                'player2': { ... },           # same shape
                'front9': {
                    'result': str | None,     # 'player1'|'player2'|'halved'|null
                    'margin': float,          # +ve = player1 ahead in quota pts
                },
                'back9':   { 'result': ..., 'margin': ... },
                'overall': { 'result': ..., 'margin': ... },
                'holes': [
                    {
                        'hole'          : int,
                        'p1_stableford' : int,   # points earned this hole
                        'p2_stableford' : int,
                        'p1_vs_quota'   : float, # running score-vs-quota
                        'p2_vs_quota'   : float,
                        'front9_margin' : float | null,
                        'back9_margin'  : float | null,
                        'overall_margin': float,
                    },
                    ...   # one entry per hole scored so far
                ],
            },
            ...   # one entry per match in this foursome
        ],
    }

    Note on "score-vs-quota" display
    ---------------------------------
    Positive p_vs_quota means the player is above quota (under par equivalent).
    Negative means below quota (over par equivalent).
    The UI can show this as "+2.1" or "−1.3" relative to quota-par.
    """
    try:
        game = QuotaNassauGame.objects.prefetch_related(
            'matches__player1', 'matches__player2'
        ).get(foursome=foursome)
    except QuotaNassauGame.DoesNotExist:
        return None

    matches_out = []

    for match in game.matches.all():
        holes_qs = list(
            QuotaNassauHoleResult.objects
            .filter(match=match)
            .order_by('hole_number')
        )

        # Most recent non-null margins for each segment
        last_f9  = next(
            (h for h in reversed(holes_qs) if h.front9_margin_after  is not None), None
        )
        last_b9  = next(
            (h for h in reversed(holes_qs) if h.back9_margin_after   is not None), None
        )
        last_all = holes_qs[-1] if holes_qs else None

        matches_out.append({
            'player1': {
                'player_id' : match.player1_id,
                'name'      : match.player1.name,
                'short_name': match.player1.short_name,
                'quota'     : match.player1_quota,
            },
            'player2': {
                'player_id' : match.player2_id,
                'name'      : match.player2.name,
                'short_name': match.player2.short_name,
                'quota'     : match.player2_quota,
            },
            'front9': {
                'result': match.front9_result,
                'margin': float(last_f9.front9_margin_after)   if last_f9  else 0.0,
            },
            'back9': {
                'result': match.back9_result,
                'margin': float(last_b9.back9_margin_after)    if last_b9  else 0.0,
            },
            'overall': {
                'result': match.overall_result,
                'margin': float(last_all.overall_margin_after) if last_all else 0.0,
            },
            'holes': [
                {
                    'hole'          : h.hole_number,
                    'p1_stableford' : h.p1_stableford,
                    'p2_stableford' : h.p2_stableford,
                    'p1_vs_quota'   : float(h.p1_score_vs_quota)    if h.p1_score_vs_quota    is not None else None,
                    'p2_vs_quota'   : float(h.p2_score_vs_quota)    if h.p2_score_vs_quota    is not None else None,
                    'front9_margin' : float(h.front9_margin_after)  if h.front9_margin_after  is not None else None,
                    'back9_margin'  : float(h.back9_margin_after)   if h.back9_margin_after   is not None else None,
                    'overall_margin': float(h.overall_margin_after) if h.overall_margin_after is not None else None,
                }
                for h in holes_qs
            ],
        })

    return {
        'status' : game.status,
        'matches': matches_out,
    }
