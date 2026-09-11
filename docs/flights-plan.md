# Flights on the Championship leaderboards

**Status:** planned, not built. Written 2026-09-11 for the Monday 2026-09-14 event.
**Applies to:** Low Net Championship and Stableford Championship.

---

## Why this exists, and why the obvious workaround does not

Two flights, each paying its own places, out of one field.

The workaround is to run two tournaments, one per flight. It fails on the actual
draw: **one or two foursomes contain both A and B flight golfers.** A foursome
belongs to one tournament, so a mixed group would have to run *two rounds side
by side* — the A players scored in one tournament, the B players in another, two
app sessions for four people walking together. That breaks the single scorecard
the group plays off and takes every in-group side game with it. It is not a
workaround; it is a different event.

So flights have to live inside one tournament.

## Decisions already taken

These are settled. They are recorded here so they are not re-litigated.

- **Each flight pays its own places.** That is the entire point of flighting.
- **Prizes are stated AMOUNTS, and each flight's pool is equal** — so both
  flights pay the *same table*. There is no per-flight payout config: the
  existing `payouts` list is applied independently to each flight, and the
  event's budget is `sum(table) × n_flights`.
- **This event's prizes are club-budgeted, not entry-funded.** `entry_fee = 0`
  and the TD types the amounts. **No fake entry fee** — nothing divides a
  budget, so nothing needs the round-to-nearest-5 rule in code. That rounding
  is the TD's own convention when setting the table.
- **No Mini Singles on a flighted event**, and none on a one-day event. This is
  a validation rule, and it removes the carve-out question entirely.
- **Flights are equal-sized**, and the remainder goes to the **lower-index**
  flight. 20 indexed golfers in two flights is A=10, B=10; 23 is A=12, B=11.
- **A golfer with no index goes to the bottom flight and is NOT counted in the
  split** — named by the TD at cut time, not stored on the golfer. See "How
  no-index is expressed" below.
- **Original statement of the rule:** The split is taken over the INDEXED golfers alone, then the no-index
  golfers are added to the highest flight — so the bottom flight is deliberately
  bigger. 23 golfers of whom 3 have no index: split the 20 indexed (A=10, B=10),
  then add the 3, giving **A=10, B=13**. Not A=12, B=11.
- **Flights are assigned on handicap INDEX**, not playing handicap. Playing
  handicap moves with tee and course; the index does not, and a golfer must not
  change flight because the second round is off a different set of tees.
- **A flight, once assigned, is frozen.** See the wrinkle below.
- **Stableford is in from the start**, not bolted on later.

### The wrinkle: "frozen at entry" cannot mean at entry

Equal-sized flights are sized off the field. So every late entry or withdrawal
resizes them, and a flight frozen when each golfer enters cannot also be
equal-sized — the two rules contradict each other.

The freeze therefore happens **when the field is final** — an explicit *Set
flights* action once pairings are set, not a derivation that re-runs. After that
the assignment is a stored fact and nothing moves it, which is what "frozen"
was protecting.

---

## How no-index is expressed

`Player.handicap_index` is **NOT NULL**, and it should stay that way.

The temptation is to make it nullable so "no index" is a property of the golfer.
That breaks him worse than it fixes him: his **playing handicap is snapshotted
onto the membership at setup** from whatever index he holds, so a golfer with no
index plays off **scratch** and gets no strokes all day. Nulling the field would
correct which flight he is ranked in and ruin the golf he actually plays. It is
also 93 non-test references and a design question — what does a golfer with no
index play off? — rather than a migration.

So the estimate stays and keeps doing its real job, and the TD names the guesses
**at cut time**:

```json
POST /api/tournaments/{id}/flights/
{"n_flights": 2, "unindexed": [412, 588, 903]}
```

Those ids come back from `tournament_field` with a `None` index, which is what
drops them out of the sizing. The knowledge lives where it actually is — the TD
knows whose number is a guess; the database cannot.

The record of the cut is the `NULL index_at_assignment` on their frozen rows, so
a re-cut a week later is explicable and `GET` can read the list back.

**It matters at three, not at one.** With a single unknown golfer in an even
field the naive alternative (just give him a high index) produces the identical
cut; the two diverge once there are two or more, or the field is odd:

| field | unknown | flights | this rule | high index |
|---|---|---|---|---|
| 36 | 1 | 2 | 18 / 18 | 18 / 18 |
| 36 | 3 | 2 | **17 / 19** | 18 / 18 |
| 35 | 1 | 2 | **17 / 18** | 18 / 17 |

---

## Phase 1 — server only, no App Store

The client renders the leaderboard **in the order the server sends and takes
`rank` verbatim.** It does not sort. Two consequences, both verified in
`mobile/lib/screens/tournament_leaderboard_screen.dart`:

- The server can return rows flight by flight, ranks restarting at 1 per flight,
  and the existing installed app draws them as contiguous blocks.
- `isLeading = rank == 1`, so **each flight's leader gets the leader treatment**
  — which is correct for flights, by accident rather than design.
- The row key is `'$rank:$name'`, unique across flights because the names differ.

So the whole of the scoring, ranking and money can ship to Railway with **no new
iOS build and no App Store review**.

### The ceiling, stated honestly

Without a client build there is **no flight header**. The board will read as two
ranked blocks with nothing between them announcing where one ends. The stopgap
is to carry the flight in the row's own `name` — `A · Paul L` — which the client
renders verbatim. It is ugly and it is temporary; it is also unambiguous, which
beats two anonymous blocks.

A second cosmetic wart: the row's `handicap` column is **playing handicap**
(`low_net_round.py`), while flights are cut on index. On a flighted board those
two numbers sitting together invite the question. Phase 2 should show the index.

---

## Design

Two shared pieces, both game-agnostic, so Stableford costs almost nothing.

### 1. `assign_flights(players_with_index, n_flights) -> {player_id: flight}`

Pure function. Sort by index ascending, cut into equal parts, hand the remainder
to the lower-index flights. No database, no game knowledge, trivially testable —
and the only place the sizing rule lives.

**A golfer with no index does not take part in the sizing.** Partition the
field first — indexed and not — split only the indexed, then append the rest to
the highest flight. Writing it the other way round (bottom-flight them, then
split the whole field) silently pushes a real golfer up a flight to make room
for one whose index nobody knows, which is exactly what this rule prevents.

The consequence is intended and should not later be read as a bug: **the bottom
flight can be larger, and both flights still pay the same table**, so more
golfers there compete for the same money. That is the accepted cost of not
letting an unknown index displace anybody.

### 2. `rank_in_flights(aggregated, *, sort_key, flight_of, payouts_cfg, eligible)`

Ranks and pays **within** each flight, returning the rows in flight order.

Both championship services already share one shape — aggregate into
`{player_id: data}`, sort, assign ranks with a tie-aware loop, then
`split_tied_places`. The **only** thing they differ on is the sort:

| Game | Sort |
|---|---|
| Low Net | net-to-par ascending |
| Stableford | points descending |

So `sort_key` is the parameter and everything else is shared.

`eligible` is not decoration. **Stableford carries an `excluded` set and pays
"among eligible players only"; Low Net does not.** A flight helper that ignores
it will pay Stableford golfers who should not be paid.

### 3. `TournamentFlight(tournament, player, flight)`

There is **no tournament-level participant model** — the field is derived from
`FoursomeMembership` across the rounds (`_field()` in
`services/tournament_settlement.py`). So there is nothing to hang a flight on,
and the frozen assignment needs its own small explicit model. One row per
golfer, written once by *Set flights*.

This is also what makes "frozen" real: a fact in the database rather than a
convention that the next calculator forgets.

### What follows for free

`services/tournament_settlement.py` iterates the standings rows and reads
`row['payout']`. **Put flights inside the two `*_championship_standings()`
functions and settlement, the receipt and the pots follow with no change.** This
is the single best structural fact about the job and it should not be given up
by computing flights anywhere else.

---

## The purse — resolved, and one wart

The money questions are answered and none of them block:

- **Amounts, not shares.** Both flights pay the same typed table.
- **Nothing divides a budget**, so there is no rounding logic to write.
- **No Mini Singles when flighted**, so `carve_out()` never runs against a
  flighted pool and the two-pools question does not arise.

What remains is cosmetic, and is knowingly accepted for this event. With
`entry_fee = 0` the championship pot takes **nothing** in and pays prizes out,
so `services/tournament_settlement.py` computes `entries_in = 0`,
`prizes_out = $X` and reports **`balanced = False`**. The settlement screen will
show the championship pot short by the full prize fund.

That is correct-but-ugly: the club pays the winners, no money moves between
golfers, and the leaderboard's payout column is the only place the prizes need
to read properly. **Decided: leaderboard column is enough for this event.**

The proper fix, when a club-funded event is worth supporting for real, is the
seam that already exists — `_Pot.transfer_in` funds a pot from outside the
entries (it is how Mini Singles day 2 is paid). A budgeted event would fund the
pot from the club rather than from `entry_fee × field`, and balance. That is a
separate piece of work from flights and should not be tangled into it.

---

## Tests

The suite already covers these calculators (`test_low_net_modes.py` and the
Stableford equivalents), so extend rather than start over.

- `assign_flights`: 22/2, 23/2 (remainder low), 23/3, a field smaller than the
  flight count.
- `assign_flights` with no-index golfers: 23 with 3 unindexed gives A=10, B=13
  (NOT A=12, B=11); a field where every golfer is unindexed; one where only the
  bottom flight would otherwise be empty.
- Ranking: ties **inside** a flight split that flight's places and nothing else.
- Money: each flight pays the full table once, so the event pays
  `sum(table) × n_flights` and no more — a tie inside a flight must not let that
  flight pay out more than its share.
- Stableford: an excluded golfer is ranked but not paid, inside a flight.
- Settlement: the pot totals are unchanged by flighting a field of one flight.

---

## Phase 2 — the client, whenever a build next ships

**The setup UI already has its home.** `_flightsDeferred()` in
`new_round_wizard.dart` draws a `Flights` card with a `NOT YET` chip on the
SCORING step — P10 chose to state the absence rather than hide it. Phase 2
replaces that card's body with the real controls (flight count, *Set flights*),
so the step's shape does not change and nothing has to be found a place.

- Real section headers per flight, with the flight's own purse stated.
- Show the **index** on a flighted board, not the playing handicap.
- Drop the `A · ` name prefix the moment headers land.

---

## Monday

Phase 1 is the plan. If it is not finished and tested by Sunday, **Monday runs
unflighted on one board and the flights are settled by hand from the final
standings** — which is safe, because the standings themselves are unaffected by
flighting. Do not run two tournaments: the mixed foursomes make that worse than
either alternative.
