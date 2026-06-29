"""
services/fourball.py
--------------------
Fourball calculator — a single 18-hole 2v2 best-ball match-play game
within a foursome.

Rules
~~~~~
* Exactly four real players, split into two fixed teams of two at setup.
* Each player plays their own ball.  A team's score for a hole is the
  BETTER (lower) of its two partners' adjusted scores (best ball).
* Lower team score wins the hole (+1 up for that team); a tie halves it.
* The match closes out early when one team leads by more holes than remain
  (dormie / "3&2"); holes after the close-out don't count.
* Handicap modes (per-game):
      net          — each player's playing handicap (× net_percent) allocated
                     by hole stroke index; score = gross − strokes.
      gross        — raw gross scores, no strokes.
      strokes_off  — the low-handicap player in the foursome plays to 0 and
                     everyone else gets round((own − low) × net_percent/100)
                     strokes allocated by stroke index across all 18 holes.
* Settlement is a single match bet: the winning team collects bet_amount per
  player (each winner +bet_amount, each loser −bet_amount, zero-sum); a
  halved match is a push.

Public API
~~~~~~~~~~
    game    = setup_fourball(foursome, team1_ids, team2_ids, ...)
    game    = calculate_fourball(foursome)
    summary = fourball_summary(foursome)
"""

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import FourballGame, FourballTeam, FourballHoleResult
from scoring.handicap import build_score_index, _strokes_on_hole
from scoring.models import HoleScore


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_fourball(
    foursome,
    team1_ids: list,
    team2_ids: list,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    bet_amount=None,
) -> FourballGame:
    """
    Create (or replace) the FourballGame for *foursome*.

    team1_ids / team2_ids must each hold exactly two real player ids with no
    overlap.  bet_amount defaults to the round's bet_unit when not supplied.

    Safe to call again — the existing game (and its teams / hole results) is
    replaced.  Returns the new FourballGame.
    """
    t1 = list(dict.fromkeys(team1_ids))   # de-dupe, preserve order
    t2 = list(dict.fromkeys(team2_ids))
    if len(t1) != 2 or len(t2) != 2:
        raise ValueError("Each Fourball team must have exactly 2 players.")
    if set(t1) & set(t2):
        raise ValueError("A player cannot be on both Fourball teams.")

    # Validate the ids belong to this foursome's real roster.
    roster = set(
        foursome.memberships
        .filter(player__is_phantom=False)
        .values_list('player_id', flat=True)
    )
    picked = set(t1) | set(t2)
    if not picked <= roster:
        raise ValueError("All Fourball players must belong to this foursome.")

    net_percent = max(0, min(200, int(net_percent)))
    if handicap_mode not in (HandicapMode.NET, HandicapMode.GROSS,
                             HandicapMode.STROKES_OFF):
        handicap_mode = HandicapMode.NET

    if bet_amount is None:
        bet_amount = foursome.round.bet_unit

    FourballGame.objects.filter(foursome=foursome).delete()

    game = FourballGame.objects.create(
        foursome      = foursome,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        bet_amount    = bet_amount,
        status        = MatchStatus.PENDING,
    )

    g_t1 = FourballTeam.objects.create(game=game, team_number=1)
    g_t1.players.set(t1)
    g_t2 = FourballTeam.objects.create(game=game, team_number=2)
    g_t2.players.set(t2)

    return game


# ---------------------------------------------------------------------------
# Score index (net / gross / strokes-off over the full 18-hole match)
# ---------------------------------------------------------------------------

def _fourball_score_index(foursome, handicap_mode: str, net_percent: int) -> dict:
    """
    Build {player_id: {hole_number: score_to_compare}} for the match.

    NET / GROSS defer to scoring.handicap.build_score_index.  STROKES_OFF is
    a single-match, full-round allocation (no Sixes per-segment spreading):
    the low playing handicap plays to 0 and everyone else gets
    round((own − low) × net_percent/100) strokes allocated by hole stroke
    index across all 18 holes.  Match play decides each hole on the actual
    net score, so the stroke-play net-double-bogey cap is intentionally off.
    """
    if handicap_mode != HandicapMode.STROKES_OFF:
        return build_score_index(
            foursome,
            handicap_mode=handicap_mode,
            net_percent=net_percent,
        )

    memberships = [
        m for m in foursome.memberships.select_related('player', 'tee').all()
        if not m.player.is_phantom
    ]
    phcps = [m.playing_handicap for m in memberships
             if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0
    player_so = {
        m.player_id: round(max(0, (m.playing_handicap or 0) - low)
                           * net_percent / 100)
        for m in memberships
    }
    member_by_pid = {m.player_id: m for m in memberships}

    rows = (
        HoleScore.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    )
    index: dict = {}
    for r in rows:
        pid = r['player_id']
        m   = member_by_pid.get(pid)
        so  = player_so.get(pid, 0)
        if m is None or m.tee_id is None or so <= 0:
            value = r['gross_score']
        else:
            si      = m.tee.hole(r['hole_number']).get('stroke_index', 18)
            value   = r['gross_score'] - _strokes_on_hole(so, si)
        index.setdefault(pid, {})[r['hole_number']] = value
    return index


def _team_best(team_pids: list, hole: int, index: dict):
    """Best (lowest) score among a team's players on *hole*, or None if no
    team member has a score yet (lone survivor after a withdrawal still
    works — min of the present scores)."""
    nets = [index[p][hole] for p in team_pids
            if p in index and hole in index[p]]
    return min(nets) if nets else None


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_fourball(foursome) -> FourballGame | None:
    """
    Recompute FourballHoleResult rows and the match result for *foursome*.

    Idempotent — hole results are replaced each call.  Returns the
    FourballGame, or None if none is set up.
    """
    try:
        game = (
            FourballGame.objects
            .prefetch_related('teams__players')
            .get(foursome=foursome)
        )
    except FourballGame.DoesNotExist:
        return None

    teams = {t.team_number: t for t in game.teams.all()}
    t1, t2 = teams.get(1), teams.get(2)
    if not t1 or not t2:
        return game

    t1_pids = list(t1.players.values_list('id', flat=True))
    t2_pids = list(t2.players.values_list('id', flat=True))

    index = _fourball_score_index(
        foursome, game.handicap_mode, game.net_percent,
    )

    FourballHoleResult.objects.filter(game=game).delete()

    holes_up    = 0          # positive = Team 1 up
    finished_on = None
    results     = []

    for hole in range(1, 19):
        t1_net = _team_best(t1_pids, hole, index)
        t2_net = _team_best(t2_pids, hole, index)
        if t1_net is None or t2_net is None:
            break  # hole not fully scored yet — stop here

        if t1_net < t2_net:
            holes_up += 1
            winner = 1
        elif t2_net < t1_net:
            holes_up -= 1
            winner = 2
        else:
            winner = None

        remaining = 18 - hole
        if abs(holes_up) > remaining:
            finished_on = hole

        results.append(FourballHoleResult(
            game                = game,
            hole_number         = hole,
            team1_net           = t1_net,
            team2_net           = t2_net,
            winning_team_number = winner,
            holes_up_after      = holes_up,
        ))
        if finished_on:
            break

    FourballHoleResult.objects.bulk_create(results)

    # ── Resolve match status / result ──────────────────────────────────────
    holes_played = len(results)
    t1.is_winner = t2.is_winner = False

    if holes_played == 0:
        game.status = MatchStatus.PENDING
        game.result = None
    elif holes_played < 18 and finished_on is None:
        game.status = MatchStatus.IN_PROGRESS
        game.result = None
    else:
        # Complete: all 18 played OR an early close-out.
        if holes_up > 0:
            game.status, game.result = MatchStatus.COMPLETE, 'team1'
            t1.is_winner = True
        elif holes_up < 0:
            game.status, game.result = MatchStatus.COMPLETE, 'team2'
            t2.is_winner = True
        else:
            game.status, game.result = MatchStatus.HALVED, 'halved'

    game.holes_up_after_final = holes_up
    game.finished_on_hole     = finished_on
    game.save(update_fields=['status', 'result', 'holes_up_after_final',
                             'finished_on_hole'])
    t1.save(update_fields=['is_winner'])
    t2.save(update_fields=['is_winner'])

    return game


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def _result_label(game: FourballGame) -> str:
    """Match-play notation: '3&2', '1 up', 'All Square', or '—' in progress."""
    if game.status == MatchStatus.PENDING:
        return '—'
    margin = abs(game.holes_up_after_final)
    if game.status == MatchStatus.HALVED:
        return 'All Square'
    if game.status != MatchStatus.COMPLETE:
        # In progress — show the live margin.
        if margin == 0:
            return 'All Square'
        side = 'Team 1' if game.holes_up_after_final > 0 else 'Team 2'
        return f'{side} {margin} up'
    side = 'Team 1' if game.holes_up_after_final > 0 else 'Team 2'
    if game.finished_on_hole is not None and game.finished_on_hole < 18:
        to_play = 18 - game.finished_on_hole
        return f'{side} wins {margin}&{to_play}'
    return f'{side} wins {margin} up'


def fourball_summary(foursome) -> dict | None:
    """
    Return a Fourball summary dict, or None if no game is set up:

    {
      'status'       : 'pending'|'in_progress'|'complete'|'halved',
      'result'       : 'team1'|'team2'|'halved'|None,
      'result_label' : '3&2' / 'All Square' / '—',
      'finished_on_hole': int|None,
      'handicap'     : {'mode': str, 'net_percent': int},
      'overall'      : {'holes_up': int, 'leader': 'team1'|'team2'|None},
      'team1' / 'team2': {'players':[names], 'short_names':[...],
                          'player_ids':[...], 'is_winner': bool},
      'holes'        : [{'hole', 't1_net', 't2_net', 'winner':'T1'|'T2'|'Halved',
                         'margin'}],
      'money'        : {'bet_amount': float, 'by_player': [{'name','amount'}]},
      'players'      : [{'player_id','name','short_name'}],   # scorecard order
      'scorecard'    : [{'hole','par','scores':[{player_id,gross,strokes}]}],
    }
    """
    try:
        game = (
            FourballGame.objects
            .prefetch_related('teams__players', 'hole_results')
            .get(foursome=foursome)
        )
    except FourballGame.DoesNotExist:
        return None

    teams = {t.team_number: t for t in game.teams.all()}
    t1, t2 = teams.get(1), teams.get(2)

    def _team_block(team):
        players = list(team.players.all()) if team else []
        return {
            'players'    : [p.name for p in players],
            'short_names': [p.short_name for p in players],
            'player_ids' : [p.id for p in players],
            'is_winner'  : bool(team.is_winner) if team else False,
        }

    holes_out = []
    for hr in game.hole_results.all():
        if hr.winning_team_number == 1:
            w = 'T1'
        elif hr.winning_team_number == 2:
            w = 'T2'
        else:
            w = 'Halved'
        holes_out.append({
            'hole'   : hr.hole_number,
            't1_net' : hr.team1_net,
            't2_net' : hr.team2_net,
            'winner' : w,
            'margin' : hr.holes_up_after,
        })

    # ── Money: single match bet, per player ────────────────────────────────
    bet_amount = float(game.bet_amount or 0)
    money = {}
    for tn, team in ((1, t1), (2, t2)):
        if not team:
            continue
        for p in team.players.all():
            if p.is_phantom:
                continue
            money.setdefault(p.id, {'name': p.name, 'amount': 0.0})
    if game.result in ('team1', 'team2'):
        win_team  = t1 if game.result == 'team1' else t2
        lose_team = t2 if game.result == 'team1' else t1
        for p in (win_team.players.all() if win_team else []):
            if not p.is_phantom:
                money[p.id]['amount'] += bet_amount
        for p in (lose_team.players.all() if lose_team else []):
            if not p.is_phantom:
                money[p.id]['amount'] -= bet_amount
    money_out = sorted(money.values(), key=lambda e: (-e['amount'], e['name']))

    # ── Per-hole gross scorecard grid (mirrors the Sixes card) ─────────────
    real_members = [
        m for m in foursome.memberships.select_related('player', 'tee').all()
        if not m.player.is_phantom
    ]
    players_out = [
        {'player_id': m.player_id, 'name': m.player.name,
         'short_name': m.player.short_name}
        for m in real_members
    ]
    real_pids = [m.player_id for m in real_members]
    tee       = real_members[0].tee if real_members else None
    par_by_hole = {h.get('number'): h.get('par')
                   for h in ((tee.holes if tee else None) or [])}
    score_by = {}
    for hs in HoleScore.objects.filter(foursome=foursome,
                                       player_id__in=real_pids):
        score_by[(hs.player_id, hs.hole_number)] = (
            hs.gross_score, hs.handicap_strokes or 0)
    scorecard = []
    for hn in range(1, 19):
        scored = [pid for pid in real_pids
                  if score_by.get((pid, hn), (None, 0))[0]]
        if not scored:
            continue
        scorecard.append({
            'hole'  : hn,
            'par'   : par_by_hole.get(hn),
            'scores': [
                {'player_id': pid,
                 'gross'    : score_by[(pid, hn)][0],
                 'strokes'  : score_by[(pid, hn)][1]}
                for pid in scored
            ],
        })

    leader = None
    if game.holes_up_after_final > 0:
        leader = 'team1'
    elif game.holes_up_after_final < 0:
        leader = 'team2'

    return {
        'status'           : game.status,
        'result'           : game.result,
        'result_label'     : _result_label(game),
        'finished_on_hole' : game.finished_on_hole,
        'handicap'         : {
            'mode'        : game.handicap_mode,
            'net_percent' : game.net_percent,
        },
        'overall'          : {
            'holes_up' : game.holes_up_after_final,
            'leader'   : leader,
        },
        'team1'            : _team_block(t1),
        'team2'            : _team_block(t2),
        'holes'            : holes_out,
        'money'            : {
            'bet_amount' : bet_amount,
            'by_player'  : money_out,
        },
        'players'          : players_out,
        'scorecard'        : scorecard,
    }
