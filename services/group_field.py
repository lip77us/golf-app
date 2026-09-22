"""
services/group_field.py
-----------------------
**A group's best-N nets, ranked against the whole field.**

Two games ask this question and they differ in exactly one thing — whether the
count moves. Irish Rumble's count escalates as the round goes on and that
movement is the game; Better Ball's is fixed for all eighteen and that fixity
is the game. Everything after the count is identical: the same per-hole walk,
the same live running total, the same tie rule, the same pool paid to a GROUP
and split among its real golfers.

So the count is the argument and the standings are shared. The alternative was
two copies of a hundred lines that would agree on the day they were written —
and the thing they would eventually disagree about is money, which is the worst
place in the app for two implementations.

Both callers pass `balls_by_hole`. Rumble derives it from its segment list;
Better Ball from one number repeated eighteen times.

## Three rules that live here because both games owe them

**The board is live from hole 1.** The running total is built from per-hole
scores rather than from completed segments, so a group ranks after one hole
instead of after six.

**A borrowed 4th counts a ball and cannot be paid.** It levels a threesome up
to the field's largest group, so the group really does put four balls on the
hole — but it is not a person, so a place that pays a group splits among the
REAL golfers. Three ways at $23.33, not four ways at $17.50.

**Ties split the money for the PLACES THEY OCCUPY.** Two groups tied for 1st
share 1st and 2nd, rather than halving 1st and leaving 2nd unclaimed. No
countbacks: a tie can be no action, and an arbitrary tiebreak decides real
money on a rule nobody agreed to.
"""
from django.db.models import Max

from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership


def balls_by_hole_from_segments(segments) -> dict:
    """`{hole: balls}` from a list of `{start_hole, end_hole, balls_to_count}`."""
    out: dict = {}
    for seg in (segments or []):
        n = seg['balls_to_count']
        for h in range(seg['start_hole'], seg['end_hole'] + 1):
            out[h] = n
    return out


def player_counts(round_obj) -> dict:
    """`{foursome_id: balls the group puts on a hole}` — phantom included.

    The borrowed 4th is counted here on purpose: it is a ball in the group's
    pool. `n_real_players` on each row is what the money uses.
    """
    return {
        fs.pk: fs.memberships.filter(player__is_phantom=False).count()
               + (1 if fs.has_phantom else 0)
        for fs in Foursome.objects.filter(round=round_obj)
    }


def group_standings(round_obj, *, balls_by_hole, score_index, par_by_hole,
                    entry_fee, payouts, net_percent) -> list:
    """The overall board — one row per group, ranked, with the money on it.

    `score_index` is `{foursome_id: {player_id: {hole: capped_score}}}` as
    `irish_rumble._build_ir_score_index` builds it; the caller owns the
    handicap treatment, because that is the other thing the two games can
    legitimately disagree about.
    """
    from services.payout import (payouts_by_place, per_person_share,
                                 split_tied_places)

    foursomes = {fs.pk: fs for fs in Foursome.objects.filter(round=round_obj)}
    counts    = player_counts(round_obj)

    hole_progress = {
        row['foursome_id']: row['max_hole']
        for row in (
            HoleScore.objects
            .filter(foursome__round=round_obj, player__is_phantom=False)
            .exclude(gross_score=None)
            .values('foursome_id')
            .annotate(max_hole=Max('hole_number'))
        )
    }

    # Running total, hole by hole — live from the first one.
    running: dict = {}
    for fid in foursomes:
        fs_scores = score_index.get(fid, {})
        n_players = counts.get(fid, 4)
        score_acc = par_acc = 0
        has_any   = False
        for hole_num in range(1, 19):
            balls = min(balls_by_hole.get(hole_num, 1), n_players)
            on_hole = sorted([ph[hole_num] for ph in fs_scores.values()
                              if hole_num in ph])
            if not on_hole:
                continue
            score_acc += sum(on_hole[:balls])
            par_acc   += par_by_hole.get(hole_num, 4) * balls
            has_any    = True
        if has_any:
            running[fid] = {'score': score_acc, 'par': par_acc}

    def _ntp(fid):
        r = running.get(fid)
        return None if r is None else r['score'] - r['par']

    scored   = sorted((fid for fid in foursomes if fid in running), key=_ntp)
    unscored = [fid for fid in foursomes if fid not in running]

    rank = 1
    ranked_rows = []
    for i, fid in enumerate(scored):
        if i > 0 and _ntp(fid) > _ntp(scored[i - 1]):
            rank = i + 1
        ranked_rows.append({'foursome_id': fid, 'rank': rank})
    ranked_rows += [{'foursome_id': fid, 'rank': None} for fid in unscored]

    rank_payout = split_tied_places(
        payouts_by_place(payouts or []), [r['rank'] for r in ranked_rows])

    out = []
    for row in ranked_rows:
        fid = row['foursome_id']
        fs  = foursomes[fid]
        r   = running.get(fid)
        real_members = list(
            fs.memberships.filter(player__is_phantom=False)
              .select_related('player').order_by('player__name'))

        phantom_info = None
        if fs.has_phantom:
            from scoring.phantom import build_phantom_info
            phantom_info = build_phantom_info(fs, net_percent)

        # **Thru lags on a levelled threesome.** A hole is not complete until
        # its donor has posted too, so cap at the last contiguous hole where
        # the borrowed ball is also in — otherwise a group reads "thru 2"
        # while still waiting on hole 2.
        current_hole = hole_progress.get(fid)
        if fs.has_phantom and current_hole:
            fs_scores = score_index.get(fid, {})
            real_pids = {m.player_id for m in real_members}
            phantom_scores = next(
                (h for pid, h in fs_scores.items() if pid not in real_pids), {})
            complete_thru = 0
            for h in range(1, current_hole + 1):
                if h in phantom_scores:
                    complete_thru = h
                else:
                    break
            current_hole = complete_thru or None

        group_payout = rank_payout.get(row['rank'], 0.0)
        out.append({
            'rank'             : row['rank'],
            'foursome_id'      : fid,
            'group'            : fs.display_name,
            'players'          : ', '.join(m.player.name for m in real_members),
            'short_names'      : ' / '.join(m.player.short_name or m.player.name
                                            for m in real_members),
            'n_players'        : counts.get(fid, 4),
            'n_real_players'   : len(real_members),
            'has_phantom'      : fs.has_phantom,
            'phantom'          : phantom_info,
            'total_score'      : r['score'] if r else None,
            'net_to_par'       : _ntp(fid),
            'current_hole'     : current_hole,
            'payout'           : group_payout,
            'per_person_payout': per_person_share(group_payout,
                                                  len(real_members)),
            'split_ways'       : len(real_members),
        })
    return out


def field_pool(round_obj, entry_fee) -> float:
    """`entry_fee × the field` — golfers, never groups, and never a phantom."""
    n = FoursomeMembership.objects.filter(
        foursome__round=round_obj, player__is_phantom=False).count()
    return round(float(entry_fee) * n, 2)
