"""
services/skins.py
-----------------
Skins calculator — played within a single foursome by 2–4 real players
(phantom players are excluded).

Scoring rules
~~~~~~~~~~~~~
* Each hole is worth 1 skin.  The player with the BEST score-to-compare
  on a hole wins it outright.
* If two or more players tie for the best score:
    - carryover=True  → the skin carries to the next hole, accumulating
                         until one player wins outright.
    - carryover=False → the skin is killed (voided for that hole).
* Skins still in the pot after hole 18 (tied carry with no winner) are
  voided — the settlement denominator simply reflects skins actually won.

Handicap modes
~~~~~~~~~~~~~~
* Net (with net_percent) and Gross reuse scoring.handicap.build_score_index
  directly — same behavior as Points 5-3-1 and Sixes.
* Strokes-Off-Low uses the same course-wide SI helper as Points 5-3-1:
  the lowest playing handicap in the foursome plays to 0 and every
  other player gets (own HCP − low HCP) strokes allocated by hole SI.

Junk skins
~~~~~~~~~~
When allow_junk=True the UI lets scorers record extra junk skins
(birdies, sandies, chip-ins, etc.) per player per hole as a count.
Junk skins are stored in SkinsPlayerHoleResult and included in the
pool split alongside the regular per-hole skins.

Settlement
~~~~~~~~~~
Pool = number_of_real_players × Round.bet_unit.
payout_i = (skins_i / total_skins_won) × pool
where skins_i = regular_skins_i + junk_skins_i.
Players with zero skins receive nothing; the pool is always fully
distributed (sum of payouts = pool when total_skins > 0).

Workflow
~~~~~~~~
1. setup_skins(foursome, ...)  — creates the SkinsGame row.  Safe to
   call repeatedly (deletes and re-creates).
2. calculate_skins(foursome)   — called after every score submission by
   api.views._recalculate_games.  Replaces all SkinsHoleResult rows.
3. skins_summary(foursome)     — returns the JSON shape consumed by the
   mobile UI and the leaderboard.
"""

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import SkinsGame, SkinsHoleResult, SkinsPlayerHoleResult
from scoring.handicap import build_score_index


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_skins(
    foursome,
    handicap_mode: str  = HandicapMode.NET,
    net_percent:   int  = 100,
    carryover:     bool = True,
    allow_junk:    bool = False,
) -> 'SkinsGame':
    """
    Create (or replace) the Skins game for a foursome.

    Deleting the old SkinsGame cascades to all SkinsHoleResult and
    SkinsPlayerHoleResult rows, so the game starts fresh each time.
    net_percent is clamped to [0, 200].
    """
    SkinsGame.objects.filter(foursome=foursome).delete()
    net_percent = max(0, min(200, int(net_percent)))

    game = SkinsGame.objects.create(
        foursome      = foursome,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        carryover     = carryover,
        allow_junk    = allow_junk,
        status        = MatchStatus.PENDING,
    )
    return game


# ---------------------------------------------------------------------------
# Strokes-Off support (course-wide SI threshold — mirrors points_531.py)
# ---------------------------------------------------------------------------

def _build_so_score_index(foursome) -> dict:
    """
    Return a gross-based score index with Strokes-Off adjustments baked in.

    The lowest playing handicap in the foursome plays to 0.  Every other
    player has SO = own_phcp − low.  Each of those players receives one
    stroke on every hole whose stroke_index ≤ SO.  If SO > 18 the
    remaining strokes wrap (full laps × all holes + partial lap by SI).
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
        so = max(0, (m.playing_handicap or 0) - low)
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


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_skins(foursome) -> list:
    """
    Re-compute SkinsHoleResult rows for the foursome's game.

    * Reads all HoleScore rows through the appropriate score index
      (net / gross / strokes-off).
    * For each hole where *every* real player has a score:
        - One clear winner → award the accumulated pot.
        - Tie + carryover  → skin carries, pot grows.
        - Tie + no carryover → skin is killed, pot resets.
    * Bulk-replaces existing SkinsHoleResult rows atomically.
    * Updates the game's status field.

    Returns the list of newly-saved SkinsHoleResult instances.
    """
    try:
        game = foursome.skins_game
    except SkinsGame.DoesNotExist:
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
        SkinsHoleResult.objects.filter(game=game).delete()
        return []

    # Build the appropriate score index.
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        score_index = _build_so_score_index(foursome)
    else:
        score_index = build_score_index(
            foursome,
            handicap_mode = game.handicap_mode,
            net_percent   = game.net_percent,
        )

    # Wipe prior hole results — re-created from scratch each call.
    SkinsHoleResult.objects.filter(game=game).delete()

    rows          = []
    pot           = 0   # skins accumulated in the current carry run
    fully_scored  = 0   # holes where all real players have a score

    for hole_num in range(1, 19):
        # All real players must have a score for this hole to be counted.
        scores_by_id: dict = {}
        for pid in real_ids:
            s = score_index.get(pid, {}).get(hole_num)
            if s is None:
                break
            scores_by_id[pid] = s
        if len(scores_by_id) != len(real_ids):
            continue  # at least one player missing — skip

        fully_scored += 1
        pot += 1  # this hole adds 1 to the pot

        min_score = min(scores_by_id.values())
        leaders   = [pid for pid, s in scores_by_id.items() if s == min_score]

        if len(leaders) == 1:
            # Outright winner — collects the whole pot.
            rows.append(SkinsHoleResult(
                game        = game,
                hole_number = hole_num,
                winner_id   = leaders[0],
                skins_value = pot,
                is_carry    = False,
            ))
            pot = 0  # reset after a win

        elif game.carryover:
            # Tied hole with carryover — skin carries to next hole.
            rows.append(SkinsHoleResult(
                game        = game,
                hole_number = hole_num,
                winner      = None,
                skins_value = pot,   # current pot being carried
                is_carry    = True,
            ))
            # pot keeps accumulating; do NOT reset

        else:
            # Tied hole without carryover — skin is killed.
            rows.append(SkinsHoleResult(
                game        = game,
                hole_number = hole_num,
                winner      = None,
                skins_value = 1,     # the 1 skin that died
                is_carry    = False,
            ))
            pot = 0  # reset; next hole starts a fresh 1-skin pot

    if rows:
        SkinsHoleResult.objects.bulk_create(rows)

    # Status: pending / in_progress / complete.
    if fully_scored == 0:
        game.status = MatchStatus.PENDING
    elif fully_scored >= 18:
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])

    return rows


# ---------------------------------------------------------------------------
# Summary (for the game screen and leaderboard)
# ---------------------------------------------------------------------------

def skins_summary(foursome) -> dict:
    """
    JSON-serialisable summary of a Skins game.

    Shape:
        {
            'status'    : 'pending' | 'in_progress' | 'complete',
            'handicap'  : {'mode': str, 'net_percent': int},
            'carryover' : bool,
            'allow_junk': bool,
            'players'   : [
                {
                    'player_id'  : int,
                    'name'       : str,
                    'short_name' : str,
                    'skins_won'  : int,   # regular per-hole skins
                    'junk_skins' : int,   # junk skins (0 if allow_junk=False)
                    'total_skins': int,
                    'payout'     : float, # pool × (total / grand_total)
                },
                ...  sorted by total_skins desc
            ],
            'holes'     : [
                {
                    'hole'        : int,
                    'winner_id'   : int | null,
                    'winner_short': str | null,
                    'skins_value' : int,
                    'is_carry'    : bool,
                    'junk'        : [
                        {'player_id': int, 'short_name': str, 'count': int},
                        ...
                    ],
                },
                ...
            ],
            'money'     : {
                'bet_unit'   : float,
                'pool'       : float,   # num_players × bet_unit
                'total_skins': int,     # grand total skins won (denom)
            },
        }
    """
    try:
        game = foursome.skins_game
    except SkinsGame.DoesNotExist:
        bet_unit = float(foursome.round.bet_unit)
        return {
            'status'    : MatchStatus.PENDING,
            'handicap'  : {'mode': HandicapMode.NET, 'net_percent': 100},
            'carryover' : True,
            'allow_junk': False,
            'players'   : [],
            'holes'     : [],
            'money'     : {'bet_unit': bet_unit, 'pool': 0.0, 'total_skins': 0},
        }

    real_members = list(
        foursome.memberships
        .select_related('player')
        .filter(player__is_phantom=False)
    )
    bet_unit    = float(foursome.round.bet_unit)
    num_players = len(real_members)
    pool        = num_players * bet_unit

    # ---- Regular skins per player -------------------------------------------
    regular_skins: dict = {m.player_id: 0 for m in real_members}
    hole_results = list(
        SkinsHoleResult.objects
        .filter(game=game)
        .select_related('winner')
        .order_by('hole_number')
    )
    for hr in hole_results:
        if hr.winner_id and hr.winner_id in regular_skins:
            regular_skins[hr.winner_id] += hr.skins_value

    # ---- Junk skins per player (only when allow_junk=True) ------------------
    junk_skins: dict        = {m.player_id: 0 for m in real_members}
    junk_by_hole_player: dict = {}   # (hole_number, player_id) → entry dict

    if game.allow_junk:
        for jr in (
            SkinsPlayerHoleResult.objects
            .filter(game=game)
            .select_related('player')
        ):
            if jr.player_id in junk_skins:
                junk_skins[jr.player_id] += jr.junk_count
            if jr.junk_count > 0:
                junk_by_hole_player[(jr.hole_number, jr.player_id)] = {
                    'player_id' : jr.player_id,
                    'short_name': jr.player.short_name,
                    'count'     : jr.junk_count,
                }

    # ---- Totals and payouts -------------------------------------------------
    total_skins_by_pid = {
        pid: regular_skins[pid] + junk_skins[pid]
        for pid in regular_skins
    }
    grand_total = sum(total_skins_by_pid.values())

    players_out: list = []
    for m in real_members:
        pid    = m.player_id
        ts     = total_skins_by_pid[pid]
        payout = (ts / grand_total * pool) if grand_total > 0 else 0.0
        players_out.append({
            'player_id'  : pid,
            'name'       : m.player.name,
            'short_name' : m.player.short_name,
            'skins_won'  : regular_skins[pid],
            'junk_skins' : junk_skins[pid],
            'total_skins': ts,
            'payout'     : round(payout, 2),
        })
    players_out.sort(key=lambda x: (-x['total_skins'], x['name']))

    # ---- Holes grid ---------------------------------------------------------
    holes_out: list = []
    for hr in hole_results:
        junk_entries = [
            v for (hn, _pid), v in junk_by_hole_player.items()
            if hn == hr.hole_number
        ]
        holes_out.append({
            'hole'        : hr.hole_number,
            'winner_id'   : hr.winner_id,
            'winner_short': hr.winner.short_name if hr.winner else None,
            'skins_value' : hr.skins_value,
            'is_carry'    : hr.is_carry,
            'junk'        : junk_entries,
        })

    return {
        'status'    : game.status,
        'handicap'  : {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'carryover' : game.carryover,
        'allow_junk': game.allow_junk,
        'players'   : players_out,
        'holes'     : holes_out,
        'money'     : {
            'bet_unit'   : bet_unit,
            'pool'       : pool,
            'total_skins': grand_total,
        },
    }
