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
from scoring.handicap import build_match_play_score_index, _strokes_on_hole
from tournament.models import FoursomeMembership


def match_play_hole_detail(foursome, p1_id, p2_id) -> dict:
    """Per-hole par / stroke-index / handicap-strokes for a 1-v-1 pairing.

    Returns ``{hole_number: {'par', 'stroke_index', 'p1_strokes',
    'p2_strokes'}}`` for holes 1-18.  The strokes are the standard match-play
    allocation — the lower-handicap player gets 0, the higher gets the
    differential allocated by stroke index — so a leaderboard/scorecard can draw
    the stroke dots without re-deriving the allowance.  Par / stroke_index come
    from player 1's tee (falling back to player 2's).
    """
    mem = {
        m.player_id: m
        for m in foursome.memberships
        .select_related('player', 'tee')
        .filter(player_id__in=[p1_id, p2_id], player__is_phantom=False)
    }
    m1, m2 = mem.get(p1_id), mem.get(p2_id)
    if not m1 or not m2:
        return {}
    hcp1 = m1.playing_handicap or 0
    hcp2 = m2.playing_handicap or 0
    so1 = max(0, hcp1 - hcp2)   # strokes player 1 receives
    so2 = max(0, hcp2 - hcp1)   # strokes player 2 receives
    disp_tee = m1.tee or m2.tee
    out = {}
    for h in range(1, 19):
        p1_si = m1.tee.hole(h).get('stroke_index', 18) if m1.tee_id else 18
        p2_si = m2.tee.hole(h).get('stroke_index', 18) if m2.tee_id else 18
        hd = disp_tee.hole(h) if disp_tee else {}
        out[h] = {
            'par'         : hd.get('par'),
            'stroke_index': hd.get('stroke_index'),
            'p1_strokes'  : _strokes_on_hole(so1, p1_si) if so1 > 0 else 0,
            'p2_strokes'  : _strokes_on_hole(so2, p2_si) if so2 > 0 else 0,
        }
    return out


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

    # The group's play order — a cup day is very often a shotgun, and every
    # match in this bracket is played by this foursome, so one lookup serves
    # them all.
    from services.hole_plan import play_order
    play_order_ = play_order(foursome.round, foursome) or list(range(1, 19))

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
        results = _play_18_hole_match(match, score_index, order=play_order_)
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


def _play_18_hole_match(match: MatchPlayMatch, score_index: dict,
                        order: list | None = None) -> list:
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

    **`order` is the group's PLAY order, and on a shotgun it is the whole
    correctness of this function.** It used to walk 1..18 and stop at the first
    unscored hole — so a group starting on 13 with six holes in stopped at the
    1st, reported a match that had not started, and then as holes 1..5 came in
    scored THOSE while ignoring the six already played. A cup day is very often
    a shotgun, which is where this matters most.

    The nines are still nines by NUMBER — a front-nine bet is holes 1–9
    whenever they get played — so only the walk and the dormie count move.
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

    walk = order or list(range(1, 19))
    for pos, hole_num in enumerate(walk):
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
        # Holes left in the group's own order, not 18 minus the number.
        remaining = len(walk) - 1 - pos
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

def _compute_sub_match(holes_data: list, start_hole: int, end_hole: int,
                       order: list | None = None) -> dict:
    """
    Compute a Nassau sub-match result for holes [start_hole..end_hole].

    Each sub-match is tracked independently: the margin starts at 0 for the
    first hole of the range, and dormie is checked against holes remaining
    *within this range*.

    **`order` is the group's play order, and the range is walked in it.**
    Dormie counted `end_hole - hole_number`, which is holes remaining only
    when the range is played in numbering order. On a shotgun from 13 the
    OVERALL range 1..18 starts at the 13th, so after six straight wins this
    returned "4 up, complete, finished on 16" — 18 minus 16 is two, while
    fourteen holes were still to come. The card would have shown a cup point
    decided that was not.

    The FRONT NINE is unaffected on that example (1..9 are played in numbering
    order however late they start), but the BACK NINE is not: 13..18 come
    first and 10..12 come last, so its remaining count needs the same
    treatment. Which is why this takes the order rather than special-casing
    the overall.

    Returns a dict:
        status           – 'pending' | 'in_progress' | 'complete'
        result           – 'player1' | 'player2' | 'halved' | None
        holes_up         – int (positive = p1 ahead) | None when pending
        finished_on_hole – hole number where sub-match closed, or None
        holes_played     – count of scored holes in this range
        holes_to_play    – holes of this range still left when it closed
                           (the `&M` in "3&2"), or None while undecided.
                           Counted along the play order, which is why the
                           caller cannot do it with `end_hole - finished`:
                           a back nine begun on the 13th closes on hole 12.
    """
    walk = [h for h in (order or list(range(1, 19)))
            if start_hole <= h <= end_hole]
    pos_of = {h: i for i, h in enumerate(walk)}
    total    = len(walk)
    relevant = sorted(
        [h for h in holes_data if h['hole_number'] in pos_of],
        key=lambda h: pos_of[h['hole_number']],
    )

    if not relevant:
        return {
            'status': 'pending', 'result': None,
            'holes_up': None, 'finished_on_hole': None, 'holes_played': 0,
            'holes_to_play': None,
        }

    margin = 0
    for idx, h in enumerate(relevant):
        if h['p1_net'] < h['p2_net']:
            margin += 1
        elif h['p2_net'] < h['p1_net']:
            margin -= 1

        remaining = total - 1 - pos_of[h['hole_number']]
        if abs(margin) > remaining:
            # Dormie — sub-match over
            return {
                'status'          : 'complete',
                'result'          : 'player1' if margin > 0 else 'player2',
                'holes_up'        : margin,
                'finished_on_hole': h['hole_number'],
                'holes_played'    : idx + 1,
                'holes_to_play'   : remaining,
            }

    holes_played = len(relevant)
    if holes_played < total:
        # Scores not yet entered for all holes in the range
        return {
            'status': 'in_progress', 'result': None,
            'holes_up': margin, 'finished_on_hole': None,
            'holes_played': holes_played, 'holes_to_play': None,
        }

    # All holes played, no dormie close
    return {
        'status'          : 'complete',
        'result'          : ('player1' if margin > 0
                             else 'player2' if margin < 0
                             else 'halved'),
        'holes_up'        : margin,
        # The last hole of the range IN PLAY ORDER — hole 12 closes a back
        # nine that began on the 13th, not hole 18.
        'finished_on_hole': walk[-1] if walk else end_hole,
        'holes_played'    : holes_played,
        # Went the distance, so nothing was left — "1 up", never "1&0".
        'holes_to_play'   : 0,
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

    # The group's play order — every sub-match range is walked in it, because
    # "holes remaining" is a play-order question even when the range itself is
    # defined by hole number.
    from services.hole_plan import play_order
    play_order_ = play_order(foursome.round, foursome) or list(range(1, 19))

    matches_out = []
    for match in bracket.matches.order_by('id'):
        holes = list(
            match.hole_results
            .order_by('hole_number')
            .values('hole_number', 'p1_net', 'p2_net', 'holes_up_after')
        )
        # Enrich each hole with par / stroke-index / per-player strokes so the
        # scorecard + leaderboard can draw the stroke dots.
        detail = match_play_hole_detail(
            foursome, match.player1_id, match.player2_id)
        for h in holes:
            d = detail.get(h['hole_number'], {})
            h['par']          = d.get('par')
            h['stroke_index'] = d.get('stroke_index')
            h['p1_strokes']   = d.get('p1_strokes', 0)
            h['p2_strokes']   = d.get('p2_strokes', 0)
        # Total strokes each player is issued over the match (the match-play
        # differential) — shown in parentheses beside the player abbreviation.
        p1_strokes_total = sum(d.get('p1_strokes', 0) for d in detail.values())
        p2_strokes_total = sum(d.get('p2_strokes', 0) for d in detail.values())
        # Full prospective hole plan (every hole, played or not) so the
        # leaderboard strip can show the whole stroke pattern up front, not just
        # holes already entered.  Net fills in per hole as scores are posted.
        net_by_hole = {h['hole_number']: h for h in holes}
        hole_plan = [
            {
                'hole_number' : hn,
                'par'         : detail[hn].get('par'),
                'stroke_index': detail[hn].get('stroke_index'),
                'p1_strokes'  : detail[hn].get('p1_strokes', 0),
                'p2_strokes'  : detail[hn].get('p2_strokes', 0),
                'p1_net'      : net_by_hole.get(hn, {}).get('p1_net'),
                'p2_net'      : net_by_hole.get(hn, {}).get('p2_net'),
            }
            for hn in sorted(detail.keys())
        ]

        # Compute each Nassau sub-match independently.
        f9  = _compute_sub_match(holes, 1,  9,  order=play_order_)
        b9  = _compute_sub_match(holes, 10, 18, order=play_order_)
        all18 = _compute_sub_match(holes, 1, 18, order=play_order_)

        matches_out.append({
            'match_id'      : match.id,
            'player1'         : match.player1.short_name,
            'player1_full'    : match.player1.name,
            'player1_id'      : match.player1_id,
            'player1_strokes' : p1_strokes_total,
            'player2'         : match.player2.short_name,
            'player2_full'    : match.player2.name,
            'player2_id'      : match.player2_id,
            'player2_strokes' : p2_strokes_total,

            # Overall 18-hole match (from backend match record)
            'status'          : match.status,
            'result'          : match.result,
            'overall_holes_up': all18['holes_up'] or 0,
            'finished_on_hole': match.finished_on_hole,
            # Holes left when it closed out — the `&M` in "3&2". Computed
            # HERE because only the server knows the group's play order; a
            # client doing `18 - finished_on_hole` is right on a round from
            # the 1st and wrong on every shotgun.
            'holes_to_play'   : (
                len(play_order_) - 1 - play_order_.index(match.finished_on_hole)
                if match.finished_on_hole in play_order_ else None),
            'holes_played'    : len(holes),

            # F9 sub-match (holes 1-9)
            'f9_status'          : f9['status'],
            'f9_result'          : f9['result'],
            'f9_holes_up'        : f9['holes_up'],
            'f9_finished_on_hole': f9['finished_on_hole'],
            # Holes of the NINE left at close-out. `9 - finished_on_hole` and
            # `18 - finished_on_hole` are both wrong on a shotgun: a back nine
            # begun on the 13th runs 13..18,10,11,12, so a match clinched on
            # hole 11 has ONE hole left, not seven.
            'f9_holes_to_play'   : f9['holes_to_play'],

            # B9 sub-match (holes 10-18)
            'b9_status'          : b9['status'],
            'b9_result'          : b9['result'],
            'b9_holes_up'        : b9['holes_up'],
            'b9_finished_on_hole': b9['finished_on_hole'],
            'b9_holes_to_play'   : b9['holes_to_play'],

            'holes': holes,
            'hole_plan': hole_plan,
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
