"""
services/sixes.py
-----------------
Six's calculator — 3 × 6-hole rotating-team best ball match play
within a foursome.

Rules
~~~~~
* The foursome plays 3 standard matches across 18 holes:
      Match 1: holes  1– 6
      Match 2: holes  7–12
      Match 3: holes 13–18
* Each match is two-vs-two best ball, using individual net scores.
* Team formation (one method per segment):
      1 – Long Drive   (segment 1 by default)
      2 – Random       (segment 2 by default)
      3 – Remainder    (segment 3 — the remaining pairing not yet used)
* Early finish / extra match:
      If a team wins their segment before the 6th hole (e.g. they go
      4&3 with 3 holes remaining), the leftover holes form a 4th
      segment.  The new segment is flagged is_extra=True.  Teams for
      the extra match are set via loser_choice (loser of the previous
      segment chooses their partner).
* Best ball: for each hole, take the lowest individual net score
  from each team; the team with the lower of those two wins the hole.
  A tie halves the hole.
* Match scoring: standard match play — win = +1, halve = 0.
  The match is over when one team leads by more holes than remain.
* Lowest net tiebreaker: if a segment is halved, the team with the
  lower combined net for that segment is declared the winner for
  bet-settlement purposes (halved = split the bet).

Workflow
~~~~~~~~
1. Call ``setup_sixes(foursome)`` once teams are decided to create
   SixesSegment and SixesTeam rows.  Team members are passed in as
   player-ID pairs; team_select_method per segment.
2. Call ``calculate_sixes(foursome)`` after each set of 6 holes
   (or whenever hole scores are entered) to update SixesHoleResult
   rows and segment statuses.

Public API
~~~~~~~~~~
    segments = setup_sixes(foursome, team_data)
    results  = calculate_sixes(foursome)
    summary  = sixes_summary(foursome)

team_data format
~~~~~~~~~~~~~~~~
    [
        {
            'start_hole': 1, 'end_hole': 6,
            'team_select_method': 'long_drive',
            'team1_player_ids': [pk, pk],
            'team2_player_ids': [pk, pk],
        },
        ...
    ]
For an extra match generated mid-round, include 'is_extra': True.
"""

from django.db import transaction

from games.models import SixesSegment, SixesTeam, SixesHoleResult
from scoring.models import HoleScore
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_sixes(foursome, team_data: list) -> list:
    """
    Create SixesSegment and SixesTeam rows for the given foursome.

    team_data is a list of dicts (see module docstring for format).
    Safe to call again — existing data is replaced.

    Returns a list of SixesSegment instances.
    """
    SixesSegment.objects.filter(foursome=foursome).delete()

    segments = []
    for i, td in enumerate(team_data, start=1):
        seg = SixesSegment.objects.create(
            foursome       = foursome,
            segment_number = i,
            start_hole     = td['start_hole'],
            end_hole       = td['end_hole'],
            is_extra       = td.get('is_extra', False),
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
    Return the lowest net score among this team's players on hole_number.
    score_index: player_id → hole_number → net_score
    """
    nets = [
        score_index[p_id][hole_number]
        for p_id in team.players.values_list('id', flat=True)
        if p_id in score_index and hole_number in score_index[p_id]
    ]
    return min(nets) if nets else None


@transaction.atomic
def calculate_sixes(foursome) -> list:
    """
    Calculate SixesHoleResult rows for all segments in this foursome.

    * Reads individual net scores from HoleScore (real players only).
    * Updates SixesHoleResult per hole, setting holes_up_after.
    * Sets SixesSegment.status and SixesTeam.is_winner when a segment
      concludes (either early finish or all holes played).
    * If a segment ends early and there is no is_extra segment already
      covering the leftover holes, one is automatically created with
      placeholder teams (loser_choice method, no players set yet).

    Returns a flat list of all SixesHoleResult instances.
    """
    segments = list(
        SixesSegment.objects.filter(foursome=foursome)
        .prefetch_related('teams__players')
        .order_by('segment_number', 'start_hole')
    )
    if not segments:
        return []

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

    all_results = []

    for seg in segments:
        teams = list(seg.teams.all())
        if len(teams) < 2:
            continue  # teams not yet set up (extra match pending)

        t1 = next((t for t in teams if t.team_number == 1), None)
        t2 = next((t for t in teams if t.team_number == 2), None)
        if not t1 or not t2:
            continue

        SixesHoleResult.objects.filter(segment=seg).delete()

        holes_up = 0  # positive = team1 leading
        finished_on = None
        results = []

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

            # Check if match is already mathematically over
            holes_remaining = seg.end_hole - hole_num  # after this hole
            if abs(holes_up) > holes_remaining:
                finished_on = hole_num

            hr = SixesHoleResult(
                segment        = seg,
                hole_number    = hole_num,
                team1_best_net = t1_net,
                team2_best_net = t2_net,
                winning_team   = winner,
                holes_up_after = holes_up,
            )
            results.append(hr)
            all_results.extend([hr])

            if finished_on:
                break

        SixesHoleResult.objects.bulk_create(results)

        # Update segment status and team winners
        holes_played = len(results)
        holes_in_seg = seg.end_hole - seg.start_hole + 1

        if holes_played == 0:
            seg.status = 'pending'
        elif holes_played < holes_in_seg and finished_on is None:
            seg.status = 'in_progress'
        else:
            # Segment is complete (all holes played OR early finish)
            if holes_up > 0:
                seg.status = 'complete'
                t1.is_winner = True
                t2.is_winner = False
            elif holes_up < 0:
                seg.status = 'complete'
                t1.is_winner = False
                t2.is_winner = True
            else:
                seg.status = 'halved'
                t1.is_winner = False
                t2.is_winner = False
            t1.save(update_fields=['is_winner'])
            t2.save(update_fields=['is_winner'])

            # ---- Early finish: check for leftover holes ----
            if finished_on and finished_on < seg.end_hole:
                leftover_start = finished_on + 1
                leftover_end   = seg.end_hole

                # Only create the extra segment if one doesn't already exist
                extra_exists = SixesSegment.objects.filter(
                    foursome   = foursome,
                    is_extra   = True,
                    start_hole = leftover_start,
                ).exists()

                if not extra_exists:
                    SixesSegment.objects.create(
                        foursome       = foursome,
                        segment_number = seg.segment_number + 1,
                        start_hole     = leftover_start,
                        end_hole       = leftover_end,
                        is_extra       = True,
                        status         = 'pending',
                    )
                    # Teams for the extra match must be set separately
                    # (loser of this segment chooses partner in person)

        seg.save(update_fields=['status'])

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
            'label'    : label,
            'is_extra' : seg.is_extra,
            'status'   : seg.status,
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
    }
