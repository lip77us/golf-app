# Futures list

Deferred ideas to consider later — not committed work. Add an entry when we
park something; move it into a real plan/doc when we pick it up.

---

## Cross-account "courses I've played" in the recents quick-pick (viral hook)

**Why:** growth. When a friend who has the app runs a game and invites you to
their foursome, we'd love that course to be effortless for you to play yourself
next time — ideally surfaced in your course recents, or even pre-selected as the
default when you start your own round soon after.

**Current state (shipped):** the recents quick-pick
(`RecentCoursesView` → `GET /api/courses/recent/`) is scoped to **your own
account's rounds** only. A course you played in a friend's round doesn't appear.
For now, invitees just type the course name in the picker. (Confirmed reasonable
to start there.)

**Approach when we build it:**
- Include courses from rounds you **played** in another account (phone-matched
  `FoursomeMembership`, the `PlayingRoundsView` source). **Exclude observed /
  watcher rounds** (`SharedRoundsView`) — play, not observe.
- Courses are account-private (copy-on-add model), so a cross-account course
  must be **resolved back to your account via `golf_api_id`** (the catalog key):
  - you already own it → instant select (as today);
  - it's in the shared catalog → **add-on-tap** (clone, brief spinner — same as
    a catalog search hit);
  - custom/pasted course with no catalog id → can't be added to your account →
    skip it.
- Mobile: the recents block switches from instant `_commit(CourseInfo)` to the
  shared `_select(hit)` source path (`account` vs `catalog`), so clone-on-tap
  works. Endpoint returns source-tagged entries like `CourseFindView`.

**Stretch:** "course as default" — when you open a new round shortly after being
added to a foursome at a course, pre-select that course rather than just listing
it in recents.

**Trade-off to note:** a not-yet-owned recent would clone on tap instead of
selecting instantly. Judged acceptable.

---

## Divisions — a women's field alongside a men's, on one card

**Why:** Tilden Seniors, 27 Oct 2026. Paul set up *TPSGC Fall Scramble 2026* —
Team Play, two-man scramble, 56 golfers (46 men, 10 women) in 14 groups — and
went looking for the flight controls. There aren't any that reach it, so the
committee ranks one mixed board of 28 pairs and reads the women's result off it
by eye. He judged that fine for Thursday; the ask is parked here.

**A division is NOT a flight, and that is the whole design.** Flights are
DERIVED — `assign_flights` cuts the field into equal-sized groups by handicap
index, remainder to the lower flight, and freezes the cut in
`TournamentFlight.index_at_assignment`. A division is DECLARED: it is a
committee category, and in this very field it could not have been computed.
Of the 28 pairs, 23 were all-men, 4 all-women and **one was mixed** — Charlie
Wicke (M) and Jean Hurricane (W) — and the committee put them in the **men's**.
Nothing about an index or a `Player.sex` would have got that right.

So: **do NOT add a `sex` argument to `assign_flights`.** Sex-derived divisions
get the mixed pair wrong, and a TD who can't override it has to leave the app.

**Current state (shipped):**
- `services/flights.py` is consumed only by `low_net_championship.py`,
  `stableford_championship.py` and `dream_round.py` — i.e. inside the two
  `*_championship_standings()` functions. It never mentions sex.
- `FlightsCard` (`widgets/flights_card.dart`) renders on exactly two screens,
  `tournament_low_net_setup_screen` and `tournament_stableford_setup_screen`,
  below the payouts. The wizard holds a card that points there, because the
  wizard runs before the tournament exists and before pairings are set.
- Team Play (`Tournament.is_team_play`, `TeamPlayConfig`,
  `services/team_play_scoring.py`) has **no** flight support at all. Setting
  `flight_count` on a team-play tournament changes nothing on its board.

**The reusable half is already there.** `rank_in_flights(rows, sort_key=,
rank_key=)` ranks and PAYS within a group, and the two championship summaries
already carry a `flights` list with a label, a size and a purse that
`FlightHeader` draws as a band. That is most of what a division board is. What
is missing is the assignment and the reach.

**Approach when we build it:**
- **Store the assignment, don't derive it.** `TournamentFlight` is the right
  precedent — one frozen row per competitor — but the label comes from the TD
  rather than from a cut. Seed it from `Player.sex` so the common case is one
  tap, and let him move anybody; the mixed pair is the case that proves the
  seed must be editable.
- **The unit differs by event shape.** A division belongs to the **team** in a
  pairs/team event and to the **golfer** in an individual one. In the scramble
  above the competitor is the pair, so a per-golfer row would have had to
  answer for a pair that straddles two divisions.
- **Reach beyond the two championships.** Team-play standings have to honour it,
  which means the division split wants to live where `rank_in_flights` is
  called from rather than inside the championship functions. Keeping it in the
  two `*_championship_standings()` is what currently makes settlement and the
  receipt need no changes (they iterate rows and read `row['payout']`) — a
  third call site has to preserve that.
- **Each division pays its own table**, which `rank_in_flights` already does.
  Entry fee is collected per division; in the Tilden event it was $0, so
  nothing was settled and the hand-picked women's winner contradicted nothing
  on screen. A real one will not be that forgiving.

**Known adjacent defect:** `services/payout.split_tied_places` returns one
figure per RANK, so a tie can lose or invent a cent (already noted under
Flights in CLAUDE.md). Small divisions tie more often than one big field, so
divisions make it likelier — `split_to_cents` is the fix and the shape change
is the work.
