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

    Every flight pays the SAME table (see the plan): equal pools and stated
    amounts mean flight B's table is flight A's table.
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

    ranked, payouts = [], {}
    for flight in sorted(by_flight):
        rows = sorted(by_flight[flight], key=sort_key)

        for pid, data, rank in _ranked(rows):
            ranked.append((pid, data, rank, flight))

        # Prize ranking is its own pass over the eligible golfers in THIS
        # flight, renumbered from 1 — see the docstring.
        prize = _ranked([r for r in rows if r[0] in eligible])
        paid = split_tied_places(payouts_cfg, [r for _pid, _d, r in prize])
        for pid, _data, r in prize:
            payouts[pid] = paid.get(r) or None

    return ranked, payouts


# ---------------------------------------------------------------------------
# Freezing the cut
# ---------------------------------------------------------------------------

def tournament_field(tournament):
    """``[(player_id, index_or_None), ...]`` for every real golfer in the event.

    The field is derived from foursome memberships — there is no
    tournament-level participant row — which is also why the cut has to be
    frozen once pairings are final rather than recomputed.
    """
    from tournament.models import FoursomeMembership
    rows = (FoursomeMembership.objects
            .filter(foursome__round__tournament=tournament,
                    player__is_phantom=False)
            .select_related('player')
            .values_list('player_id', 'player__handicap_index')
            .distinct())
    return [(pid, idx) for pid, idx in rows]


def set_flights(tournament, n_flights: int = None):
    """Cut the field and FREEZE it. Returns ``{player_id: flight_no}``.

    Replaces any previous assignment wholesale — a re-cut after a withdrawal is
    a new cut, not a patch, because the sizing depends on the whole field.

    Passing ``n_flights`` also stores it on the tournament, so the count and the
    assignment can never disagree.
    """
    from django.db import transaction
    from tournament.models import TournamentFlight

    if n_flights is None:
        n_flights = tournament.flight_count
    if n_flights < 1:
        raise ValueError('Set a flight count of 1 or more before cutting.')

    field = tournament_field(tournament)
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


def prefixed_name(name: str, flight, flighted: bool) -> str:
    """``A · Paul L`` — the STOPGAP until a client build draws flight headers.

    The shipped app renders the leaderboard in server order and prints the row's
    name verbatim, so flighting works end to end with no build; what it cannot
    do is announce where one flight ends and the next begins. Carrying the
    letter in the name is ugly and unambiguous, which beats two anonymous blocks.

    It is applied ONLY in the summary (the client-facing payload), never in
    `*_championship_standings`, so it cannot leak into settlement or a receipt —
    those read `player_name` off the standings rows.

    Delete this the moment headers ship.
    """
    if not flighted or not flight:
        return name
    return f'{flight_label(flight)} · {name}'
