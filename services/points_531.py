"""
services/points_531.py
----------------------
Points 5-3-1 calculator — a three-player, per-hole points game played
over 18 holes in a single foursome.  Designed for casual rounds where
the foursome has exactly three real players; phantom players (if any)
are excluded entirely, which matches the game's origin as "a casual
game you play when you're a three-some".

Scoring rules
~~~~~~~~~~~~~
* On each hole, the three real players are ranked by their score-to-
  compare (net, gross, or strokes-off-adjusted depending on the match's
  handicap_mode).  Lowest wins.
* Baseline points are 5 / 3 / 1 for 1st / 2nd / 3rd.  Ties split points
  evenly across tied positions, so every hole pays exactly 9 points:
      - clear 1/2/3 → 5, 3, 1
      - 2-way tie for 1st (+ 3rd clear) → 4, 4, 1
      - 2-way tie for 2nd (1st clear) → 5, 2, 2
      - 3-way tie → 3, 3, 3
* A hole is only scored once all three real players have submitted a
  gross score for it; holes with a missing score are skipped on this
  pass and the game's status stays 'in_progress'.

Settlement
~~~~~~~~~~
* Per-hole "par" is 3 points (9 total / 3 players).  For a player who
  has played N holes, their money delta is:

        money = (their_points − 3 × N) × bet_unit

  A 55-point player over a full 18 holes wins 1 × bet_unit; the three
  players' money always sums to zero because every scored hole awards
  exactly 9 points total.

Handicap modes
~~~~~~~~~~~~~~
* Net (with net_percent) and Gross reuse scoring.handicap.build_score_index
  directly — same behavior as Sixes.
* Strokes-Off-Low uses a simple course-wide rule (not Sixes-style
  segment spreading): the lowest playing handicap in the foursome
  plays to 0, and every other player gets one stroke per hole whose
  stroke_index ≤ their SO count, capped via cycling if SO > 18 (which
  practically never happens).  This mirrors the "extras" rule in the
  Sixes calculator and is the natural fit for a non-segmented game.

Workflow
~~~~~~~~
1. ``setup_points_531(foursome, handicap_mode, net_percent)`` creates
   the Points531Game row.  Safe to call repeatedly — existing game data
   is replaced and any stale hole results are removed.
2. ``calculate_points_531(foursome)`` is called after every score
   submission by api.views._run_active_game_calculators.  It replaces
   all Points531PlayerHoleResult rows for this game based on the current
   HoleScore table and updates the game's status.
3. ``points_531_summary(foursome)`` returns the JSON shape consumed by
   the mobile UI.

Decimal note
~~~~~~~~~~~~
Points are stored as Decimal(4,2) on Points531PlayerHoleResult and
produced as plain floats from the summary (wrapped in json-safe types).
Using a step of 0.5 would also work, but Decimal lets us emit the
on-disk values unchanged and keeps the summary API shape simple.
"""

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import Points531Game, Points531PlayerHoleResult
from scoring.handicap import build_score_index
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_points_531(
    foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
) -> 'Points531Game':
    """
    Create (or replace) the Points 5-3-1 game for a foursome.

    Phantom presence is tolerated — the calculator simply ignores
    phantom players — but the casual-round UI should only offer this
    game when the foursome has exactly three real players.  We don't
    enforce the 3-real rule here so tests and admin scripts can still
    create the row; calculate_points_531 will just score whichever
    real players are present (2, 3, or 4) using the same tie-split
    logic, though the money math only guarantees zero-sum with 3.

    Clamp net_percent to the validated range so a bad caller can't
    poison the DB.
    """
    # Drop any prior state — this mirrors setup_sixes's "safe to call
    # again" contract so re-setup from the UI is idempotent.
    Points531Game.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))

    game = Points531Game.objects.create(
        foursome      = foursome,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        status        = MatchStatus.PENDING,
    )
    return game


# ---------------------------------------------------------------------------
# Strokes-Off support (course-wide SI threshold — simpler than Sixes)
# ---------------------------------------------------------------------------

def _build_so_score_index(foursome, net_percent: int = 100) -> dict:
    """
    Return a gross-based score_index with strokes-off adjustments baked
    in for every real player.

    The rule: the lowest playing handicap in the foursome plays to 0.
    Every other player has SO = own_phcp − low.  Each of those players
    receives one stroke on every hole whose stroke_index is ≤ SO.  If
    a player's SO exceeds 18 the remaining strokes wrap to all holes
    a second time (extremely uncommon; included for completeness).

    This function builds on top of build_score_index(gross) so no logic
    in scoring/handicap.py needs to change.
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
        so = round(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
        if so <= 0:
            continue

        per_player = score_index.get(m.player_id)
        if not per_player:
            continue

        # One stroke on holes with SI ≤ (so mod 18), plus one extra
        # stroke on every hole once for each full lap of 18 in `so`.
        # Practically, full_laps is virtually always 0.
        full_laps = so // 18
        remainder = so % 18

        for hole_num, score in list(per_player.items()):
            si = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = full_laps + (1 if si <= remainder else 0)
            if strokes:
                per_player[hole_num] = score - strokes

    return score_index


# ---------------------------------------------------------------------------
# Per-hole points allocator (tie-splitting)
# ---------------------------------------------------------------------------

_BASELINE_POINTS: tuple = (5, 3, 1)


def _allocate_hole_points(ranked_ids: list, scores_by_id: dict) -> dict:
    """
    Given a list of real player ids in any order and the net-score for
    each one on a single hole, return {player_id: Decimal(points)}.

    Algorithm
    ---------
    * Sort the ids by their score ascending (lowest is best).
    * Walk the sorted list grouping consecutive equal-score runs;
      each group gets the average of the baseline point values at
      the positions it spans.
    * Positions past the 3rd (only possible if called with more than
      3 players — we tolerate that for testing flexibility) contribute
      a baseline of 0 points.

    Returns a dict covering every player_id passed in, so callers can
    persist a row per (game, player, hole) without missing anyone.
    """
    if not ranked_ids:
        return {}

    # Stable secondary sort on player_id so ties give deterministic ordering.
    order = sorted(ranked_ids, key=lambda pid: (scores_by_id[pid], pid))

    out: dict = {}
    pos = 0  # 0-based position
    n   = len(order)

    while pos < n:
        score = scores_by_id[order[pos]]
        end   = pos + 1
        while end < n and scores_by_id[order[end]] == score:
            end += 1

        # Baseline points for positions [pos, end) — positions ≥ 3 are 0.
        span_points = [
            _BASELINE_POINTS[i] if i < len(_BASELINE_POINTS) else 0
            for i in range(pos, end)
        ]
        group_total = sum(span_points)
        group_size  = end - pos
        # Use Decimal + explicit quantize-ish behavior via division —
        # Decimal('9')/Decimal('3') = Decimal('3'), Decimal('8')/Decimal('2')
        # = Decimal('4'), Decimal('4')/Decimal('2') = Decimal('2').
        share = Decimal(group_total) / Decimal(group_size)
        for i in range(pos, end):
            out[order[i]] = share

        pos = end

    return out


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_points_531(foursome) -> list:
    """
    Re-compute Points531PlayerHoleResult for the foursome's game.

    * Reads all HoleScore rows through the appropriate score index
      (net / gross / strokes-off).
    * For each hole where *every* real player has a score, awards 5/3/1
      with tie-splitting so each hole pays exactly 9 points total.
    * Bulk-replaces the existing Points531PlayerHoleResult rows for the
      game in a single atomic transaction.
    * Updates the game's status — 'pending' if no holes scored yet,
      'in_progress' if some holes scored but the round isn't complete,
      'complete' once every hole 1..18 is fully scored.

    Returns the list of newly-saved Points531PlayerHoleResult instances.
    """
    try:
        game = foursome.points_531_game
    except Points531Game.DoesNotExist:
        return []

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    real_ids = [m.player_id for m in real_members]
    if not real_ids:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        Points531PlayerHoleResult.objects.filter(game=game).delete()
        return []

    # Pick the score index that matches the game's handicap policy.
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        score_index = _build_so_score_index(foursome, net_percent=game.net_percent)
    else:
        score_index = build_score_index(
            foursome,
            handicap_mode=game.handicap_mode,
            net_percent=game.net_percent,
        )

    # Wipe prior hole results first; we re-create them from scratch
    # every call so the idempotency contract matches Sixes.
    Points531PlayerHoleResult.objects.filter(game=game).delete()

    rows = []
    fully_scored_holes = 0
    for hole_num in range(1, 19):
        scores_by_id: dict = {}
        for pid in real_ids:
            s = score_index.get(pid, {}).get(hole_num)
            if s is None:
                break
            scores_by_id[pid] = s
        if len(scores_by_id) != len(real_ids):
            continue  # at least one real player missing — skip this hole

        fully_scored_holes += 1
        points_map = _allocate_hole_points(real_ids, scores_by_id)
        for pid, pts in points_map.items():
            rows.append(Points531PlayerHoleResult(
                game           = game,
                player_id      = pid,
                hole_number    = hole_num,
                net_score      = scores_by_id[pid],
                points_awarded = pts,
            ))

    if rows:
        Points531PlayerHoleResult.objects.bulk_create(rows)

    # Status: pending until first hole, in_progress once some are scored,
    # complete when all 18 are fully scored across every real player.
    if fully_scored_holes == 0:
        game.status = MatchStatus.PENDING
    elif fully_scored_holes >= 18:
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])

    return rows


# ---------------------------------------------------------------------------
# Summary (for the leaderboard / game screen)
# ---------------------------------------------------------------------------

def points_531_summary(foursome) -> dict:
    """
    JSON-serialisable summary of a Points 5-3-1 game.

    Shape:
        {
            'status'   : 'pending' | 'in_progress' | 'complete',
            'handicap' : {'mode': str, 'net_percent': int},
            'players'  : [
                {'player_id': int, 'name': str, 'short_name': str,
                 'points': float, 'holes_played': int,
                 'money': float},
                ...
            ],
            'holes'    : [
                {'hole': int,
                 'entries': [
                    {'player_id': int, 'short_name': str,
                     'net_score': int, 'points': float},
                    ...
                 ]},
                ...
            ],
            'money'    : {'bet_unit': float, 'par_per_hole': 3},
        }
    """
    try:
        game = foursome.points_531_game
    except Points531Game.DoesNotExist:
        return {
            'status'  : 'pending',
            'handicap': {'mode': HandicapMode.NET, 'net_percent': 100},
            'players' : [],
            'holes'   : [],
            'money'   : {'bet_unit': float(foursome.round.bet_unit),
                         'par_per_hole': 3},
        }

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    by_pid = {m.player_id: m.player for m in real_members}

    # Pull all hole results, grouped by hole for the grid and by player
    # for the leaderboard totals.  One query + in-Python group keeps
    # life simple; per-game row counts are tiny (≤ 54 per game).
    results = list(
        Points531PlayerHoleResult.objects
        .filter(game=game)
        .select_related('player')
        .order_by('hole_number', 'player_id')
    )

    # Hole-by-hole grid
    holes_out: list = []
    by_hole: dict = {}
    for r in results:
        by_hole.setdefault(r.hole_number, []).append(r)
    for hole_num in sorted(by_hole):
        entries = [
            {
                'player_id' : r.player_id,
                'name'      : r.player.name,
                'short_name': r.player.short_name,
                'net_score' : r.net_score,
                'points'    : float(r.points_awarded),
            }
            for r in by_hole[hole_num]
        ]
        # Sort entries on the hole by points desc (winner first), then
        # by short_name for stable display.
        entries.sort(key=lambda e: (-e['points'], e['short_name']))
        holes_out.append({
            'hole'    : hole_num,
            'entries' : entries,
        })

    # Player totals
    bet_unit = float(foursome.round.bet_unit)
    par_per_hole = 3  # points baseline per player per hole (9 / 3)
    holes_played_by_pid: dict = {}
    points_by_pid: dict = {}
    for r in results:
        holes_played_by_pid[r.player_id] = holes_played_by_pid.get(r.player_id, 0) + 1
        points_by_pid[r.player_id] = (
            points_by_pid.get(r.player_id, Decimal('0')) + r.points_awarded
        )

    players_out: list = []
    for pid, player in by_pid.items():
        pts = float(points_by_pid.get(pid, Decimal('0')))
        hp  = holes_played_by_pid.get(pid, 0)
        money = (pts - par_per_hole * hp) * bet_unit
        players_out.append({
            'player_id'   : pid,
            'name'        : player.name,
            'short_name'  : player.short_name,
            'points'      : pts,
            'holes_played': hp,
            'money'       : money,
        })
    # Leaderboard: money desc, then name for stable ordering.
    players_out.sort(key=lambda e: (-e['money'], e['name']))

    return {
        'status'  : game.status,
        'handicap': {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'players' : players_out,
        'holes'   : holes_out,
        'money'   : {
            'bet_unit'    : bet_unit,
            'par_per_hole': par_per_hole,
        },
    }
