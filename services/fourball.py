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
from core.handicap_math import round_half_up


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
        m.player_id: round_half_up(max(0, (m.playing_handicap or 0) - low)
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

    # Walk the holes in PLAY ORDER (start hole + wraparound), not 1→18, so a
    # mid-course / shotgun / partial round accrues match state from the first
    # hole actually played. Reduces to 1..18 for a normal round. The match-play
    # loop still stops at the first hole not yet scored (in play order).
    from services.hole_plan import play_order
    order = play_order(foursome.round, foursome)
    n = len(order)

    holes_up    = 0          # positive = Team 1 up
    finished_on = None
    results     = []

    for pos, hole in enumerate(order):
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

        remaining = n - 1 - pos          # holes left to play after this one
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
    elif holes_played < n and finished_on is None:
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

def _result_label(game: FourballGame, holes_to_play: int | None = None) -> str:
    """Match-play notation: '3&2', '1 up', 'All Square', or '—' in progress.

    ``holes_to_play`` is the number of holes left when the match closed out,
    computed from PLAY ORDER by the caller (so a mid-course start gets the right
    '&M'). Falls back to ``18 - finished_on_hole`` (correct for a normal round).
    """
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
    if game.finished_on_hole is not None:
        to_play = (holes_to_play if holes_to_play is not None
                   else 18 - game.finished_on_hole)
        if to_play > 0:
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
      'holes_to_play': int|None,   # holes left at close-out, in PLAY ORDER
      'handicap'     : {'mode': str, 'net_percent': int},
      'overall'      : {'holes_up': int, 'leader': 'team1'|'team2'|None},
      'team1' / 'team2': {'players':[names], 'short_names':[...],
                          'player_ids':[...], 'is_winner': bool},
      'holes'        : [{'hole', 't1_net', 't2_net', 'winner':'T1'|'T2'|'Halved',
                         'margin'}],
      'money'        : {'bet_amount': float,
                        'by_player': [{'player_id','name','amount'}]},
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

    # Holes remaining when the match closed out, in PLAY ORDER, for the '&M'
    # close-out notation (right even for a mid-course / shotgun start).
    from services.hole_plan import play_order
    _order = play_order(foursome.round, foursome)
    _holes_to_play = None
    if game.finished_on_hole is not None:
        try:
            _holes_to_play = len(_order) - 1 - _order.index(game.finished_on_hole)
        except ValueError:
            _holes_to_play = max(0, 18 - game.finished_on_hole)

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
            money.setdefault(
                p.id, {'player_id': p.id, 'name': p.name, 'amount': 0.0})
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

    # ── Per-hole scorecard grid (dots + stroke index + hole-winner tint) ────
    # Mirrors Nassau: every hole in play (play order) with par + stroke index
    # (so an observer sees where strokes fall), per-player gross + strokes for
    # the dots, and the winning team per hole so the card can tint it.
    real_members = [
        m for m in foursome.memberships.select_related('player', 'tee').all()
        if not m.player.is_phantom
    ]
    real_pids = [m.player_id for m in real_members]
    team_of = {}
    for _tn, _tm in teams.items():
        if _tm:
            for _p in _tm.players.all():
                team_of[_p.id] = _tn
    players_out = [
        {'player_id': m.player_id, 'name': m.player.name,
         'short_name': m.player.short_name,
         'team': team_of.get(m.player_id)}
        for m in real_members
    ]
    tee       = real_members[0].tee if real_members else None
    par_by_hole = {h.get('number'): h.get('par')
                   for h in ((tee.holes if tee else None) or [])}
    si_by_hole  = {h.get('number'): h.get('stroke_index')
                   for h in ((tee.holes if tee else None) or [])}
    # Net honours the game's handicap mode (incl. strokes-off), so gross − net
    # is the real per-hole allocation — not the generic stored handicap_strokes.
    net_index = _fourball_score_index(
        foursome, game.handicap_mode, game.net_percent)
    gross_by = {}
    for hs in HoleScore.objects.filter(foursome=foursome,
                                       player_id__in=real_pids):
        gross_by[(hs.player_id, hs.hole_number)] = hs.gross_score
    winner_by_hole = {
        h['hole']: (1 if h['winner'] == 'T1'
                    else 2 if h['winner'] == 'T2' else None)
        for h in holes_out
    }
    holes_in_play = _order or list(range(1, 19))
    # **The dots have to be on the holes AHEAD of you** — they say where the
    # strokes fall, which is only useful before the hole is played. This read
    # `gross - net`, so an unscored hole had no gross, no net and no dots.
    # Reported from a fourball on 1 Oct 2026, strokes-off at 100%: dots on the
    # holes already in and nothing on the rest.
    #
    # `full_round_strokes` is the allocator the match LOCK CARD already uses
    # for this game, so the card and the ribbon cannot disagree, and it is the
    # same anchor the engine measures strokes-off against. (It allocates over
    # a full 18 rather than scaling for a part round — fourball is an 18-hole
    # match, so that is not a case it has.)
    from services.live_activity_registry import full_round_strokes
    strokes_by = full_round_strokes(
        foursome,
        handicap_mode=game.handicap_mode,
        net_percent=game.net_percent,
        holes=holes_in_play,
    )
    scorecard = []
    for hn in holes_in_play:
        row_scores = []
        for pid in real_pids:
            g = gross_by.get((pid, hn))
            row_scores.append({
                'player_id': pid, 'gross': g,
                'strokes'  : strokes_by.get(pid, {}).get(hn, 0),
            })
        scorecard.append({
            'hole'        : hn,
            'par'         : par_by_hole.get(hn),
            'stroke_index': si_by_hole.get(hn),
            'winner_id'   : None,
            'winner_team' : winner_by_hole.get(hn),
            'scores'      : row_scores,
        })

    leader = None
    if game.holes_up_after_final > 0:
        leader = 'team1'
    elif game.holes_up_after_final < 0:
        leader = 'team2'

    return {
        'status'           : game.status,
        'result'           : game.result,
        'result_label'     : _result_label(game, _holes_to_play),
        'finished_on_hole' : game.finished_on_hole,
        # Holes left when it closed out — the `&M` in "3&2". Computed HERE
        # because only the server knows the group's play order; a client doing
        # `18 - finished_on_hole` is right on a round from the 1st and wrong on
        # every shotgun. None while the match is still live.
        'holes_to_play'    : _holes_to_play,
        # Holes COMPLETED (match-play "thru N") — a count, not a hole number, so
        # it reads right for a mid-course / shotgun start (played 7–12 = thru 6).
        'holes_played'     : len(holes_out),
        # The group's CURRENT hole number = the last hole played in PLAY ORDER
        # (robust vs. relying on hole_results row order). Drives the leaderboard
        # grid's scroll/highlight so it follows play even after wrapping (…18→1).
        'current_hole'     : _order[len(holes_out) - 1] if holes_out else 0,
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
        'holes_in_play'    : holes_in_play,
    }


# ---------------------------------------------------------------------------
# Score-entry card — `~/Downloads/handoff-fourball-score-entry`
# ---------------------------------------------------------------------------

def fourball_hole_card(foursome, hole: int) -> dict:
    """Everything the Fourball score-entry screen draws for ONE hole.

    **It renders the engine.** The best ball, the hole, the match state and
    the close-out are `calculate_fourball`'s; the `&M` in `3&2` especially,
    because only the server knows the group's play order.

    The one thing this adds is **which ball counted** — the handoff's
    `counts: Paul · Larry`. The engine stores the side's best NET and not
    whose it was, so the names come from the same `_fourball_score_index`
    the engine measured with, compared against the same `_team_best`. Two
    golfers tie for it often enough that it is a list.

    **Holes after a close-out carry no team score at all** (`counts_for_card`
    false). The engine stops writing rows there, which is the rule; this says
    so rather than leaving the card to infer it from a missing row.

    Returns `{}` when the game is not set up, so a caller can test the key.
    Gated on the GAME, not its status — no card means no keypad, which is the
    failure Points, Rabbit, Sixes, Wolf and Vegas each hit in turn.
    """
    from services.hole_plan import play_order
    from services.player_labels import first_names
    from services.live_activity_registry import full_round_strokes

    summary = fourball_summary(foursome)
    if not summary:
        return {}
    try:
        game = (FourballGame.objects
                .prefetch_related('teams__players').get(foursome=foursome))
    except FourballGame.DoesNotExist:        # pragma: no cover - summary implies one
        return {}

    teams = {t.team_number: t for t in game.teams.all()}
    if not teams.get(1) or not teams.get(2):
        return {}

    order = play_order(foursome.round, foursome) or list(range(1, 19))
    if hole not in order:
        return {}
    pos = order.index(hole)

    members = [m for m in foursome.memberships.select_related('player', 'tee')
               if not m.player.is_phantom]
    by_pid = {m.player_id: m.player for m in members}
    rank = {m.player_id: i for i, m in enumerate(members)}
    # **In MEMBERSHIP order**, which is the order the names appear on the
    # card — `FourballTeam.players` is a many-to-many and comes back in
    # whatever order the database gives.
    side_ids = {n: sorted((p.id for p in t.players.all() if not p.is_phantom),
                          key=lambda pid: rank.get(pid, 99))
                for n, t in teams.items()}
    label = first_names(by_pid)

    index = _fourball_score_index(
        foursome, game.handicap_mode, game.net_percent)
    strokes_by = full_round_strokes(
        foursome, handicap_mode=game.handicap_mode,
        net_percent=game.net_percent, holes=order)
    gross_by = {
        r['player_id']: r['gross_score']
        for r in (HoleScore.objects
                  .filter(foursome=foursome, hole_number=hole,
                          player_id__in=list(by_pid))
                  .exclude(gross_score=None)
                  .values('player_id', 'gross_score'))
    }

    tee = next((m.tee for m in members if m.tee_id), None)
    geometry = tee.hole(hole) if tee else {}

    per_hole = {h['hole']: h for h in (summary.get('holes') or [])}
    entry    = per_hole.get(hole) or {}

    # **Does this hole count?** The engine stops writing rows at the
    # close-out, so a hole past it has no team score — only each golfer's own
    # card, and anything the group decides to play for.
    finished_on = summary.get('finished_on_hole')
    closed_pos  = (order.index(finished_on)
                   if finished_on is not None and finished_on in order
                   else None)
    # **Closed out EARLY is a different thing from decided on the last hole**,
    # and the engine sets `finished_on_hole` for both — a 1 UP win on the 18th
    # leaves no holes to play, so `abs(holes_up) > remaining` is true there
    # too. Only the early one takes the `3&2` wording and leaves holes that
    # stop counting.
    closed_out = closed_pos is not None and closed_pos < len(order) - 1
    counts_for_card = closed_out and pos > closed_pos

    rows = []
    for n in (1, 2):
        for pid in side_ids[n]:
            rows.append({
                'player_id'      : pid,
                'name'           : by_pid[pid].name,
                'short'          : by_pid[pid].short_name,
                'first'          : label.get(pid, ''),
                'course_handicap': next(
                    (m.course_handicap for m in members
                     if m.player_id == pid), None),
                'strokes'        : strokes_by.get(pid, {}).get(hole, 0),
                'gross'          : gross_by.get(pid),
                'net'            : index.get(pid, {}).get(hole),
                'side'           : n,
                'counted'        : False,
            })
    by_row = {r['player_id']: r for r in rows}

    sides = []
    for n in (1, 2):
        best = _team_best(side_ids[n], hole, index)
        counts = [pid for pid in side_ids[n]
                  if index.get(pid, {}).get(hole) == best] if best is not None \
            else []
        # Only a hole that COUNTS has a ball that counted — after a close-out
        # there is no team score to be the best of.
        if not counts_for_card:
            for pid in counts:
                by_row[pid]['counted'] = True
        result = None
        w = entry.get('winner')
        if w == 'Halved':
            result = 'halved'
        elif w in ('T1', 'T2'):
            result = 'won' if w == f'T{n}' else 'lost'
        sides.append({
            'side'      : n,
            'label'     : ' + '.join(label.get(pid, '') for pid in side_ids[n]),
            'player_ids': list(side_ids[n]),
            'best'      : best,
            'counts'    : [label.get(pid, '') for pid in counts],
            'result'    : result,
        })

    # **Every golfer still playing has a score.** After a close-out the
    # scorer may mark a golfer as picked up, which no row on this server can
    # express — the tray counts what it has and says so.
    scored = sum(1 for r in rows if r['gross'] is not None)
    hole_complete = scored == len(rows)

    # ── The match card ──────────────────────────────────────────────────────
    holes_up = entry.get('margin')
    if holes_up is None:
        # Not this hole's row — the standing coming INTO it, which is what a
        # part-scored hole should report.
        prior = [per_hole[h] for h in order[:pos] if h in per_hole]
        holes_up = prior[-1]['margin'] if prior else 0
    leader = 1 if holes_up > 0 else (2 if holes_up < 0 else None)
    margin = abs(holes_up)
    played = len([h for h in order[:pos + 1] if h in per_hole])
    to_play = len(order) - 1 - pos

    is_final = (pos == len(order) - 1 and hole in per_hole) or (
        closed_out and pos >= closed_pos)
    lead_label = sides[leader - 1]['label'] if leader else ''

    if closed_out and pos >= closed_pos:
        # The `&M` is the engine's, because only it knows the group's play
        # order — `18 - finished_on_hole` is right from the 1st tee and wrong
        # off every shotgun.
        to_play_at_close = summary.get('holes_to_play') or 0
        figure = (f'{margin}&{to_play_at_close}' if to_play_at_close
                  else f'{margin} UP')
        headline = f'{lead_label} won' if counts_for_card \
            else f'{lead_label} win'
        after = list(order[closed_pos + 1:])
        if counts_for_card:
            line = (f'Closed out on {finished_on}. '
                    'Scores here go on the card only.')
        elif after:
            span = (f'{after[0]}–{after[-1]}' if len(after) > 1
                    else f'{after[0]}')
            line = f'Closed out on {finished_on}. Holes {span} don’t count.'
        else:                                 # pragma: no cover - defensive
            line = f'Closed out on {finished_on}.'
    elif pos == len(order) - 1 and hole in per_hole:
        if leader is None:
            headline, figure = 'Match halved', 'AS'
            line = 'Level after 18 · a push'
        else:
            headline, figure = f'{lead_label} win', f'{margin} UP'
            line = f'Final after {len(order)}'
    elif leader is None:
        headline, figure = 'All square', 'AS'
        line = f'thru {played} · {to_play} to play'
    else:
        headline, figure = lead_label, f'{margin} UP'
        line = f'thru {played} · {to_play} to play'

    # The pill on the hole card says the same thing in one phrase.
    if closed_out and pos >= closed_pos:
        state = f'{headline} {figure}'
    elif leader is None:
        state = 'All square'
    else:
        state = f'{lead_label} {margin} UP'

    # ── The nine strip: the block of nine this hole sits in, by PLAY ORDER ──
    block = (pos // 9) * 9
    strip = []
    for i, h in enumerate(order[block:block + 9], start=block):
        row = per_hole.get(h)
        strip.append({
            'hole'   : h,
            'result' : (row['winner'] if row else None),
            'played' : row is not None,
            'dead'   : bool(closed_out and i > closed_pos),
        })

    bet = float(game.bet_amount or 0)
    money = []
    if bet:
        # The engine settles only a FINISHED match; before that the figure is
        # what the standing is worth if it holds, which is what `now` means.
        for n in (1, 2):
            amount = 0.0 if leader is None else (bet if n == leader else -bet)
            money.append({'side': n, 'label': sides[n - 1]['label'],
                          'amount': amount})
        money.sort(key=lambda e: -e['amount'])

    return {
        'hole'        : hole,
        'par'         : geometry.get('par'),
        'stroke_index': geometry.get('stroke_index'),
        'yards'       : geometry.get('yards'),
        'nine'        : 'front nine' if hole <= 9 else 'back nine',
        'thru'        : pos + 1,
        'stake'       : bet,
        'players'     : rows,
        'sides'       : sides,
        'scored'      : scored,
        'hole_complete': hole_complete,
        # This hole is past the close-out: gross and net only, no team score.
        'counts_for_card': counts_for_card,
        'closed_out'  : closed_out,
        'finished_on_hole': finished_on if closed_out else None,
        'match'       : {
            'leader'  : leader,
            'margin'  : margin,
            'headline': headline,
            'figure'  : figure,
            'line'    : line,
            'state'   : state,
            'is_final': is_final,
        },
        'strip'       : strip,
        'money'       : money,
        'round_over'  : hole_complete and pos == len(order) - 1,
        'next_hole'   : order[pos + 1] if pos + 1 < len(order) else None,
    }
