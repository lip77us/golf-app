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
    handicap_allocation: str = RabbitGame.ALLOC_PER_SEGMENT,
    extra_rabbits: bool = False,
) -> 'RabbitGame':
    """Create (or replace) the Rabbit game for a foursome.  Safe to call
    again — the prior game + its hole results are dropped first."""
    RabbitGame.objects.filter(foursome=foursome).delete()

    net_percent  = max(0, min(200, int(net_percent)))
    num_segments = num_segments if num_segments in (1, 2, 3) else 1
    allocation   = (handicap_allocation
                    if handicap_allocation in
                    (RabbitGame.ALLOC_PER_SEGMENT, RabbitGame.ALLOC_FULL_ROUND)
                    else RabbitGame.ALLOC_PER_SEGMENT)
    # Extra rabbits are an accumulate-only mechanic (stop-after-one never decides
    # a leg early), so force the flag off outside accumulate mode.
    extras = bool(extra_rabbits) and bool(accumulate)

    return RabbitGame.objects.create(
        foursome            = foursome,
        handicap_mode       = handicap_mode,
        net_percent         = net_percent,
        accumulate          = bool(accumulate),
        num_segments        = num_segments,
        handicap_allocation = allocation,
        extra_rabbits       = extras,
        status              = MatchStatus.PENDING,
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


def _build_rabbit_so_seg_index(foursome, seg_lists, net_percent: int = 100) -> dict:
    """Strokes-Off score index with each golfer's strokes spread PER SEGMENT
    (Sixes-style), returning {pid: {hole: net_score}} for scored holes.

    The lowest playing handicap plays to 0.  Every other player's SO strokes
    (own_phcp − low, at net_percent) are split evenly across the segments — the
    earliest segments absorb the remainder (7 over 3 → 3·2·2) — then allocated
    to the hardest holes (lowest stroke index) within each segment's own range,
    wrapping if a segment's share exceeds its hole count.
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
    low  = min(phcps) if phcps else 0
    nseg = len(seg_lists) or 1

    for m in memberships:
        if m.tee_id is None:
            continue
        so = round(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
        if so <= 0:
            continue
        per_player = score_index.get(m.player_id)
        if not per_player:
            continue
        base, rem = divmod(so, nseg)
        for si_idx, seg_holes in enumerate(seg_lists):
            share = base + (1 if si_idx < rem else 0)
            if share <= 0 or not seg_holes:
                continue
            # Hardest holes first within THIS segment; wrap for a share that
            # exceeds the segment length (only when SO > holes, very rare).
            ranked = sorted(
                seg_holes,
                key=lambda h: m.tee.hole(h).get('stroke_index', 18),
            )
            for k in range(share):
                h = ranked[k % len(ranked)]
                # Net is only meaningful for scored holes; an unscored stroke
                # hole lands when its score is entered and recalc re-runs.
                if per_player.get(h) is not None:
                    per_player[h] -= 1
    return score_index


def _score_index(game, foursome, seg_lists=None) -> dict:
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        # Per-segment spread only differs from round-wide when there's more
        # than one segment; a single 18-hole match is identical either way.
        if (game.handicap_allocation == RabbitGame.ALLOC_PER_SEGMENT
                and seg_lists and len(seg_lists) > 1):
            return _build_rabbit_so_seg_index(
                foursome, seg_lists, net_percent=game.net_percent)
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


def _hole_nets(score_index, real_ids, hole):
    """(complete, nets) for a hole across every real player."""
    nets = {}
    for pid in real_ids:
        s = score_index.get(pid, {}).get(hole)
        if s is None:
            return False, {}
        nets[pid] = s
    return True, nets


def _advance_rabbit(holder, lead, nets, real_ids, accumulate):
    """Apply one fully-scored hole to the (holder, lead) state.  Returns
    (holder, lead, event, winner_id) — the single source of truth for the
    catch / hold / free transitions (shared by the fixed and dynamic paths)."""
    winner = _outright_winner(nets)
    if holder is None:
        if winner is not None:
            return winner, 1, RabbitHoleResult.GRAB, winner
        return None, 0, RabbitHoleResult.TIE, winner
    opp_low = min(nets[pid] for pid in real_ids if pid != holder)
    if opp_low < nets[holder]:
        lead -= 1
        if lead <= 0:
            return None, 0, RabbitHoleResult.FREED, winner
        return holder, lead, RabbitHoleResult.BEATEN, winner
    if nets[holder] < opp_low:
        if accumulate:
            return holder, lead + 1, RabbitHoleResult.EXTEND, winner
        return holder, lead, RabbitHoleResult.HELD, winner   # stop-mode: capped
    return holder, lead, RabbitHoleResult.HELD, winner        # tie for low


def _run_rabbit(game, foursome, score_index, real_ids, bet_unit):
    """Compute the leg schedule + per-hole state from the current scores.

    Returns (rows, segments, fully_scored):
      * rows      — unsaved RabbitHoleResult instances (scored holes only)
      * segments  — [{index, is_extra, holes:[hole,...], holder, lead, complete,
                      value}]; value is the per-leg stake (bet_unit, or bet_unit/2
                      for a single-hole extra).
      * fully_scored — count of fully-scored holes.

    With extra_rabbits OFF the legs are the fixed segment_hole_lists ranges —
    byte-for-byte the original behaviour.  With it ON (accumulate only) each leg
    ends the moment the holder's lead exceeds the holes remaining in it, the next
    leg starts on the very next hole, and leftover holes after the standard legs
    form up to two extra rabbits (loose start) — Sixes' close-out/extra mechanic,
    minus the teams.
    """
    dynamic = bool(game.extra_rabbits) and bool(game.accumulate)
    rows: list = []
    segments: list = []
    fully_scored = 0

    def _finish(index, is_extra, holes, holder, lead):
        complete = bool(holes) and all(
            _hole_nets(score_index, real_ids, h)[0] for h in holes)
        value = (bet_unit / 2.0) if (is_extra and len(holes) == 1) else bet_unit
        segments.append({
            'index': index, 'is_extra': is_extra, 'holes': list(holes),
            'holder': holder, 'lead': lead, 'complete': complete, 'value': value,
        })

    if not dynamic:
        for idx, seg_holes in enumerate(
                segment_hole_lists(foursome, game.num_segments), start=1):
            holder, lead = None, 0
            for hole in seg_holes:
                complete, nets = _hole_nets(score_index, real_ids, hole)
                if not complete:
                    continue                       # skip unscored; state carries
                fully_scored += 1
                holder, lead, event, winner = _advance_rabbit(
                    holder, lead, nets, real_ids, game.accumulate)
                rows.append(RabbitHoleResult(
                    game=game, hole_number=hole, segment=idx,
                    winner_id=winner, holder_id=holder, lead=lead, event=event))
            _finish(idx, False, seg_holes, holder, lead)
        return rows, segments, fully_scored

    # ── Dynamic: early-lock scheduling + extra rabbits ───────────────────────
    positions = play_order(foursome.round, foursome)
    n         = len(positions)
    seg_len   = max(1, n // max(1, game.num_segments))
    pos, seg_idx, standard_done, extras_done = 0, 0, 0, 0
    while pos < n:
        seg_idx += 1
        is_extra = standard_done >= game.num_segments
        # Standard legs + the FIRST extra can lock; the 2nd extra runs to the end
        # (the cap — at most two extras / five legs at three segments).
        can_lock   = not (is_extra and extras_done >= 1)
        window_end = (n - 1) if is_extra else min(pos + seg_len - 1, n - 1)
        holder, lead, end_pos, cur = None, 0, window_end, pos
        while cur <= window_end:
            hole = positions[cur]
            complete, nets = _hole_nets(score_index, real_ids, hole)
            if complete:
                fully_scored += 1
                holder, lead, event, winner = _advance_rabbit(
                    holder, lead, nets, real_ids, True)
                rows.append(RabbitHoleResult(
                    game=game, hole_number=hole, segment=seg_idx,
                    winner_id=winner, holder_id=holder, lead=lead, event=event))
                if can_lock and holder is not None and lead > (window_end - cur):
                    end_pos = cur                  # decided early → leg ends here
                    break
            cur += 1
        _finish(seg_idx, is_extra, positions[pos:end_pos + 1], holder, lead)
        pos = end_pos + 1
        if is_extra:
            extras_done += 1
        else:
            standard_done += 1
        if standard_done >= game.num_segments and (pos >= n or extras_done >= 2):
            break
    return rows, segments, fully_scored


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

    seg_lists   = segment_hole_lists(foursome, game.num_segments)
    score_index = _score_index(game, foursome, seg_lists)
    holes_total = sum(len(s) for s in seg_lists)
    bet_unit    = float(foursome.round.bet_unit)

    rows, _segments, fully_scored = _run_rabbit(
        game, foursome, score_index, real_ids, bet_unit)

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
            'handicap'    : {'mode': HandicapMode.STROKES_OFF, 'net_percent': 100,
                             'allocation': RabbitGame.ALLOC_PER_SEGMENT},
            'accumulate'   : True,
            'num_segments' : 1,
            'extra_rabbits': False,
            'segments'     : [],
            'players'      : [],
            'holes'        : [],
            'current'      : {'holder_id': None, 'holder_short': None,
                              'lead': 0, 'segment': 1},
            'money'        : {'bet_unit': bet_unit, 'entry': bet_unit,
                              'pot': bet_unit, 'seg_value': bet_unit,
                              'max_liability': bet_unit},
        }

    members  = _real_members(foursome)
    by_pid   = {m.player_id: m.player for m in members}
    real_ids = list(by_pid.keys())
    order       = play_order(foursome.round, foursome)   # holes in play order
    seg_lists   = segment_hole_lists(foursome, game.num_segments)
    score_index = _score_index(game, foursome, seg_lists)

    # The leg schedule (fixed, or early-lock + extras when extra_rabbits is on).
    rows, segments, _ = _run_rabbit(
        game, foursome, score_index, real_ids, bet_unit)
    seg_of      = {h: s['index'] for s in segments for h in s['holes']}

    # Each leg (standard or extra) is its own Sixes-style match worth `value`
    # (bet_unit, or bet_unit/2 for a single-hole extra); the holder at the leg's
    # end collects `value` from each opponent, and a leg left loose pushes.
    n     = len(real_ids) or 3
    entry = bet_unit

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

    results = {r.hole_number: r for r in rows}

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

    # Segments — one entry per leg (standard + any extras), settled zero-sum.
    money_by_pid = {pid: 0.0 for pid in real_ids}
    seg_out: list = []
    max_at_risk  = 0.0
    for s in segments:
        seg_holes = s['holes']
        holder_id = s['holder']
        lead      = s['lead']
        complete  = s['complete']
        value     = s['value']
        max_at_risk += value
        payout = 0.0
        if complete and holder_id is not None:
            payout = value * (n - 1)            # holder's net gain this leg
            money_by_pid[holder_id] += payout
            for pid in real_ids:
                if pid != holder_id:
                    money_by_pid[pid] -= value
        seg_out.append({
            'index'       : s['index'],
            'is_extra'    : s['is_extra'],
            'start_hole'  : seg_holes[0] if seg_holes else None,
            'end_hole'    : seg_holes[-1] if seg_holes else None,
            'holes'       : len(seg_holes),
            'holder_id'   : holder_id,
            'holder_short': short(holder_id) if holder_id else None,
            'lead'        : lead,
            'complete'    : complete,
            'value'       : value,
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
        'handicap'    : {'mode': game.handicap_mode, 'net_percent': game.net_percent,
                         'allocation': game.handicap_allocation},
        'accumulate'   : game.accumulate,
        'num_segments' : game.num_segments,
        'extra_rabbits': game.extra_rabbits,
        'segments'     : seg_out,
        'players'      : players_out,
        'holes'        : holes_out,
        'current'      : {
            'holder_id'   : cur_holder,
            'holder_short': short(cur_holder) if cur_holder else None,
            'lead'        : cur_lead,
            'segment'     : cur_seg,
        },
        'money'        : {
            'bet_unit'     : entry,
            'entry'        : entry,
            'seg_value'    : entry,
            'pot'          : max_at_risk,     # sum of the actual legs' values
            'max_liability': (game.num_segments +
                              (2 if game.extra_rabbits else 0)) * entry,
        },
    }
