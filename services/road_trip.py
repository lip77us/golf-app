"""
services/road_trip.py
---------------------
Road Trip — **best m of n rounds, scored to par, with two titles.**

A trip plays n rounds (2–14), usually a different course each day. Each
golfer's best m of them count, and the trip runs Net and Gross side by side.

Rules (all settled 28 Sep 2026; see
docs/design-review/handoff-road-trip/HANDOFF.md)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* **To par, against that round's course par.** Ten courses with ten pars
  cannot be compared on raw totals. It is also what makes a dropped round
  meaningful — dropped on its own merit, not because the course was hard.
* **Each title picks its OWN best rounds.** Net and Gross are two
  competitions, not two views of one, so a golfer's counted set can differ
  between them. This is why the selection is run per title rather than once.
* **The double bogey cap is per title** — net on, gross off by default.
* **An unfinished round does not count.** Not "counts partially": a half-
  played round at level par would displace a finished 73, which is the same
  trap `round_counting` documents one level up. Here it is stricter, because a
  trip's rounds are at different courses on different days — an unfinished
  round is one that was abandoned, not one in progress on the last afternoon.
* **Eligibility is three states, and the board shows all three.**
  `ranked` (m completed rounds), `qualifying` (fewer, but m is still
  reachable) and `ineligible` (m can no longer be reached). A golfer who
  cannot reach m is not hidden — his rounds were real — he simply has no
  claim on the title.
* **Provisional until every ranked golfer has m completed rounds.**
* **Ties are settled on the final round, then backwards.** Skipping any round
  either golfer missed, and reading that title's score whether or not the
  round counted. If every shared round is equal they share the place.

What this module does NOT decide
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
**The handicap a played round was scored on.** That is the membership's, and
it is already baked into every `HoleScore.handicap_strokes` the round stored.
The trip's handicap MODE and its manual adjustments decide what a round not
yet played gets set to — see `index_for` and `apply_indexes` — and once a hole
is scored the number stops moving. Recomputing net from an index log would
give an answer the round's own scorecard disagrees with, which is the one
thing the board must never do.

Public API
~~~~~~~~~~
    rows    = road_trip_standings(tournament, title)   # 'net' | 'gross'
    summary = road_trip_summary(tournament)
    idx     = index_for(tournament, player, round_number)
"""
from decimal import Decimal

from core.models import RoundStatus
from scoring.handicap import effective_hcp_for, make_strokes_fn
from scoring.models import HoleScore
from tournament.models import Foursome

#: The trip scores at full allowance — the course handicap IS the playing
#: handicap here. An allowance is a per-game lever and a trip has no single
#: game to hang one on.
FULL_ALLOWANCE = 100

TITLES = ('net', 'gross')


def _config(tournament):
    return getattr(tournament, 'road_trip_config', None)


def road_trip_on(tournament) -> bool:
    return 'road_trip' in (tournament.active_games or [])


# ---------------------------------------------------------------------------
# Handicaps
# ---------------------------------------------------------------------------

def index_for(tournament, player, round_number: int) -> Decimal:
    """The index [player] plays round [round_number] off.

    Three inputs, in order of authority:

    1. **A manual adjustment** whose `from_round_number` has been reached. The
       latest such wins, so a second cut supersedes a first. It outranks the
       mode in BOTH directions — the packet is explicit that a manual change
       is available whether the trip is locked or updated, and a locked trip
       that ignored the organiser's own ruling would be locking him out.
    2. **Locked** — the index recorded when the trip was set up.
    3. **Updated** — the golfer's index as it stands now.
    """
    adj = [a for a in tournament.road_trip_index_adjustments.all()
           if a.player_id == player.id and a.from_round_number <= round_number]
    if adj:
        latest = max(adj, key=lambda a: (a.from_round_number, a.created_at))
        return Decimal(str(latest.handicap_index))

    config = _config(tournament)
    if config is not None and config.handicap_mode == 'locked':
        started = (config.starting_indexes or {}).get(str(player.id))
        if started is not None:
            return Decimal(str(started))
        # **No recorded start is not a reason to invent one.** A golfer added
        # after the trip was set up has no locked index; his current one is
        # the honest answer, and `capture_starting_indexes` records it the
        # next time the trip is saved.
    return Decimal(str(player.handicap_index))


def capture_starting_indexes(tournament) -> dict:
    """Record what every golfer in the field is playing off today.

    Called when the trip is configured. **Existing entries are never
    overwritten**: the whole point of a locked index is that it does not move,
    and re-saving the setup screen on day four must not quietly relock
    everybody on the numbers they have drifted to.
    """
    config = _config(tournament)
    if config is None:
        return {}
    current = dict(config.starting_indexes or {})
    for fs in (Foursome.objects.filter(round__tournament=tournament)
               .prefetch_related('memberships__player')):
        for m in fs.memberships.all():
            if m.player.is_phantom:
                continue
            current.setdefault(str(m.player_id), str(m.player.handicap_index))
    if current != (config.starting_indexes or {}):
        config.starting_indexes = current
        config.save(update_fields=['starting_indexes'])
    return current


def apply_indexes(tournament) -> int:
    """Write each golfer's trip handicap onto the rounds he has NOT played.

    This is what makes `locked` and a manual adjustment real. The engine reads
    the membership, because the membership is what every stored
    `handicap_strokes` came from — so the trip's index has to reach the round
    before the round is scored, not be applied on top of it afterwards.

    **Only rounds with no scores.** A round already under way keeps the
    handicap it is being scored with; that is the same threshold a tee change
    uses, and the same promise the adjust sheet makes.

    Returns the number of memberships changed.
    """
    from scoring.models import HoleScore
    config = _config(tournament)
    if config is None:
        return 0

    rounds = _trip_rounds(tournament)
    scored = set(
        HoleScore.objects
        .filter(foursome__round__tournament=tournament,
                gross_score__isnull=False)
        .values_list('foursome__round_id', flat=True)
        .distinct()
    )

    changed = 0
    for r in rounds:
        if r.id in scored:
            continue
        for fs in r.foursomes.all():
            for m in fs.memberships.all():
                if m.player.is_phantom or m.tee_id is None:
                    continue
                want = course_handicap(
                    index_for(tournament, m.player, r.round_number), m.tee)
                if m.playing_handicap_override != want:
                    m.playing_handicap_override = want
                    # The hub shows CH and PH, and a forced number that left
                    # them reading the old one would have the golfer playing
                    # off a figure the screen does not show.
                    m.course_handicap  = want
                    m.playing_handicap = want
                    m.save(update_fields=['playing_handicap_override',
                                          'course_handicap',
                                          'playing_handicap'])
                    changed += 1
    return changed


def course_handicap(index, tee) -> int:
    """`round(index × slope / 113 + (rating − par))` — the WHS figure.

    The same arithmetic `Player.course_handicap` does, taken apart so a trip
    can hand it an index from its own log rather than the golfer's current one.
    """
    from core.handicap_math import round_half_up
    ch = (float(index) * (float(tee.slope) / 113.0)
          + (float(tee.course_rating) - float(tee.par)))
    return round_half_up(ch)


# ---------------------------------------------------------------------------
# One round's cards
# ---------------------------------------------------------------------------

def _round_rows(round_obj, config) -> dict:
    """``{player_id: {net_to_par, gross_to_par, holes, complete, ...}}``.

    Par comes from each golfer's OWN tee, like every other card in the app: on
    a mixed card the forward tee can play a hole as a five where the back tee
    plays it as a four, and a score to par has to be against the par actually
    played.
    """
    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee')
    )

    # One allocator per distinct starting hole — `make_strokes_fn` re-reads
    # the course's tees, and two groups off the same tee share an answer.
    fn_cache: dict = {}

    def _strokes_fn(fs):
        key = fs.starting_hole or round_obj.starting_hole or 1
        if key not in fn_cache:
            fn_cache[key] = make_strokes_fn(fs)
        return fn_cache[key]

    meta: dict = {}
    for fs in foursomes:
        fn = _strokes_fn(fs)
        for m in fs.memberships.all():
            if m.player.is_phantom or m.tee_id is None:
                continue
            meta[m.player_id] = (m, fn)
    if not meta:
        return {}

    scores = (
        HoleScore.objects
        .filter(foursome__round=round_obj,
                player_id__in=list(meta),
                gross_score__isnull=False)
        .values('player_id', 'hole_number', 'gross_score')
    )

    net_cap   = config.net_max_double_bogey if config else True
    gross_cap = config.gross_max_double_bogey if config else False
    expected  = round_obj.num_holes or 18

    rows: dict = {}
    for row in scores:
        pid  = row['player_id']
        m, fn = meta[pid]
        hole = row['hole_number']
        try:
            par = m.tee.hole(hole).get('par')
        except StopIteration:
            par = None
        if par is None:
            # No par for the hole is no to-par value, and guessing 4 would
            # invent a birdie. The hole is not counted, and the round then
            # reads as incomplete — which is the honest outcome.
            continue
        strokes = fn(effective_hcp_for(m, FULL_ALLOWANCE), m.tee, hole)
        gross   = row['gross_score']

        # **One hole, two ceilings.** Net double bogey is par + 2 + the
        # strokes received; gross double bogey is par + 2 flat. They are
        # applied to the same gross score and then read differently, which is
        # what keeps the two titles honest about the same round.
        g = min(gross, par + 2) if gross_cap else gross
        n = (min(gross, par + 2 + strokes) if net_cap else gross) - strokes

        r = rows.setdefault(pid, {
            'gross': 0, 'net': 0, 'par': 0, 'holes': 0,
            'handicap': effective_hcp_for(m, FULL_ALLOWANCE),
        })
        r['gross'] += g
        r['net']   += n
        r['par']   += par
        r['holes'] += 1

    out = {}
    for pid, r in rows.items():
        complete = r['holes'] >= expected
        out[pid] = {
            'gross_to_par': r['gross'] - r['par'],
            'net_to_par'  : r['net'] - r['par'],
            'holes'       : r['holes'],
            'par'         : r['par'],
            'handicap'    : r['handicap'],
            # **Both must be true.** A round whose own status is still open is
            # not a result even with eighteen holes on it — the group may yet
            # correct a score — and eighteen holes on a closed round is what
            # makes it one.
            'complete'    : complete and round_obj.status == RoundStatus.COMPLETE,
        }
    return out


# ---------------------------------------------------------------------------
# The board
# ---------------------------------------------------------------------------

def _trip_rounds(tournament) -> list:
    return list(tournament.rounds.order_by('round_number')
                .prefetch_related('foursomes__memberships__player',
                                  'foursomes__memberships__tee'))


def _field_names(tournament) -> dict:
    names = {}
    for fs in (Foursome.objects.filter(round__tournament=tournament)
               .prefetch_related('memberships__player')):
        for m in fs.memberships.all():
            if not m.player.is_phantom:
                names[m.player_id] = m.player.name
    return names


def _gather(tournament, config) -> tuple:
    """``(rounds, per_player)`` — every golfer's row for every round."""
    rounds = _trip_rounds(tournament)
    per_player: dict = {}
    for i, r in enumerate(rounds):
        for pid, row in _round_rows(r, config).items():
            per_player.setdefault(pid, {})[i] = row
    return rounds, per_player


def _tie_break(a_rows, b_rows, n_rounds, title) -> int:
    """The final round, then backwards — **skipping any round either missed.**

    Skipping rather than treating a missed round as a loss: the rule is about
    who played the better golf on the days they BOTH played, and a golfer who
    sat out the 9th did not lose it. Reads that title's score whether or not
    the round COUNTED, because the question is who played better, not whose
    card was tidier — a dropped round is still a round he played.

    **An unfinished round is skipped like a missed one.** It is not a round
    either man has played yet, and reading it walks into the trap `_row`
    names: a part-played card reports a to-par against the holes it has, so
    four holes at level par reads as E and beats a finished 74. Two golfers
    in different groups can be thru 11 and thru 4, and the one with fewer
    holes behind him would take the tie for having had less chance to go
    wrong — then lose it again an hour later. A tie settled by a round still
    being played is not settled.
    """
    for i in range(n_rounds - 1, -1, -1):
        x, y = a_rows.get(i), b_rows.get(i)
        if not x or not y or not x['complete'] or not y['complete']:
            continue
        key = f'{title}_to_par'
        if x[key] != y[key]:
            return (x[key] - y[key], i)
    return (0, None)


def road_trip_standings(tournament, title: str) -> dict:
    """One title's board: ranked, still qualifying, and not eligible.

    Returns ``{'ranked': [...], 'qualifying': [...], 'ineligible': [...],
    'provisional': bool, 'counts': m, 'rounds': n}``.
    """
    config = _config(tournament)
    if config is None or title not in config.titles:
        return {}

    rounds, per_player = _gather(tournament, config)
    n = len(rounds)
    m = tournament.rounds_to_count or n
    m = max(1, min(m, n)) if n else 0
    names = _field_names(tournament)
    key = f'{title}_to_par'

    # The latest adjustment per golfer, for the row's own badge.
    adjusted: dict = {}
    for a in tournament.road_trip_index_adjustments.all():
        prev = adjusted.get(a.player_id)
        if prev is None or (a.from_round_number, a.created_at) > prev[0]:
            adjusted[a.player_id] = (
                (a.from_round_number, a.created_at),
                {'from_round': a.from_round_number,
                 'index'     : float(a.handicap_index),
                 'reason'    : a.reason},
            )
    adjusted = {pid: v[1] for pid, v in adjusted.items()}

    # A round nobody can still play is spent, whatever its status says. What
    # is left to a golfer is the rounds he has NOT completed and which are not
    # already finished without him.
    finished = {i for i, r in enumerate(rounds)
                if r.status == RoundStatus.COMPLETE}

    entries = []
    # **The FIELD, not only the golfers with scores.** A man entered in the
    # trip who has not teed off yet is still in it — he shows as qualifying
    # with nothing posted, which is what the board is for on day one.
    for pid in names:
        by_round = per_player.get(pid, {})
        done = {i: row for i, row in by_round.items() if row['complete']}
        # Still available to him: rounds he has not completed and which have
        # not closed without him.
        left = len([i for i in range(n) if i not in done and i not in finished])
        played = len(done)
        best = sorted(done.items(), key=lambda kv: (kv[1][key], -kv[0]))[:m]
        counted = {i for i, _ in best}
        entries.append({
            'player_id' : pid,
            'name'      : names.get(pid, ''),
            'adjusted'  : adjusted.get(pid),
            'rounds'    : by_round,
            'counted'   : counted,
            'total'     : sum(row[key] for _, row in best),
            'played'    : played,
            'needs'     : max(0, m - played),
            'can_reach' : played + left >= m,
        })

    ranked     = [e for e in entries if e['played'] >= m]
    qualifying = [e for e in entries if e['played'] < m and e['can_reach']]
    ineligible = [e for e in entries if e['played'] < m and not e['can_reach']]

    import functools

    def cmp(a, b):
        if a['total'] != b['total']:
            return a['total'] - b['total']
        return _tie_break(a['rounds'], b['rounds'], n, title)[0]

    ranked.sort(key=functools.cmp_to_key(cmp))

    # Places, and the note that says WHICH round settled a tie. A tie that the
    # walk-back never separates shares the place.
    for i, e in enumerate(ranked):
        prev = ranked[i - 1] if i else None
        if prev and prev['total'] == e['total'] and \
                _tie_break(prev['rounds'], e['rounds'], n, title)[0] == 0:
            e['rank'] = prev['rank']
            e['tied'] = True
            prev['tied'] = True
        else:
            e['rank'] = i + 1
            e.setdefault('tied', False)
        nxt = ranked[i + 1] if i + 1 < len(ranked) else None
        note = None
        for other in (prev, nxt):
            if other is not None and other['total'] == e['total']:
                d, ri = _tie_break(e['rounds'], other['rounds'], n, title)
                if d != 0 and ri is not None:
                    note = rounds[ri].course.name if rounds[ri].course_id else None
                    break
        e['tie_note'] = note

    # Qualifying and ineligible are listed on what they have, best first —
    # they have no place, but the board still reads as a board. **A golfer
    # with nothing posted goes last**, not first: his total is zero because he
    # has not played, and sorting him to the top of the list would read as
    # level par.
    for group in (qualifying, ineligible):
        group.sort(key=lambda e: (e['played'] == 0, e['total'], e['name']))

    return {
        'title'      : title,
        'counts'     : m,
        'rounds'     : n,
        # **Provisional while the board can still move**: a round is open or
        # unplayed, or somebody is still qualifying. Until then it is
        # comparing full cards with part-built ones, and the client draws the
        # chip and keeps the prize italic.
        #
        # **Not `any golfer with fewer than m rounds`**, which is what this
        # read before: an INELIGIBLE golfer never reaches m by definition, so
        # one man going home early left a finished trip permanently
        # provisional — the chip up and the prize italic with every round
        # closed and nothing left to play.
        'provisional': (bool(qualifying)
                        or any(r.status != RoundStatus.COMPLETE
                               for r in rounds)
                        or not ranked),
        'ranked'     : [_row(e, rounds, title, m) for e in ranked],
        'qualifying' : [_row(e, rounds, title, m) for e in qualifying],
        'ineligible' : [_row(e, rounds, title, m) for e in ineligible],
    }


def _row(e, rounds, title, m) -> dict:
    """One golfer's row, with a cell per round.

    A cell is one of four states and the board draws each differently:
    `counted`, `dropped`, `missed` (he did not play it) and `pending` (played
    but not complete, or not yet played by anybody).
    """
    key = f'{title}_to_par'
    cells = []
    for i, r in enumerate(rounds):
        row = e['rounds'].get(i)
        if row is None:
            state = 'missed' if r.status == RoundStatus.COMPLETE else 'pending'
            cells.append({'round': r.round_number, 'state': state,
                          'to_par': None, 'holes': 0})
            continue
        if not row['complete']:
            state = 'pending'
        else:
            state = 'counted' if i in e['counted'] else 'dropped'
        cells.append({
            'round' : r.round_number,
            'state' : state,
            # **A part-played round reports no figure.** Four holes at level
            # par reads as E, which on a row of finished rounds is a score
            # that beats them — the same trap that keeps an incomplete round
            # out of the counting. `holes` is there so the cell can say
            # `thru 4` instead.
            'to_par': row[key] if state != 'pending' else None,
            'holes' : row['holes'],
        })
    return {
        'player_id': e['player_id'],
        'name'     : e['name'],
        # **The cut travels with the row.** An index moved mid-trip changes
        # what every later round is worth, so a board that showed the totals
        # without it would be reporting a competition whose rules changed
        # without saying so.
        'adjusted' : e.get('adjusted'),
        'rank'     : e.get('rank'),
        'tied'     : e.get('tied', False),
        'tie_note' : e.get('tie_note'),
        'total'    : e['total'] if e['played'] >= m else None,
        'played'   : e['played'],
        'needs'    : e['needs'],
        'cells'    : cells,
    }


def road_trip_summary(tournament) -> dict:
    """Both titles, the rounds they were played over, and the trip's settings."""
    config = _config(tournament)
    if config is None:
        return {}
    rounds = _trip_rounds(tournament)
    return {
        'titles'       : config.titles,
        'counts'       : tournament.rounds_to_count or len(rounds),
        'n_rounds'     : len(rounds),
        'handicap_mode': config.handicap_mode,
        'net_cap'      : config.net_max_double_bogey,
        'gross_cap'    : config.gross_max_double_bogey,
        'rounds'       : [
            {'index'      : i,
             'round_id'   : r.id,
             'round_number': r.round_number,
             'label'      : f'R{r.round_number}',
             'course'     : r.course.name if r.course_id else '',
             'date'       : r.date.isoformat() if r.date else None,
             'status'     : r.status,
             'is_complete': r.status == RoundStatus.COMPLETE}
            for i, r in enumerate(rounds)
        ],
        **{t: road_trip_standings(tournament, t) for t in config.titles},
    }
