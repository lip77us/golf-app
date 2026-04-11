"""
services/scramble.py
--------------------
Scramble calculator.

Rules
~~~~~
* The foursome plays as a team — all players tee off, best drive is selected,
  all play from there, repeat until holed.
* One gross score per hole per foursome (entered as ScrambleHoleScore).
* Team handicap = average of playing handicaps × handicap_pct
  (from Round.scramble_config, default 20%).
* Team handicap strokes are allocated across holes by stroke index
  (same logic as individual handicaps).
* Net score = gross - handicap strokes on hole.
* Foursomes ranked by lowest total net score.

Public API
~~~~~~~~~~
    results = calculate_scramble(round_obj)
    summary = scramble_summary(round_obj)
"""

import math
from django.db import transaction

from games.models import ScrambleHoleScore, ScrambleResult
from tournament.models import Foursome, FoursomeMembership


def _team_handicap(foursome, handicap_pct: float) -> int:
    """
    Calculate team playing handicap for a scramble.
    Average of real players' playing handicaps × handicap_pct, rounded.
    """
    memberships = (
        FoursomeMembership.objects
        .filter(foursome=foursome, player__is_phantom=False)
        .values_list('playing_handicap', flat=True)
    )
    hcps = list(memberships)
    if not hcps:
        return 0
    avg = sum(hcps) / len(hcps)
    return round(avg * handicap_pct)


def _handicap_strokes_on_hole(team_handicap: int, stroke_index: int) -> int:
    """Same allocation logic as FoursomeMembership.handicap_strokes_on_hole."""
    full_strokes = team_handicap // 18
    remainder    = team_handicap % 18
    extra        = 1 if stroke_index <= remainder else 0
    return full_strokes + extra


@transaction.atomic
def calculate_scramble(round_obj) -> list:
    """
    Calculate ScrambleResult rows for every foursome in the round.

    Reads scramble_config from the Round:
        {'min_drives_per_player': 2, 'handicap_pct': 0.20}
    handicap_pct defaults to 0.20 if not set.

    Safe to call repeatedly — previous results are replaced.

    Returns a list of ScrambleResult instances ordered by rank.
    """
    config       = round_obj.scramble_config or {}
    handicap_pct = float(config.get('handicap_pct', 0.20))
    tee          = round_obj.course

    foursomes = list(Foursome.objects.filter(round=round_obj).order_by('group_number'))

    # Pre-calculate team handicaps
    team_hcps = {fs.pk: _team_handicap(fs, handicap_pct) for fs in foursomes}

    # Fetch all scramble hole scores keyed by foursome_id → hole_number
    hole_scores = (
        ScrambleHoleScore.objects
        .filter(foursome__round=round_obj)
        .exclude(gross_score=None)
        .values('foursome_id', 'hole_number', 'gross_score')
    )
    score_index: dict = {}
    for hs in hole_scores:
        score_index.setdefault(hs['foursome_id'], {})[hs['hole_number']] = hs['gross_score']

    ScrambleResult.objects.filter(round=round_obj).delete()
    fs_results = []

    for foursome in foursomes:
        team_hcp   = team_hcps[foursome.pk]
        fs_scores  = score_index.get(foursome.pk, {})
        total_gross = total_net = 0
        complete    = True

        for hole_data in tee.holes:
            hole_number  = hole_data['number']
            stroke_index = hole_data['stroke_index']
            gross        = fs_scores.get(hole_number)

            if gross is None:
                complete = False
                continue

            strokes    = _handicap_strokes_on_hole(team_hcp, stroke_index)
            net        = gross - strokes
            total_gross += gross
            total_net   += net

            # Update ScrambleHoleScore with calculated values
            ScrambleHoleScore.objects.filter(
                foursome=foursome, hole_number=hole_number
            ).update(handicap_strokes=strokes, net_score=net)

        fs_results.append({
            'foursome'    : foursome,
            'total_gross' : total_gross if complete else None,
            'total_net'   : total_net   if complete else None,
        })

    # Rank by total net (lowest wins); incomplete rounds unranked
    completed = [r for r in fs_results if r['total_net'] is not None]
    completed.sort(key=lambda r: r['total_net'])
    rank_map: dict = {}
    rank = 1
    for i, r in enumerate(completed):
        if i > 0 and r['total_net'] > completed[i - 1]['total_net']:
            rank = i + 1
        rank_map[r['foursome'].pk] = rank

    saved = []
    for r in fs_results:
        result = ScrambleResult.objects.create(
            round       = round_obj,
            foursome    = r['foursome'],
            total_gross = r['total_gross'],
            total_net   = r['total_net'],
            rank        = rank_map.get(r['foursome'].pk),
        )
        saved.append(result)

    return saved


def scramble_summary(round_obj) -> list:
    """
    Return ranked scramble results as a list of dicts:
        {
            'rank'        : int or None,
            'group'       : str,
            'players'     : str,
            'total_gross' : int or None,
            'total_net'   : int or None,
        }
    """
    results = (
        ScrambleResult.objects
        .filter(round=round_obj)
        .select_related('foursome')
        .order_by('rank', 'foursome__group_number')
    )

    summary = []
    for r in results:
        players = ', '.join(
            m.player.name for m in
            r.foursome.memberships.filter(player__is_phantom=False)
                                  .select_related('player')
                                  .order_by('player__name')
        )
        summary.append({
            'rank'        : r.rank,
            'group'       : f"Group {r.foursome.group_number}",
            'players'     : players,
            'total_gross' : r.total_gross,
            'total_net'   : r.total_net,
        })

    return summary
