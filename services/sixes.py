"""
services/sixes.py
-----------------
Six's calculator — 3 × 6-hole rotating-team best ball match play
within a foursome.

Rules
~~~~~
* The foursome plays 3 standard matches.  Each match immediately follows
  the previous one — there are no gaps between matches:

      Match 1 starts at hole 1  and runs for up to 6 holes.
      Match 2 starts at the hole after Match 1 ends.
      Match 3 starts at the hole after Match 2 ends.

  If no match ends early the schedule is holes 1-6, 7-12, 13-18.

* If a match ends early (one team leads by more holes than remain), the
  NEXT match begins on the very next hole rather than waiting for the
  original slot to expire.  Any holes left over AFTER all three standard
  matches are collected into an optional 4th "extra" match at the end.

  Example — Match 1 ends at hole 5:
      Match 1: holes  1– 5  (finished early)
      Match 2: holes  6–11  (starts right away)
      Match 3: holes 12–17
      Extra:   hole  18     (1 accumulated hole)

* Each match is two-vs-two best ball, using individual net scores.
* Team formation:
      Match 1: Long Drive (or user-chosen order)
      Match 2: Random (auto-generated at setup — different from Match 1)
      Match 3: Remainder (the third possible pairing)
      Extra:   Loser of the previous segment chooses their partner.
* Best ball: lowest individual net score from each team per hole.
* Match scoring: win = +1, halve = 0.  Match over when one team leads
  by more holes than remain.
* Lowest net tiebreaker: halved segments award the split to the team
  with the lower combined net (stored as 'halved' status).

Workflow
~~~~~~~~
1. Call ``setup_sixes(foursome, team_data)`` once at the start,
   passing data for all three standard segments.
2. Call ``calculate_sixes(foursome)`` after each hole submission to
   update results, move segment boundaries if an early finish occurred,
   and create the extra segment if needed.

team_data format
~~~~~~~~~~~~~~~~
    [
        {
            'start_hole': 1, 'end_hole': 6,
            'team_select_method': 'long_drive',
            'team1_player_ids': [pk, pk],
            'team2_player_ids': [pk, pk],
        },
        {
            'start_hole': 7, 'end_hole': 12,
            'team_select_method': 'random',
            'team1_player_ids': [pk, pk],
            'team2_player_ids': [pk, pk],
        },
        {
            'start_hole': 13, 'end_hole': 18,
            'team_select_method': 'remainder',
            'team1_player_ids': [pk, pk],
            'team2_player_ids': [pk, pk],
        },
    ]
For an extra match generated mid-round, include 'is_extra': True.
"""

from django.db import transaction

from core.models import HandicapMode
from games.models import SixesSegment, SixesTeam, SixesHoleResult
from scoring.handicap import (
    build_score_index,
    _strokes_for_segment_index,
    _allocate_segment_strokes,
)
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_sixes(
    foursome,
    team_data: list,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
) -> list:
    """
    Create SixesSegment and SixesTeam rows for the given foursome.

    team_data is a list of dicts (see module docstring for format).
    Expects all three standard segments to be included so that
    calculate_sixes can process the full round without gaps.
    Safe to call again — existing data is replaced.

    The handicap_mode and net_percent are stored on every segment so they
    travel with the match.  They default to 'net' at 100% for backward
    compatibility with existing callers; a caller may pass 'gross' for a
    no-handicap match, or 'net' with net_percent=90 for 90% allowance, etc.

    Returns a list of SixesSegment instances.
    """
    SixesSegment.objects.filter(foursome=foursome).delete()

    # Clamp percent to the validated range so a bad caller can't poison the DB.
    net_percent = max(0, min(200, int(net_percent)))

    segments = []
    for i, td in enumerate(team_data, start=1):
        seg = SixesSegment.objects.create(
            foursome       = foursome,
            segment_number = i,
            start_hole     = td['start_hole'],
            end_hole       = td['end_hole'],
            is_extra       = td.get('is_extra', False),
            handicap_mode  = handicap_mode,
            net_percent    = net_percent,
        )

        # Team 1
        t1 = SixesTeam.objects.create(
            segment            = seg,
            team_number        = 1,
            team_select_method = td['team_select_method'],
        )
        t1.players.set(td['team1_player_ids'])

        # Team 2
        t2 = SixesTeam.objects.create(
            segment            = seg,
            team_number        = 2,
            team_select_method = td['team_select_method'],
        )
        t2.players.set(td['team2_player_ids'])

        segments.append(seg)

    return segments


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

def _best_net_for_team(team: SixesTeam, hole_number: int, score_index: dict) -> int | None:
    """
    Return the lowest score among this team's players on hole_number.

    The value in score_index may be a net or gross score depending on the
    match's handicap_mode (see scoring.handicap.build_score_index); this
    function is agnostic to which — it just picks the minimum for best-ball.
    """
    nets = [
        score_index[p_id][hole_number]
        for p_id in team.players.values_list('id', flat=True)
        if p_id in score_index and hole_number in score_index[p_id]
    ]
    return min(nets) if nets else None


def _score_segment(seg: SixesSegment, score_index: dict) -> tuple:
    """
    Score all playable holes in *seg*, persist SixesHoleResult rows, and
    update the segment's status field.

    Returns (results, finished_on) where finished_on is the hole number
    where the match ended early, or None if it ran to completion / is still
    in progress.  Returns ([], None) when teams haven't been assigned yet.
    """
    teams = list(seg.teams.all())
    if len(teams) < 2:
        seg.status = 'pending'
        seg.save(update_fields=['status'])
        return [], None

    t1 = next((t for t in teams if t.team_number == 1), None)
    t2 = next((t for t in teams if t.team_number == 2), None)
    if not t1 or not t2:
        seg.status = 'pending'
        seg.save(update_fields=['status'])
        return [], None

    SixesHoleResult.objects.filter(segment=seg).delete()

    holes_up    = 0
    finished_on = None
    results     = []

    for hole_num in range(seg.start_hole, seg.end_hole + 1):
        t1_net = _best_net_for_team(t1, hole_num, score_index)
        t2_net = _best_net_for_team(t2, hole_num, score_index)

        if t1_net is None or t2_net is None:
            break  # incomplete — stop here

        # Determine hole winner
        if t1_net < t2_net:
            holes_up += 1
            winner = t1
        elif t2_net < t1_net:
            holes_up -= 1
            winner = t2
        else:
            winner = None  # halved

        # Check if match is mathematically over
        holes_remaining = seg.end_hole - hole_num
        if abs(holes_up) > holes_remaining:
            finished_on = hole_num

        results.append(SixesHoleResult(
            segment        = seg,
            hole_number    = hole_num,
            team1_best_net = t1_net,
            team2_best_net = t2_net,
            winning_team   = winner,
            holes_up_after = holes_up,
        ))

        if finished_on:
            break

    SixesHoleResult.objects.bulk_create(results)

    # ── Update segment status ──────────────────────────────────────────────
    holes_played = len(results)
    holes_in_seg = seg.end_hole - seg.start_hole + 1

    if holes_played == 0:
        seg.status = 'pending'
    elif holes_played < holes_in_seg and finished_on is None:
        seg.status = 'in_progress'
    else:
        # Complete (all holes played OR early finish)
        if holes_up > 0:
            seg.status   = 'complete'
            t1.is_winner = True
            t2.is_winner = False
        elif holes_up < 0:
            seg.status   = 'complete'
            t1.is_winner = False
            t2.is_winner = True
        else:
            seg.status   = 'halved'
            t1.is_winner = False
            t2.is_winner = False
        t1.save(update_fields=['is_winner'])
        t2.save(update_fields=['is_winner'])

    seg.save(update_fields=['status'])
    return results, finished_on


# ---------------------------------------------------------------------------
# Strokes-Off overlay helpers (see calculate_sixes below for why they exist)
# ---------------------------------------------------------------------------

def _overlay_so_strokes_for_segment(seg, segment_idx, player_so, member_by_pid, score_index):
    """
    Apply this standard segment's SO strokes to *score_index* in place.

    For each player with SO > 0 we compute how many strokes they receive
    in this match — floor(SO/3), plus 1 for the first SO%3 matches — and
    allocate those strokes to the hardest holes (lowest stroke index) in
    this segment's *actual* range (seg.start_hole..seg.end_hole), then
    subtract from the player's per-hole score.

    Returns a {player_id: {hole_number: strokes_applied}} dict so the
    caller can undo strokes on holes that were never reached if the match
    ends early (preventing the next segment from double-counting them).
    """
    applied: dict = {}
    for pid, so in player_so.items():
        if so <= 0:
            continue
        member = member_by_pid.get(pid)
        if member is None or member.tee_id is None:
            continue
        strokes_this_seg = _strokes_for_segment_index(so, segment_idx)
        if strokes_this_seg <= 0:
            continue
        holes_with_si = [
            (h, member.tee.hole(h).get('stroke_index', 18))
            for h in range(seg.start_hole, seg.end_hole + 1)
        ]
        allocation = _allocate_segment_strokes(strokes_this_seg, holes_with_si)
        player_entries = score_index.get(pid)
        if not player_entries:
            continue
        for h, strokes in allocation.items():
            if h in player_entries:
                player_entries[h] -= strokes
                applied.setdefault(pid, {})[h] = strokes
    return applied


def _overlay_so_strokes_for_extras(start_hole, player_so, member_by_pid, score_index):
    """
    Apply the extras SO rule to every remaining hole in one shot.

    For holes start_hole..18, any hole whose stroke_index <= the player's
    SO grants that player one stroke (subtracted from score_index in
    place).  Used once, just before the extras chain scores.
    """
    for pid, so in player_so.items():
        if so <= 0:
            continue
        member = member_by_pid.get(pid)
        if member is None or member.tee_id is None:
            continue
        player_entries = score_index.get(pid)
        if not player_entries:
            continue
        for h in range(start_hole, 19):
            if h in player_entries:
                si = member.tee.hole(h).get('stroke_index', 18)
                if si <= so:
                    player_entries[h] -= 1


@transaction.atomic
def calculate_sixes(foursome) -> list:
    """
    Calculate SixesHoleResult rows for all segments in this foursome.

    Key behaviour:
    * Standard segments (is_extra=False) have their start/end holes
      dynamically repositioned on each call: if a previous segment ended
      early, the next one shifts left so it starts on the very next hole.
    * After all three standard segments, any holes remaining before hole 18
      form a single extra segment (is_extra=True).  If no holes remain the
      extra segment is deleted.
    * The extra segment's teams must be assigned separately (loser's choice)
      via the /sixes/extra-teams/ endpoint; once teams exist the segment is
      scored like any other.

    Returns a flat list of all SixesHoleResult instances saved this call.
    """
    segments = list(
        SixesSegment.objects.filter(foursome=foursome)
        .prefetch_related('teams__players')
        .order_by('segment_number', 'start_hole')
    )
    if not segments:
        return []

    # All segments of the same foursome share the same handicap settings —
    # setup_sixes writes the same values to each one — so reading them off
    # the first segment is sufficient.
    first_seg     = segments[0]
    handicap_mode = first_seg.handicap_mode or HandicapMode.NET
    net_percent   = first_seg.net_percent or 100

    standard_segs = [s for s in segments if not s.is_extra]
    extra_segs    = [s for s in segments if s.is_extra]

    # score_index: player_id → hole_number → score_to_compare
    #
    # Non-SO modes: build the whole index once up front — strokes don't
    # depend on segment positions so pre-computing is fine.
    #
    # SO mode: segment stroke allocation depends on each match's actual
    # range, which depends on where the previous match ended.  That's a
    # chicken-and-egg with a pre-built index, so instead we start from a
    # gross index and overlay each standard segment's strokes *just in
    # time*, right after we've repositioned that segment.  When a match
    # ends early, we also undo the strokes on unplayed holes so the next
    # segment doesn't inherit a double discount on its first hole.
    so_mode = handicap_mode == HandicapMode.STROKES_OFF
    if so_mode:
        score_index = build_score_index(
            foursome,
            handicap_mode=HandicapMode.GROSS,
        )
        memberships = list(
            foursome.memberships
            .select_related('player', 'tee')
            .filter(player__is_phantom=False)
        )
        phcps = [m.playing_handicap for m in memberships
                 if m.playing_handicap is not None]
        low = min(phcps) if phcps else 0
        player_so = {
            m.player_id: round(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
            for m in memberships
        }
        member_by_pid = {m.player_id: m for m in memberships}
    else:
        score_index = build_score_index(
            foursome,
            handicap_mode=handicap_mode,
            net_percent=net_percent,
            segments=segments,
        )
        player_so = {}
        member_by_pid = {}

    all_results = []
    current_hole = 1  # tracks the first hole of the next match

    # ── Score standard segments ────────────────────────────────────────────
    for idx, seg in enumerate(standard_segs):
        # Reposition this segment so it starts right after the previous one.
        expected_end = min(current_hole + 5, 18)
        if seg.start_hole != current_hole or seg.end_hole != expected_end:
            seg.start_hole = current_hole
            seg.end_hole   = expected_end
            seg.save(update_fields=['start_hole', 'end_hole'])

        # SO mode: overlay this segment's strokes on the gross score_index
        # *after* repositioning, so we allocate strokes against the range
        # the match is actually playing (not the canonical/pre-reposition
        # range).
        so_applied: dict = {}
        if so_mode:
            so_applied = _overlay_so_strokes_for_segment(
                seg, idx, player_so, member_by_pid, score_index
            )

        results, finished_on = _score_segment(seg, score_index)
        all_results.extend(results)

        # Advance pointer: next match starts right after this one ends.
        if finished_on:
            # Undo SO strokes on holes that were never played.  Without this,
            # the next segment would inherit those strokes in the shared
            # score_index and then add its own — producing a double discount
            # on the first hole of the new segment.
            if so_mode and so_applied:
                for pid, hole_strokes in so_applied.items():
                    player_entries = score_index.get(pid)
                    if not player_entries:
                        continue
                    for h, strokes in hole_strokes.items():
                        if h > finished_on and h in player_entries:
                            player_entries[h] += strokes  # undo
            current_hole = finished_on + 1   # early finish — start immediately
        else:
            current_hole = seg.end_hole + 1  # normal end

    # ── Extra match chain ─────────────────────────────────────────────────────
    # Any holes freed by early finishes are collected into one or more extra
    # segments.  If an extra match itself ends early another one starts
    # immediately after, just as standard matches do.
    if current_hole <= 18:
        # SO mode: apply the extras SI-threshold rule to every remaining
        # hole before we score any extra segment.  A player with SO=N gets
        # one stroke on any hole whose stroke_index <= N.
        if so_mode:
            _overlay_so_strokes_for_extras(
                current_hole, player_so, member_by_pid, score_index
            )
        extra_segs_sorted = sorted(extra_segs, key=lambda s: s.segment_number)
        extra_idx     = 0
        extra_current = current_hole
        processed_ids: set = set()

        while extra_current <= 18:
            if extra_idx < len(extra_segs_sorted):
                # Reuse an existing extra segment, repositioning if needed.
                extra = extra_segs_sorted[extra_idx]
                if extra.start_hole != extra_current or extra.end_hole != 18:
                    extra.start_hole = extra_current
                    extra.end_hole   = 18
                    extra.save(update_fields=['start_hole', 'end_hole'])
            else:
                # Create a new extra segment.  It inherits handicap_mode /
                # net_percent from the standard segments so the whole match
                # is played under one consistent set of rules.
                all_so_far  = standard_segs + extra_segs_sorted[:extra_idx]
                max_seg_num = max((s.segment_number for s in all_so_far), default=3)
                extra = SixesSegment.objects.create(
                    foursome       = foursome,
                    segment_number = max_seg_num + 1,
                    start_hole     = extra_current,
                    end_hole       = 18,
                    is_extra       = True,
                    status         = 'pending',
                    handicap_mode  = handicap_mode,
                    net_percent    = net_percent,
                )

            processed_ids.add(extra.id)
            results, finished_on = _score_segment(extra, score_index)
            all_results.extend(results)

            # Chain: if this extra ended early, start another immediately after.
            if finished_on is not None and finished_on < 18:
                extra_current = finished_on + 1
                extra_idx    += 1
            else:
                break  # pending, in-progress, or used all remaining holes

        # Remove stale extra segments that are no longer needed.
        stale_ids = [e.id for e in extra_segs_sorted if e.id not in processed_ids]
        if stale_ids:
            SixesSegment.objects.filter(id__in=stale_ids).delete()
    else:
        # All holes consumed by standard matches — remove any stale extras.
        SixesSegment.objects.filter(foursome=foursome, is_extra=True).delete()

    return all_results


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def sixes_summary(foursome) -> dict:
    """
    Return a summary dict:
    {
        'segments': [
            {
                'label'      : 'Holes 1–6 (Match 1)',
                'is_extra'   : False,
                'status'     : 'complete',
                'winner'     : 'Team 1' | 'Team 2' | 'Halved',
                'team1'      : { 'players': [...names...], 'method': str },
                'team2'      : { 'players': [...names...], 'method': str },
                'holes'      : [{'hole': n, 't1_net': x, 't2_net': y,
                                 'winner': 'T1'|'T2'|'Halved', 'margin': n}],
            },
            ...
        ],
        'overall': {
            'team1_wins'   : int,
            'team2_wins'   : int,
            'halves'       : int,
        }
    }
    """
    segments = (
        SixesSegment.objects
        .filter(foursome=foursome)
        .prefetch_related('teams__players', 'hole_results__winning_team')
        .order_by('segment_number', 'start_hole')
    )

    seg_out = []
    t1_total_wins = t2_total_wins = halves = 0

    # All segments share the same handicap config; read it off the first.
    first = segments.first() if hasattr(segments, 'first') else (list(segments)[0] if segments else None)
    handicap_mode = getattr(first, 'handicap_mode', HandicapMode.NET) if first else HandicapMode.NET
    net_percent   = getattr(first, 'net_percent', 100) if first else 100

    # Per-player running money total for this foursome.  One unit per
    # decided match — winners +bet_unit, losers -bet_unit, halved = 0.
    # Phantoms are skipped so they never appear in the leaderboard.
    bet_unit    = float(foursome.round.bet_unit)
    money_totals = {}  # player_id → {'name': ..., 'amount': float}

    for i, seg in enumerate(segments, start=1):
        teams  = list(seg.teams.all())
        t1     = next((t for t in teams if t.team_number == 1), None)
        t2     = next((t for t in teams if t.team_number == 2), None)

        # Resolve winner label AND credit/debit each real player on the
        # winning / losing team for this segment's decided result.  We
        # only move money on 'complete' with an is_winner=True team; a
        # 'halved' segment is a wash and 'pending'/'in_progress' haven't
        # paid out yet.
        winning_team = None
        losing_team  = None
        if seg.status == 'complete':
            if t1 and t1.is_winner:
                winner_label = 'Team 1'
                t1_total_wins += 1
                winning_team, losing_team = t1, t2
            elif t2 and t2.is_winner:
                winner_label = 'Team 2'
                t2_total_wins += 1
                winning_team, losing_team = t2, t1
            else:
                winner_label = 'Halved'
                halves += 1
        elif seg.status == 'halved':
            winner_label = 'Halved'
            halves += 1
        else:
            winner_label = '—'

        if winning_team is not None and losing_team is not None:
            for p in winning_team.players.all():
                if p.is_phantom:
                    continue
                entry = money_totals.setdefault(p.id, {'name': p.name, 'amount': 0.0})
                entry['amount'] += bet_unit
            for p in losing_team.players.all():
                if p.is_phantom:
                    continue
                entry = money_totals.setdefault(p.id, {'name': p.name, 'amount': 0.0})
                entry['amount'] -= bet_unit

        extra_label = ' (extra)' if seg.is_extra else ''

        # For completed matches that ended early, show the actually-played
        # range rather than the potential range.  seg.end_hole is still the
        # potential end (we don't trim it during repositioning) so we reach
        # into hole_results for the last hole that was scored.
        hole_results_list = list(seg.hole_results.all())
        if (seg.status in ('complete', 'halved')
                and hole_results_list
                and hole_results_list[-1].hole_number < seg.end_hole):
            display_end = hole_results_list[-1].hole_number
        else:
            display_end = seg.end_hole
        label = f"Holes {seg.start_hole}–{display_end} (Match {i}{extra_label})"

        holes_out = []
        for hr in hole_results_list:
            if hr.winning_team is None:
                hole_winner = 'Halved'
            elif hr.winning_team.team_number == 1:
                hole_winner = 'T1'
            else:
                hole_winner = 'T2'
            holes_out.append({
                'hole'    : hr.hole_number,
                't1_net'  : hr.team1_best_net,
                't2_net'  : hr.team2_best_net,
                'winner'  : hole_winner,
                'margin'  : hr.holes_up_after,
            })

        seg_out.append({
            'label'      : label,
            'start_hole' : seg.start_hole,
            'end_hole'   : seg.end_hole,
            'is_extra'   : seg.is_extra,
            'status'     : seg.status,
            'winner'   : winner_label,
            'team1'    : {
                'players' : [p.name for p in t1.players.all()] if t1 else [],
                'method'  : t1.team_select_method if t1 else '',
            },
            'team2'    : {
                'players' : [p.name for p in t2.players.all()] if t2 else [],
                'method'  : t2.team_select_method if t2 else '',
            },
            'holes'    : holes_out,
        })

    # Emit money sorted by amount desc then name so the leaderboard is
    # stable as scores come in; ensure every real player in the foursome
    # appears even if they haven't been involved in a decided match yet.
    for m in foursome.memberships.select_related('player').all():
        if m.player.is_phantom:
            continue
        money_totals.setdefault(m.player_id,
                                {'name': m.player.name, 'amount': 0.0})
    money_out = sorted(
        money_totals.values(),
        key=lambda e: (-e['amount'], e['name']),
    )

    return {
        'segments': seg_out,
        'overall' : {
            'team1_wins' : t1_total_wins,
            'team2_wins' : t2_total_wins,
            'halves'     : halves,
        },
        'handicap' : {
            'mode'        : handicap_mode,
            'net_percent' : net_percent,
        },
        'money' : {
            'bet_unit'  : bet_unit,
            'by_player' : money_out,
        },
    }
