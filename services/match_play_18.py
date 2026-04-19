import logging
from django.db import transaction
from core.models import HandicapMode
from games.models import MatchPlay18Game, MatchPlay18Team, MatchPlay18HoleResult, HoleScore
from services.scoring.handicap import build_score_index

logger = logging.getLogger(__name__)


@transaction.atomic
def setup_match_play_18(foursome, team1_ids: list[int], team2_ids: list[int],
                        handicap_mode: str = HandicapMode.NET, net_percent: int = 100) -> MatchPlay18Game:
    """
    Setup an 18-hole Match Play game for a foursome.
    Deletes any existing MatchPlay18Game for this foursome.
    """
    MatchPlay18Game.objects.filter(foursome=foursome).delete()

    game = MatchPlay18Game.objects.create(
        foursome=foursome,
        handicap_mode=handicap_mode,
        net_percent=net_percent,
        status='pending'
    )

    t1 = MatchPlay18Team.objects.create(game=game, team_number=1)
    t1.players.set(team1_ids)

    t2 = MatchPlay18Team.objects.create(game=game, team_number=2)
    t2.players.set(team2_ids)

    return game


@transaction.atomic
def calculate_match_play_18(foursome) -> MatchPlay18Game | None:
    """
    Calculates the hole-by-hole results for an 18-hole Match Play game.
    Supports early finish.
    """
    try:
        game = MatchPlay18Game.objects.prefetch_related('teams__players').get(foursome=foursome)
    except MatchPlay18Game.DoesNotExist:
        return None

    teams = list(game.teams.all())
    t1 = next((t for t in teams if t.team_number == 1), None)
    t2 = next((t for t in teams if t.team_number == 2), None)

    if not t1 or not t2:
        return game

    t1_pids = [p.id for p in t1.players.all()]
    t2_pids = [p.id for p in t2.players.all()]

    score_index = build_score_index(
        foursome,
        handicap_mode=game.handicap_mode,
        net_percent=game.net_percent,
    )

    MatchPlay18HoleResult.objects.filter(game=game).delete()

    holes_up = 0
    results = []
    finished_on_hole = None
    game_result = None

    for hole_num in range(1, 19):
        # Best net score for each team on this hole
        t1_scores = [score_index.get(pid, {}).get(hole_num) for pid in t1_pids]
        t1_valid  = [s for s in t1_scores if s is not None]
        t1_net    = min(t1_valid) if t1_valid else None

        t2_scores = [score_index.get(pid, {}).get(hole_num) for pid in t2_pids]
        t2_valid  = [s for s in t2_scores if s is not None]
        t2_net    = min(t2_valid) if t2_valid else None

        if t1_net is None or t2_net is None:
            break

        # Determine hole winner
        if t1_net < t2_net:
            winner = 'team1'
            holes_up += 1
        elif t2_net < t1_net:
            winner = 'team2'
            holes_up -= 1
        else:
            winner = 'halved'

        results.append(MatchPlay18HoleResult(
            game=game,
            hole_number=hole_num,
            team1_best_net=t1_net,
            team2_best_net=t2_net,
            winner=winner,
            holes_up_after=holes_up,
        ))

        holes_remaining = 18 - hole_num
        if abs(holes_up) > holes_remaining:
            finished_on_hole = hole_num
            game_result = 'team1' if holes_up > 0 else 'team2'
            break

    if results:
        MatchPlay18HoleResult.objects.bulk_create(results)

    holes_played = len(results)
    if finished_on_hole:
        game.status = 'complete'
        game.result = game_result
        game.finished_on_hole = finished_on_hole
    elif holes_played == 18:
        game.status = 'complete'
        game.finished_on_hole = 18
        if holes_up > 0:
            game.result = 'team1'
        elif holes_up < 0:
            game.result = 'team2'
        else:
            game.result = 'halved'
    elif holes_played > 0:
        game.status = 'in_progress'
        game.result = None
        game.finished_on_hole = None
    else:
        game.status = 'pending'
        game.result = None
        game.finished_on_hole = None

    game.save(update_fields=['status', 'result', 'finished_on_hole'])
    return game


def match_play_18_summary(foursome) -> dict | None:
    try:
        game = MatchPlay18Game.objects.prefetch_related(
            'teams__players', 'hole_results'
        ).get(foursome=foursome)
    except MatchPlay18Game.DoesNotExist:
        return None

    teams = list(game.teams.all())
    t1 = next((t for t in teams if t.team_number == 1), None)
    t2 = next((t for t in teams if t.team_number == 2), None)

    holes_out = [
        {
            'hole'   : hr.hole_number,
            't1_net' : hr.team1_best_net,
            't2_net' : hr.team2_best_net,
            'winner' : hr.winner,
            'margin' : hr.holes_up_after,
        }
        for hr in game.hole_results.all()
    ]

    return {
        'status': game.status,
        'result': game.result,
        'finished_on_hole': game.finished_on_hole,
        'handicap': {
            'mode': game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'team1': [p.name for p in t1.players.all()] if t1 else [],
        'team2': [p.name for p in t2.players.all()] if t2 else [],
        'holes': holes_out,
    }
