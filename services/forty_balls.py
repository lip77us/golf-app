"""
services/forty_balls.py
-----------------------
40 Balls — the Irish Rumble family's one game where the GROUP decides.

A foursome gets **40 balls** for the round and a threesome **30**; on each hole
it spends 0 to k of them and the best n nets count against n × par. Two 3s on a
par 4 for two balls is −2. Lowest total wins.

Nothing is chosen at setup. The count is picked hole by hole, AFTER the scores
are in, which is the whole game: the group sees its nets and then decides what
they are worth. Spend four on a hole everybody birdied and you have four fewer
for the closing stretch.

Rules (settled 26 Sep 2026; see
docs/design-review/handoff-forty-balls/HANDOFF.md)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* **Budget is 10 × group size**, derived from the roster at scoring time and
  never stored — a group that loses a player must not keep spending his ten.
  **No borrowed 4th**: a phantom cannot choose, and a ball nobody hit is not a
  ball the group may count.
* **Hole result** = sum of the counted scores − n × par. `0` balls is level,
  and contributes no score at all.
* **The threesome factor is 4/3, applied to the TOTAL and not per hole**, and
  only for ranking. −4 on 30 balls ranks as −5.3. Ties compare the unrounded
  figure, because rounding two different totals to one decimal is how a tie
  gets invented.
* **Only the most recent scored hole's count is editable.** Once the next hole
  has scores the one before it is settled — the choice was made with that
  hole's information and re-making it later is a different game.

The bounds
~~~~~~~~~~
The budget has to come out exactly, so each hole's count is confined::

    left  = B - spent_so_far
    after = holes remaining AFTER this one
    lo    = max(0, left - k * after)     # fewest that still lets B be reached
    hi    = min(k, left)                 # most that does not overshoot

`lo == hi` means the group has no choice left, and the app fills the rest in:
at `k` it is **no slack left** (every ball counts from here), at `0` it is
**budget spent** (scores still go in for the championship, but none of them
count). Those fills are flagged `app_set` so the board can draw them amber —
a run of 4s should read as arithmetic, not as a decision.

Public API
~~~~~~~~~~
    state    = hole_state(foursome, hole_number)   # lo, hi, left, slack, …
    set_count(foursome, hole_number, count)
    summary  = forty_balls_summary(round_obj)
"""
from fractions import Fraction

from core.models import HandicapMode
from games.models import FortyBallsConfig, FortyBallsHoleCount
from scoring.handicap import effective_hcp_for, make_strokes_fn
from scoring.models import HoleScore
from services.hole_plan import play_order
from tournament.models import Foursome

#: Balls per golfer. 4 × 10 = 40, 3 × 10 = 30.
BALLS_PER_GOLFER = 10

#: What a threesome's total is multiplied by so it can be ranked against a
#: foursome's. Kept EXACT (a Fraction) rather than 1.333…: the packet says ties
#: compare the unrounded figure, and a float would decide some of them on the
#: seventeenth decimal place.
THREESOME_FACTOR = Fraction(4, 3)


class FortyBallsLocked(Exception):
    """A count was submitted for a hole that is no longer the group's to pick."""


# ---------------------------------------------------------------------------
# The group
# ---------------------------------------------------------------------------

def _real_members(foursome) -> list:
    """The golfers who can spend a ball. **Phantoms cannot.**"""
    return [m for m in foursome.memberships.select_related('player', 'tee').all()
            if not m.player.is_phantom]


def group_size(foursome) -> int:
    return len(_real_members(foursome))


def budget(foursome) -> int:
    """10 balls a golfer — derived, never stored."""
    return BALLS_PER_GOLFER * group_size(foursome)


# ---------------------------------------------------------------------------
# One group's scores
# ---------------------------------------------------------------------------

def _config(round_obj):
    return getattr(round_obj, 'forty_balls_config', None)


def _scores_for(foursome, config) -> tuple:
    """``(nets, pars)`` — ``{hole: {player_id: score}}`` and ``{hole: par}``.

    The handicap adjustment and the double-bogey cap are applied HERE, before
    anything is chosen, because the group picks between the numbers it is shown
    and those are the numbers that count.
    """
    mode = config.handicap_mode if config else HandicapMode.NET
    pct  = config.net_percent if config else 100
    cap  = bool(config.net_max_double_bogey) if config else True

    members = _real_members(foursome)
    strokes_fn = make_strokes_fn(foursome)

    pars = {}
    first = next((m for m in members if m.tee_id), None)
    if first:
        pars = {h['number']: h['par'] for h in (first.tee.holes or [])}

    rows = (HoleScore.objects
            .filter(foursome=foursome, gross_score__isnull=False,
                    player__is_phantom=False)
            .values('player_id', 'hole_number', 'gross_score'))

    by_pid = {m.player_id: m for m in members}
    nets: dict = {}
    for r in rows:
        m = by_pid.get(r['player_id'])
        if m is None or m.tee_id is None:
            continue
        hole = r['hole_number']
        par = pars.get(hole)
        if mode == HandicapMode.GROSS:
            score = r['gross_score']
        else:
            score = r['gross_score'] - strokes_fn(
                effective_hcp_for(m, pct), m.tee, hole)
        if cap and par is not None:
            # The damage limiter, applied before the pick — net double bogey in
            # Net, gross in Gross.
            score = min(score, par + 2)
        nets.setdefault(hole, {})[r['player_id']] = score

    return nets, pars


def _fully_scored(foursome, nets, holes) -> list:
    """Holes where EVERY real golfer has a score, in play order.

    The picker appears only once the last score on a hole is in — the group
    cannot choose between nets it has not seen.
    """
    k = group_size(foursome)
    return [h for h in holes if len(nets.get(h, {})) >= k and k > 0]


# ---------------------------------------------------------------------------
# The bounds
# ---------------------------------------------------------------------------

def bounds(k: int, left: int, after: int) -> tuple:
    """``(lo, hi)`` — the counts this hole may take.

    ``after`` is the number of holes remaining AFTER this one. `lo` is the
    fewest that still lets the budget be reached; `hi` the most that does not
    overshoot it.
    """
    lo = max(0, left - k * after)
    hi = min(k, left)
    return lo, max(lo, hi)


def hole_state(foursome, hole_number: int) -> dict:
    """Everything the picker draws for one hole.

    ``slack`` is what the packet calls "balls you can still skip": the balls
    the group could still decline over the holes it has left. It starts at
    ``k × holes − B`` (8 for a foursome, 6 for a threesome) and only falls.
    """
    round_obj = foursome.round
    config = _config(round_obj)
    k = group_size(foursome)
    B = budget(foursome)
    holes = play_order(round_obj, foursome)

    counts = {c.hole_number: c for c in foursome.forty_balls_counts.all()}
    spent_before = sum(c.count for h, c in counts.items()
                       if h in holes and holes.index(h) < holes.index(hole_number)) \
        if hole_number in holes else 0

    pos = holes.index(hole_number) if hole_number in holes else 0
    after = len(holes) - pos - 1
    left = B - spent_before
    lo, hi = bounds(k, left, after)

    nets, pars = _scores_for(foursome, config)
    scored = _fully_scored(foursome, nets, holes)
    picked = counts.get(hole_number)

    return {
        'hole'        : hole_number,
        'group_size'  : k,
        'budget'      : B,
        'spent'       : spent_before,
        'left'        : left,
        'holes_after' : after,
        'lo'          : lo,
        'hi'          : hi,
        'count'       : picked.count if picked else None,
        'app_set'     : bool(picked.app_set) if picked else False,
        # `2.7 a hole, 15 to play` — the average the scorer is asked for.
        'average'     : (round(left / after, 1) if after > 0 else None),
        # Balls the group can still leave out, over the holes it has left
        # (this one included).
        'slack'       : k * (after + 1) - left,
        'can_pick'    : hole_number in scored and _is_editable(
                            foursome, hole_number, scored, counts),
        'scores_in'   : hole_number in scored,
        'par'         : pars.get(hole_number),
        'nets'        : nets.get(hole_number, {}),
    }


def _is_editable(foursome, hole_number, scored, counts) -> bool:
    """Only the most recent SCORED hole may be picked or changed.

    Once the next hole has scores the one before it is settled: the choice was
    made with that hole's information, and re-making it later with the next
    hole's is a different game.
    """
    if hole_number not in scored:
        return False
    return hole_number == scored[-1]


# ---------------------------------------------------------------------------
# Choosing
# ---------------------------------------------------------------------------

def set_count(foursome, hole_number: int, count: int) -> FortyBallsHoleCount:
    """Record the group's pick, and fill in anything it no longer chooses."""
    state = hole_state(foursome, hole_number)
    if not state['scores_in']:
        raise FortyBallsLocked(
            f'Hole {hole_number} is not fully scored yet — the group picks '
            f'after it has seen the nets.')
    if not state['can_pick']:
        raise FortyBallsLocked(
            f'Hole {hole_number} is settled. Only the most recent scored hole '
            f'can be changed.')
    if not state['lo'] <= count <= state['hi']:
        raise FortyBallsLocked(
            f"{count} balls is outside {state['lo']}–{state['hi']} on this "
            f"hole — the budget would not come out.")

    row, _ = FortyBallsHoleCount.objects.update_or_create(
        foursome=foursome, hole_number=hole_number,
        defaults={'count': count, 'app_set': False})
    _fill_forced(foursome)
    return row


def _fill_forced(foursome) -> None:
    """Write the counts the group no longer has a say in.

    Walks forward from the first unpicked hole; the moment `lo == hi` every
    later hole is decided too, so the whole tail is written at once and flagged
    `app_set`. Stops as soon as a hole has a real choice again — which cannot
    happen once the tail is forced, but the loop does not need to know that.
    """
    round_obj = foursome.round
    k = group_size(foursome)
    B = budget(foursome)
    holes = play_order(round_obj, foursome)
    counts = {c.hole_number: c for c in foursome.forty_balls_counts.all()}

    spent = 0
    for pos, h in enumerate(holes):
        existing = counts.get(h)
        if existing is not None and not existing.app_set:
            spent += existing.count
            continue
        after = len(holes) - pos - 1
        lo, hi = bounds(k, B - spent, after)
        if lo != hi:
            # A real choice remains; anything the app wrote beyond here is no
            # longer forced and must come back off.
            FortyBallsHoleCount.objects.filter(
                foursome=foursome, app_set=True,
                hole_number__in=holes[pos:]).delete()
            return
        FortyBallsHoleCount.objects.update_or_create(
            foursome=foursome, hole_number=h,
            defaults={'count': lo, 'app_set': True})
        spent += lo


# ---------------------------------------------------------------------------
# The board
# ---------------------------------------------------------------------------

def group_card(foursome) -> dict:
    """One group's whole card: per-hole counts, results and the running budget."""
    round_obj = foursome.round
    config = _config(round_obj)
    k = group_size(foursome)
    B = budget(foursome)
    holes = play_order(round_obj, foursome)
    nets, pars = _scores_for(foursome, config)
    counts = {c.hole_number: c for c in foursome.forty_balls_counts.all()}

    rows = []
    total = 0
    spent = 0
    for h in holes:
        par = pars.get(h)
        picked = counts.get(h)
        n = picked.count if picked else None
        hole_nets = nets.get(h, {})
        counted_ids = []
        result = None
        if n is not None and par is not None:
            best = sorted(hole_nets.items(), key=lambda kv: kv[1])[:n]
            counted_ids = [pid for pid, _ in best]
            result = sum(v for _, v in best) - n * par
            total += result
            spent += n
        rows.append({
            'hole'       : h,
            'par'        : par,
            'count'      : n,
            'app_set'    : bool(picked.app_set) if picked else False,
            'result'     : result,
            'counted_ids': counted_ids,
            'scores'     : hole_nets,
        })

    unpicked = len([r for r in rows if r['count'] is None])
    left = B - spent
    return {
        'foursome_id' : foursome.pk,
        'group_number': foursome.group_number,
        'group_size'  : k,
        'budget'      : B,
        'spent'       : spent,
        'left'        : left,
        # Balls the group can still leave out over the holes it has left. It
        # cannot go below zero — at zero every remaining ball is spoken for,
        # which is the `all count` state.
        'slack'       : max(0, k * unpicked - left),
        'holes_left'  : unpicked,
        'total'       : total,
        # **The 4/3 factor, exact and applied to the TOTAL.** Ranking only —
        # the per-hole figures on the card stay raw.
        'factor'      : (str(THREESOME_FACTOR) if k == 3 else None),
        'ranking_total': float(total * THREESOME_FACTOR) if k == 3 else float(total),
        'holes'       : rows,
        'holes_in_play': holes,
    }
