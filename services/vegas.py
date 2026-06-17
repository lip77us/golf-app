"""
services/vegas.py — Las Vegas (2v2) casual game.

Each hole, a team's "number" is its two NET scores with the low score as the
tens digit and the high as the ones (each digit capped at 9). The lower number
wins the hole and scores the *difference* between the two numbers. A gross
birdie either flips the opponents' digits or multiplies the points (per setup),
and tied holes can carry. Settlement is 1-to-1 per player: each player's money
is the running point differential × bet_unit (winners +, losers −), clipped by
the optional per-side loss cap.

Mirrors the Points 5-3-1 / Sixes service contract: setup_vegas / calculate_vegas
(idempotent, called from _recalculate_games) / vegas_summary.
"""
from __future__ import annotations

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import VegasGame, VegasTeam, VegasHoleResult
from scoring.handicap import build_score_index, _par_by_hole, _cap_value
from services import wager


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_vegas(
    foursome,
    team1_ids: list,
    team2_ids: list,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    net_max_double_bogey: bool = True,
    birdie_mode: str = 'flip',
    carryover: bool = False,
    loss_cap=None,
) -> VegasGame:
    """Create (or replace) the Vegas game for a foursome. Idempotent."""
    VegasGame.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))
    if birdie_mode not in ('flip', 'multiplier'):
        birdie_mode = 'flip'
    if loss_cap is not None:
        loss_cap = Decimal(str(loss_cap))
        if loss_cap < 0:
            loss_cap = None

    game = VegasGame.objects.create(
        foursome             = foursome,
        handicap_mode        = handicap_mode,
        net_percent          = net_percent,
        net_max_double_bogey = bool(net_max_double_bogey),
        birdie_mode          = birdie_mode,
        carryover            = bool(carryover),
        loss_cap             = loss_cap,
        status               = MatchStatus.PENDING,
    )
    t1 = VegasTeam.objects.create(game=game, team_number=1)
    t1.players.set(team1_ids)
    t2 = VegasTeam.objects.create(game=game, team_number=2)
    t2.players.set(team2_ids)
    return game


# ---------------------------------------------------------------------------
# Score index (net digits, honouring the game's own net-double-bogey flag)
# ---------------------------------------------------------------------------

def _net_index(foursome, game) -> dict:
    """{player_id: {hole: net_score}} per the game's handicap policy, with the
    game's own net-double-bogey cap applied."""
    if game.handicap_mode != HandicapMode.STROKES_OFF:
        return build_score_index(
            foursome,
            handicap_mode=game.handicap_mode,
            net_percent=game.net_percent,
            net_double_bogey=game.net_max_double_bogey,
        )

    # Strokes-off-low: low playing handicap plays to 0; others get
    # (phcp − low) strokes on the hardest holes. Cap applied per the game flag.
    index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)
    members = list(
        foursome.memberships.select_related('player', 'tee')
        .filter(player__is_phantom=False))
    phcps = [m.playing_handicap for m in members if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0
    par_by_hole = _par_by_hole(foursome) if game.net_max_double_bogey else {}
    for m in members:
        if m.tee_id is None:
            continue
        so = round(max(0, (m.playing_handicap or 0) - low) * game.net_percent / 100)
        per_player = index.get(m.player_id)
        if not per_player:
            continue
        full, rem = so // 18, so % 18
        for hole_num, gross in list(per_player.items()):
            si = m.tee.hole(hole_num).get('stroke_index', 18)
            strokes = full + (1 if si <= rem else 0)
            value = gross - strokes
            per_player[hole_num] = _cap_value(
                value, par_by_hole.get(hole_num), game.net_max_double_bogey)
    return index


# ---------------------------------------------------------------------------
# Engine helpers
# ---------------------------------------------------------------------------

def _team_number(net_a: int, net_b: int) -> int:
    """Two net scores → the team's 2-digit number (low = tens, high = ones),
    each digit capped at 9 so the number stays two digits."""
    a, b = min(net_a, 9), min(net_b, 9)
    lo, hi = (a, b) if a <= b else (b, a)
    return lo * 10 + hi


def _flip(num: int) -> int:
    """Reverse a 2-digit team number (high digit becomes the tens)."""
    return (num % 10) * 10 + (num // 10)


# ---------------------------------------------------------------------------
# Calculate
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_vegas(foursome) -> list:
    """Recompute VegasHoleResult rows for the foursome's game. Idempotent."""
    try:
        game = foursome.vegas_game
    except VegasGame.DoesNotExist:
        return []

    teams = {t.team_number: list(t.players.values_list('id', flat=True))
             for t in game.teams.all()}
    t1_ids, t2_ids = teams.get(1, []), teams.get(2, [])

    VegasHoleResult.objects.filter(game=game).delete()

    # Need exactly two players per team to form a number.
    if len(t1_ids) != 2 or len(t2_ids) != 2:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    net_index   = _net_index(foursome, game)
    gross_index = build_score_index(foursome, handicap_mode=HandicapMode.GROSS)
    par_by_hole = _par_by_hole(foursome)

    def best_under(player_ids, hole):
        par = par_by_hole.get(hole)
        if par is None:
            return 0
        best = 0
        for pid in player_ids:
            gross = gross_index.get(pid, {}).get(hole)
            if gross is not None and (par - gross) > best:
                best = par - gross
        return best

    rows = []
    carry = 0
    scored = 0
    for hole in range(1, 19):
        n1a = net_index.get(t1_ids[0], {}).get(hole)
        n1b = net_index.get(t1_ids[1], {}).get(hole)
        n2a = net_index.get(t2_ids[0], {}).get(hole)
        n2b = net_index.get(t2_ids[1], {}).get(hole)
        if None in (n1a, n1b, n2a, n2b):
            continue  # hole not fully scored yet
        scored += 1

        num1 = _team_number(n1a, n1b)
        num2 = _team_number(n2a, n2b)
        birdie1 = best_under(t1_ids, hole) >= 1
        birdie2 = best_under(t2_ids, hole) >= 1
        multiplier = 1

        if game.birdie_mode == 'flip':
            # Any team's birdie flips the OTHER team's number, before deciding.
            if birdie1:
                num2 = _flip(num2)
            if birdie2:
                num1 = _flip(num1)

        if num1 < num2:
            winner, diff = 'team1', num2 - num1
            if game.birdie_mode == 'multiplier':
                multiplier = 1 + best_under(t1_ids, hole)
        elif num2 < num1:
            winner, diff = 'team2', num1 - num2
            if game.birdie_mode == 'multiplier':
                multiplier = 1 + best_under(t2_ids, hole)
        else:
            winner, diff = 'halved', 0

        if winner == 'halved':
            if game.carryover:
                carry += 1
            rows.append(VegasHoleResult(
                game=game, hole_number=hole, team1_number=num1,
                team2_number=num2, winner='halved', points=0,
                multiplier=1, carry_count=carry))
        else:
            carry_mult = (carry + 1) if game.carryover else 1
            points = diff * multiplier * carry_mult
            rows.append(VegasHoleResult(
                game=game, hole_number=hole, team1_number=num1,
                team2_number=num2, winner=winner, points=points,
                multiplier=multiplier, carry_count=carry))
            carry = 0

    if rows:
        VegasHoleResult.objects.bulk_create(rows)

    game.status = (MatchStatus.PENDING if scored == 0
                   else MatchStatus.COMPLETE if scored >= 18
                   else MatchStatus.IN_PROGRESS)
    game.save(update_fields=['status'])
    return rows


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def vegas_summary(foursome) -> dict:
    """JSON-serialisable summary for the leaderboard / game screen."""
    bet_unit = float(foursome.round.bet_unit)
    try:
        game = foursome.vegas_game
    except VegasGame.DoesNotExist:
        # Empty/pending → mirror the mobile casual default (Strokes-Off Low) so
        # the setup screen lands there for a fresh game.
        return {
            'status': 'pending',
            'handicap': {'mode': HandicapMode.STROKES_OFF, 'net_percent': 100},
            'net_max_double_bogey': True,
            'birdie_mode': 'flip',
            'carryover': False,
            'teams': [],
            'holes': [],
            'money': {'bet_unit': bet_unit},
        }

    team_objs = {t.team_number: t for t in game.teams.prefetch_related('players')}

    def team_players(n):
        t = team_objs.get(n)
        if not t:
            return []
        return [{'player_id': p.id, 'name': p.name, 'short_name': p.short_name}
                for p in t.players.all()]

    holes = list(game.hole_results.all())
    t1_points = sum(h.points for h in holes if h.winner == 'team1')
    t2_points = sum(h.points for h in holes if h.winner == 'team2')

    # 1-to-1 per player: each player's money = the point differential × bet_unit.
    # Encode that via vs_average by feeding each player 2× their team total, then
    # let wager.settle apply the per-side (per-player) loss cap, zero-sum.
    money_by_team = {1: 0.0, 2: 0.0}
    p1, p2 = team_players(1), team_players(2)
    if (p1 and p2) and (t1_points or t2_points):
        sides = {}
        for pl in p1:
            sides[pl['player_id']] = 2 * t1_points
        for pl in p2:
            sides[pl['player_id']] = 2 * t2_points
        cfg = wager.WagerConfig(
            funding='per_point', settlement='vs_average',
            rate=Decimal(str(bet_unit)),
            cap=game.loss_cap,
        )
        settled = wager.settle(sides, cfg)
        # Players on a team settle to the same amount; read one per team.
        money_by_team[1] = float(settled.get(p1[0]['player_id'], 0))
        money_by_team[2] = float(settled.get(p2[0]['player_id'], 0))

    teams_out = [
        {'team_number': 1, 'players': p1, 'points': t1_points,
         'money': money_by_team[1]},
        {'team_number': 2, 'players': p2, 'points': t2_points,
         'money': money_by_team[2]},
    ]
    holes_out = [
        {'hole': h.hole_number, 'team1_number': h.team1_number,
         'team2_number': h.team2_number, 'winner': h.winner,
         'points': h.points, 'multiplier': h.multiplier,
         'carry': h.carry_count}
        for h in holes
    ]

    return {
        'status': game.status,
        'handicap': {'mode': game.handicap_mode, 'net_percent': game.net_percent},
        'net_max_double_bogey': game.net_max_double_bogey,
        'birdie_mode': game.birdie_mode,
        'carryover': game.carryover,
        'teams': teams_out,
        'holes': holes_out,
        'money': {'bet_unit': bet_unit},
    }
