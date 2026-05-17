"""
services/multi_skins.py
-----------------------
Multi-Foursome Skins calculator — a Round-level skins pool that crosses
every participating foursome.

Scoring rules
~~~~~~~~~~~~~
* Each hole is worth 1 skin.  The player with the BEST score-to-compare
  on a hole wins it outright.
* Tied best score → skin dies (no carryover, no junk).
* Only holes where EVERY participant has a score on file are counted.

Handicap modes
~~~~~~~~~~~~~~
* Net (with net_percent) and Gross use scoring.handicap.build_score_index
  per-foursome and union the results.
* Strokes-Off-Low is round-wide: the lowest playing handicap across all
  participants plays to 0; everyone else's SO = own − low.  Strokes are
  allocated by each player's tee stroke index (each foursome may use a
  different tee, so SI per player is local to their membership).

Settlement
~~~~~~~~~~
Pool = participants × bet_unit.
payout_i = (skins_i / total_skins_won) × pool.
Players with zero skins receive nothing; the pool is always fully
distributed when at least one skin is won.

Workflow
~~~~~~~~
1. setup_multi_skins(round, participant_ids, ...) — create or replace
   the MultiSkinsGame.  Safe to call repeatedly.
2. calculate_multi_skins(round) — recompute MultiSkinsHoleResult rows.
   Called from api.views after every score submission in any foursome
   that touches this round.
3. multi_skins_summary(round) — JSON shape consumed by the mobile UI.
"""
from __future__ import annotations

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import MultiSkinsGame, MultiSkinsHoleResult
from scoring.handicap import build_score_index
from scoring.models import HoleScore


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_multi_skins(
    round_obj,
    participant_ids: list[int],
    handicap_mode:   str  = HandicapMode.NET,
    net_percent:     int  = 100,
    bet_unit:        float | None = None,
) -> MultiSkinsGame:
    """
    Create (or replace) the Multi-Skins game for a Round.

    participant_ids must reference players that have a FoursomeMembership
    in this round.  Anyone outside the round is silently filtered out.
    """
    MultiSkinsGame.objects.filter(round=round_obj).delete()

    net_percent = max(0, min(200, int(net_percent)))

    game = MultiSkinsGame.objects.create(
        round         = round_obj,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        bet_unit      = bet_unit if bet_unit is not None else round_obj.bet_unit,
        status        = MatchStatus.PENDING,
    )
    valid_pids = set(
        _round_player_ids(round_obj)
    )
    pids = [pid for pid in participant_ids if pid in valid_pids]
    if pids:
        game.participants.set(pids)
    return game


def _round_player_ids(round_obj) -> list[int]:
    """All real-player IDs across every foursome in this round."""
    from tournament.models import FoursomeMembership
    return list(
        FoursomeMembership.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .values_list('player_id', flat=True)
    )


# ---------------------------------------------------------------------------
# Score index across the whole round
# ---------------------------------------------------------------------------

def _build_round_score_index(round_obj, game: MultiSkinsGame) -> dict:
    """
    Return {player_id: {hole_number: adjusted_score}} unioned across
    every foursome in the round, for the game's participants only.

    Net/Gross: delegate to the per-foursome `build_score_index` and merge.
    Strokes-Off-Low: anchored on the lowest participant handicap, applied
    using each player's own tee.
    """
    participant_ids = set(game.participants.values_list('id', flat=True))
    if not participant_ids:
        return {}

    foursomes = list(round_obj.foursomes.all())

    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_so_round_index(foursomes, participant_ids, game.net_percent)

    merged: dict = {}
    for fs in foursomes:
        per_fs = build_score_index(
            fs,
            handicap_mode = game.handicap_mode,
            net_percent   = game.net_percent,
        )
        for pid, holes in per_fs.items():
            if pid in participant_ids:
                merged.setdefault(pid, {}).update(holes)
    return merged


def _build_so_round_index(
    foursomes:        list,
    participant_ids:  set[int],
    net_percent:      int,
) -> dict:
    """
    Strokes-Off-Low across the whole round.  Low handicap is the lowest
    playing_handicap among PARTICIPANTS (not the foursome low).  Each
    player gets one stroke on every hole whose stroke_index ≤ their SO,
    using the stroke_index from their OWN membership's tee.
    """
    memberships = []
    for fs in foursomes:
        for m in fs.memberships.select_related('player', 'tee').filter(
            player__is_phantom=False, player_id__in=participant_ids,
        ):
            memberships.append(m)

    if not memberships:
        return {}

    phcps = [m.playing_handicap for m in memberships
             if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0

    # Pull all gross scores in one query.
    rows = (
        HoleScore.objects
        .filter(
            foursome__round__in=[fs.round_id for fs in foursomes],
            player_id__in=participant_ids,
        )
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    )

    by_member = {m.player_id: m for m in memberships}
    out: dict = {}
    for r in rows:
        pid    = r['player_id']
        gross  = r['gross_score']
        member = by_member.get(pid)
        if member is None or member.tee_id is None:
            out.setdefault(pid, {})[r['hole_number']] = gross
            continue
        so = round(max(0, (member.playing_handicap or 0) - low)
                   * net_percent / 100)
        if so <= 0:
            out.setdefault(pid, {})[r['hole_number']] = gross
            continue
        full_laps = so // 18
        remainder = so %  18
        si        = member.tee.hole(r['hole_number']).get('stroke_index', 18)
        strokes   = full_laps + (1 if si <= remainder else 0)
        out.setdefault(pid, {})[r['hole_number']] = gross - strokes
    return out


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_multi_skins(round_obj) -> list:
    """
    Recompute MultiSkinsHoleResult rows for the round's Multi-Skins game.
    Returns the list of newly-saved rows (or [] if no game exists).
    """
    try:
        game = round_obj.multi_skins_game
    except MultiSkinsGame.DoesNotExist:
        return []

    participant_ids = list(game.participants.values_list('id', flat=True))
    MultiSkinsHoleResult.objects.filter(game=game).delete()

    if len(participant_ids) < 2:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    score_index = _build_round_score_index(round_obj, game)

    rows         = []
    fully_scored = 0

    for hole_num in range(1, 19):
        scores: dict = {}
        complete = True
        for pid in participant_ids:
            s = score_index.get(pid, {}).get(hole_num)
            if s is None:
                complete = False
                break
            scores[pid] = s
        if not complete:
            continue

        fully_scored += 1
        min_score = min(scores.values())
        leaders   = [pid for pid, s in scores.items() if s == min_score]

        winner_id = leaders[0] if len(leaders) == 1 else None
        rows.append(MultiSkinsHoleResult(
            game        = game,
            hole_number = hole_num,
            winner_id   = winner_id,
        ))

    if rows:
        MultiSkinsHoleResult.objects.bulk_create(rows)

    if fully_scored == 0:
        game.status = MatchStatus.PENDING
    elif fully_scored >= 18:
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])

    return rows


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def multi_skins_summary(round_obj) -> dict:
    """
    JSON-serialisable summary for the mobile client.

    Shape:
        {
            'status'    : 'pending' | 'in_progress' | 'complete',
            'handicap'  : {'mode': str, 'net_percent': int},
            'players'   : [
                {'player_id', 'name', 'short_name', 'foursome_id',
                 'group_number', 'skins_won', 'payout'},  # sorted by skins_won
            ],
            'holes'     : [
                {'hole', 'winner_id', 'winner_short', 'is_dead'},
            ],
            'money'     : {'bet_unit', 'pool', 'total_skins'},
        }
    """
    try:
        game = round_obj.multi_skins_game
    except MultiSkinsGame.DoesNotExist:
        bet_unit = float(round_obj.bet_unit)
        return {
            'status'   : MatchStatus.PENDING,
            'handicap' : {'mode': HandicapMode.NET, 'net_percent': 100},
            'players'  : [],
            'holes'    : [],
            'money'    : {'bet_unit': bet_unit, 'pool': 0.0, 'total_skins': 0},
        }

    bet_unit = float(game.bet_unit)

    # Build participant info — group_number/foursome_id come from their
    # FoursomeMembership in this round.
    from tournament.models import FoursomeMembership
    memberships = list(
        FoursomeMembership.objects
        .filter(
            foursome__round=round_obj,
            player__in=game.participants.all(),
        )
        .select_related('player', 'foursome')
    )
    by_pid = {m.player_id: m for m in memberships}

    skins_won: dict = {m.player_id: 0 for m in memberships}
    hole_results = list(
        MultiSkinsHoleResult.objects
        .filter(game=game)
        .select_related('winner')
        .order_by('hole_number')
    )
    for hr in hole_results:
        if hr.winner_id and hr.winner_id in skins_won:
            skins_won[hr.winner_id] += 1

    grand_total = sum(skins_won.values())
    pool        = len(memberships) * bet_unit

    players_out: list = []
    for m in memberships:
        pid    = m.player_id
        won    = skins_won[pid]
        payout = (won / grand_total * pool) if grand_total > 0 else 0.0
        players_out.append({
            'player_id'   : pid,
            'name'        : m.player.name,
            'short_name'  : m.player.short_name,
            'foursome_id' : m.foursome_id,
            'group_number': m.foursome.group_number,
            'skins_won'   : won,
            'payout'      : round(payout, 2),
        })
    players_out.sort(key=lambda x: (-x['skins_won'], x['name']))

    holes_out: list = [
        {
            'hole'        : hr.hole_number,
            'winner_id'   : hr.winner_id,
            'winner_short': hr.winner.short_name if hr.winner else None,
            'is_dead'     : hr.winner_id is None,
        }
        for hr in hole_results
    ]

    return {
        'status'   : game.status,
        'handicap' : {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'players'  : players_out,
        'holes'    : holes_out,
        'money'    : {
            'bet_unit'   : bet_unit,
            'pool'       : pool,
            'total_skins': grand_total,
        },
    }
