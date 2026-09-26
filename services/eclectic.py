"""
services/eclectic.py
--------------------
Eclectic — the best score on every hole number, across every round of the
event. Eighteen bests make a golfer's card; lowest total wins.

Rules (all settled 26 Sep 2026; see
docs/design-review/handoff-eclectic/HANDOFF.md)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* **Matched by hole NUMBER**, across every round and every course.
* **Compared to par** — that round's par for that hole. A gross total means
  nothing across two courses with different pars, and to-par is what the game
  is scored on anyway: a 4 on the Ridge's par-5 5th is a birdie and beats a
  par 4 on North Links' 5th.
* **Lowest to-par is kept.** A tie between rounds keeps the EARLIER round, for
  display only — the total is the same either way.
* **Two pools**, gross and net, scored and paid separately.
* **Net strokes are per round, before selection** — that round's handicap at
  full allowance on that course's stroke index. No tournament handicap, no
  blended stroke index.
* **No net double-bogey cap.** Only the best score on a hole counts, so a
  ceiling on the worst one changes nothing.
* **A missed round is still eligible — but the card must cover all eighteen
  hole numbers.** Ruled 26 Sep 2026. Missing holes add nothing to the total, so
  without this a golfer who played ONE round of three competes on ten holes
  against a full card's fifty-four and can win the money on it. The seeded demo
  produced exactly that: T3 on −2 from ten holes, level with a golfer who had
  played all three rounds.

  So a card with a hole nobody covered is RANKED BELOW every complete card and
  cannot be paid. It is not hidden: the scores are real and the golfer played
  them. A hole with no candidate still draws as `–`.

  **The rule is self-normalising**, which is why it needs no "is the event
  live" test: during round 1 every card is incomplete, so it separates nobody;
  once a round finishes everyone who played it is complete together; and the
  only golfer it isolates afterwards is the one with an actual gap.
* **Ties split the money for the places they cover.** No countback.

Availability
~~~~~~~~~~~~
Individual events with **2+ rounds, every one of them 18 holes**. One round is
not an eclectic, it is the round; and a 9-hole round would put nine holes of
the card permanently out of reach of half the field.

Public API
~~~~~~~~~~
    ok, reason = eclectic_available(tournament)
    rows       = eclectic_standings(tournament, pool)   # 'gross' | 'net'
    summary    = eclectic_summary(tournament)
"""
from core.models import RoundStatus
from scoring.handicap import effective_hcp_for, make_strokes_fn
from scoring.models import HoleScore
from tournament.models import Foursome

#: The allowance. **100% is the rule, not a default** — the packet says "that
#: round's course handicap at 100%", meaning no allowance is taken off it. It
#: is passed through `effective_hcp_for` rather than read off
#: `membership.course_handicap` so that a FORCED playing handicap still wins:
#: that number came off an externally-managed card and is already final.
FULL_ALLOWANCE = 100

#: Every hole number an eclectic card has. The game is gated on 18-hole rounds,
#: so this is the card, not an assumption about a round.
CARD_HOLES = list(range(1, 19))


# ---------------------------------------------------------------------------
# Availability
# ---------------------------------------------------------------------------

def eclectic_available(tournament) -> tuple:
    """``(ok, reason)`` — whether this event can play an eclectic.

    The reason is written to be SHOWN: the wizard puts it under the game's name
    when the entry is disabled. An event with one round hides the entry
    entirely rather than disabling it, which is the caller's decision, so the
    two cases are distinguishable by the reason string's caller, not here.
    """
    rounds = list(tournament.rounds.all())
    if len(rounds) < 2:
        return False, 'Needs two or more rounds'
    if any((r.num_holes or 18) != 18 for r in rounds):
        return False, 'Needs every round to be 18 holes'
    return True, ''


# ---------------------------------------------------------------------------
# One round's cards
# ---------------------------------------------------------------------------

def _round_cards(round_obj) -> dict:
    """``{player_id: {hole: {'gross', 'par', 'strokes'}}}`` for one round.

    Par and stroke index come from each golfer's OWN tee, not the round's or
    the first player's. On a mixed card the forward tee can play a hole as a
    five where the back tee plays it as a four, and a golfer's score to par has
    to be against the par he actually played — which is the same rule the
    scorecard already uses for its own par row.
    """
    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee')
    )

    # **One allocator per distinct STARTING HOLE, not per foursome.**
    # `make_strokes_fn` re-reads the course's tees to find the hole universe,
    # so calling it per foursome cost 43 tee queries on the six-round event in
    # the local database — most of the whole summary. Its answer depends on the
    # round and on the group's start (a partial round re-ranks within the holes
    # played), and on nothing else, so two groups off the same tee share one.
    fn_cache: dict = {}

    def _strokes_fn(fs):
        key = fs.starting_hole or round_obj.starting_hole or 1
        if key not in fn_cache:
            fn_cache[key] = make_strokes_fn(fs)
        return fn_cache[key]

    cards: dict = {}
    meta: dict = {}          # player_id -> (membership, strokes_fn)
    for fs in foursomes:
        strokes_fn = _strokes_fn(fs)
        for m in fs.memberships.all():
            if m.player.is_phantom or m.tee_id is None:
                continue
            meta[m.player_id] = (m, strokes_fn)
            cards[m.player_id] = {}

    if not cards:
        return {}

    scores = (
        HoleScore.objects
        .filter(foursome__round=round_obj,
                player_id__in=list(cards),
                gross_score__isnull=False)
        .values('player_id', 'hole_number', 'gross_score')
    )

    for row in scores:
        pid = row['player_id']
        m, strokes_fn = meta[pid]
        hole = row['hole_number']
        try:
            par = m.tee.hole(hole).get('par')
        except StopIteration:
            par = None
        if par is None:
            # A tee with no data for this hole cannot produce a to-par value,
            # and guessing par 4 would invent a birdie. Skip the candidate.
            continue
        cards[pid][hole] = {
            'gross'  : row['gross_score'],
            'par'    : par,
            # The allocation for THIS round on THIS course. `make_strokes_fn`
            # is the shared allocator, so a plus handicap gives strokes back on
            # the low-index holes here exactly as it does everywhere else.
            'strokes': strokes_fn(effective_hcp_for(m, FULL_ALLOWANCE),
                                  m.tee, hole),
        }

    return cards


# ---------------------------------------------------------------------------
# The card
# ---------------------------------------------------------------------------

def _field_names(tournament) -> dict:
    """``{player_id: name}`` for every real golfer in the event."""
    names = {}
    for fs in (Foursome.objects.filter(round__tournament=tournament)
               .prefetch_related('memberships__player')):
        for m in fs.memberships.all():
            if not m.player.is_phantom:
                names[m.player_id] = m.player.name
    return names


def _all_round_cards(tournament) -> list:
    """``_round_cards`` for every round, in play order — read ONCE.

    Both pools and the whole summary are built from this list. Reading it per
    pool would double the queries on a board that loads on every leaderboard
    request, and the six-round event in the local database is twelve round
    reads instead of six.
    """
    return [_round_cards(r) for r in tournament.rounds.order_by('round_number')]


def _build_cards(tournament, pool: str, per_round=None) -> tuple:
    """``(cards, rounds)`` — every golfer's eclectic in ``pool``.

    ``cards`` is ``{player_id: {'name', 'holes': {h: kept}, 'total',
    'holes_kept'}}``; ``rounds`` is the round list in play order.

    ``kept`` carries the round it came from, so the board can mark the cell:
    ``{'round_index', 'to_par', 'gross', 'par', 'strokes'}``.

    ``per_round`` lets a caller that already has the rounds' cards hand them
    over instead of paying for them twice.
    """
    rounds = list(tournament.rounds.order_by('round_number'))
    if per_round is None:
        per_round = _all_round_cards(tournament)

    names = _field_names(tournament)

    cards: dict = {}
    for pid, name in names.items():
        holes: dict = {}
        for h in CARD_HOLES:
            best = None
            for idx, card in enumerate(per_round):
                entry = card.get(pid, {}).get(h)
                if entry is None:
                    continue
                strokes = entry['strokes'] if pool == 'net' else 0
                to_par = entry['gross'] - strokes - entry['par']
                # **Strictly less than**, so an equal score from a later round
                # never displaces the earlier one. Which cell is marked makes
                # no difference to the total; it makes a difference to a golfer
                # reading his own card, and the earlier round is the one he
                # made it on.
                if best is None or to_par < best['to_par']:
                    best = {
                        'round_index': idx,
                        'to_par'     : to_par,
                        'gross'      : entry['gross'],
                        'par'        : entry['par'],
                        'strokes'    : strokes,
                    }
            if best is not None:
                holes[h] = best

        cards[pid] = {
            'name'  : name,
            'holes' : holes,
            'total' : sum(v['to_par'] for v in holes.values()),
            'holes_kept': len(holes),
        }

    return cards, rounds


# ---------------------------------------------------------------------------
# Standings
# ---------------------------------------------------------------------------

def eclectic_standings(tournament, pool: str, per_round=None,
                       cards=None) -> list:
    """Ranked rows for one pool, with the money.

    A golfer with NO holes at all — entered, not yet teed off — is ranked last
    rather than leading on a total of zero, which is what a bare ascending sort
    would do to him.
    """
    config = getattr(tournament, 'eclectic_config', None)
    if config is None:
        return []
    if pool not in config.pools:
        return []

    payouts_cfg = {
        p['place']: float(p['amount'])
        for p in ((config.gross_payouts if pool == 'gross'
                   else config.net_payouts) or [])
    }
    excluded = set(config.excluded_player_ids or [])

    if cards is None:
        cards, _rounds = _build_cards(tournament, pool, per_round)
    if not cards:
        return []

    def _bucket(d) -> int:
        """0 = a whole card, 1 = one with a gap, 2 = nothing posted yet.

        The gap bucket is what stops a ten-hole card outranking a
        fifty-four-hole one; the empty bucket is what stops a golfer who has
        not teed off leading on a total of zero.
        """
        if d['holes_kept'] == 0:
            return 2
        return 0 if d['holes_kept'] >= len(CARD_HOLES) else 1

    def _sort_key(kv):
        d = kv[1]
        if _bucket(d) == 2:
            return (2, 0, 0)
        # More holes kept breaks a tie in the SORT so the board reads sensibly
        # mid-event; it does NOT break it in the RANK, because the game is the
        # total and two golfers level on it are level.
        return (_bucket(d), d['total'], -d['holes_kept'])

    from services.flights import rank_in_flights
    ranked_f, payouts = rank_in_flights(
        cards,
        sort_key=_sort_key,
        rank_key=lambda kv: ((2, 0) if _bucket(kv[1]) == 2
                             else (_bucket(kv[1]), kv[1]['total'])),
        # **Eclectic is never flighted.** The flights cut is the
        # championship's; a side game riding on it would pay two boards from
        # one table. One flight holding everybody is the same code path the
        # unflighted championship uses.
        flight_of=lambda pid: 1,
        payouts_cfg=payouts_cfg,
        # **A card with a gap cannot be paid.** Same mechanism the TD's own
        # exclusions use, so the prize ranking is recomputed over the eligible
        # alone and the place moves UP to the golfer behind him.
        eligible={pid for pid, d in cards.items()
                  if _bucket(d) == 0} - excluded,
    )

    rows = []
    counts = {}
    for _pid, _d, rank, _f in ranked_f:
        counts[rank] = counts.get(rank, 0) + 1
    for pid, data, rank, _flight in ranked_f:
        rows.append({
            'player_id'  : pid,
            'player_name': data['name'],
            'rank'       : rank,
            'tied'       : counts.get(rank, 1) > 1,
            'total'      : data['total'] if data['holes_kept'] else None,
            'holes_kept' : data['holes_kept'],
            'payout'     : payouts.get(pid),
            'excluded'   : pid in excluded,
            # Every hole number covered by at least one round. The board says
            # `10 of 18` when it is not, because "not paid" with no reason is
            # the thing the flag exists to avoid.
            'card_complete': data['holes_kept'] >= len(CARD_HOLES),
            'card_holes'   : len(CARD_HOLES),
        })
    return rows


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def _round_meta(tournament) -> list:
    """One entry per round: label, course, date, par, and its course INITIAL.

    **The initial scheme is all-or-nothing.** The packet draws `R1 N` / `R3 R`
    with a legend reading `N North Links · R The Ridge`, which works when the
    courses start with different letters. The six-round event in the local
    database is at Bandon, where the five courses are `Bandon Dunes`,
    `Bandon Trails`, `Pacific Dunes`, `Bandon - Sheep Ranch` and
    `Bandon Dunes — Old Macdonald`: every one of them is `B`.

    Giving the first course its letter and blanking the rest would put a
    suffix on one row and nothing on four, which reads as a rendering fault
    rather than as a rule. So a single collision drops the scheme for the whole
    card and the legend keys on the ROUND label instead, which is already on
    the row and is always unique.
    """
    rounds = list(
        tournament.rounds.order_by('round_number')
        .select_related('course')
        .prefetch_related('foursomes__memberships__tee')
    )

    by_course = {}
    for r in rounds:
        by_course.setdefault(r.course_id, (r.course.name or '').strip())

    letters = {cid: (name[:1].upper() if name else '')
               for cid, name in by_course.items()}
    collides = (len({l for l in letters.values() if l}) != len(letters)
                or any(not l for l in letters.values()))
    if collides:
        letters = {cid: '' for cid in letters}

    out = []
    for idx, r in enumerate(rounds):
        par = None
        fs = next(iter(r.foursomes.all()), None)
        if fs:
            m = next((m for m in fs.memberships.all() if m.tee_id), None)
            if m:
                par = sum(h.get('par', 0) for h in (m.tee.holes or [])) or None
        out.append({
            'index'   : idx,
            'label'   : f'R{r.round_number}',
            'round_id': r.id,
            'course'  : r.course.name,
            'course_initial': letters.get(r.course_id, ''),
            'date'    : r.date.isoformat() if getattr(r, 'date', None) else None,
            'par'     : par,
            'num_holes': r.num_holes or 18,
            'is_complete': r.status == RoundStatus.COMPLETE,
        })
    return out


def _course_legend(rounds: list) -> list:
    """``[{'key', 'course'}, …]`` — what the card's header spells out.

    Keyed on the initial when the scheme holds (`N North Links`), and on the
    round label when it does not (`R1 Bandon Dunes`). One course played twice
    is named once under the initial scheme and once per round without it,
    because without initials there is nothing else to key it on.
    """
    if not rounds:
        return []
    if all(r['course_initial'] for r in rounds):
        seen = {}
        for r in rounds:
            seen.setdefault(r['course_initial'], r['course'])
        return [{'key': k, 'course': c} for k, c in seen.items()]
    return [{'key': r['label'], 'course': r['course']} for r in rounds]


def _single_course_holes(tournament, rounds) -> dict:
    """``{'par': {h: p}, 'stroke_index': {h: si}}`` when the whole event is on
    ONE course, else ``{}``.

    The card draws the app's standard `Par` and `Index` bands from this. They
    are omitted on a mixed-course event rather than guessed: two courses mean
    two pars and two stroke indexes on the same hole number, so one row of
    either would be wrong for half the card. The notation carries par there
    instead, which is the handoff's own rule.

    Read off the first tee in play — on one course the field's tees can still
    differ, and a per-golfer par row is not a thing a shared card can draw. The
    SCORES are always scored against each golfer's own tee; this is the header,
    and it says what the course is.
    """
    if len({r['course'] for r in rounds}) != 1:
        return {}
    first = tournament.rounds.order_by('round_number').first()
    if first is None:
        return {}
    fs = first.foursomes.first()
    if fs is None:
        return {}
    m = next((m for m in fs.memberships.all() if m.tee_id), None)
    if m is None:
        return {}
    return {
        'par': {h['number']: h.get('par') for h in (m.tee.holes or [])},
        'stroke_index': {h['number']: h.get('stroke_index')
                         for h in (m.tee.holes or [])},
    }


def eclectic_summary(tournament) -> dict:
    """Everything the board draws, for both pools.

    ``cards`` carries the whole grid — every round's gross on every hole and
    which one was kept — because the row OPENS into it and a second request per
    golfer would be a request per row.
    """
    config = getattr(tournament, 'eclectic_config', None)
    if config is None:
        return {}

    rounds = _round_meta(tournament)
    n_courses = len({r['course'] for r in rounds})
    legend = _course_legend(rounds)
    live = [r for r in rounds if not r['is_complete']]

    # Read once, used by both pools and by every card below.
    per_round = _all_round_cards(tournament)

    pools = {}
    for pool in config.pools:
        cards, _ = _build_cards(tournament, pool, per_round)
        standings = eclectic_standings(tournament, pool, per_round, cards)

        detail = {}
        for row in standings:
            pid = row['player_id']
            kept = cards.get(pid, {}).get('holes', {})
            detail[pid] = {
                'rounds': [
                    {
                        'label': rounds[i]['label'],
                        'course_initial': rounds[i]['course_initial'],
                        'holes': {
                            h: {
                                'gross'  : v['gross'],
                                'par'    : v['par'],
                                'strokes': v['strokes'] if pool == 'net' else 0,
                                'to_par' : (v['gross']
                                            - (v['strokes'] if pool == 'net' else 0)
                                            - v['par']),
                                'kept'   : (h in kept
                                            and kept[h]['round_index'] == i),
                            }
                            for h, v in sorted(per_round[i].get(pid, {}).items())
                        },
                    }
                    for i in range(len(rounds))
                ],
                'best': {h: v['to_par'] for h, v in sorted(kept.items())},
            }

        fee = float(config.gross_entry_fee if pool == 'gross'
                    else config.net_entry_fee)
        pools[pool] = {
            'entry_fee': fee,
            'pool'     : round(fee * len(standings), 2),
            'payouts'  : [
                {'place': p['place'], 'amount': float(p['amount'])}
                for p in ((config.gross_payouts if pool == 'gross'
                           else config.net_payouts) or [])
            ],
            'standings': standings,
            'cards'    : detail,
        }

    return {
        'pools'     : config.pools,
        'rounds'    : rounds,
        'n_rounds'  : len(rounds),
        'n_courses' : n_courses,
        'course_legend': legend,
        # Present only on a one-course event — see `_single_course_holes`.
        **_single_course_holes(tournament, rounds),
        # `R3 live · projected` — the chip that says the money can still move.
        'live_label': (f"{live[0]['label']} live" if len(live) == 1
                       else (f'{len(live)} rounds live' if live else '')),
        'is_final'  : not live,
        # Each pool under its own key, and ABSENT when it is off — so a client
        # cannot draw a Net board for a gross-only event by reading an empty
        # dict as a real one.
        **pools,
    }
