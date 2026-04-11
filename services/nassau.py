"""
services/nassau.py
------------------
Nassau calculator — 9-9-18 fixed-team best ball match play with
auto-press.

Rules
~~~~~
* Two fixed teams (2 players each) play all 18 holes together.
* Three simultaneous bets:
      Front 9   (holes  1–9)
      Back 9    (holes 10–18)
      Overall   (holes  1–18)
* Scoring: team best ball per hole using individual net scores.
  Lower team net wins the hole; ties halve the hole.
* Auto-press: when a team falls 2 or more holes down within a nine,
  the trailing team gets an automatic press.  The press covers ONLY
  the remaining holes in that nine (it does NOT extend into the other
  nine and is NOT a full new nine).
  Multiple presses per nine are possible.
* Press amount: NassauGame.press_pct × Round.bet_unit.
* Result labels: 'team1', 'team2', or 'halved'.

Public API
~~~~~~~~~~
    game    = setup_nassau(foursome, team1_ids, team2_ids, press_pct=0.50)
    result  = calculate_nassau(foursome)
    summary = nassau_summary(foursome)
"""

from django.db import transaction

from games.models import NassauGame, NassauTeam, NassauHoleScore, NassauPress
from scoring.models import HoleScore
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_nassau(foursome, team1_ids: list, team2_ids: list,
                 press_pct: float = 0.50) -> NassauGame:
    """
    Create or replace the NassauGame, teams, and hole score stubs for
    this foursome.

    team1_ids / team2_ids: lists of Player PKs.
    press_pct: fraction of Round.bet_unit for each press (default 0.50).

    Returns the NassauGame instance.
    """
    NassauGame.objects.filter(foursome=foursome).delete()

    game = NassauGame.objects.create(
        foursome  = foursome,
        press_pct = press_pct,
        status    = 'pending',
    )

    t1 = NassauTeam.objects.create(game=game, team_number=1)
    t1.players.set(team1_ids)

    t2 = NassauTeam.objects.create(game=game, team_number=2)
    t2.players.set(team2_ids)

    return game


# ---------------------------------------------------------------------------
# Calculator helpers
# ---------------------------------------------------------------------------

def _best_net(team: NassauTeam, hole_num: int, score_index: dict) -> int | None:
    """Lowest net score from this team's players on hole_num."""
    player_ids = list(team.players.values_list('id', flat=True))
    nets = [
        score_index[pid][hole_num]
        for pid in player_ids
        if pid in score_index and hole_num in score_index[pid]
    ]
    return min(nets) if nets else None


def _resolve_result(holes_up: int) -> str:
    """Convert a final holes_up margin into a result string."""
    if holes_up > 0:
        return 'team1'
    elif holes_up < 0:
        return 'team2'
    return 'halved'


# ---------------------------------------------------------------------------
# Main calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_nassau(foursome) -> NassauGame | None:
    """
    Calculate NassauHoleScore rows, detect auto-presses, and resolve
    the front-9, back-9, overall, and press results.

    Safe to call repeatedly — all NassauHoleScore and NassauPress rows
    are replaced on each call.

    Returns the updated NassauGame instance, or None if no game exists.
    """
    try:
        game = NassauGame.objects.prefetch_related('teams__players').get(
            foursome=foursome
        )
    except NassauGame.DoesNotExist:
        return None

    teams = list(game.teams.all())
    t1 = next(t for t in teams if t.team_number == 1)
    t2 = next(t for t in teams if t.team_number == 2)

    # Build score index: player_id → hole_number → net_score
    hole_scores = (
        HoleScore.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .exclude(net_score=None)
        .values('player_id', 'hole_number', 'net_score')
    )
    score_index: dict = {}
    for hs in hole_scores:
        score_index.setdefault(hs['player_id'], {})[hs['hole_number']] = hs['net_score']

    # Delete old calculated data
    NassauHoleScore.objects.filter(game=game).delete()
    NassauPress.objects.filter(game=game).delete()

    # Running totals
    front9_up = 0    # positive = team1 leading front 9
    back9_up  = 0    # positive = team1 leading back 9
    overall_up = 0   # positive = team1 leading overall

    # Press tracking per nine: list of dicts
    #   {'start': int, 'end': int, 'nine': 'front'|'back', 'margin': int,
    #    'trigger_hole': int, 'triggered': bool}
    active_presses: list = []
    completed_presses: list = []

    # Which holes belong to which nine
    front_holes = range(1, 10)
    back_holes  = range(10, 19)

    hole_score_objs = []

    for hole_num in range(1, 19):
        t1_net = _best_net(t1, hole_num, score_index)
        t2_net = _best_net(t2, hole_num, score_index)

        if t1_net is None or t2_net is None:
            break  # stop at first incomplete hole

        # Hole result
        if t1_net < t2_net:
            winner = 'team1'
            delta  = 1
        elif t2_net < t1_net:
            winner = 'team2'
            delta  = -1
        else:
            winner = 'halved'
            delta  = 0

        overall_up += delta

        # Per-nine margin tracking
        if hole_num in front_holes:
            nine_key = 'front'
            front9_up += delta
            nine_margin = front9_up
            nine_end    = 9
        else:
            nine_key = 'back'
            back9_up += delta
            nine_margin = back9_up
            nine_end    = 18

        # ----- Update active presses for this nine -----
        # Each press tracks its own running margin
        new_active = []
        for press in active_presses:
            if press['nine'] != nine_key:
                new_active.append(press)
                continue
            press['margin'] += delta
            holes_left_in_press = press['end'] - hole_num
            if hole_num == press['end'] or abs(press['margin']) > holes_left_in_press:
                # Press is complete
                completed_presses.append(press)
            else:
                new_active.append(press)
        active_presses = new_active

        # ----- Auto-press trigger -----
        # Triggered when the trailing team goes 2 down within the nine,
        # AND there are holes remaining in that nine,
        # AND no press was already triggered at this exact hole.
        holes_left_in_nine = nine_end - hole_num
        already_triggered = any(
            p['trigger_hole'] == hole_num and p['nine'] == nine_key
            for p in active_presses + completed_presses
        )
        if abs(nine_margin) >= 2 and holes_left_in_nine > 0 and not already_triggered:
            new_press = {
                'nine'         : nine_key,
                'trigger_hole' : hole_num,
                'start'        : hole_num + 1,
                'end'          : nine_end,
                'margin'       : 0,   # press starts fresh from next hole
            }
            active_presses.append(new_press)

        hole_score_objs.append(NassauHoleScore(
            game           = game,
            hole_number    = hole_num,
            team1_best_net = t1_net,
            team2_best_net = t2_net,
            winner         = winner,
            front9_up_after = front9_up if hole_num in front_holes else None,
            back9_up_after  = back9_up  if hole_num in back_holes  else None,
        ))

    # Any press still active when we ran out of holes is also complete
    completed_presses.extend(active_presses)

    NassauHoleScore.objects.bulk_create(hole_score_objs)

    # Persist press rows
    press_objs = []
    for p in completed_presses:
        press_objs.append(NassauPress(
            game             = game,
            nine             = p['nine'],
            triggered_on_hole = p['trigger_hole'],
            start_hole       = p['start'],
            end_hole         = p['end'],
            result           = _resolve_result(p['margin']),
            holes_up         = p['margin'],
        ))
    NassauPress.objects.bulk_create(press_objs)

    # Determine nine / overall results
    holes_played = len(hole_score_objs)
    front_complete   = holes_played >= 9
    back_complete    = holes_played >= 18
    overall_complete = holes_played >= 18

    game.front9_result  = _resolve_result(front9_up)   if front_complete   else None
    game.back9_result   = _resolve_result(back9_up)    if back_complete    else None
    game.overall_result = _resolve_result(overall_up)  if overall_complete else None

    if overall_complete:
        game.status = 'complete'
    elif holes_played > 0:
        game.status = 'in_progress'
    else:
        game.status = 'pending'

    game.save()
    return game


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def nassau_summary(foursome) -> dict | None:
    """
    Return a summary of the Nassau game:

    {
        'bet_unit'     : Decimal,        # from Round.bet_unit
        'press_pct'    : Decimal,        # e.g. 0.50
        'press_value'  : Decimal,        # bet_unit * press_pct
        'teams'        : {
            'team1': [player_name, ...],
            'team2': [player_name, ...],
        },
        'front9'  : { 'result': 'team1'|'team2'|'halved'|None, 'margin': int },
        'back9'   : { 'result': ..., 'margin': int },
        'overall' : { 'result': ..., 'margin': int },
        'presses' : [
            {
                'nine'    : 'front'|'back',
                'trigger' : int,           # hole press was triggered on
                'holes'   : 'X–Y',         # e.g. '7–9'
                'result'  : 'team1'|'team2'|'halved'|None,
                'margin'  : int,
            },
            ...
        ],
        'payouts'  : {
            # Net dollar amounts: positive = team1 owes team2, negative = team2 owes
            # (caller can decide display direction)
            'front9'  : Decimal,
            'back9'   : Decimal,
            'overall' : Decimal,
            'presses' : Decimal,
            'total'   : Decimal,
        },
        'holes'    : [
            {
                'hole'   : int,
                'winner' : 'team1'|'team2'|'halved',
                't1_net' : int,
                't2_net' : int,
                'front9_margin' : int|None,
                'back9_margin'  : int|None,
            },
            ...
        ],
    }
    """
    try:
        game = NassauGame.objects.prefetch_related('teams__players').get(
            foursome=foursome
        )
    except NassauGame.DoesNotExist:
        return None

    teams = {t.team_number: t for t in game.teams.all()}
    bet_unit    = foursome.round.bet_unit
    press_value = bet_unit * game.press_pct

    # Payout helper: +ve means team1 wins that unit
    def _payout(result: str | None) -> object:
        from decimal import Decimal
        if result == 'team1':
            return bet_unit
        if result == 'team2':
            return -bet_unit
        return Decimal('0')

    def _press_payout(result: str | None) -> object:
        from decimal import Decimal
        if result == 'team1':
            return press_value
        if result == 'team2':
            return -press_value
        return Decimal('0')

    presses_qs = NassauPress.objects.filter(game=game).order_by('triggered_on_hole')
    presses_out = [
        {
            'nine'    : p.nine,
            'trigger' : p.triggered_on_hole,
            'holes'   : f"{p.start_hole}–{p.end_hole}",
            'result'  : p.result,
            'margin'  : p.holes_up,
        }
        for p in presses_qs
    ]

    press_total = sum(_press_payout(p['result']) for p in presses_out)

    front9_pay  = _payout(game.front9_result)
    back9_pay   = _payout(game.back9_result)
    overall_pay = _payout(game.overall_result)

    holes_qs = NassauHoleScore.objects.filter(game=game).order_by('hole_number')
    holes_out = [
        {
            'hole'          : h.hole_number,
            'winner'        : h.winner,
            't1_net'        : h.team1_best_net,
            't2_net'        : h.team2_best_net,
            'front9_margin' : h.front9_up_after,
            'back9_margin'  : h.back9_up_after,
        }
        for h in holes_qs
    ]

    # Final nine margins from last recorded hole score
    front9_margin = next(
        (h['front9_margin'] for h in reversed(holes_out) if h['front9_margin'] is not None), 0
    )
    back9_margin = next(
        (h['back9_margin'] for h in reversed(holes_out) if h['back9_margin'] is not None), 0
    )
    overall_margin = (front9_margin or 0) + (back9_margin or 0)

    return {
        'bet_unit'    : bet_unit,
        'press_pct'   : game.press_pct,
        'press_value' : press_value,
        'teams'       : {
            'team1': [p.name for p in teams[1].players.all()] if 1 in teams else [],
            'team2': [p.name for p in teams[2].players.all()] if 2 in teams else [],
        },
        'front9'  : {'result': game.front9_result,  'margin': front9_margin},
        'back9'   : {'result': game.back9_result,   'margin': back9_margin},
        'overall' : {'result': game.overall_result, 'margin': overall_margin},
        'presses' : presses_out,
        'payouts' : {
            'front9'  : front9_pay,
            'back9'   : back9_pay,
            'overall' : overall_pay,
            'presses' : press_total,
            'total'   : front9_pay + back9_pay + overall_pay + press_total,
        },
        'holes'   : holes_out,
    }
