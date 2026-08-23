"""
services/team_play.py
---------------------
Team Play format rules — how many balls count on a hole, and the drive
requirement (docs/design-review/handoff-team-play/SPEC.md §4 and §5).

Pure logic: config values and hole data in, structures out.  No DB access, so
the packet's worked examples are the tests.

The drive tracker is the part of a team round that actually gets complicated,
and the reason is stated once here because it shapes every function below:
**three of the four rules are quotas and one is a schedule.**  A quota is
satisfied whenever you like, so the useful number is how much room is LEFT.  A
schedule has no slack at all — what it needs is one line on the tee.
"""

from decimal import Decimal, ROUND_HALF_UP


BALLS_PER_HOLE = 4          # a four-man team hits four balls, phantom included
FRONT = (1, 9)
BACK  = (10, 18)


def balls_per_hole(config) -> int:
    """
    How many balls the team puts in the air — its size, phantom included.

    Four for a foursome, two for a pair.  Everything a quota measures scales
    off this: a pairs quota of one each per nine is **two of nine**, seven
    free, which is why "one each per nine" is the usual pairs rule — two men
    and eighteen holes is a lot of slack.
    """
    return int(getattr(config, 'team_size', BALLS_PER_HOLE) or BALLS_PER_HOLE)


# ---------------------------------------------------------------------------
# 1. Ball counts — how many of the four scores count on a hole (shamble)
# ---------------------------------------------------------------------------

def resolve_ball_counts(config, holes) -> dict:
    """
    ``{hole_number: balls_that_count}`` for all eighteen, whatever the mode.

    Every mode resolves to the same shape so nothing downstream has to know
    which one the TD picked — the card, the preview, the allowance and the
    scoring all read this dict.

    ``holes`` is the tee's hole list (``[{'number', 'par', 'stroke_index'}…]``),
    needed only by the par-based mode.
    """
    from tournament.models import TeamPlayConfig

    numbers = [h['number'] for h in holes]

    if config.ball_count_mode == TeamPlayConfig.COUNT_ESCALATING:
        # A preset, NOT a grid recipe.  "Sixes" is the shape people describe in
        # words, and making them tap eighteen cells to express it is the app
        # failing to listen.
        return {n: 1 if n <= 6 else (2 if n <= 12 else 3) for n in numbers}

    if config.ball_count_mode == TeamPlayConfig.COUNT_PAR_BASED:
        # The short holes are where a team can afford to need everybody.
        by_par = {3: 3, 4: 2, 5: 1}
        return {h['number']: by_par.get(h['par'], 1) for h in holes}

    if config.ball_count_mode == TeamPlayConfig.COUNT_PER_HOLE:
        stored = config.ball_counts or {}
        return {
            n: int(stored.get(str(n), stored.get(n, config.ball_count_fixed)))
            for n in numbers
        }

    return {n: int(config.ball_count_fixed) for n in numbers}


def ball_count_runs(counts: dict) -> list:
    """
    The preview, collapsed into runs: ``[(1, 6, 1), (7, 12, 2), (13, 18, 3)]``
    → *Holes 1–6, best 1 net.*

    It reads back in sentences because that is the check which catches a
    per-hole grid accidentally left at all 2s, or a par-based setting on a
    course with five par 3s that turns out much harder than intended.
    """
    runs = []
    for hole in sorted(counts):
        n = counts[hole]
        if runs and runs[-1][2] == n and runs[-1][1] == hole - 1:
            runs[-1] = (runs[-1][0], hole, n)
        else:
            runs.append((hole, hole, n))
    return [tuple(r) for r in runs]


def ball_count_summary(counts: dict) -> dict:
    """
    ``36 counted of 72 played`` — the number that describes the round, and the
    one that tells a TD more than any of the settings do.

    Fixed-at-2 and escalating both total 36, distributed differently.  Seeing
    that is what makes the choice read as CHARACTER rather than difficulty,
    which is why the total is on the screen at all.

    ``full_count_holes`` are the holes set to all four: legal, and flagged —
    no drop score, so one blow-up is the team's.  Deliberate on a closing hole,
    an accident anywhere else.
    """
    played  = len(counts) * BALLS_PER_HOLE
    counted = sum(counts.values())
    avg     = (Decimal(counted) / Decimal(len(counts))) if counts else Decimal('0')
    return {
        'counted'          : counted,
        'played'           : played,
        'avg_per_hole'     : avg.quantize(Decimal('0.1'), rounding=ROUND_HALF_UP),
        'runs'             : ball_count_runs(counts),
        'full_count_holes' : sorted(h for h, n in counts.items() if n >= BALLS_PER_HOLE),
    }


# ---------------------------------------------------------------------------
# 2. Drives — three quotas and one schedule
# ---------------------------------------------------------------------------

def drive_windows(config) -> list:
    """
    The windows a quota is measured over.

    **Per nine is TWO windows, and the front does not carry to the back.**  A
    man short on the front is already short; a tracker that only totals
    eighteen says he is fine until the 18th green.
    """
    from tournament.models import TeamPlayConfig

    if config.drive_rule == TeamPlayConfig.DRIVE_PER_NINE:
        return [FRONT, BACK]
    if config.drive_rule == TeamPlayConfig.DRIVE_PER_18:
        return [(1, 18)]
    return []


def window_requirement(config, real_player_count: int) -> dict:
    """
    What one window asks of a team, and how much room that leaves.

    **A short FOUR-man team owes four men's worth, not three.**  It fields a
    phantom, so the quota is four men's worth and the phantom's share FLOATS —
    any of the three real men can cover it.  Three men at two each would be six
    drives, but a three-man foursome is not really three.

    **A pair has no phantom**, so nothing floats: a two-man team owes two men's
    worth and a three-man best-ball pair owes three.  ``real_player_count``
    above the team size therefore raises the quota rather than lowering it, and
    the ``floating`` term falls out at zero on its own.

    ``free`` is the figure a captain actually uses: twelve required of eighteen
    means six free, and that is what tells him whether he can let his long
    hitter drive the par 5.
    """
    per_golfer = int(config.drives_required)
    size       = balls_per_hole(config)
    # A team owes its SIZE's worth, or its roster's worth when the roster is
    # bigger — a three-man best-ball pair owes three, not two.
    total      = max(size, real_player_count) * per_golfer
    holes      = 9 if len(drive_windows(config)) == 2 else 18
    return {
        'per_golfer'     : per_golfer,
        'required'       : total,
        'holes'          : holes,
        'free'           : max(0, holes - total),
        # The phantom's share, satisfiable by ANY of the real men rather than
        # owed by a particular one.  Zero in pairs, which have no phantom.
        'floating'       : max(0, size - real_player_count) * per_golfer,
    }


def window_state(config, window, picks: dict, real_player_ids,
                 thru_hole: int) -> dict:
    """
    One window's tracker: who has driven, who owes, and — the part that matters
    — whether it is still possible.

    ``picks``   ``{hole_number: player_id}`` for holes already played.
    ``thru_hole``  the last hole completed (0 before the round starts).

    **The warning has to come before it is too late, not on 18.**  The failure
    every group has had: three holes left, five drives owed; it became
    impossible two holes ago and nobody noticed.  So this returns the two
    states separately —

        ``tight``       owed == holes remaining.  It still works, but only if
                        every remaining hole goes to a man who owes one.
        ``impossible``  owed > holes remaining.  The window cannot be satisfied.

    Both are amber on screen.  Neither ever blocks the tap: the team may
    knowingly take the shortfall, and by default a shortfall costs nothing.
    """
    start, end = window
    req        = window_requirement(config, len(real_player_ids))
    per_golfer = req['per_golfer']

    used = {pid: 0 for pid in real_player_ids}
    holes_used = {pid: [] for pid in real_player_ids}
    for hole, pid in picks.items():
        if start <= hole <= end and pid in used:
            used[pid] += 1
            holes_used[pid].append(hole)

    # Personal shortfall, then the phantom's floating share — which any drive
    # beyond a man's own minimum goes toward.
    personal_owed = sum(max(0, per_golfer - n) for n in used.values())
    surplus       = sum(max(0, n - per_golfer) for n in used.values())
    floating_owed = max(0, req['floating'] - surplus)
    owed          = personal_owed + floating_owed

    holes_left = max(0, end - max(thru_hole, start - 1))
    started    = thru_hole >= start

    return {
        'window'      : window,
        'started'     : started,
        'required'    : req['required'],
        'per_golfer'  : per_golfer,
        'owed'        : owed,
        'holes_left'  : holes_left,
        # Holes left that are NOT already spoken for. This is the number a
        # captain actually uses — it tells him whether he can give the par 5 to
        # his long hitter, which "4 required of 9" does not.
        'free_left'   : max(0, holes_left - owed),
        'tight'       : owed == holes_left and owed > 0,
        'impossible'  : owed > holes_left,
        'golfers'     : [
            {
                'player_id' : pid,
                'used'      : used[pid],
                'holes'     : sorted(holes_used[pid]),
                'owes'      : max(0, per_golfer - used[pid]),
            }
            for pid in real_player_ids
        ],
    }


def drive_shortfall(config, picks: dict, real_player_ids) -> int:
    """
    Drives missing at the end of the round, summed over every window.

    Recorded either way; it changes the money only if the TD chose the stroke
    penalty.  **Falling short costs nothing by default** — most groups treat
    the requirement as honour, and silently disqualifying a team over a drive
    count would be the worst outcome the app could produce.
    """
    if not drive_windows(config):
        return 0
    return sum(
        window_state(config, w, picks, real_player_ids, thru_hole=w[1])['owed']
        for w in drive_windows(config)
    )


def drive_penalty_strokes(config, picks: dict, real_player_ids) -> int:
    """Two strokes per missing drive, added to the team's gross at the END of
    the round — and only when the TD opted in.  A schedule has nothing to fall
    short of, so it never penalises."""
    from tournament.models import TeamPlayConfig

    if config.drive_penalty != TeamPlayConfig.PENALTY_TWO_STROKE:
        return 0
    return 2 * drive_shortfall(config, picks, real_player_ids)


# ---------------------------------------------------------------------------
# 3. Alternating pairs — the schedule
# ---------------------------------------------------------------------------

def build_rota(player_ids) -> list:
    """
    The repeating cycle of whoever is up on the tee.

    Four men → the two driving pairs the team set, alternating.
    Three men → **AB, BC, AC, repeat.**  Two drivers every hole and each man
    sits out every third, which is as even as three into two goes.  The man
    sitting out plays the phantom's ball — the 1st and 4th shots.
    **Two men → A, B, repeat** — the alternate-shot tee rota, odd holes to the
    first man and even to the second.  Same mechanic, one name per entry
    instead of two.

    The rota is the TEAM's, set on the 1st tee and then fixed for eighteen
    holes.  The app does not derive it from handicap: the men decide in ten
    seconds, it is the only part of the rule anyone enjoys, and a computed
    order would be overridden on the spot.  A rota that can be re-cut mid-round
    is not a rota — and in an alternate shot a pair that loses track plays a
    hole out of order and the round is gone.
    """
    ids = list(player_ids)
    if len(ids) == 2:
        a, b = ids
        return [(a,), (b,)]
    if len(ids) == 3:
        a, b, c = ids
        return [(a, b), (b, c), (a, c)]
    if len(ids) == 4:
        a, b, c, d = ids
        return [(a, b), (c, d)]
    return []


def pair_on_hole(rota, hole_number: int):
    """
    Whose tee shot is in play.  The pair set first drives the 1st hole, and the
    cycle runs from there.

    (The packet's tracker illustration opens mid-round at hole 8 and draws the
    cycle from there rather than from hole 1 — it is showing the pattern, not
    an offset.  Hole 1 takes the first pair.)
    """
    if not rota:
        return None
    return rota[(hole_number - 1) % len(rota)]


def phantom_cover_on_hole(rota, player_ids, hole_number: int):
    """For a three-man team, the man not driving — he takes the phantom's 1st
    and 4th shots.  The team hits four balls either way, which is the whole
    point of the phantom."""
    pair = pair_on_hole(rota, hole_number)
    if not pair or len(player_ids) != 3:
        return None
    return next((pid for pid in player_ids if pid not in pair), None)
