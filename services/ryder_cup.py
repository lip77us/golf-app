"""
services/ryder_cup.py
---------------------
Ryder Cup team points aggregator.

This service sits above the individual game calculators.  It reads resolved
segment results from each game and converts them into RyderCupMatchPoints
rows, then rolls those up into team totals for the TeamTournament.

Supported GameType values
~~~~~~~~~~~~~~~~~~~~~~~~~
    nassau       — reads NassauGame.front9/back9/overall_result
    quota_nassau — reads QuotaNassauMatch.front9/back9/overall_result
                   (one row per match × 3 segments)
    irish_rumble — cross-foursome pairing; compares accumulated
                   Irish Rumble scores at F9/B9/18 (stroke totals,
                   lower wins) — tracked via RyderCupIrishRumblePairing
    match_play   — reads MatchPlayMatch.result for completed matches
                   (each 9-hole match = 1 Ryder Cup point)

Adding support for a new GameType only requires adding a new branch in
_extract_foursome_points() below.

Public API
~~~~~~~~~~
    calculate_ryder_cup_points(round_obj)   → list[RyderCupMatchPoints]
    ryder_cup_summary(team_tournament)      → dict
"""

from decimal import Decimal

from django.db import transaction

from core.models import GameType, MatchStatus
from games.models import (
    NassauGame,
    QuotaNassauGame,
    IrishRumbleConfig,
    MatchPlayBracket,
)
from tournament.models import (
    Foursome,
    RyderCupRoundConfig,
    RyderCupFoursomeConfig,
    RyderCupIrishRumblePairing,
    RyderCupMatchPoints,
    TournamentTeam,
    TeamTournament,
)
from services.irish_rumble import _build_ir_score_index, _par_index_for_round


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _pts(result: 'str | None', point_value: Decimal, multiplier: Decimal):
    """
    Convert a Nassau-style segment result into (team1_points, team2_points).

    'team1'  → (point_value × multiplier,  0)
    'team2'  → (0,  point_value × multiplier)
    'halved' → (half,  half)
    None     → (0, 0)   — not yet resolved
    """
    base = point_value * multiplier
    half = base / 2
    if result == 'team1':  return base, Decimal(0)
    if result == 'team2':  return Decimal(0), base
    if result == 'halved': return half, half
    return Decimal(0), Decimal(0)


def _quota_to_ryder(player_result: 'str | None') -> 'str | None':
    """
    QuotaNassauMatch stores results as 'player1'|'player2'|'halved'.
    RyderCupMatchPoints expects 'team1'|'team2'|'halved'.
    player1 maps to team1 (the team whose player was registered as p1).
    """
    if player_result == 'player1': return 'team1'
    if player_result == 'player2': return 'team2'
    return player_result   # 'halved' or None pass through


def _resolve_score(a: 'int | None', b: 'int | None') -> 'str | None':
    """Lower cumulative stroke score wins (golf).  None if either is incomplete."""
    if a is None or b is None:
        return None
    if a < b:  return 'team1'
    if b < a:  return 'team2'
    return 'halved'


# ---------------------------------------------------------------------------
# Per-foursome point extraction
# ---------------------------------------------------------------------------

def _extract_foursome_points(
    fs_config: RyderCupFoursomeConfig,
    pv: Decimal,
    mul: Decimal,
) -> list:
    """
    Read the game record for this foursome and return a list of
    RyderCupMatchPoints instances (not yet saved).

    Dispatches on fs_config.game_type.
    Per-foursome point_value overrides the round-level pv when set.
    """
    # Per-foursome override — always present (default 1.00)
    pv = Decimal(str(fs_config.point_value))
    foursome = fs_config.foursome
    t1, t2   = fs_config.team1, fs_config.team2
    gtype    = fs_config.game_type
    rows     = []

    # ── Nassau (four-ball or singles) ──────────────────────────────────────
    if gtype == GameType.NASSAU:
        try:
            game = NassauGame.objects.get(foursome=foursome)
        except NassauGame.DoesNotExist:
            return []

        for seg, result in [
            ('front9',  game.front9_result),
            ('back9',   game.back9_result),
            ('overall', game.overall_result),
        ]:
            t1_pts, t2_pts = _pts(result, pv, mul)
            rows.append(RyderCupMatchPoints(
                round_config = fs_config.round_config,
                team1        = t1,
                team2        = t2,
                foursome     = foursome,
                segment      = seg,
                game_type    = gtype,
                result       = result,
                team1_points = t1_pts,
                team2_points = t2_pts,
            ))

    # ── Quota Nassau (one row per match × 3 segments) ─────────────────────
    elif gtype == GameType.QUOTA_NASSAU:
        try:
            game = QuotaNassauGame.objects.prefetch_related(
                'matches__player1', 'matches__player2'
            ).get(foursome=foursome)
        except QuotaNassauGame.DoesNotExist:
            return []

        for match in game.matches.all():
            for seg, raw_result in [
                ('front9',  match.front9_result),
                ('back9',   match.back9_result),
                ('overall', match.overall_result),
            ]:
                result   = _quota_to_ryder(raw_result)
                t1p, t2p = _pts(result, pv, mul)
                rows.append(RyderCupMatchPoints(
                    round_config = fs_config.round_config,
                    team1        = t1,
                    team2        = t2,
                    foursome     = foursome,
                    player1      = match.player1,
                    player2      = match.player2,
                    segment      = seg,
                    game_type    = gtype,
                    result       = result,
                    team1_points = t1p,
                    team2_points = t2p,
                ))

    # ── Singles Nassau / 18-Hole Singles ──────────────────────────────────
    # SINGLES_NASSAU: 3 cup points per match (F9 / B9 / Overall), each worth pv.
    # SINGLES_18: 1 cup point per match (Overall only), worth pv.
    # Both formats use MatchPlayBracket with hole-level MatchPlayHoleResult rows.
    elif gtype in (GameType.SINGLES_NASSAU, GameType.SINGLES_18):
        from services.cup_singles import _compute_sub_match

        def _mp_to_cup(r):
            """MatchPlayMatch result → Ryder Cup result."""
            if r == 'player1': return 'team1'
            if r == 'player2': return 'team2'
            return r  # 'halved' or None pass through

        try:
            bracket = MatchPlayBracket.objects.prefetch_related(
                'matches__player1', 'matches__player2', 'matches__hole_results'
            ).get(foursome=foursome)
        except MatchPlayBracket.DoesNotExist:
            return []

        for mp_match in bracket.matches.all():
            if gtype == GameType.SINGLES_NASSAU:
                # Derive F9 / B9 / Overall results from hole-by-hole data.
                holes_data = [
                    {
                        'hole_number': r.hole_number,
                        'p1_net'     : r.p1_net,
                        'p2_net'     : r.p2_net,
                    }
                    for r in sorted(
                        mp_match.hole_results.all(),
                        key=lambda r: r.hole_number,
                    )
                ]
                f9    = _compute_sub_match(holes_data, 1,  9)
                b9    = _compute_sub_match(holes_data, 10, 18)
                all18 = _compute_sub_match(holes_data, 1,  18)

                for seg, sub in [
                    ('front9',  f9),
                    ('back9',   b9),
                    ('overall', all18),
                ]:
                    result   = _mp_to_cup(sub['result'])
                    t1p, t2p = _pts(result, pv, mul)
                    rows.append(RyderCupMatchPoints(
                        round_config = fs_config.round_config,
                        team1        = t1,
                        team2        = t2,
                        foursome     = foursome,
                        player1      = mp_match.player1,
                        player2      = mp_match.player2,
                        segment      = seg,
                        game_type    = gtype,
                        result       = result,
                        team1_points = t1p,
                        team2_points = t2p,
                    ))
            else:
                # SINGLES_18: single overall result stored on the match record.
                result   = _mp_to_cup(mp_match.result)
                t1p, t2p = _pts(result, pv, mul)
                rows.append(RyderCupMatchPoints(
                    round_config = fs_config.round_config,
                    team1        = t1,
                    team2        = t2,
                    foursome     = foursome,
                    player1      = mp_match.player1,
                    player2      = mp_match.player2,
                    segment      = 'overall',
                    game_type    = gtype,
                    result       = result,
                    team1_points = t1p,
                    team2_points = t2p,
                ))

    # ── Triple Cup (4 matches: fourball + foursomes + 2 singles) ───────────
    # One cup-points row per TC match, mirroring cup_round_live_summary so the
    # stored standings match the live cup scorecard.  point_value is PER MATCH
    # — a TC group decides 4 matches.
    elif gtype == GameType.TRIPLE_CUP:
        from services.triple_cup import triple_cup_summary
        try:
            tcs = triple_cup_summary(foursome) or {}
        except Exception:
            tcs = {}
        for tcm in tcs.get('matches', []):
            result   = tcm.get('result')   # 'team1'|'team2'|'halved'|None
            t1p, t2p = _pts(result, pv, mul)
            rows.append(RyderCupMatchPoints(
                round_config = fs_config.round_config,
                team1        = t1,
                team2        = t2,
                foursome     = foursome,
                segment      = tcm.get('segment') or 'overall',
                game_type    = gtype,
                result       = result,
                team1_points = t1p,
                team2_points = t2p,
            ))

    return rows


# ---------------------------------------------------------------------------
# Irish Rumble head-to-head
# ---------------------------------------------------------------------------

def _extract_ir_pairing_points(
    pairing: RyderCupIrishRumblePairing,
    rc_config: RyderCupRoundConfig,
    pv: Decimal,
    mul: Decimal,
    round_obj,
) -> list:
    """
    Compare two foursomes' accumulated Irish Rumble scores Nassau-style
    (F9 / B9 / Overall 18).  Lower cumulative stroke score wins each segment.

    Updates pairing.front9/back9/overall_result in-place and returns a list
    of RyderCupMatchPoints instances for the three segments.
    """
    rows = []

    try:
        config = round_obj.irish_rumble_config
    except IrishRumbleConfig.DoesNotExist:
        return []

    score_index = _build_ir_score_index(
        round_obj, config.handicap_mode, config.net_percent
    )

    # How many balls to count per hole
    balls_by_hole: dict = {}
    for seg in config.segments:
        for h in range(seg['start_hole'], seg['end_hole'] + 1):
            balls_by_hole[h] = seg['balls_to_count']

    def _cumulative(foursome, max_hole: int) -> 'int | None':
        """Accumulated Irish Rumble score for a foursome through max_hole."""
        fs_scores = score_index.get(foursome.pk, {})
        n_players = (
            foursome.memberships.filter(player__is_phantom=False).count()
            + (1 if foursome.has_phantom else 0)
        )
        total = 0
        for h in range(1, max_hole + 1):
            n      = min(balls_by_hole.get(h, 1), n_players)
            scores = sorted([
                ph[h] for ph in fs_scores.values() if h in ph
            ])
            if len(scores) < n:
                return None   # incomplete
            total += sum(scores[:n])
        return total

    fa, fb = pairing.foursome_a, pairing.foursome_b

    f9_a  = _cumulative(fa, 9)
    f9_b  = _cumulative(fb, 9)
    f18_a = _cumulative(fa, 18)
    f18_b = _cumulative(fb, 18)
    b9_a  = (f18_a - f9_a) if (f18_a is not None and f9_a is not None) else None
    b9_b  = (f18_b - f9_b) if (f18_b is not None and f9_b is not None) else None

    # team_a is the "team1" perspective in this pairing
    pairing.front9_result  = _resolve_score(f9_a,  f9_b)
    pairing.back9_result   = _resolve_score(b9_a,  b9_b)
    pairing.overall_result = _resolve_score(f18_a, f18_b)
    pairing.save()

    for seg, result in [
        ('front9',  pairing.front9_result),
        ('back9',   pairing.back9_result),
        ('overall', pairing.overall_result),
    ]:
        t1p, t2p = _pts(result, pv, mul)
        rows.append(RyderCupMatchPoints(
            round_config         = rc_config,
            team1                = pairing.team_a,
            team2                = pairing.team_b,
            irish_rumble_pairing = pairing,
            segment              = seg,
            game_type            = GameType.IRISH_RUMBLE,
            result               = result,
            team1_points         = t1p,
            team2_points         = t2p,
        ))

    return rows


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_ryder_cup_points(round_obj) -> list:
    """
    (Re)compute RyderCupMatchPoints rows for a Round.

    Reads results from every game already calculated for this round and
    converts them into Ryder Cup points.  Safe to call repeatedly — previous
    rows for this round are deleted first.

    Returns a list of saved RyderCupMatchPoints instances.
    """
    try:
        rc_config = round_obj.ryder_cup_config
    except RyderCupRoundConfig.DoesNotExist:
        return []

    RyderCupMatchPoints.objects.filter(round_config=rc_config).delete()

    pv  = rc_config.nassau_point_value
    mul = rc_config.point_multiplier
    rows = []

    # ── Per-foursome games ─────────────────────────────────────────────────
    for fs_cfg in rc_config.foursome_configs.select_related(
        'foursome', 'team1', 'team2'
    ):
        rows.extend(_extract_foursome_points(fs_cfg, pv, mul))

    # ── Irish Rumble cross-group pairings ─────────────────────────────────
    for pairing in rc_config.irish_rumble_pairings.select_related(
        'foursome_a', 'foursome_b', 'team_a', 'team_b'
    ):
        rows.extend(_extract_ir_pairing_points(pairing, rc_config, pv, mul, round_obj))

    RyderCupMatchPoints.objects.bulk_create(rows)
    return rows


def ryder_cup_summary(team_tournament: TeamTournament) -> dict:
    """
    Return overall standings and a per-round breakdown for a TeamTournament.

    Shape
    -----
    {
        'tournament_name': str,
        'draft_complete' : bool,
        'teams': [
            {
                'team_number'  : int,
                'name'         : str,
                'colour'       : str,
                'short_code'   : str,
                'total_points' : float,
                'players'      : [
                    {'player_id': int, 'name': str, 'short_name': str},
                    ...
                ],
            },
            ...
        ],
        'rounds': [
            {
                'round_id'          : int,
                'round_number'      : int,
                'date'              : str,   # ISO date
                'course'            : str,
                'nassau_point_value': float,
                'point_multiplier'  : float,
                'notes'             : str,
                'team_points'       : [
                    {'team_name': str, 'points': float}, ...
                ],
                'matches': [
                    {
                        'game_type' : str,
                        'group'     : int | null,
                        'team1'     : str,
                        'team2'     : str,
                        'player1'   : str | null,   # short_name for singles
                        'player2'   : str | null,
                        'segments'  : [
                            {
                                'segment' : str,   # 'front9'|'back9'|'overall'
                                'result'  : str | null,
                                't1_pts'  : float,
                                't2_pts'  : float,
                            },
                            ...
                        ],
                    },
                    ...
                ],
            },
            ...
        ],
    }
    """
    teams = list(
        team_tournament.teams
        .prefetch_related('players')
        .order_by('team_number')
    )
    team_totals = {t.pk: Decimal(0) for t in teams}

    rounds_out = []

    for rc in team_tournament.round_configs.select_related(
        'round__course'
    ).prefetch_related(
        'match_points__team1',
        'match_points__team2',
        'match_points__foursome',
        'match_points__player1',
        'match_points__player2',
        'match_points__irish_rumble_pairing',
    ).order_by('round__round_number'):

        round_team_pts = {t.pk: Decimal(0) for t in teams}

        # ── Group match_points by logical match ────────────────────────────
        # Key: (source_id, game_type, player1_id, player2_id)
        # This collapses the 3 segment rows for a single match into one group.
        match_groups: dict = {}
        for mp in rc.match_points.all():
            if mp.foursome_id is not None:
                source_key = ('fs', mp.foursome_id)
            else:
                source_key = ('ir', mp.irish_rumble_pairing_id)

            key = (source_key, mp.game_type, mp.player1_id, mp.player2_id)
            match_groups.setdefault(key, []).append(mp)

            # Accumulate per-round totals (use team PK to avoid name collisions)
            if mp.team1_id in round_team_pts:
                round_team_pts[mp.team1_id] += mp.team1_points
            if mp.team2_id in round_team_pts:
                round_team_pts[mp.team2_id] += mp.team2_points

        # ── Add round totals to tournament totals ──────────────────────────
        for tpk, pts in round_team_pts.items():
            team_totals[tpk] = team_totals.get(tpk, Decimal(0)) + pts

        # ── Build match rows for output ────────────────────────────────────
        SEGMENT_ORDER = ['front9', 'back9', 'overall']
        matches_out = []
        for _key, segments in match_groups.items():
            first = segments[0]
            matches_out.append({
                'game_type': first.game_type,
                'group'    : (
                    first.foursome.group_number if first.foursome_id else None
                ),
                'team1'    : first.team1.name,
                'team2'    : first.team2.name,
                'player1'  : first.player1.short_name if first.player1_id else None,
                'player2'  : first.player2.short_name if first.player2_id else None,
                'segments' : [
                    {
                        'segment': mp.segment,
                        'result' : mp.result,
                        't1_pts' : float(mp.team1_points),
                        't2_pts' : float(mp.team2_points),
                    }
                    for mp in sorted(
                        segments,
                        key=lambda x: (
                            SEGMENT_ORDER.index(x.segment)
                            if x.segment in SEGMENT_ORDER else 99
                        ),
                    )
                ],
            })

        rounds_out.append({
            'round_id'          : rc.round_id,
            'round_number'      : rc.round.round_number,
            'date'              : str(rc.round.date),
            'course'            : rc.round.course.name,
            'nassau_point_value': float(rc.nassau_point_value),
            'point_multiplier'  : float(rc.point_multiplier),
            'notes'             : rc.notes,
            'team_points'       : [
                {
                    'team_name': t.name,
                    'points'   : float(round_team_pts.get(t.pk, Decimal(0))),
                }
                for t in teams
            ],
            'matches': matches_out,
        })

    return {
        'tournament_name': team_tournament.tournament.name,
        'cup_name'       : team_tournament.cup_name,
        'draft_complete' : team_tournament.draft_complete,
        'teams'          : [
            {
                'team_id'      : t.pk,
                'team_number'  : t.team_number,
                'name'         : t.name,
                'colour'       : t.colour,
                'short_code'   : t.short_code,
                'total_points' : float(team_totals.get(t.pk, Decimal(0))),
                'players'      : [
                    {
                        'player_id' : p.id,
                        'name'      : p.name,
                        'short_name': p.short_name,
                    }
                    for p in t.players.all()
                ],
            }
            for t in teams
        ],
        'rounds': rounds_out,
    }
