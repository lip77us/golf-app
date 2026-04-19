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
from scoring.handicap import build_score_index
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

    # score_index: player_id → hole_number → score_to_compare
    # Contents depend on handicap_mode (gross score, net at 100%, or net at
    # a custom percentage).  See scoring/handicap.py for the rules.
    score_index = build_score_index(
        foursome,
        handicap_mode=handicap_mode,
        net_percent=net_percent,
    )

    standard_segs = [s for s in segments if not s.is_extra]
    extra_segs    = [s for s in segments if s.is_extra]

    all_results = []
    current_hole = 1  # tracks the first hole of the next match

    # ── Score standard segments ────────────────────────────────────────────
    for seg in standard_segs:
        # Reposition this segment so it starts right after the previous one.
        expected_end = min(current_hole + 5, 18)
        if seg.start_hole != current_hole or seg.end_hole != expected_end:
            seg.start_hole = current_hole
            seg.end_hole   = expected_end
            seg.save(update_fields=['start_hole', 'end_hole'])

        results, finished_on = _score_segment(seg, score_index)
        all_results.extend(results)

        # Advance pointer: next match starts right after this one ends.
        if finished_on:
            current_hole = finished_on + 1   # early finish — start immediately
        else:
            current_hole = seg.end_hole + 1  # normal end

    # ── Extra match chain ─────────────────────────────────────────────────────
    # Any holes freed by early finishes are collected into one or more extra
    # segments.  If an extra match itself ends early another one starts
    # immediately after, just as standard matches do.
    if current_hole <= 18:
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

    for i, seg in enumerate(segments, start=1):
        teams  = list(seg.teams.all())
        t1     = next((t for t in teams if t.team_number == 1), None)
        t2     = next((t for t in teams if t.team_number == 2), None)

        if seg.status == 'complete':
            if t1 and t1.is_winner:
                winner_label = 'Team 1'
                t1_total_wins += 1
            elif t2 and t2.is_winner:
                winner_label = 'Team 2'
                t2_total_wins += 1
            else:
                winner_label = 'Halved'
                halves += 1
        elif seg.status == 'halved':
            winner_label = 'Halved'
            halves += 1
        else:
            winner_label = '—'

        extra_label = ' (extra)' if seg.is_extra else ''
        label = f"Holes {seg.start_hole}–{seg.end_hole} (Match {i}{extra_label})"

        holes_out = []
        for hr in seg.hole_results.all():
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
    }
