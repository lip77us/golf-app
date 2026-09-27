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
* **Budget is 10 × the group's STARTING size, and a dropout does not reduce
  it.** Ruled 26 Sep 2026. Two men left out of a threesome still owe 30 balls
  between them; four out of a foursome still owe 40. The budget is what the
  group signed up to spend, and losing a player cuts its CAPACITY to spend it,
  not the debt.

  So a group can run out of room: when the balls it still owes exceed what its
  remaining golfers can hit over the holes it has left, the budget can no
  longer come out and the group is **disqualified** from 40 Balls. Its scores
  still stand for the championship — the DQ is this game's, not the round's.

  **No borrowed 4th**: a phantom cannot choose, and a ball nobody hit is not a
  ball the group may count. A withdrawn golfer keeps his membership row, so the
  starting size survives him; what changes is how many balls each remaining
  hole can absorb.
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

    left     = B - spent_so_far
    capacity = balls the REMAINING holes can absorb, counting each hole's own
               active roster (so a withdrawal shrinks it from that hole on)
    lo       = max(0, left - capacity_after)   # fewest that still reaches B
    hi       = min(active_here, left)          # most that does not overshoot

`capacity` is a SUM over holes rather than `k × after`, because after a
withdrawal the holes are not all worth the same number of balls any more. With
nobody withdrawn the two are identical, which is why the shipped arithmetic is
the degenerate case rather than a branch.

`left > capacity_here` is the DQ: no sequence of legal picks reaches the budget.

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
    """The group's STARTING size — withdrawn golfers included.

    A withdrawal keeps the membership row (`withdrew_after_hole`), so this
    survives one, which is exactly the ruling: the budget does not shrink when
    a man drops out.
    """
    return len(_real_members(foursome))


def budget(foursome) -> int:
    """10 balls a golfer, fixed by the STARTING size.

    Not re-derived from who is still playing: two men left out of a threesome
    still owe 30 between them. What a dropout takes away is capacity, not debt.
    """
    return BALLS_PER_GOLFER * group_size(foursome)


def active_on_hole(foursome, hole_number: int, members=None) -> int:
    """How many of the group can put a ball on this hole.

    A golfer is active on hole h until the hole he withdrew after — the same
    convention `services/skins.py` uses, stated once there and reused rather
    than re-derived.
    """
    members = members if members is not None else _real_members(foursome)
    return sum(1 for m in members
               if m.withdrew_after_hole is None
               or hole_number <= m.withdrew_after_hole)


def _capacity(foursome, holes: list, members=None) -> int:
    """Balls the given holes can absorb between them.

    A SUM rather than `k × len(holes)`, because after a withdrawal the holes
    are not all worth the same number of balls. With nobody withdrawn the two
    are identical.
    """
    members = members if members is not None else _real_members(foursome)
    return sum(active_on_hole(foursome, h, members) for h in holes)


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

def bounds(here: int, left: int, capacity_after: int) -> tuple:
    """``(lo, hi)`` — the counts this hole may take.

    ``here`` is how many golfers can put a ball on THIS hole; ``capacity_after``
    is what all the later holes can absorb between them. `lo` is the fewest that
    still lets the budget be reached, `hi` the most that does not overshoot it.

    When `lo > hi` the budget is unreachable — see `is_dq`. The caller decides
    what to do about that; this returns the raw pair so the condition stays
    visible rather than being clamped away.
    """
    lo = max(0, left - capacity_after)
    hi = min(here, left)
    return lo, hi


def hole_state(foursome, hole_number: int) -> dict:
    """Everything the picker draws for one hole.

    ``slack`` is what the packet calls "balls you can still skip": the balls
    the group could still decline over the holes it has left. It starts at
    ``k × holes − B`` (8 for a foursome, 6 for a threesome) and only falls.
    """
    round_obj = foursome.round
    config = _config(round_obj)
    members = _real_members(foursome)
    k = len(members)
    B = budget(foursome)
    holes = play_order(round_obj, foursome)

    counts = {c.hole_number: c for c in foursome.forty_balls_counts.all()}
    pos = holes.index(hole_number) if hole_number in holes else 0
    spent_before = sum(c.count for h, c in counts.items()
                       if h in holes and holes.index(h) < pos)

    remaining = holes[pos:]
    here = active_on_hole(foursome, hole_number, members)
    cap_after = _capacity(foursome, holes[pos + 1:], members)
    cap_here = here + cap_after
    left = B - spent_before
    lo, hi = bounds(here, left, cap_after)

    nets, pars = _scores_for(foursome, config)
    scored = _fully_scored(foursome, nets, holes)
    picked = counts.get(hole_number)

    # **The budget can no longer come out.** Enough golfers dropped out that
    # the holes left cannot absorb the balls still owed — see the module note.
    dq = left > cap_here

    return {
        'hole'        : hole_number,
        'group_size'  : k,
        'active_here' : here,
        'budget'      : B,
        'spent'       : spent_before,
        'left'        : left,
        'holes_after' : len(holes) - pos - 1,
        'capacity'    : cap_here,
        'lo'          : lo,
        'hi'          : hi,
        'dq'          : dq,
        'count'       : picked.count if picked else None,
        'app_set'     : bool(picked.app_set) if picked else False,
        # `2.7 a hole, 15 to play` — the average the scorer is asked for.
        'average'     : (round(left / (len(holes) - pos - 1), 1)
                         if len(holes) - pos - 1 > 0 else None),
        # Balls the group can still leave out over the holes it has left, this
        # one included. Never below zero: at zero every remaining ball is
        # spoken for, which is the `all count` state.
        'slack'       : max(0, cap_here - left),
        'can_pick'    : (not dq) and hole_number in scored and _is_editable(
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
    if state['dq']:
        raise FortyBallsLocked(
            f"This group owes {state['left']} balls with room for "
            f"{state['capacity']} — the budget cannot come out, so it is out "
            f"of 40 Balls. Its scores still count for the championship.")
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
    members = _real_members(foursome)
    B = budget(foursome)
    holes = play_order(round_obj, foursome)
    counts = {c.hole_number: c for c in foursome.forty_balls_counts.all()}

    spent = 0
    for pos, h in enumerate(holes):
        existing = counts.get(h)
        if existing is not None and not existing.app_set:
            spent += existing.count
            continue
        here = active_on_hole(foursome, h, members)
        cap_after = _capacity(foursome, holes[pos + 1:], members)
        lo, hi = bounds(here, B - spent, cap_after)
        if lo > hi:
            # Unreachable — the group is out. Nothing is written: an app-set
            # count on a DQ'd group would be a number pretending the budget
            # still comes out.
            FortyBallsHoleCount.objects.filter(
                foursome=foursome, app_set=True,
                hole_number__in=holes[pos:]).delete()
            return
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

    unpicked = [r['hole'] for r in rows if r['count'] is None]
    left = B - spent
    members = _real_members(foursome)
    capacity = _capacity(foursome, unpicked, members)
    # **Out of 40 Balls, not out of the round.** The scores below still stand
    # for the championship; what cannot happen any more is the budget coming
    # out, so there is no honest total to rank.
    dq = left > capacity
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
        'slack'       : max(0, capacity - left),
        'holes_left'  : len(unpicked),
        'capacity'    : capacity,
        'dq'          : dq,
        'total'       : total,
        # **The 4/3 factor, exact and applied to the TOTAL.** Ranking only —
        # the per-hole figures on the card stay raw.
        'factor'      : (str(THREESOME_FACTOR) if k == 3 else None),
        # No ranking figure for a DQ'd group: a total built from a budget that
        # cannot come out is not a result, and sorting on it would place it.
        'ranking_total': None if dq else (
            float(total * THREESOME_FACTOR) if k == 3 else float(total)),
        'holes'       : rows,
        'holes_in_play': holes,
    }
