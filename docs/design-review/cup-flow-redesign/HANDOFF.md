# Cup flow redesign — implementation handoff

**Target:** the Triple Cup tournament flow, ahead of the September 2026 Cup event.
**Nature of this work:** editing an existing 28-step flow, not building a new one.

Two reference sets exist in the Halved Design System:

| | Where | What it is |
|---|---|---|
| Before | `handoff-cup-flow/01–28.png` + `.html` | Simulator captures of the shipped build (Tilden Ryder Cup, Aug 2026) |
| After | `screens/cup-*.html` and friends | The redesign, drawn in the Halved system |
| Why | `screens/cup-create-flow-map.html` | The diagnosis all of this comes from — read this first |

Numbers below (`13`, `24`…) always refer to the shipped capture in `handoff-cup-flow/`.

---

## Phase 4 — answers to implementation feedback

Raised after Phases 1–3 landed. Each item is settled; the file named is redrawn.

### Assumptions that did not hold

**Competition selector — dropped.** A tournament carries exactly one cup, so a selector
would hold one item. The cup name and its points rule are now a static line under the app
bar; the four view tabs stay a fixed segmented control. Multiple cups per tournament is not
roadmap intent — do not build the data model toward it.
→ `after/cup-leaderboard.html`

**Team colour — six named swatches, confirmed.** Red, Blue, Green, Orange, Yellow, Purple.
The **name** is what is stored; every surface resolves it through one palette. Six is the
ceiling: as many as stay distinguishable at 20 px and legible on white, and more sides than
the cup formats support. No custom picker. The swatch row names the selection in a caption
rather than labelling each square — six labels do not fit at 375 px.
→ `after/cup-design-teams.html`

### Decisions confirmed

**Start Round is non-blocking.** Correct as built. The screen is redrawn to match: the
builder cannot seat an illegal group, a golfer left out is usually a deliberate rest, so the
button is live once one group exists. The tally reads GROUPS / PLAYING / SITTING OUT, and
unassigned golfers are named with an **Assign** link in a neutral note, not an amber blocker.
The derived-vs-explicit sit-out question is closed — derived.
→ `after/round-groups.html`

**Complete Round: cup-only TD restriction, confirmed.** A casual round keeps its designated
scorer. The distinction is now stated in the notes so it does not read as an oversight.
→ `after/cup-round-hub.html`

### Deferred items resolved

**In-picker side switcher — dropped.** The draft board's per-team **Add** already answers
which side is being filled, so the switcher was a second control for a question just asked.
The screen keeps the header/side-name, cap, staged picks and taken-locked rows; the
switch-confirm sheet is gone, and held picks are discarded on leaving.
→ `after/draft-add-players.html`

**Shotgun start rules — specified.** In `after/group-builder.html`, "Shotgun rules":

- One group per hole, assigned on creation to the lowest free hole. Taken holes are locked
  in the picker, not hidden.
- Above 18 groups it is a double shotgun (1A / 1B share a hole); the B slot is offered only
  once every hole is taken. **Not drawn.**
- Shotgun collapses per-group tee times to one round value; the interval control is hidden,
  not disabled.
- Formats defining segments by hole cannot shotgun — struck with that reason.

**Remembered tee interval — it lives on the course.** A new field on the course record, in
minutes, default 10. The builder writes it when a TD changes it and reads it as the default
for every later round at that course. Not a tournament field.

**"Starts N" inference — accepted as-is.** No change; the note that it assumes the fixed
Triple Cup hole map is correct and worth keeping in the code.

**Net skins and Nassau press — still open.** Not specified this round. Do not build them.

### The blocker: group-bet attach path

Your read is right, and it is now drawn: **`after/group-bet-attach.html`**.

Player-initiated from the group's own card on the round hub, gated to a member of that
group, not a TD control. One correction to the write-up: the mechanism to reuse is
**multi-group skins**, not multi-round.

The rule that matters: **reach is one option, not a set of switches.** The existing
multi-group-skins "Attach to" control gains *the tournament* as one more answer alongside
*this group* and *several groups*. Single-select — a game is **never** attached to both a
set of groups and the tournament. That state has no meaning (the pot would be counted twice
and the two settlements would disagree), so make it unreachable rather than validating
against it.

Once this lands, `after/leaderboard-group-bets.html` is pure display over each foursome's
configured games. Its "Add one" links now point at the attach screen rather than the group
builder.

---

## The one problem

The wizard asks for things it cannot know yet, and calls itself finished eight steps
before setup actually is. Three symptoms:

- **Type is asked second** (`14`), after basics — so the wizard cannot honestly tell
  you how long it is, because type decides whether draft, teams and match selection
  exist at all.
- **Group count is asked at `19`**, six steps before groups become real at `27`.
- **Review (`20`) reads as the end.** Eight required steps follow it.

Everything below follows from fixing those three.

---

## Target sequence

| Phase | Screens | Scope |
|---|---|---|
| 1 · What kind of event | Type & format, Event details, Handicap | All types |
| 2 · Teams | Teams | Cup only |
| 3 · Format per round | Games by round, Tournament side game | All types |
| 4 · Save & draft | Review & save, Draft board, Add players to a side | Cup only |
| 5 · Build the groups | Group builder, Groups for this round | All types |
| 6 · Play | Round hub, Cup leaderboard, Cup hub, Group bets, TD tools | All types |

---

## Phase 1 — wizard resequence (September-critical)

### 1.1 Type & format → new first step
- **Before:** `13` basics, then `14` tournament game.
- **After:** `screens/cup-wizard-step1.html`
- Type is the **scoring unit** — side, golfer, pair or group — and the format sets it.
  Scores captured, leaderboard shape and group-bet availability all follow from it.
- The step list is **derived from the answer**, so the progress indicator is honest.
  Kill the hardcoded "4 of 4".
- Replaces shipped `13` and `14`.

### 1.2 Event details
- **Before:** `13` (name, course, date) and `15` (course, date, players per round) —
  the same fields twice.
- **After:** `screens/cup-event-details.html`
- Name, home course, and **one round per date**. Dates create rounds.
- **Drop "players per round" entirely.** It is a guess; entitlement comes from the
  draft and assignment comes from the group builder.
- Course is inherited per round with a per-round override.
- Shipped `15` is retired.

### 1.3 Handicap
- **Before:** `16`
- **After:** `screens/cup-handicap.html`
- Mode only (Net / Gross / SO Low). Course and date move out to event details.
- Allowance is set **per segment** at its match-play standard.
- **Strike the net double-bogey cap** — match play has no stroke total to protect.

### 1.4 Teams
- **Before:** `17`
- **After:** `screens/cup-design-teams.html`
- Count, colours, **names and badges** in one place, so the draft never renames.
- 16-character name cap (derived from iPhone 13 mini).
- Colours lock once taken; badge collisions **warn, not block**.

> **Bug to fix here.** "Number of Teams" defaults to 2 and renders highlighted, but
> **Next stays disabled until a chip is explicitly tapped.** Init state and highlight
> state disagree. Either commit the default to state on mount, or don't highlight it.

### 1.5 Games by round
- **Before:** `19` and `28`
- **After:** `screens/cup-games-by-round.html`
- **Remove the group-count field.** Derive it from round setup. This is the single
  change that takes the guess out of the middle of the flow.
- Points shown per group; format and points set per segment, per round.

### 1.6 Tournament side game
- **Before:** `18`
- **After:** `screens/cup-side-game.html`
- Field-wide games only — Irish Rumble, Pink Ball.
- **When the format is exclusive (Triple Cup), strike the step and state the reason.**
  Today it is a step with no legal answer.
- Skins, Nassau and rabbit move out of here to **group scope** (Phase 2).

### 1.7 Review & save
- **Before:** `20` review, `21` created — two screens.
- **After:** `screens/cup-review.html`
- Absorbs `21`. One screen.
- Primary button reads **"Save & continue to draft"**, not "Finish".
- **Name what remains:** draft, then one round setup per round.
- No empty sections — unfinished setup renders as actionable rows.
- Every subtitle matches the button it names.

---

## Phase 2 — group builder (September-critical)

The highest-leverage change in the flow. All four tournament families walk it, and it
is currently spread across the most screens. A captain building four groups walks
twelve screens to do one job.

### 2.1 Group builder — 5 screens become 1
- **Before:** `24` set matches, `25` tee selection, `26` tee time, plus the standalone
  Set Tees screen. Three screens describing one group.
- **After:** `screens/group-builder.html`
- One card per group: golfers, tees, tee time, start format, group bets.
- **Tee time defaults to previous group + 10 minutes.** The clock dial is doing work
  for a value that is nearly always predictable.
- Add **Set all** for tees. Today the menu covers the row it belongs to.
- Show the group index, as `23` does and `24` does not.
- Never render `triple_cup` raw.

### 2.2 Groups for this round
- **Before:** `27`
- **After:** `screens/round-groups.html`
- Composition, tee time, tees and bets per group; unassigned golfers **by name**.
- **Start Round states its own blocker** rather than sitting disabled.

### 2.3 Draft
- **Before:** `22` draft open, `23` add players.
- **After:** `screens/ryder-cup-draft.html`, `screens/draft-add-players.html`
- **Lock stays disabled until every side is legal.** Today it is enabled at zero players.
- Don't invite a drag gesture with no target while rosters are empty.
- Add-players header **names the side being filled** — today it never says.
- Count runs against roster size; drafted golfers show who holds them.

### 2.4 Retired
- Shipped `03` "Set up cup round" — which cup game and which teams are both answered
  in Phase 1 step 3 now.

---

## Phase 3 — play surfaces (can land after September)

| Screen | Before | After |
|---|---|---|
| Round hub | `05` | `screens/cup-round-hub.html` |
| Cup leaderboard | `04` | `screens/cup-leaderboard.html` |
| Cup hub | `01` | `screens/cup-hub.html` — live score on the tournament card; six flat rows become one primary action plus a grouped round-setup disclosure |
| Group bets | — | `screens/leaderboard-group-bets.html` — skins, Nassau, rabbit settled from gross already entered. A tab at group scope, **not a second scoring flow** |

---

## Do not touch

These ship as they are. No changes requested.

- `02` Lock draft
- `06` TD menu · `07` Remove no-show · `08` Swap tee position — the only steps that
  assume the plan was wrong, and the ones a real Cup morning needs most
- `09` Championship tab
- ~~`10` Overview · `11` Details · `12` My Foursome~~ — superseded in live testing; see Phase 5

---

## Not drawn yet — do not implement

- **Pairings** (two-man only). Two golfers a side, set once and carried per round —
  the two-man equivalent of the draft. The wizard names this step; no screen exists.
  Same shape as the draft board, one side per pair instead of two rosters of eight.

---

## Beyond cup — what the type-first change implies

`cup-wizard-step1.html` makes the flow serve four families. What varies between them
is **how many golfers share a score**; everything else follows. See the divergence
table in `cup-create-flow-map.html` for the full matrix.

Two consequences worth knowing before you build the wizard's branching:

1. **The group builder is shared work** — all four families walk it. Build it generic.
2. **The one-ball formats need something the app does not have.** Alternate shot,
   Chapman and scramble put a single card in for two or four golfers. Best ball,
   shamble and bramble keep individual cards, so they are the cheap half.

Skins, rabbit and Nassau are **group bets, not tournament types** — they need
individual gross, which is what decides them.

---

## Phase 5 — Cup leaderboard, reworked in live testing (built, merged)

Engineering reworked the cup leaderboard during a live test on an eight-group cup
and merged it to `main`. The mocks are redrawn to match; nothing here is a build
request. Source: `docs/design-review/cup-flow-redesign/FEEDBACK-testing-rework.md`.

| Was | Now |
| --- | --- |
| Overview, Details, My Foursome as separate views | One **Cup Detail** tab: two-panel scoreboard, then a card per group |
| My Foursome tab | The viewer's own group sorts first, rest in tee-time order; header reads `Group 4 (my group) · 8:30 AM` |
| Names repeated per segment | Full names once at the top of the card, initials in the four segment rows (`BK / AP vs RS / RW`); a solo side's Phantom is named in the header, real golfer first |
| Group card drills into per-group standings | Cards are non-interactive — a Triple Cup has no per-foursome bet |
| Bar marker at the to-win point | Marker is the **even line**, dead centre on the divider; "16½ to win" stays in the text |
| "points played" | "**points decided**" — a point is not earned until its match is decided |

Design confirms all six as drawn in `screens/cup-leaderboard.html`.

**New surface — Edit tee times.** The tee-time pencil lived only in initial setup,
so a running cup had no way to nudge one group. Added under Round setup: groups in
tee-time order, tap a time to change it, saves immediately; after a change it offers
to shift the later groups by the same amount. Drawn in `screens/edit-tee-times.html`
— list state and shift prompt. Open: whether a shift notifies affected players.

Also fixed in passing, not design-relevant: Triple Cup segment "thru N" counted the
segment's full hole range instead of scored holes; now counts decided holes only.

---

## Phase 6 — Mixed cup: a day that runs several games

A cup that is not a Triple Cup runs **several point-bearing games at once**, and each
foursome plays exactly one of them. The shipped wizard cannot express this: step 1
asks for one cup format for the whole tournament.

### Where the code already supports it

| Fact | Where |
| --- | --- |
| Per-round game plan is already a **list**, not one value | `new_round_wizard.dart` — `_roundCupGames: Map<int, List<String>>` |
| Per-game point values already exist per round | `new_round_wizard.dart` — `_roundCupPoints: Map<int, Map<String, double>>` |
| Cup game catalog | `new_round_wizard.dart` — `_kCupGameChoices` (nassau, irish_rumble, singles_nassau, triple_cup …) |
| Per-foursome game assignment exists | `cup_round_setup_screen.dart` — `_gameType` per foursome; `triple_cup` locks every foursome via `_roundFormat` |

**The bottleneck is step 1.** `_cupFormats` offers exactly `triple | singles | fourball`,
one answer for the whole cup, and `_cupFormat` then drives `_cupFormatExclusive` and the
derived step flow.

### The change, in four screens

1. **`cup-wizard-step1.html`** — the cup branch becomes **Mixed cup** (default) or
   **Triple Cup** (the preset; exclusive, owns all 18 holes). Singles and Fourball stop
   being tournament-level formats and become games in a day's list. The consequence strip
   for a mixed cup is honest about not knowing: scores-in "depends on the game each
   foursome plays", group bets available **only** in games that keep individual gross.

2. **`cup-games-by-round-mixed.html`** — step 5. Two questions in order: **which games**,
   then **how many of each** and **what each is worth**. Every game counts in its own unit:

   | Game | Counted in | Cost |
   | --- | --- | --- |
   | Fourball, Nassau pairs | foursomes | 2 per side per foursome |
   | Two-man Chapman, two-man scramble | foursomes | 2 per side per foursome |
   | Singles, Singles Nassau | twosomes | 1 per side per twosome |
   | Irish Rumble, Scramble | **on/off — one match at most** | 4 per side, 8 golfers |

   A game is in the day when its count is above zero — there is no separate checkbox.
   The meter counts **against one side's roster** (16 here), because every match takes the
   same number from each side. Points are a stepper on the round card next to the count,
   priced per match per game per day. Both counts and prices are known here, so the round
   total, cup total and to-win number are real.

3. **`group-builder-mixed.html`** — round setup. The day's plan is a **worklist**: every
   match step 5 paid for is a row, built ones showing their group and tee time. The captain
   picks which to build next; **group numbers are assigned by tee time on save, not build
   order**. The game decides the group's shape (2v2 foursome / 1v1 twosome / four from one
   side), and an Irish Rumble is one row that builds **two** groups. Shotgun is available
   here — unlike Triple Cup, a mixed day has no shared segment split to protect.

4. **`round-game-assignment.html`** — the same round seen by game rather than by group:
   contained matches vs foursome-against-foursome, with **red against blue enforced**.
   A side's foursome with no opposite number is drawn as an incomplete match and
   Start Round stays disabled until every game balances.

### Open, not designed

- **Half points.** Every one of these games can halve; no step names the rule.
- **Handicap by game.** A Chapman group and a Singles group in the same round take
  different allowances, and no screen says so.
- Whether a game's point unit (per match vs per segment) is fixed per game across the cup
  or free per round.

---

## Phase 7 — Confirmations from live testing (Aug 2026)

Engineering built, verified and merged a two-game mixed cup (Four Ball Nassau +
Singles Nassau, strokes off). The list below is design's answer to that pass.
Everything marked **confirmed** is now the intended design — the mocks in this pack
have been redrawn to match rather than the build being changed back.

### Setup / wizard

1. **Side games are individual-tournament-only. Confirmed.** A cup's points come from
   its games-by-round plan; a field-wide side game sitting outside that plan has no
   way to be worth anything. Irish Rumble stays available inside the plan.
   `cup-side-game.html` is now a tournament screen, not a cup screen.
2. **A mixed cup never re-offers Triple Cup at setup. Confirmed.** The Round Format
   toggle is a wizard-time choice; showing it again at setup made a destructive action
   look like a navigation one. Suppress it whenever a mixed plan exists, and filter the
   game picker to what step 5 still owes — which is what `group-builder-mixed.html`
   already draws as the worklist.
3. **The Irish Rumble variant picker belongs at group setup. Confirmed.** The variant is
   round-level and chosen once; group setup is the first screen where the round is real.
   Keep the live segment preview — it is the only place a captain can check the balls
   pattern before play.
4. **Back on review exits the flow.** Noted; the mocks do not draw Back as an add action.

### Scoring

5. **Anchor = your competition. Confirmed.** Strokes off should read the same on the
   Stroke Play tab as in the match a golfer is actually playing; anchoring on the field
   low made the two disagree. Two players in one singles foursome having different
   anchors is correct and worth a one-line note under the tab header so it does not
   read as a bug.

### Leaderboard — drawn in `cup-leaderboard-mixed.html`

6. **One Stroke Play tab. Confirmed.** Two tabs with the same name, one of them blank.
7. **Full names in match headers. Confirmed.** "AB vs AB" is unreadable. The dropped
   roster row was duplicating the match rows.
8. **The per-hole grid belongs on the leaderboard. Confirmed.** The match result alone
   left the tab with nothing to look at, and the grid is already the shape players know
   from score entry and sixes.
9. **Prospective stroke dots. Confirmed.** The stroke plan is knowable at the first tee;
   showing it only in arrears meant the information arrived after it was useful.
10. **Green dots everywhere. Confirmed.** Red on a team-coloured row read as a marker.
11. **"AY (12)" row labels. Confirmed.** Matches the Nassau grid's strokes-in-play
    convention, and the full name is one line above.

### The five open calls — now decided

- **Half points: a halved match splits the point.** ½ to each side, always, in every
  game. Not a per-game setting and not a captain option — a cup that can end tied is
  the point of a cup.
- **Handicap: per-game allowance, defaulted, set when the match is built.** Reversed
  after review — a cup-wide number cannot be right for a day that runs Chapman beside
  Singles. Each game arrives with its USGA standard already filled in, so a captain who
  wants the standard does nothing; the control follows the Triple Cup Foursomes pattern,
  in two shapes: a **percentage per golfer** where each golfer plays a ball (Singles 100%,
  Nassau pairs / Fourball 90%, Irish Rumble 100%) and a **combined side handicap** where
  the side plays one (Foursomes 50/50 low+high, Chapman 60/40, Scramble 25/20/15/10).
  Drawn on `group-builder-mixed.html`, which is the only screen that knows a group's
  game. The card shows the resulting strokes, not just the setting.
- **Point unit: free per round.** The stepper on the round card is the only place a
  game's price and unit are set, so the same game can pay per match one day and per
  segment the next. Nothing is carried between rounds.
- **Odd twosome: offer a Phantom partner**, exactly as the Triple Cup does. The pattern
  already exists, players already read it on the leaderboard, and the alternative —
  blocking odd counts — makes the captain solve the app's arithmetic.
- **Stage 3 reframe: not yet.** `round-game-assignment.html` covers the function.
  Revisit after more cups have run; it is shared with Triple Cup, so a rework should be
  driven by both, not by one testing pass.

### Scramble and Irish Rumble — stroke play, points for the win

Both are **one row** at score entry, not two: the group *is* one side, and the four it
plays against is a separate group on a separate phone. There is no hole-by-hole match to
run, so the card keeps a **team total** — gross, net, to par — with the opposing group's
total shown for reference as it arrives.

**Points are for the win, never per stroke.** A per-stroke price makes the cup total
unknowable until the last card is in, which destroys *"16½ to win"* — the number the
whole format exists to produce. Low net total takes the match's points; a tie halves
them, like every other game.

### New — six team games, in three pairs

The foursome-counted family is now **six rows**, each game in a one-match and a
three-segment form:

| One match | Nassau (front + back + overall) |
| --- | --- |
| Fourball | Nassau pairs |
| Two-man Chapman | Chapman Nassau |
| Foursomes | Foursomes Nassau |

They are separate rows, not a segment toggle inside one row, because they are priced
differently and a captain choosing a day's games is choosing between them. All six count
at **2 per side per foursome**, and a Nassau variant takes its base game's handicap
allowance — no seventh and eighth allowance to set.

**Foursomes** matters most: without alternate shot a mixed cup cannot run a real
multi-day Ryder Cup, which is the format this whole path exists to support.

**Naming, unsettled.** The list reads cleaner as *Fourball / Fourball Nassau* to match
the other two pairs, but *Nassau pairs* is the string already in the app. Worth deciding
before the strings are written.

### Hole wins — one convention everywhere

**The winning side's score cells are tinted in its team colour**, spanning both players
of the pair so the block reads as one side rather than two scores. Halved holes stay
plain; most holes halve, and tinting them would leave nothing to find. The tint uses the
**net** score — the number the match is decided on — so it can never disagree with the
running result.

This **replaces the "Won by" initials row** on the casual Nassau card: same information,
one row shorter, and read off the scores themselves rather than a legend below them.
Applied to the cup leaderboard's Nassau and Singles grids (`cup-leaderboard-mixed.html`)
and the casual Nassau progress grid (`nassau-play.html`). Stroke-play cards — Scramble,
Irish Rumble — carry no tint: there is no hole to win, only a total.
