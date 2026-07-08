"""
services/rabbit.py
------------------
Rabbit calculator — a three-player "catch the rabbit" game.

The first player to win a hole outright (strictly lowest net, no tie)
**catches** the rabbit and runs ahead.  They hold it until an opponent
**beats** them on a hole:

* accumulate=True  — the holder builds a lead: +1 for every hole they win
  while holding, −1 for every hole they're beaten; they only lose the
  rabbit when the lead drops to 0 (then it's loose / up for grabs again).
* accumulate=False — the holder loses the rabbit the first hole they're
  beaten (lead capped at 1).

A hole that's tied for low changes nothing.  A hole that frees the rabbit
does NOT also grab it — grabbing is a fresh outright win on a later, loose
hole.

Segments: num_segments is 1 (one 18-hole match), 2 (two 9-hole matches),
or 3 (three 6-hole matches).  The rabbit resets at the start of each
segment.  Whoever holds the rabbit when a segment ends wins that segment;
a segment that ends loose is a push.

Settlement: bet_unit is the per-segment stake (Sixes-style — each segment is
its own match, NOT a share of one pot).  On every completed segment the holder
collects bet_unit from each non-holder; a push moves no money.  So the table
nets to zero and winning every segment is worth (n-1) × num_segments units.

Handicap modes mirror Points 5-3-1 / Wolf (Net %, Gross, Strokes-Off-Low).

Workflow (same shape as the other casual games):
  1. setup_rabbit(...) creates the RabbitGame row (idempotent).
  2. calculate_rabbit(foursome) runs after every score submission and
     rebuilds RabbitHoleResult from the HoleScore table.
  3. rabbit_summary(foursome) returns the JSON the mobile UI consumes.
"""

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import RabbitGame, RabbitHoleResult
from services.points_531 import _build_so_score_index
from services.hole_plan import play_order, segment as _hole_segment
from scoring.handicap import build_score_index
from scoring.models import HoleScore


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_rabbit(
    foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    accumulate: bool = True,
    num_segments: int = 1,
) -> 'RabbitGame':
    """Create (or replace) the Rabbit game for a foursome.  Safe to call
    again — the prior game + its hole results are dropped first."""
    RabbitGame.objects.filter(foursome=foursome).delete()

    net_percent  = max(0, min(200, int(net_percent)))
    num_segments = num_segments if num_segments in (1, 2, 3) else 1

    return RabbitGame.objects.create(
        foursome      = foursome,
        handicap_mode = handicap_mode,
        net_percent   = net_percent,
        accumulate    = bool(accumulate),
        num_segments  = num_segments,
        status        = MatchStatus.PENDING,
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


def _score_index(game, foursome) -> dict:
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_so_score_index(foursome, net_percent=game.net_percent)
    return build_score_index(
        foursome,
        handicap_mode=game.handicap_mode,
        net_percent=game.net_percent,
    )


def segment_hole_lists(foursome, num_segments: int) -> list:
    """Return [[hole, ...], ...] — the holes in each segment, split by POSITION
    in the group's play order (via services.hole_plan.segment), not by absolute
    hole number.

    A full 18 starting on hole 1 reproduces the classic ranges:
    1 → [1..18]; 2 → [1..9][10..18]; 3 → [1..6][7..12][13..18]. A back-9 / 9-hole
    round splits its 9 played holes the same way (1 → all 9; 3 → three 3-hole
    segments); a shotgun follows the group's wrapped play order.
    """
    return _hole_segment(foursome.round, foursome, max(1, num_segments))


def _segment_of_map(seg_lists: list) -> dict:
    """{hole_number: 1-based segment index} from the segment hole lists."""
    return {h: i for i, holes in enumerate(seg_lists, start=1) for h in holes}


def _outright_winner(nets: dict):
    """Return the player_id with the strictly lowest net, or None on a
    tie for low."""
    if not nets:
        return None
    low = min(nets.values())
    leaders = [pid for pid, s in nets.items() if s == low]
    return leaders[0] if len(leaders) == 1 else None


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_rabbit(foursome) -> list:
    """Rebuild RabbitHoleResult rows from the current HoleScore table and
    update the game's status."""
    try:
        game = foursome.rabbit_game
    except RabbitGame.DoesNotExist:
        return []

    real_ids = [m.player_id for m in _real_members(foursome)]
    RabbitHoleResult.objects.filter(game=game).delete()
    if not real_ids:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    score_index = _score_index(game, foursome)
    seg_lists   = segment_hole_lists(foursome, game.num_segments)
    holes_total = sum(len(s) for s in seg_lists)
    accumulate  = game.accumulate

    rows = []
    fully_scored = 0
    for seg_index, seg_holes in enumerate(seg_lists, start=1):
        holder = None     # player_id or None (loose)
        lead   = 0
        for hole in seg_holes:          # play order within the segment
            nets = {}
            complete = True
            for pid in real_ids:
                s = score_index.get(pid, {}).get(hole)
                if s is None:
                    complete = False
                    break
                nets[pid] = s
            if not complete:
                continue          # skip unscored holes; state carries
            fully_scored += 1

            winner = _outright_winner(nets)   # outright low, else None

            if holder is None:
                # Loose — an outright win catches the rabbit.
                if winner is not None:
                    holder, lead = winner, 1
                    event = RabbitHoleResult.GRAB
                else:
                    event = RabbitHoleResult.TIE
            else:
                opp_low = min(nets[pid] for pid in real_ids if pid != holder)
                if opp_low < nets[holder]:
                    # Rabbit beaten — lead drops; freed at 0.
                    lead -= 1
                    if lead <= 0:
                        holder, lead = None, 0
                        event = RabbitHoleResult.FREED
                    else:
                        event = RabbitHoleResult.BEATEN
                elif nets[holder] < opp_low:
                    # Rabbit wins the hole.
                    if accumulate:
                        lead += 1
                        event = RabbitHoleResult.EXTEND
                    else:
                        event = RabbitHoleResult.HELD   # capped at 1
                else:
                    # Rabbit tied for low with an opponent — no change.
                    event = RabbitHoleResult.HELD

            rows.append(RabbitHoleResult(
                game        = game,
                hole_number = hole,
                segment     = seg_index,
                winner_id   = winner,
                holder_id   = holder,
                lead        = lead,
                event       = event,
            ))

    if rows:
        RabbitHoleResult.objects.bulk_create(rows)

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

def _phcp_in_play(mode, npct, phcp, low_phcp) -> int:
    if mode == HandicapMode.GROSS:
        return 0
    if mode == HandicapMode.STROKES_OFF:
        return round(max(0, phcp - low_phcp) * npct / 100)
    return round(phcp * npct / 100)


def rabbit_summary(foursome) -> dict:
    """JSON-serialisable summary for the mobile Rabbit screen + leaderboard."""
    bet_unit = float(foursome.round.bet_unit)
    try:
        game = foursome.rabbit_game
    except RabbitGame.DoesNotExist:
        return {
            'status'      : 'pending',
            'handicap'    : {'mode': HandicapMode.STROKES_OFF, 'net_percent': 100},
            'accumulate'  : True,
            'num_segments': 1,
            'segments'    : [],
            'players'     : [],
            'holes'       : [],
            'current'     : {'holder_id': None, 'holder_short': None,
                             'lead': 0, 'segment': 1},
            'money'       : {'bet_unit': bet_unit, 'entry': bet_unit,
                             'pot': bet_unit, 'seg_value': bet_unit},
        }

    members  = _real_members(foursome)
    by_pid   = {m.player_id: m.player for m in members}
    real_ids = list(by_pid.keys())
    score_index = _score_index(game, foursome)
    order       = play_order(foursome.round, foursome)   # holes in play order
    seg_lists   = segment_hole_lists(foursome, game.num_segments)
    seg_of      = _segment_of_map(seg_lists)
    nseg        = len(seg_lists) or 1

    # bet_unit is the per-segment stake (Sixes-style — each segment is its own
    # match, not a share of one pot).  On every completed segment each loser
    # pays the holder one full bet_unit and the holder collects from all
    # opponents.  Winning every segment nets +(n-1)·num_segments; losing every
    # segment nets −num_segments.  Push segments (loose at the end) move nothing.
    n         = len(real_ids) or 3
    entry     = bet_unit
    pot       = entry * nseg          # max a single player can lose (all segments)
    per_loser = entry                 # each loser pays a full stake per lost segment

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

    # Per-hole grid, in play order.
    holes_out: list = []
    for hole in order:
        r = results.get(hole)
        seg = seg_of.get(hole, 1)
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
        holes_out.append({
            'hole'        : hole,
            'segment'     : seg,
            'par'         : par_by_hole.get(hole),
            'winner_id'   : r.winner_id if r else None,
            'winner_short': short(r.winner_id) if (r and r.winner_id) else None,
            'holder_id'   : r.holder_id if r else None,
            'holder_short': short(r.holder_id) if (r and r.holder_id) else None,
            'lead'        : r.lead if r else 0,
            'event'       : r.event if r else None,
            'entries'     : entries,
        })

    # Segments: holder at the last scored hole; complete when all holes scored.
    money_by_pid = {pid: 0.0 for pid in real_ids}
    seg_out: list = []
    for i, seg_holes in enumerate(seg_lists, start=1):
        complete  = bool(seg_holes) and all(
            results.get(h) is not None for h in seg_holes)
        # Holder is the state after the last scored hole in the segment (play
        # order), so a partial / wraparound segment settles on its real last hole.
        holder_id, lead = None, 0
        for h in reversed(seg_holes):
            if results.get(h) is not None:
                holder_id = results[h].holder_id
                lead      = results[h].lead
                break
        payout = 0.0
        if complete and holder_id is not None:
            payout = per_loser * (n - 1)        # holder's net gain this segment
            money_by_pid[holder_id] += payout
            for pid in real_ids:
                if pid != holder_id:
                    money_by_pid[pid] -= per_loser
        seg_out.append({
            'index'       : i,
            'start_hole'  : seg_holes[0] if seg_holes else None,
            'end_hole'    : seg_holes[-1] if seg_holes else None,
            'holder_id'   : holder_id,
            'holder_short': short(holder_id) if holder_id else None,
            'lead'        : lead,
            'complete'    : complete,
            'payout'      : payout,        # to the holder; others split −payout
        })

    # Current live state — the latest scored hole overall (play order).
    cur_holder, cur_lead, cur_seg = None, 0, 1
    for h in reversed(order):
        if results.get(h) is not None:
            cur_holder = results[h].holder_id
            cur_lead   = results[h].lead
            cur_seg    = results[h].segment
            break

    players_out = []
    for pid, player in by_pid.items():
        segs_won = sum(1 for s in seg_out
                       if s['complete'] and s['holder_id'] == pid)
        players_out.append({
            'player_id'   : pid,
            'name'        : player.name,
            'short_name'  : player.short_name,
            'money'       : money_by_pid.get(pid, 0.0),
            'segments_won': segs_won,
            'phcp_in_play': phcp_by_pid.get(pid),
        })
    players_out.sort(key=lambda e: (-e['money'], e['name']))

    return {
        'status'      : game.status,
        'handicap'    : {'mode': game.handicap_mode, 'net_percent': game.net_percent},
        'accumulate'  : game.accumulate,
        'num_segments': game.num_segments,
        'segments'    : seg_out,
        'players'     : players_out,
        'holes'       : holes_out,
        'current'     : {
            'holder_id'   : cur_holder,
            'holder_short': short(cur_holder) if cur_holder else None,
            'lead'        : cur_lead,
            'segment'     : cur_seg,
        },
        'money'       : {'bet_unit': entry, 'entry': entry, 'pot': pot,
                         'seg_value': entry},
    }
