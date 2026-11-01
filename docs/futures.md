# Futures list

Deferred ideas to consider later — not committed work. Add an entry when we
park something; move it into a real plan/doc when we pick it up.

---

## Field games for SOME of the groups (3 or 4 foursomes in a side game)

**Why:** asked for directly (Paul, 1 Nov 2026) the night before Castlewood —
he wanted to play 40 Balls with two or three of his groups and found there is
no way to arrange it. A 14-group event has one set of groups who want a group
game and twelve who do not.

**The distinction that matters, and it is already half-built.** The app has
two kinds of game on a round:

* **Per-foursome games** — skins, Nassau, Sixes, spots, rabbit … — are stored
  on the FOURSOME (`Foursome.active_games`, read alongside the round's in
  `_hole_tray_summaries` and `FoursomeSerializer.get_configured_games`). These
  already work for a subset of groups. Nothing to do.
* **Field games** — the one-pool family, Irish Rumble / Better Ball / Hot Seat
  / 40 Balls — are round-level and have no subset notion at all. These are the
  request.

**What blocks 40 Balls specifically**, measured rather than guessed:

1. `FortyBallsConfig` is a `OneToOneField(Round)` — no participant or group
   list anywhere in it.
2. `forty_balls_summary` builds a row for EVERY `Foursome` in the round, and a
   group that never picks a count sits at level par (`total` 0) in the middle
   of the ranking until the very end, where `dq = left > capacity` finally
   drops it. So the board is misleading all day rather than just untidy.
3. The pool is `entry_fee × every real golfer in the round`
   (`group_field.field_pool`), not the groups playing.
4. **The one that makes it unusable:** `_fortyBallsRound` is round-level, so
   every group gets the ball-count picker and `needsPick` holds the next-hole
   button until it picks. Turning 40 Balls on for a 14-group event forces all
   fourteen to spend balls on every hole.

**Approach when we build it.** The cheapest shape is almost certainly to make
these games read `Foursome.active_games` the way the per-foursome family
already does — a participating-groups set rather than a new concept — and then
scope four things to it: the board's row set, the pool, the DQ rule, and the
score-entry gate. The config stays round-level (one stake, one table); what
becomes per-group is who is IN.

Worth deciding at the same time: a group that opts in late, and whether the
pool is `entry_fee × golfers in participating groups` (almost certainly yes,
since that is what `field_pool` means one level down).

**What we did instead, for the record:** nothing. He dropped the side game
rather than run it for everybody, which is the right call and also the
evidence that the gap is worth closing.

---

## The card-mate rule blocks a pool whose scores come from elsewhere

**Why:** found the night before Castlewood (1 Nov 2026) while planning a
Multi-Group Skins pool fed by a linked tournament round.

`utils/skins_cards.cardsProblem` refuses a draw where any card has nobody on
Halved — *"somebody has to keep their score — put them in a group with a
golfer who is."* That is the right rule when the pool round IS where the
scores are entered, which is the flow it was written for.

It is the wrong rule for a **linked** pool. There the host round's cards are
deliberately empty: `_resolve_participant_memberships` binds each golfer to
the source round where he has the most scores, so a login-less golfer parked
in the host round is scored in the round that was linked, by whoever scores
THAT round. Nobody keeps score on the host card, so a card with no Halved
golfer on it strands nobody.

The practical cost: a login-less golfer can only be in the pool at 4 per
Halved card-mate, even when his scores are coming from a tournament round
somebody else is keeping. Castlewood had 23 of 60 on the app, so the cap sat
at 92 seats against a field of 60 and never bit — but it would on a field
with fewer members.

**Note the server never had this rule.** `valid_participant_ids` wants
host-round member OR on-app and says nothing about card-mates, so this is
the picker being stricter than the engine — the same shape as the grey-out
that `canJoinPool` replaced in Oct 2026.

**Approach:** the rule needs to know whether the host round will be scored at
all, which it cannot know at create time (the link comes after). Options,
cheapest first: relax it once the round HAS a linked source (the Groups
screen is reachable from the hub afterwards); or ask outright on the picker
whether the scores come from somewhere else; or drop the card-mate test for a
round whose primary is `multi_skins` and warn instead of refusing.

---

## Tournament setup in the TD console (big screen)

**Why:** Paul, 1 Nov 2026 — *"I think the next tournament setup I will do in
the TD web page is this one. Would be easier with a big screen."* Setting up
60 golfers in four flights across fifteen foursomes is laptop work, and the
console exists precisely because that is true of the night before an event.

**Current state:** `console/` has sign-in, the Golf Genius roster import, the
course library / editor and custom tees. It has **no tournament setup at
all** — creating an event, the field, the draw, the championship and its
payouts are mobile-only (`new_round_wizard.dart`, the two championship setup
screens).

**Approach:** this is a big surface and the wizard is the spec rather than the
thing to port — it carries decisions (the eight honest steps, money where it
is charged, the derived step list) that a web version should keep. The natural
first slice is the part that is worst on a phone and already has its data in
the console: **the field and the draw**, since the roster import is there and
a fifteen-foursome draw is a table.

Flights would be the second slice, and it has a prerequisite in its own entry
below.

---

## Explicit flight assignment, and why it is not just an uneven cut

Split out of the Castlewood evening (see the Flights section in `CLAUDE.md`
for the full account). `assign_flights` cuts equal sizes only, so a cut made
in another system cannot be mirrored, and **naming the no-index golfers makes
the bottom flight BIGGER rather than making a flight of them** — four flights
over 54 indexed golfers with six guessed gives 14/14/13/19, not 18/18/18/6.

The useful half: `rank_in_flights` is already size-agnostic — it groups by
whatever flight a golfer is in, restarts ranks at 1, and apportions each
flight's purse by `len(by_flight[f])`. Uneven flights rank and pay correctly
today. **Only the writer is missing**, and the shape it needs is in CLAUDE.md
along with the two things it has to refuse.

Castlewood's cut was written by hand over `railway ssh`. Doing that twice is
the signal to build it.

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

---

## The stuck keyboard on Round chat — diagnosed, not fixed, not reproduced

Reported 1 Nov 2026: *"I went to send a message and then got stuck in the app
with the keypad showing. The done button did nothing. I had to exit the app to
close the keyboard."* Paul could not reproduce it afterwards and parked it, so
this is the diagnosis waiting for the next sighting rather than a fix.

**What is provable from the code**, and is a real defect whether or not it is
the reported one: the Round chat composer
(`screens/round_feed_screen.dart`, `_Composer`) is the **only field in the app
set to `TextInputAction.newline`**, so its bottom-right key is `return` and
inserts a line break. On an empty or one-line message that is indistinguishable
from a dead button — and Paul confirmed he pressed *the keyboard's own key*. He
reached the screen from a score screen, which is where the `RoundChatButton`
lives, so "a score screen" in the report is where he started.

**The screen has no dismissal of its own.** No `keyboardDismissBehavior`
(four other screens already use `onDrag`), no `onTapOutside`, no unfocus after
a send. Both escapes are global and neither is discoverable from the field:
`KeyboardDismissal`'s tap-anywhere, and its grey Done bar.

**That bar has broken on this exact screen twice before** — it covered the
composer at Ranch Solano (17 Sep 2026), and again when a MediaQuery nested
below the wrapper threw the inflated inset away. Round chat is its repeat
offender, which is the reason to suspect it a third time.

**What was tried and did NOT reproduce it:** a widget test driving the global
Done bar against a composer configured exactly like this one, newline key
included, releases focus correctly (`mobile/test/round_chat_keyboard_test.dart`,
kept as a guard). So the bar's mechanism is sound in isolation; if it failed on
the real screen the cause is something that host does not model — the pushed
route, the 25-second poll rebuilding the screen under it, or the bar being
drawn over the composer again.

**A fix was written and reverted**, because it carries a cost that wants
deciding rather than assuming: making the return key `send` fixes the dead key
AND dismisses the keyboard, but removes the ability to type a line break in a
message. Worth doing if the diagnosis is confirmed; not worth trading
blind.

**The zero-cost half DID go in** (Paul, 1 Nov 2026): both transcript lists now
carry `keyboardDismissBehavior: onDrag`, so dragging the messages puts the
keyboard away — the one escape discoverable from the field, and the answer four
other screens already use. It removes nothing, so it needed no decision. The
dead return key is still dead.

**What to capture next time it happens**, in this order — the first two
discriminate between the two candidate causes:
1. Was the grey **Done bar** visible on top of the keyboard, or was the
   composer sitting where it should have been?
2. Did the bottom-right key read `return` or `Done`?
3. A screenshot. The two prior rounds of this were both settled by one
   (`CLAUDE.md`: *"Ask for the screenshot earlier"*).
4. Whether tapping the message transcript dismissed it.
