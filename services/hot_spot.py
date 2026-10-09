"""
services/hot_spot.py
--------------------
Hot Spot calculator.

Rules
~~~~~
* A field of foursomes, one pool, paid to the winning GROUP — the Irish
  Rumble money model, reused verbatim.
* On every hole one golfer is the ANCHOR and his score counts whatever it
  is.  The team adds the BEST NET OF THE OTHER THREE.  Two scores count.
* The anchor rotates on an order each group sets on the first tee
  (``Foursome.hot_spot_order``), repeating every four holes.  Over eighteen
  that gives the first two golfers five holes each and the other two four.
* The last two holes are the organiser's call (``HotSpotConfig.finish_rule``):
  keep rotating, best 2, or three then four.
* Every score is capped at net double bogey — a RULE here, not the round's
  opt-in setting, because carrying the anchor's bad hole IS the format and
  an uncapped blow-up would decide the field on one hole.
* A threesome borrows a 4th from the field exactly as Rumble does.  The
  borrowed ball can BE the best net of the others; it never anchors.

What is shared, and what is not
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Handicap treatment, the cap and the borrowed 4th come from
``services.irish_rumble``; the board, the tie rule and the pool split come
from ``services.group_field``.  The one thing Hot Spot owns is the per-hole
SELECTION, which it hands to ``group_standings`` as ``select_scores``.  That
is deliberate: the money is the thing two copies would eventually disagree
about, so there is one copy of it and Hot Spot adds a function.

Stableford is a DISPLAY of the same ranking, not a second competition
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Standard Stableford points are ``max(0, 2 - (net - par))``, and the forced
cap already pins every score at ``par + 2`` or better — so no score ever
reaches the flat 0 region where the mapping stops being linear.  Points per
counting ball are therefore exactly ``2 - diff``, and a group's total is
``2 * n - net_to_par`` where ``n`` is the number of counting balls, which is
the SAME for every group in a round.  Ranking high-to-low on points is
identical to ranking low-to-high on net-to-par.

So there is one ranking and ``scoring`` picks the column.  Do not "fix" this
by adding a descending sort: that would be a second ordering authority over
one competition, and the two would eventually disagree on a tie.

Public API
~~~~~~~~~~
    config  = setup_hot_spot(round_obj, ...)
    plan    = hole_plan_for(round_obj, foursome, config)
    order   = anchor_order(foursome)
    results = calculate_hot_spot(round_obj)
    summary = hot_spot_summary(round_obj)
"""
from django.db import transaction

from games.models import HotSpotConfig, HotSpotResult
from scoring.models import HoleScore
from tournament.models import Foursome
from services.hole_plan import play_order
from services.irish_rumble import (_build_ir_score_index, _par_index_for_round,
                                   ensure_irish_rumble_phantom)


class HotSpotLocked(Exception):
    """The anchor order cannot change once the group has posted a score."""


# ── the anchor order ────────────────────────────────────────────────────────

def real_player_ids(foursome) -> list:
    """The group's real golfers, in card order. The borrowed 4th is excluded
    because it never anchors."""
    return [m.player_id for m in
            foursome.memberships.filter(player__is_phantom=False)
                    .select_related('player').order_by('id')]


def anchor_order(foursome) -> list:
    """The group's anchor order, or card order when they have not set one.

    A fallback rather than a refusal: an unset order must not make a round
    unscoreable, and card order is the only neutral answer. The client still
    prompts on the first tee — ``order_is_set`` is what it asks.
    """
    stored = list(foursome.hot_spot_order or [])
    real = real_player_ids(foursome)
    # Keep only golfers still in the group, then append anyone the stored
    # order does not mention (a golfer added after it was set).
    kept = [pid for pid in stored if pid in real]
    return kept + [pid for pid in real if pid not in kept]


def order_is_set(foursome) -> bool:
    stored = [pid for pid in (foursome.hot_spot_order or [])
              if pid in real_player_ids(foursome)]
    return len(stored) == len(real_player_ids(foursome)) and bool(stored)


def has_any_real_score(foursome) -> bool:
    return HoleScore.objects.filter(
        foursome=foursome, gross_score__isnull=False,
        player__is_phantom=False).exists()


@transaction.atomic
def set_anchor_order(foursome, player_ids) -> list:
    """Set the group's anchor order. Refused once a real score is posted.

    The lock is the first score, not the edit ceiling: the order decides who
    anchored hole 1, so changing it after that hole is scored rewrites what
    that hole meant. Same reasoning as Banker's window of zero.
    """
    if has_any_real_score(foursome):
        raise HotSpotLocked(
            'The anchor order is set on the first tee and locks when the '
            'first score goes in — it decides who anchored hole 1.')
    real = set(real_player_ids(foursome))
    ids = [int(p) for p in player_ids]
    if set(ids) != real or len(ids) != len(real):
        raise HotSpotLocked(
            'The anchor order must name every real golfer in the group '
            'exactly once.')
    foursome.hot_spot_order = ids
    foursome.save(update_fields=['hot_spot_order'])
    return ids


# ── setup ──────────────────────────────────────────────────────────────────

@transaction.atomic
def setup_hot_spot(round_obj, *, scoring='to_par', handicap_mode=None,
                   net_percent=85, finish_rule='keep_rotating',
                   entry_fee=None, payouts=None) -> HotSpotConfig:
    """Create or update the round's config, then rescore.

    Strokes-off-low is refused rather than silently coerced: it plays a golfer
    off the LOW man, and a field of foursomes has no single low man to play
    off — the same reason individual play does not offer it.
    """
    from core.models import HandicapMode
    mode = handicap_mode or HandicapMode.NET
    if mode not in (HandicapMode.NET, HandicapMode.GROSS):
        raise ValueError(
            'Hot Spot is net or gross: strokes off the low golfer needs one '
            'low golfer, and a field of groups does not have one.')

    defaults = {
        'scoring': scoring,
        'handicap_mode': mode,
        'net_percent': max(50, min(130, int(net_percent))),
        'finish_rule': finish_rule,
    }
    if entry_fee is not None:
        defaults['entry_fee'] = entry_fee
    if payouts is not None:
        defaults['payouts'] = payouts

    config, _ = HotSpotConfig.objects.update_or_create(
        round=round_obj, defaults=defaults)
    calculate_hot_spot(round_obj)
    return config


# ── the per-hole plan ───────────────────────────────────────────────────────

def hole_plan_for(round_obj, foursome, config) -> dict:
    """``{hole_number: {'anchor': player_id|None, 'count': int}}``.

    Keyed by hole NUMBER so callers can look a hole up, but derived from the
    group's PLAY ORDER — a shotgun group starting on the 7th rotates from its
    own first tee, and "the last two holes" are the last two it plays, not
    the 17th and 18th on the card. Hole number and play position are the same
    integer only on a round that starts at the 1st, which is exactly why this
    is easy to get wrong.
    """
    holes = play_order(round_obj, foursome)
    order = anchor_order(foursome)
    n_real = len(order)
    out = {}
    if not holes or not n_real:
        return out

    last_two = set(holes[-2:])
    finish = config.finish_rule

    for pos, hole in enumerate(holes):
        if hole in last_two and finish != 'keep_rotating':
            if finish == 'best_2':
                out[hole] = {'anchor': None, 'count': 2}
            else:                                   # three_then_four
                out[hole] = {'anchor': None,
                             'count': 3 if hole == holes[-2] else 4}
            continue
        # The rotation counts only the holes it actually governs, so under
        # best_2 / three_then_four the last two do not consume a turn.
        out[hole] = {'anchor': order[pos % n_real], 'count': 2}
    return out


def _counting_scores(plan_for_hole, hole_scores, n_players):
    """The scores that count on one hole.

    ``hole_scores`` is ``{player_id: score}`` for everyone with a score,
    including the borrowed 4th. Returns ``[]`` when the hole cannot be scored
    yet, which is what keeps a part-scored hole out of the running total.
    """
    anchor = plan_for_hole['anchor']
    count = plan_for_hole['count']

    if anchor is None:
        # No anchor: the best `count` of whoever is in, and every ball the
        # group is expected to post has to be there first.
        if len(hole_scores) < min(count, n_players):
            return []
        return sorted(hole_scores.values())[:count]

    if anchor not in hole_scores:
        return []                      # the anchor's score IS the hole
    others = [s for pid, s in hole_scores.items() if pid != anchor]
    if not others:
        return []
    return [hole_scores[anchor], min(others)]


def _selector(round_obj, config, foursomes):
    """Build the ``select_scores`` callable ``group_standings`` takes."""
    plans = {fs.pk: hole_plan_for(round_obj, fs, config) for fs in foursomes}

    def select(fid, hole_num, fs_scores, n_players):
        plan = plans.get(fid, {}).get(hole_num)
        if plan is None:
            return []
        hole_scores = {pid: holes[hole_num]
                       for pid, holes in fs_scores.items()
                       if hole_num in holes}
        if not hole_scores:
            return []
        return _counting_scores(plan, hole_scores, n_players)

    return select, plans


def _score_index(round_obj, config, capped_out=None):
    """Capped, handicapped scores. ``force_cap`` because the cap is a RULE of
    Hot Spot, not the round's opt-in setting — see the module docstring.

    ``capped_out`` collects which scores were actually clamped, for the card's
    amber outline. A capped score reads ``par + 2`` exactly like a genuine net
    double bogey, so it cannot be told apart after the fact."""
    return _build_ir_score_index(
        round_obj, config.handicap_mode, config.net_percent,
        force_cap=True, capped_out=capped_out)


# ── calculate / summary ─────────────────────────────────────────────────────

@transaction.atomic
def calculate_hot_spot(round_obj) -> list:
    """Rebuild ``HotSpotResult`` for every foursome. Safe to call repeatedly."""
    config = HotSpotConfig.objects.filter(round=round_obj).first()
    if config is None:
        return []

    # Same place Rumble does it, and for the same reason: an existing round
    # picks the borrowed 4th up on the next score without a setup re-save.
    ensure_irish_rumble_phantom(round_obj)

    foursomes = list(Foursome.objects.filter(round=round_obj)
                     .order_by('group_number'))
    rows = _standings(round_obj, config, foursomes)

    HotSpotResult.objects.filter(round=round_obj).delete()
    saved = [
        HotSpotResult(
            round=round_obj,
            foursome_id=r['foursome_id'],
            total=r['net_to_par'],
            holes_in=r.get('holes_in') or 0,
            rank=r['rank'],
        )
        for r in rows
    ]
    HotSpotResult.objects.bulk_create(saved)
    return saved


def _standings(round_obj, config, foursomes):
    from services.group_field import field_pool, group_standings  # noqa: F401

    select, plans = _selector(round_obj, config, foursomes)
    score_index = _score_index(round_obj, config)
    par_by_hole = _par_index_for_round(round_obj)

    rows = group_standings(
        round_obj,
        balls_by_hole={},               # unused — the selector decides
        score_index=score_index,
        par_by_hole=par_by_hole,
        entry_fee=config.entry_fee,
        payouts=config.payouts or [],
        net_percent=config.net_percent,
        select_scores=select,
    )

    # Counting balls per group, for the Stableford column and for "thru".
    for row in rows:
        fid = row['foursome_id']
        fs_scores = score_index.get(fid, {})
        plan = plans.get(fid, {})
        balls = holes_in = 0
        for hole_num, p in plan.items():
            hole_scores = {pid: h[hole_num] for pid, h in fs_scores.items()
                           if hole_num in h}
            counting = _counting_scores(p, hole_scores,
                                        row.get('n_players') or 4)
            if counting:
                balls += len(counting)
                holes_in += 1
        row['holes_in'] = holes_in
        row['counting_balls'] = balls
        ntp = row.get('net_to_par')
        # See the module docstring: points are 2 per counting ball minus the
        # net-to-par, exactly, because the cap keeps the mapping linear.
        row['points'] = None if ntp is None else (2 * balls - ntp)
    return rows


def hot_spot_summary(round_obj) -> dict:
    """The board, plus what each card needs to draw a hole."""
    config = HotSpotConfig.objects.filter(round=round_obj).first()
    if config is None:
        return {'configured': False, 'overall': [], 'groups': []}

    from services.group_field import field_pool, player_counts

    foursomes = list(Foursome.objects.filter(round=round_obj)
                     .order_by('group_number'))
    # The SAME count the board uses. `len(fs_scores)` would be "players with a
    # score so far", which is a different number, and the card would then
    # disagree with the board about which balls counted on a part-scored
    # no-anchor hole.
    counts = player_counts(round_obj)
    rows = _standings(round_obj, config, foursomes)
    capped: dict = {}
    score_index = _score_index(round_obj, config, capped_out=capped)
    par_by_hole = _par_index_for_round(round_obj)
    plans = {fs.pk: hole_plan_for(round_obj, fs, config) for fs in foursomes}

    by_id = {fs.pk: fs for fs in foursomes}
    groups = []
    for fs in foursomes:
        plan = plans.get(fs.pk, {})
        fs_scores = score_index.get(fs.pk, {})
        order = anchor_order(fs)
        names = {m.player_id: (m.player.short_name or m.player.name)
                 for m in fs.memberships.select_related('player')}
        holes_out = []
        for hole_num in play_order(round_obj, fs):
            p = plan.get(hole_num)
            if p is None:
                continue
            hole_scores = {pid: h[hole_num] for pid, h in fs_scores.items()
                           if hole_num in h}
            counting = _counting_scores(p, hole_scores,
                                        counts.get(fs.pk, 4))
            # Which PLAYERS counted — the card tints these, so it has to be
            # the ids and not just the figures.
            counted_ids = []
            if counting:
                if p['anchor'] is not None:
                    counted_ids.append(p['anchor'])
                    others = sorted(
                        ((s, pid) for pid, s in hole_scores.items()
                         if pid != p['anchor']))
                    if others:
                        counted_ids.append(others[0][1])
                else:
                    counted_ids = [pid for _, pid in
                                   sorted((s, pid) for pid, s
                                          in hole_scores.items())][:p['count']]
            par = par_by_hole.get(hole_num, 4)
            holes_out.append({
                'hole': hole_num,
                'par': par,
                'anchor_id': p['anchor'],
                'anchor_short': names.get(p['anchor']) if p['anchor'] else None,
                'count': p['count'],
                'scores': {str(pid): s for pid, s in hole_scores.items()},
                'counted_ids': counted_ids,
                'capped_ids': sorted(
                    capped.get(fs.pk, {}).get(hole_num, set())),
                'counted_total': sum(counting) if counting else None,
                'to_par': (sum(counting) - par * len(counting))
                          if counting else None,
            })
        groups.append({
            'foursome_id': fs.pk,
            'group': fs.display_name,
            'order': order,
            'order_short': [names.get(pid) for pid in order],
            'order_is_set': order_is_set(fs),
            'order_locked': has_any_real_score(fs),
            'holes': holes_out,
        })

    return {
        'configured': True,
        'scoring': config.scoring,
        'handicap_mode': config.handicap_mode,
        'net_percent': config.net_percent,
        'finish_rule': config.finish_rule,
        'entry_fee': float(config.entry_fee),
        'payouts': config.payouts or [],
        'pool': field_pool(round_obj, config.entry_fee),
        'overall': rows,
        'groups': groups,
    }
