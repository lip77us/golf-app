"""
services/honors.py
------------------
Honors calculator — a side-game-only "carry the honor" points game.

A single token, **the honor**, is won by taking a hole outright (the
strictly lowest score-to-compare, no tie).  Whoever wins a hole outright
takes the honor; they keep it until another player wins a hole outright.
A hole with no outright winner (a tie for low) never beats the holder —
"a tie doesn't beat you" — so the current holder simply keeps it.

Every hole a player is holding the honor they score **1 point**, so a
player's total points = the number of holes they held the honor.  A hole
that's still loose (nobody has won a hole outright yet) awards no point.

Settlement reuses the shared wager engine (services.wager) on the point
totals; ``bet_unit`` (the round stake) is the value of one point:

* pool                  — everyone antes bet_unit; the pot splits by share
                          of points (PROPORTIONAL). Entry is the cap.
* per_point + 'average' — settle vs the field average (VS_AVERAGE). Default.
* per_point + 'all'     — pay everyone above you (PAY_ABOVE).
* per_point + 'first'   — only the leader collects (PAY_WINNER).

Handicap modes mirror Points 5-3-1 / Rabbit (Net %, Gross, Strokes-Off-Low).

Workflow (same shape as the other casual games):
  1. setup_honors(...) creates the HonorsGame row (idempotent).
  2. calculate_honors(foursome) runs after every score submission and
     rebuilds HonorsHoleResult from the HoleScore table.
  3. honors_summary(foursome) returns the JSON the mobile UI consumes.
"""

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import HonorsGame, HonorsHoleResult
from scoring.handicap import build_score_index
from scoring.models import HoleScore
from services.hole_plan import play_order
from services.points_531 import _build_so_score_index
from services.wager import (
    PER_POINT, POOL, PROPORTIONAL, VS_AVERAGE, PAY_ABOVE, PAY_WINNER,
    WagerConfig, settle,
)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_honors(
    foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    loss_cap=None,
    payout_style: str = 'per_point',
    per_point_mode: str = 'average',
    participant_player_ids=None,
) -> 'HonorsGame':
    """Create (or replace) the Honors game for a foursome.  Safe to call
    again — the prior game + its hole results are dropped first.

    ``participant_player_ids`` restricts the game to a subset of the group
    (empty/None = all real players)."""
    HonorsGame.objects.filter(foursome=foursome).delete()

    net_percent = max(0, min(200, int(net_percent)))

    if loss_cap is not None:
        loss_cap = Decimal(str(loss_cap))
        if loss_cap < 0:
            loss_cap = None

    if payout_style not in ('pool', 'per_point'):
        payout_style = 'per_point'
    if per_point_mode not in ('average', 'all', 'first'):
        per_point_mode = 'average'

    return HonorsGame.objects.create(
        foursome       = foursome,
        handicap_mode  = handicap_mode,
        net_percent    = net_percent,
        loss_cap       = loss_cap,
        payout_style   = payout_style,
        per_point_mode = per_point_mode,
        participant_player_ids = list(participant_player_ids or []),
        status         = MatchStatus.PENDING,
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _real_members(foursome) -> list:
    return list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player__is_phantom=False)
    )


def _participant_members(game, foursome) -> list:
    """Real members restricted to the game's participant subset.  An empty
    participant list = all real players (backward compatible)."""
    members = _real_members(foursome)
    subset = set(game.participant_player_ids or [])
    if subset:
        members = [m for m in members if m.player_id in subset]
    return members


def _score_index(game, foursome) -> dict:
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_so_score_index(foursome, net_percent=game.net_percent)
    return build_score_index(
        foursome,
        handicap_mode=game.handicap_mode,
        net_percent=game.net_percent,
    )


def _outright_winner(nets: dict):
    """Return the player_id with the strictly lowest score, or None on a
    tie for low."""
    if not nets:
        return None
    low = min(nets.values())
    leaders = [pid for pid, s in nets.items() if s == low]
    return leaders[0] if len(leaders) == 1 else None


def _phcp_in_play(mode, npct, phcp, low_phcp) -> int:
    if mode == HandicapMode.GROSS:
        return 0
    if mode == HandicapMode.STROKES_OFF:
        return round(max(0, phcp - low_phcp) * npct / 100)
    return round(phcp * npct / 100)


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_honors(foursome) -> list:
    """Rebuild HonorsHoleResult rows from the current HoleScore table and
    update the game's status.

    Walks the holes in the group's play order.  On each fully-scored hole:
      * compute the outright winner (strictly lowest score, else None);
      * if there IS an outright winner, the honor passes to them;
      * otherwise the holder is unchanged (keeps it if held, stays loose
        if nobody holds it) — a tie never beats the holder.
    The holder AFTER the hole scores 1 point for that hole.
    """
    try:
        game = foursome.honors_game
    except HonorsGame.DoesNotExist:
        # 'honors' is active for this round but was never explicitly configured
        # (added as a side game without completing the setup screen). Honors is a
        # DERIVED overlay that needs no per-hole input, so auto-create it with
        # sensible defaults (Strokes-Off Low, settle vs the field average) and
        # score from the entered gross — matching Stroke Play / Stableford
        # instead of sitting at "not started". An explicit setup later
        # overwrites this. Guard on active_games so we only auto-init when the
        # round actually wants Honors.
        active = (set(foursome.active_games or [])
                  | set(foursome.round.active_games or []))
        if 'honors' not in active:
            return []
        game = setup_honors(foursome, handicap_mode=HandicapMode.STROKES_OFF)

    real_ids = [m.player_id for m in _participant_members(game, foursome)]
    HonorsHoleResult.objects.filter(game=game).delete()
    if not real_ids:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    score_index = _score_index(game, foursome)
    order       = play_order(foursome.round, foursome)   # holes in play order
    holes_total = len(order)

    rows = []
    holder = None       # player_id or None (loose)
    fully_scored = 0
    for hole in order:
        nets = {}
        complete = True
        for pid in real_ids:
            s = score_index.get(pid, {}).get(hole)
            if s is None:
                complete = False
                break
            nets[pid] = s
        if not complete:
            continue          # skip unscored holes; the honor carries
        fully_scored += 1

        winner = _outright_winner(nets)   # outright low, else None (tie)
        if winner is not None:
            holder = winner               # a hole win takes the honor

        rows.append(HonorsHoleResult(
            game        = game,
            hole_number = hole,
            winner_id   = winner,
            holder_id   = holder,
        ))

    if rows:
        HonorsHoleResult.objects.bulk_create(rows)

    if fully_scored == 0:
        game.status = MatchStatus.PENDING
    elif fully_scored >= holes_total:
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])
    return rows


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def honors_summary(foursome) -> dict:
    """JSON-serialisable summary for the mobile Honors leaderboard card.

    Shape:
        {
          'status'   : 'pending'|'in_progress'|'complete',
          'handicap' : {'mode': str, 'net_percent': int},
          'players'  : [{player_id, name, short_name, points, holes_held,
                         money, phcp_in_play}],           # sorted money desc
          'holes'    : [{hole, par, winner_id, winner_short,
                         holder_id, holder_short,
                         entries: [{player_id, short_name, name,
                                    net_score, gross, is_winner, is_holder}],
                         cum: {player_id: cumulative_points},
                         average: float}],                # running field average
          'current'  : {holder_id, holder_short},
          'money'    : {bet_unit, average, payout_style, per_point_mode, loss_cap},
        }
    """
    bet_unit = float(foursome.round.bet_unit)
    try:
        game = foursome.honors_game
    except HonorsGame.DoesNotExist:
        return {
            'status'  : 'pending',
            # Casual default → Strokes-Off Low, matching the other casual-game
            # setup screens so a fresh Honors game lands on SO.
            'handicap': {'mode': HandicapMode.STROKES_OFF, 'net_percent': 100},
            'players' : [],
            'holes'   : [],
            'current' : {'holder_id': None, 'holder_short': None},
            'participant_player_ids': [],
            'money'   : {'bet_unit': bet_unit, 'average': 0.0,
                         'payout_style': 'per_point', 'per_point_mode': 'average',
                         'loss_cap': None},
        }

    members  = _participant_members(game, foursome)
    by_pid   = {m.player_id: m.player for m in members}
    real_ids = list(by_pid.keys())
    score_index = _score_index(game, foursome)
    order       = play_order(foursome.round, foursome)

    # Gross + par for display.
    gross_index: dict = {}
    for r in (
        HoleScore.objects
        .filter(foursome=foursome, player_id__in=real_ids)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    ):
        gross_index.setdefault(r['player_id'], {})[r['hole_number']] = r['gross_score']

    sample_tee = next((m.tee for m in members if m.tee_id is not None), None)
    par_by_hole: dict = {}
    if sample_tee is not None:
        for h in order:
            par_by_hole[h] = sample_tee.hole(h).get('par')

    phcps    = [(m.playing_handicap or 0) for m in members
                if m.playing_handicap is not None]
    low_phcp = min(phcps) if phcps else 0
    phcp_by_pid = {
        m.player_id: _phcp_in_play(game.handicap_mode, game.net_percent or 100,
                                   (m.playing_handicap or 0), low_phcp)
        for m in members
    }

    def short(pid):
        p = by_pid.get(pid)
        return p.short_name if p else None

    results = {r.hole_number: r for r in game.hole_results.all()}

    # Per-hole grid, in play order, with a running cumulative-points + average
    # trail so the card can show "who's above the average after each hole".
    n = len(real_ids) or 1
    cum: dict = {pid: 0 for pid in real_ids}
    points_by_pid: dict = {pid: 0 for pid in real_ids}
    holes_out: list = []
    cur_holder = None
    for hole in order:
        r = results.get(hole)
        if r is not None and r.holder_id is not None:
            cum[r.holder_id] = cum.get(r.holder_id, 0) + 1
            cur_holder = r.holder_id
        entries = []
        for pid in real_ids:
            net = score_index.get(pid, {}).get(hole)
            entries.append({
                'player_id' : pid,
                'short_name': by_pid[pid].short_name,
                'name'      : by_pid[pid].name,
                'net_score' : net,
                'gross'     : gross_index.get(pid, {}).get(hole),
                'is_winner' : bool(r and r.winner_id == pid),
                'is_holder' : bool(r and r.holder_id == pid),
            })
        total_so_far = sum(cum.values())
        holes_out.append({
            'hole'        : hole,
            'par'         : par_by_hole.get(hole),
            'winner_id'   : r.winner_id if r else None,
            'winner_short': short(r.winner_id) if (r and r.winner_id) else None,
            'holder_id'   : r.holder_id if r else None,
            'holder_short': short(r.holder_id) if (r and r.holder_id) else None,
            'entries'     : entries,
            'cum'         : dict(cum),
            'average'     : (total_so_far / n) if r is not None else None,
        })

    points_by_pid = dict(cum)   # final cumulative == total points held

    # Money via the shared wager engine on the point totals.
    if game.payout_style == 'pool':
        cfg = WagerConfig(
            funding    = POOL,
            settlement = PROPORTIONAL,
            entry      = Decimal(str(bet_unit)),
        )
    else:
        _MODE = {'average': VS_AVERAGE, 'all': PAY_ABOVE, 'first': PAY_WINNER}
        cfg = WagerConfig(
            funding    = PER_POINT,
            settlement = _MODE.get(game.per_point_mode, VS_AVERAGE),
            rate       = Decimal(str(bet_unit)),
            cap        = game.loss_cap,
        )
    payouts = settle(
        {pid: points_by_pid.get(pid, 0) for pid in by_pid},
        cfg,
    )

    total_points = sum(points_by_pid.values())
    average = (total_points / n) if n else 0.0

    players_out: list = []
    for pid, player in by_pid.items():
        players_out.append({
            'player_id'   : pid,
            'name'        : player.name,
            'short_name'  : player.short_name,
            'points'      : points_by_pid.get(pid, 0),
            'holes_held'  : points_by_pid.get(pid, 0),
            'money'       : float(payouts[pid]),
            'phcp_in_play': phcp_by_pid.get(pid),
        })
    players_out.sort(key=lambda e: (-e['money'], -e['points'], e['name']))

    return {
        'status'  : game.status,
        'handicap': {'mode': game.handicap_mode, 'net_percent': game.net_percent},
        'players' : players_out,
        'holes'   : holes_out,
        'current' : {
            'holder_id'   : cur_holder,
            'holder_short': short(cur_holder) if cur_holder else None,
        },
        'participant_player_ids': list(game.participant_player_ids or []),
        'money'   : {
            'bet_unit'      : bet_unit,
            'average'       : average,
            'payout_style'  : game.payout_style,
            'per_point_mode': game.per_point_mode,
            'loss_cap'      : float(game.loss_cap) if game.loss_cap is not None else None,
        },
    }
