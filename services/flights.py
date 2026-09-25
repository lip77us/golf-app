"""
services/flights.py
-------------------
Cutting a tournament field into flights, and ranking inside them.

Two pieces, both deliberately game-agnostic so the Low Net and Stableford
championships share one implementation rather than growing two:

    assign_flights(field, n_flights)  -> {player_id: flight_no}
    rank_in_flights(...)              -> rows, ranked and paid WITHIN each flight

Design notes live in ``docs/flights-plan.md``.  The two rules most likely to be
"tidied" into something wrong are stated at their implementations: the remainder
goes to the LOWER-index flight, and a golfer with no index does not take part in
the sizing at all.
"""
from decimal import Decimal


# ---------------------------------------------------------------------------
# Assignment
# ---------------------------------------------------------------------------

def assign_flights(field, n_flights: int) -> dict:
    """``{player_id: flight_no}`` (1 = lowest index), for a field of
    ``(player_id, handicap_index_or_None)`` pairs.

    **Equal-sized, remainder to the LOWER flights.** 23 indexed golfers in two
    flights is A=12, B=11 — the better players' flight absorbs the odd man, not
    the other way round.

    **A golfer with no index goes to the bottom flight and is NOT counted in
    the split.** The split is taken over the indexed golfers alone and the rest
    are appended afterwards, so the bottom flight is deliberately bigger. 23
    golfers of whom 3 have no index gives A=10, B=13 — *not* A=12, B=11.

    Doing it the other way round (bottom-flight them first, then split the whole
    field) pushes a real golfer up a flight to make room for one whose index
    nobody knows, which is the thing this rule exists to prevent. The cost is
    accepted and intended: both flights pay the same table, so the bottom flight
    has more golfers competing for the same money.

    Ties on index are broken by ``player_id`` so the cut is deterministic — two
    golfers on 11.4 either side of the boundary must not swap flights because a
    queryset came back in a different order.
    """
    if n_flights < 1:
        raise ValueError('n_flights must be at least 1')

    indexed, unindexed = [], []
    for pid, idx in field:
        (unindexed if idx is None else indexed).append((pid, idx))

    indexed.sort(key=lambda p: (Decimal(str(p[1])), p[0]))

    base, remainder = divmod(len(indexed), n_flights)
    out, pos = {}, 0
    for flight in range(1, n_flights + 1):
        size = base + (1 if flight <= remainder else 0)
        for pid, _idx in indexed[pos:pos + size]:
            out[pid] = flight
        pos += size

    for pid, _idx in unindexed:
        out[pid] = n_flights

    return out


def flight_sizes(assignment: dict, n_flights: int) -> list:
    """``[count, ...]`` per flight — for stating the cut back to the TD before
    it is frozen, and for the tests that pin the remainder rule."""
    return [sum(1 for f in assignment.values() if f == n)
            for n in range(1, n_flights + 1)]


# ---------------------------------------------------------------------------
# Ranking
# ---------------------------------------------------------------------------

def apportion(total_cents: int, weights) -> list:
    """Divide `total_cents` by `weights` so the parts sum EXACTLY to it.

    Largest-remainder: every part gets its floor, and the leftover cents go
    to the parts with the biggest fractions, ties by position. Rounding each
    part on its own is what invents money — three flights of three out of
    nine each rounding $66.666 to $66.67 pays $200.01 of a $200 table, which
    is the odd cent a TD should never have to see.
    """
    total_w = sum(weights)
    if total_w <= 0:
        return [0] * len(weights)
    exact = [total_cents * w / total_w for w in weights]
    parts = [int(x) for x in exact]
    left = total_cents - sum(parts)
    order = sorted(range(len(weights)), key=lambda i: (-(exact[i] - parts[i]), i))
    for i in order[:left]:
        parts[i] += 1
    return parts


def scale_table(payouts_cfg, purse_cents: int) -> dict:
    """The event's payout table rewritten to pay exactly `purse_cents`.

    **A flight's purse is its own golfers' entries.** Fifteen golfers cut 8/7
    at $10 a head means $80 and $70 — each flight divides what its own players
    put in. Since everybody pays the same entry, that share is `size / field`,
    so the fee itself never has to be passed in; the caller works the purses
    out with :func:`apportion` and hands one in here.

    Before this, every flight paid the table in FULL: eight golfers at $20 put
    $160 in, a $100/$60 table over two flights took $320 out, and the event was
    short by exactly one pool. Reported from a real event, 25 Sep 2026.

    **Proportional, not an equal division of the pool.** An equal split pays a
    7-man flight and an 8-man flight the same money, so neither plays for what
    it paid in — and it strands a cent that is an artifact rather than a fact
    about the field. Here the flights differ because their fields differ.

    The places sum exactly to the purse: each is rounded to the cent and the
    remainder lands on FIRST place.
    """
    table = {int(k): float(v or 0) for k, v in (payouts_cfg or {}).items()}
    total = sum(table.values())
    if total <= 0 or not table:
        return {k: 0.0 for k in table}

    places = sorted(table)
    out, spent = {}, 0
    for place in places[1:]:
        c = round(table[place] / total * purse_cents)
        out[place] = c / 100
        spent += c
    out[places[0]] = (purse_cents - spent) / 100
    return out


def rank_in_flights(aggregated, *, sort_key, rank_key, flight_of, payouts_cfg,
                    eligible=None):
    """``([(player_id, data, rank, flight), ...], {player_id: payout})``.

    Ranks and pays WITHIN each flight, returning rows in flight order so a
    client that renders the server's list verbatim draws contiguous blocks with
    ranks restarting at 1.

    The two championships differ in exactly one respect — how a row is ordered
    and compared — so that is the parameter:

        Low Net     net-to-par ascending
        Stableford  points descending

    **`sort_key` and `rank_key` are not the same thing, and collapsing them into
    one is a real bug.** Low Net SORTS on (net-to-par, −holes played) but RANKS
    on net-to-par alone — two golfers level on net-to-par share a rank even
    though one has played more holes and sorts above the other. Passing the sort
    key as the tie test would silently split that tie and pay two places.

    ``eligible`` is not decoration. Stableford carries an excluded set and pays
    "among eligible players only"; Low Net does not. Note what that means and
    what this therefore copies from the shipped behaviour: an excluded golfer
    keeps his DISPLAY rank, but the prize ranking is recomputed over the
    eligible golfers alone — so the man behind him moves up a paid place rather
    than that place going unclaimed.

    **Each flight pays a share of the table proportional to its SIZE**, which
    is the same thing as saying it pays out what its own golfers paid in — see
    :func:`scale_table`. A single flight holds the whole field, so the table is
    untouched and the unflighted event is the degenerate case rather than a
    second path.
    """
    from services.payout import split_tied_places

    eligible = set(aggregated) if eligible is None else set(eligible)

    def _ranked(rows):
        """Ties share a rank; the next rank skips by the size of the tie."""
        out, rank = [], 1
        for i, (pid, data) in enumerate(rows):
            if i > 0 and rank_key((pid, data)) != rank_key(rows[i - 1]):
                rank = i + 1
            out.append((pid, data, rank))
        return out

    by_flight: dict = {}
    for pid, data in aggregated.items():
        by_flight.setdefault(flight_of(pid), []).append((pid, data))

    # **Every flight's purse is its own golfers' entries**, apportioned so the
    # purses sum to the table exactly — rounding each on its own invents a
    # cent across the flights, which is the odd cent a TD should never see.
    order = sorted(by_flight)
    table_cents = round(
        sum(float(v or 0) for v in (payouts_cfg or {}).values()) * 100)
    purses = dict(zip(order, apportion(
        table_cents, [len(by_flight[f]) for f in order])))

    ranked, payouts = [], {}
    for flight in order:
        rows = sorted(by_flight[flight], key=sort_key)

        for pid, data, rank in _ranked(rows):
            ranked.append((pid, data, rank, flight))

        flight_cfg = scale_table(payouts_cfg, purses[flight])

        # Prize ranking is its own pass over the eligible golfers in THIS
        # flight, renumbered from 1 — see the docstring.
        prize = _ranked([r for r in rows if r[0] in eligible])
        paid = split_tied_places(flight_cfg, [r for _pid, _d, r in prize])
        for pid, _data, r in prize:
            payouts[pid] = paid.get(r) or None

    return ranked, payouts


# ---------------------------------------------------------------------------
# Freezing the cut
# ---------------------------------------------------------------------------

def tournament_field(tournament, unindexed=None):
    """``[(player_id, index_or_None), ...]`` for every real golfer in the event.

    The field is derived from foursome memberships — there is no
    tournament-level participant row — which is also why the cut has to be
    frozen once pairings are final rather than recomputed.

    **`unindexed` is how "no index" is expressed, and it is deliberately not a
    property of the golfer.** `Player.handicap_index` is NOT NULL, and it should
    stay that way: a golfer whose index nobody knows still needs one, or he
    plays off scratch and gets no strokes all day. So the estimate keeps doing
    its real job — giving him shots — and the TD names, at cut time, whose
    number is a guess. That knowledge lives with the TD, not in the database.

    The ids named here come back with a ``None`` index, which is what drops them
    out of the sizing and puts them at the bottom (see :func:`assign_flights`).
    """
    from tournament.models import FoursomeMembership
    unindexed = set(unindexed or ())
    rows = (FoursomeMembership.objects
            .filter(foursome__round__tournament=tournament,
                    player__is_phantom=False)
            .select_related('player')
            .values_list('player_id', 'player__handicap_index')
            .distinct())
    return [(pid, None if pid in unindexed else idx) for pid, idx in rows]


class FlightsLocked(Exception):
    """The cut cannot move because the field has started playing under it."""


def cut_is_locked(tournament) -> bool:
    """True once any REAL golfer has posted a gross score in this tournament.

    **Frozen means frozen.** Until this commit "frozen" in this module meant
    *stored rather than recomputed* — the assignment was written down, and
    nothing stopped a TD replacing it on the 14th. Re-cutting mid-round
    silently re-ranks both boards and moves prize money under golfers who are
    still on the course, which is the one thing a cut must not do.

    Phantoms are excluded, the same rule `has_any_score` uses: a padded
    three-ball must not lock a cut nobody has played a hole under.
    """
    from scoring.models import HoleScore
    return HoleScore.objects.filter(
        foursome__round__tournament=tournament,
        gross_score__isnull=False,
        player__is_phantom=False,
    ).exists()


def _same_cut(tournament, n_flights: int, unindexed) -> bool:
    """True when this request would write exactly what is already stored.

    **An idempotent re-post is not a change and is not refused.** A setup
    screen that saves on close, or a double tap, must not be told the round
    has started — the same rule Sequoya's pairing lock uses, where `[B, A]`
    is not a redraw of `[A, B]`.
    """
    if (tournament.flight_count or 0) != n_flights:
        return False
    stored = dict(tournament.flights.values_list('player_id', 'flight'))
    if not stored:
        return False
    stored_unindexed = set(
        tournament.flights.filter(index_at_assignment__isnull=True)
        .values_list('player_id', flat=True))
    if stored_unindexed != set(unindexed or []):
        return False
    field = tournament_field(tournament, unindexed=set(unindexed or []))
    return assign_flights(field, n_flights) == stored


def set_flights(tournament, n_flights: int = None, unindexed=None):
    """Cut the field and FREEZE it. Returns ``{player_id: flight_no}``.

    Replaces any previous assignment wholesale — a re-cut after a withdrawal is
    a new cut, not a patch, because the sizing depends on the whole field.

    Passing ``n_flights`` also stores it on the tournament, so the count and the
    assignment can never disagree.

    ``unindexed`` names the golfers whose entered index is a guess (see
    :func:`tournament_field`). They are recorded with a NULL
    ``index_at_assignment``, which is both what they were treated as and the
    only record that the cut was made that way — so a re-cut a week later can
    be explained, and so `GET` can read the list back.
    """
    from django.db import transaction
    from tournament.models import TournamentFlight

    if n_flights is None:
        n_flights = tournament.flight_count
    if n_flights < 1:
        raise ValueError('Set a flight count of 1 or more before cutting.')

    # **Refused in the SERVICE, not the view**, so every caller is covered —
    # the lesson `setup_sixes` learned when its guard lived one layer up.
    if cut_is_locked(tournament) and not _same_cut(
            tournament, n_flights, unindexed):
        raise FlightsLocked(
            'The field has started playing under this cut, so it cannot '
            'change. Re-cutting now would re-rank both boards and move prize '
            'money under golfers who are still on the course.')

    field = tournament_field(tournament, unindexed=unindexed)
    known_ids = {pid for pid, _idx in field}
    stray = set(unindexed or ()) - known_ids
    if stray:
        # A typo'd id silently doing nothing would change the cut without
        # saying so — and the cut is money.
        raise ValueError(
            f'Not in this tournament: {sorted(stray)}')
    assignment = assign_flights(field, n_flights)
    index_of = dict(field)

    with transaction.atomic():
        TournamentFlight.objects.filter(tournament=tournament).delete()
        TournamentFlight.objects.bulk_create([
            TournamentFlight(tournament=tournament, player_id=pid,
                             flight=flight, index_at_assignment=index_of[pid])
            for pid, flight in assignment.items()
        ])
        if tournament.flight_count != n_flights:
            tournament.flight_count = n_flights
            tournament.save(update_fields=['flight_count'])

    return assignment


def flight_map(tournament) -> dict:
    """``{player_id: flight_no}`` as frozen, or ``{}`` when unflighted.

    **A golfer with no frozen row falls to the bottom flight**, not to a crash
    and not to flight 1. He joined after the cut — a late entry, or a
    substitute — and the bottom flight is where an unknown goes, the same rule
    the unindexed follow.
    """
    if not tournament.flight_count or tournament.flight_count < 2:
        return {}
    frozen = dict(tournament.flights.values_list('player_id', 'flight'))
    if not frozen:
        return {}
    bottom = tournament.flight_count
    return {pid: frozen.get(pid, bottom) for pid, _idx in tournament_field(tournament)}


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

_LETTERS = 'ABCDEFGH'


def flight_label(flight: int) -> str:
    """1 -> 'A'. Golfers say "I'm in B", not "I'm in flight 2"."""
    return _LETTERS[flight - 1] if 1 <= flight <= len(_LETTERS) else str(flight)


def cut_index_map(tournament) -> dict:
    """``{player_id: index_at_assignment}`` — the index the cut was MADE on.

    Not the golfer's index today. A flighted board shows this because it is the
    number that explains where he is: an index that has moved since the cut
    would sit in a flight it no longer justifies and read as a bug.

    ``None`` for a golfer the TD named as unindexed, which is the record that
    his entered number was a guess.
    """
    if not tournament.flight_count or tournament.flight_count < 2:
        return {}
    return dict(tournament.flights.values_list('player_id',
                                               'index_at_assignment'))


def flight_blocks(tournament, standings, payouts_cfg) -> list:
    """One entry per flight, in board order — what a client draws headers from.

    **The purse is what this flight's own golfers paid in** — the table scaled
    by its share of the field, which is `size / field` because every golfer
    pays the same entry. Fifteen golfers cut 8/7 shows $80 and $70.

    It used to be the whole table on every flight: two flights funded by one
    $160 pool each said `$160 purse`, which is where the money bug sat in
    plain sight and read as a generous event rather than an impossible one.

    Still the COMMITTED figure rather than what a flight has paid so far — a
    client summing actual payouts would report `$0` before anybody has scored
    and read as a flight with no prize.

    Sized from the standings rather than from the frozen rows so the header
    counts what the board actually shows — a late entry with no frozen row is
    in the bottom flight on both, and the two must not disagree.
    """
    n = tournament.flight_count or 0
    if n < 2:
        return []
    table = sum(float(p.get('amount') or 0) for p in (payouts_cfg or []))
    sizes = {}
    for row in standings:
        f = row.get('flight')
        if f:
            sizes[f] = sizes.get(f, 0) + 1
    order = sorted(sizes)
    # The SAME apportionment the money uses, so the header cannot advertise a
    # purse the board does not pay.
    purses = apportion(round(table * 100), [sizes[f] for f in order])
    return [{'flight': f,
             'label' : flight_label(f),
             'size'  : sizes.get(f, 0),
             'purse' : purses[i] / 100}
            for i, f in enumerate(order)]
