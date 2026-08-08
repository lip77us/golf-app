# Cup flow redesign — implementation plan

**Target:** the Triple Cup tournament flow, ahead of the **September 2026 Cup event.**
**Nature:** an edit of the existing 28-step flow, not a new feature. Seven steps replace
the wizard's front half; five screens collapse into one group builder; the play surfaces get
a lighter pass.

**Source of truth**
- Design references (HTML + notes columns): `docs/design-review/cup-flow-redesign/` — `after/`, `before/`, `foundations/`, `HANDOFF.md`.
  The **notes column** beside each phone frame carries the decisions the pixels don't.
- Diagnosis: `docs/design-review/cup-flow-redesign/after/cup-create-flow-map.html` — the full 28-step map and the four-family divergence table.
- Implementation target: `mobile/lib/` (Flutter/Dart). Palette in `mobile/lib/theme/halved_brand.dart`.

Design files are prototypes of intended look and behaviour — recreate in Flutter with existing
widgets/theme, don't lift the HTML. Fidelity is high: final colours, type, spacing, copy, and
the drawn interactions.

---

## The one problem

The wizard asks for things it cannot know yet, and calls itself finished eight steps before
setup actually is. Three symptoms, and everything below follows from fixing them:

- **Type is asked second**, so the wizard can't honestly say how long it is — type decides
  whether draft, teams and match selection exist at all.
- **Group count is asked in games-by-round**, six steps before groups become real.
- **Review reads as the end.** Eight required steps follow it.

---

## The two architectural spines — build these first

Everything else hangs off two changes. They are independent of each other and can proceed in
parallel.

### Spine A — the wizard becomes a derived step list

*Unlocks all of Phase 1. Moderate churn, not a rewrite.*

> **Status: landed** (`new_round_wizard.dart`). `_step` now indexes a derived
> `List<_StepKind> _stepFlow` computed from tournament type; `_totalSteps` is
> `_stepFlow.length`; header shows an honest 1-indexed "N of M"; `_canAdvance`
> and `_stepBody` switch on `_currentStep` (a `_StepKind`), and the `logicalStep`
> shim + the two cup pre-switch special-cases are gone. Post-creation is a
> terminal `_isPostCreate` state, not a flow member. **One-name decision applied:**
> `_cupNameCtrl` removed, cup persists under the single `_nameCtrl`; the cup-name
> field + its Next-gate are gone from `_Step2CupDesign` (which also fixes the
> "Teams Next disabled despite default" bug). Adding/striking a step (e.g. the
> exclusive-format side-game rule) is now a one-line edit to `_stepFlow`.
> `flutter analyze` clean; not yet run in the simulator.

Today `new_round_wizard.dart` drives an `int _step` through a switch, with a constant step
count:

- `int get _totalSteps => _isCupTournament ? 5 : 6;` — `new_round_wizard.dart:71`
- Header prints `'$_step of ${_totalSteps - 1}'` — `new_round_wizard.dart:767` → the **"4 of 4" lie**.
- `_isCupTournament` keys off `_tournamentActiveGames.contains(GameIds.teamCup)` — L65–67.
- Cup already fakes a different length with ad-hoc offsets: `logicalStep = (cup && _step>=4) ? _step+1 : _step` (L869), plus pre-switch special-cases at L811 / L835.

**Change:** replace the `_step:int` + `_totalSteps:int` pair with an ordered
`List<_WizardStep>` built from the chosen **type / format / round-count** (step kind → builder
fn + `canAdvance` predicate + title). `_step` becomes an index into that list; `_totalSteps`
becomes `steps.length`; header/progress read from the list so "N of 7 / 9" is honest.

The step *bodies* (`_Step0Tournament` … `_Step6GameSetup`) survive — they get re-scoped/split,
not deleted. Churn concentrates in ~5 index-assuming spots:

- `_totalSteps` getter — L71
- `_canAdvance` switch — L359–411
- `_next` / `_back` — L413–425
- `_stepBody` special-cases + `logicalStep` shim — L811 / L835 / L869
- header / progress — L764–773

Converting these to list lookups removes the shim and the "of 4" lie in one pass, and is what
lets exclusive Triple Cup **strike** the side-game step honestly.

*Caveat:* the sentinel `_step = _totalSteps` used to reach the post-create screen (L570, L745)
goes away once Review absorbs "Created".

### Spine B — group count is derived, never asked

*Unlocks Phase 2.*

Today side size is asked ~6 steps too early on the cup **creation** form
(`_ppTeamCtrl = TextEditingController(text: '6')`, `ryder_cup_draft_screen.dart:46`, posted via
`postTeamTournamentSetup(playersPerTeam: ...)` L128–133) — before any roster exists. Group
count then separately *emerges* as `_foursomes.length` in round setup.

The casual path already does this right: `groupSizes(n)` in `utils/grouping.dart:22` derives
group count purely from roster size (`8→[4,4]`, `14→[4,4,3,3]`), consumed cleanly in
`setup_round_players_screen.dart`.

**Change — one number, set once, read everywhere:**

1. Set side size on the **draft add-players** screen (step 6), off the creation form.
2. `roster = sides × sideSize`.
3. `groups = ceil(roster / 4)` via the existing `groupSizes()` helper — with an odd-remainder
   note ("one will be short, round setup will say which").
4. Gate **Lock Draft** on every side reaching that side size.
5. Open **round setup** seeded with that many groups; `round-groups`' tally reads off it, not
   `_foursomes.length`.

> **Progress — B1 + B2 landed.**
> - **B1:** `players_per_team` surfaced on the client (`TeamTournamentSummary.playersPerTeam`);
>   the backend already emitted it, the model just dropped it. Foundation for all derivation.
> - **B2 (= the `cup-games-by-round` redesign):** the wizard **stops asking group count** — the
>   "Groups" stepper is removed from `_RoundGameSlots`, the column is relabelled "Per segment",
>   and an amber note explains "Side size is set in the draft, and the group count … follow[s]
>   from it." The wizard persists **empty `cup_group_counts`**, so "points to win" honestly
>   defers rather than being guessed at 1 group. `cup_group_counts` is only a pre-setup
>   projection — once a round's foursomes exist the real count takes over, so nothing regresses
>   permanently. (Backend unchanged; `Round.cup_group_counts` still accepts the empty dict.)
> - **B3 landed — side size is the single input, on the draft.** `ryder_cup_summary` now emits
>   `players_per_team` (B1's client parse needs it — it was missing from the GET/PATCH payload).
>   New backend `PATCH /team-tournament/` updates `players_per_team` without touching rosters
>   (`postTeamTournamentSetup` *replaces* the whole thing, so it couldn't be reused mid-draft).
>   The draft board gains a **"Players per side"** stepper, a derived line
>   ("2 sides × 4 = 8 golfers · 2 groups of four", with an odd-remainder note), **"X of N"** fill
>   per team (green when full), and **Lock Draft gated** until every side reaches the side size —
>   verified end to end on device incl. the gate flipping.
> - **B4 landed — round setup derives the group count.** `cup_round_setup_screen` now imports
>   `grouping.dart` and derives `_expectedGroupCount = groupSizes(rosterSize).length` from the
>   drafted roster. The "Groups for this round" review page shows a tally —
>   **"1 of 2 groups built · 1 more from 8 drafted"** — instead of the count silently emerging
>   from `_foursomes.length`; unassigned golfers are listed by name. Verified on device.
>
> **Spine B core is complete (B1–B4): side size is the single input, group count derives from it
> everywhere — the wizard no longer asks, the draft sets side size and gates Lock on it, and
> round setup derives the target from the roster.**
>
> **Spine B follow-ups — all landed:**
> - **Handicap index** now shows on the draft roster + round-setup picker (`CupPlayer.handicapIndex`,
>   emitted by `ryder_cup_summary`).
> - **Vestigial group-count plumbing deleted** — `_roundCupGroupCounts` +
>   `onGroupCountsChanged` + `_RoundGameSlots.currentGroupCounts` removed from the wizard (the map
>   was write-only once B2 stopped asking; `createRound` still sends `cup_group_counts: {}`).
> - **"Points to win" projects pre-setup** — `cup_standings._planned_possible` now falls back to
>   `_derive_group_counts(round)`, which reads the live side size off the draft
>   (`players_per_team × sides → ceil(roster/4) groups`) instead of the empty stored counts. Only a
>   single-cup-format round is projected; a multi-format round stays unprojected rather than guessing
>   its split. Read-time derivation — no persisted `cup_group_counts`, so it can't go stale when the
>   side size changes. Verified: roster 8 → 2 groups → 8.0 possible (triple_cup); 302 scoring tests green.

### Corollary — make `type` / `format` a stored fact

`_isCupTournament` is *derived* from which championship-chip is toggled. Making type the first
explicit question means the type picker should **set** the games set, and the derived step-list
recomputes on change. This also stabilizes the Phase-3 leaderboard, whose tab structure is
computed from that runtime inference today.

---

## Phase 1 — wizard resequence (September-critical)

Build order. Each screen mapped to where the shipped version lives in the 3,619-line wizard.

| # | Screen (after/) | Becomes | Lands at (`new_round_wizard.dart`) |
|---|---|---|---|
| 1 | `cup-wizard-step1` ✅ **landed** | Type & format as the **first** step; scoring-unit pills (side/golfer/pair/group); consequence strip; **derived step-plan panel** driving an honest "1 of N" | new `_StepKind.typeFormat` + `_Step1TypeFormat` widget; championship selection moved off `_Step0Tournament`; Cup + Individual wired, Two-man/Four-man staged (disabled "Soon"); cup format informational (per-round games still authoritative) |
| 2 | `cup-event-details` ✅ **landed** | Name + event course + **one round per date** (dates create rounds); course inherited per round with override; **drop "players per round"** | new `_StepEventDetails` (merges name/rounds off the tournament step + course/date off the details step); rounds are a dated card list with "Add a round"; `_additionalRounds` inherit the event course at persist. Enum renamed `tournament`→`eventDetails`, `details`→`handicap`; New/Existing kept. Follow-ups: course picker shows casual "Play here"/"Playing today" copy (mock wanted "Use"); per-round step multiplication (header 7→9) not yet wired |
| 3 | `cup-handicap` ✅ **landed** | Mode only (Net / Gross / SO-Low); **strike the net double-bogey cap** (match play has no total to protect); **SO Low is the default for cup formats** (foursome-based match play), Net for individual | `_StepHandicap` gains `isMatchPlay`: cup shows a struck "NOT SHOWN" cap card (live toggle kept for non-cup), cap forced off at persist for cup. Handicap default derives from type via `_defaultHandicapForFormat` with a `_handicapModeTouched` guard. **Deferred:** foursomes combined allowance (Low%/High%) — needs wizard→`postTripleCupSetup` wiring (wizard only makes stubs); worked-example panel; dedupe the shared selector's "Handicap" label |
| 4 | `cup-design-teams` ✅ **landed** | Count + colours + **names + badges** in one place (16-char cap, counter from 12); colours **lock once taken**; badge auto-derives + **collisions warn, not block** | new `_StepTeams` replaces `_Step2CupDesign`; swatches with locking replace `_CupTeamColourRow` (deleted); per-team `TextEditingController`s (fixed 4-max) + `_teamBadgeOwned`; persists real `name` + `short_code` (badge, backend already supports it) so the draft never renames. Secondary-game toggle removed (moves to `cup-side-game`). DB-verified: Bandits/B, Blues/B, Team 3/3 |
| 5 | `cup-games-by-round` | Format + points **per segment, per round**; **remove the group-count field** (derive it) | `_RoundGameSlots`: delete the Groups stepper — header L2412–15, control L2435–69, `_setGroupCount` L2359 |
| 6 | `cup-side-game` ✅ **landed** | Field-wide games only (Irish Rumble, Pink Ball; None default); **struck when exclusive** (Triple Cup); Skins/Nassau/rabbit relocation note | new `_StepKind.sideGame` conditionally in the cup `_stepFlow` (absent when `_cupFormatExclusive` = Triple Cup — the flow just drops it, count stays honest); `_StepSideGame` widget; side game persisted into each round's `active_games`. DB-verified: `['singles_18','irish_rumble']`. Follow-up: struck **card** isn't shown (step is simply omitted); Irish Rumble's own hole setup is a later sub-screen |
| 7 | `cup-review` ✅ **landed** | Names what remains; **no empty sections** — the "0 players" line becomes an actionable amber todo; button **"Save & draft teams"** | new `_StepCupReview` (cup branch of the review case; non-cup keeps `_Step5Review`): cup card (name + game + handicap + team pills w/ badge+colour), rounds card (course/date/game chip), amber "No players added yet" todo (warns), scoring card, "What happens after saving" 1-2-3, ready line. `_BottomBar` cup label → "Save & draft teams". Follow-up: post-save still shows the "Tournament Created" launchpad — fully absorbing it (auto-nav to draft) is deferred. Also fixed the teams "Badge" label truncating to "Bad…" (now a BADGE caption) |

---

## Phase 2 — group builder + draft (September-critical, highest leverage)

All four tournament families walk the group builder — build it generic. A captain building four
groups currently walks twelve screens to do one job.

| Screen (after/) | Becomes | Lands at |
|---|---|---|
| `ryder-cup-draft` | Both rosters visible, then a single **Lock disabled until every side is legal**; team colours from **hex**, not a fixed name→Color switch | `ryder_cup_draft_screen.dart` — `_DraftBoard` L407; Lock button always-on today L452–461; `_lockDraft` L237; `_teamColor` switch L574 |
| `draft-add-players` ✅ **landed (core)** | **Header names the side** being filled (colour-dot badge + "Add to Reds"); fill count "1 of 4 on this side · pick 3 more"; **selection caps at the open slots** ("Reds is full — deselect to swap", overflow rows disabled); already-drafted golfers shown **locked with "On <side>"** + team dot | `_PlayerPickerDialog` reworked to take `teamName`/`teamColour`/`sideSize`/`currentCount`/`taken`; `_addPlayers` builds the taken-on-other-sides list; `_teamColor` promoted to a top-level fn (shared by cards + picker). Side-size stepper + derived group line already live on the **board** (B3), so they're not duplicated in the dialog. **Verified on device:** "Add to Reds", 1-of-4 count, cap at 3 with disabled overflow, "Already drafted (1) · On Blues" locked, Add 3 → Reds 4/4. **Deferred:** in-picker side-switcher + switch-confirm staging (the board's per-team Add buttons already choose the side); Unassigned/All filter tabs (search already filters); inline "create a golfer not in My Golfers" |
| `group-builder` ✅ **landed (core)** | **5 screens → 1 card**, one per group: golfers **with index**, inline **tees + "Set all"**, **tee time = previous group + interval** (±5 steppers, not a clock dial), group number shown; **`triple_cup` now renders "Triple Cup"** | `_BuildStep` collapsed `players`+`tees`+`teeTime` → one `group` step; new `_GroupBuilder` widget replaces `_PlayerPicker`/`_TeePicker`/`_TeeTimePicker` (all deleted). Golfers section (picked golfers w/ index + inline `TeePicker` + remove + "Set all tees") over a team-grouped pool that **dims a full side to "Team full"** (`_teamCap`=2); tee-time card defaults to previous+`_kTeeInterval` (10 min) with ±5, carried group→group (`_defaultTeeTimeForNewGroup`); sex-matched tee prefill on add. `_gameLabel` maps `triple_cup`. **Verified on device:** built 2 groups (2v2), tee times 08:05 → 08:15 carried, Start Round persisted both foursomes. **Deferred:** Shotgun toggle + starting-hole; per-course interval memory (needs a Course field); showing already-assigned golfers dimmed with their group name (currently just excluded from the pool) |
| `round-groups` ✅ **landed** | Composition + tees + tee time per row; **unassigned golfers by name** with an Assign link; header assigned/not-in-a-group counts | `_ReviewPage` rebuilt: each group card shows a **composition pill** (`_composition` → "2 v 2" / "1 v 2"), players **grouped by side with team badges**, a **tee summary** (`_teeSummary` → "All White tees" / "White · 1 on Gold" / "Tees not set"), and an editable friendly tee time; the tally line gained assigned/unassigned counts. New **"Not in a group (N)"** section lists each golfer by name (team · index) with an **Assign** link → `_assignGolfer(id)` opens the builder on a fresh group with that golfer seated + tee time carried. **Verified on device** incl. the Assign round-trip. **Note:** kept Start Round enabled at ≥1 group rather than hard-blocking on sit-outs (the builder already prevents illegal groups, and deliberate rests are legal — the mock itself flags this as open); the unassigned section is the actionable surface instead. Follow-up: tap a group row to re-open it in the builder for edits |

**Retired:** shipped `24` set-matches, `25` tee selection, `26` tee time, the standalone Set-Tees
screen (all → group builder), and `03` "Set up cup round" (its two questions answered in Phase 1).

---

## Bug bundle (several are quick, independent wins)

These are called out in the design notes and verified in code. Some can land ahead of the
larger refactors.

> **Status — all resolved.** `triple_cup` label (group-builder), Teams "Next" gate (`cupDesign`
> returns true), net double-bogey cap struck (cup-handicap), Lock-at-zero (B3), add-players header
> names the side (draft-add-players), golfer index (group-builder/pickers), duplicate team colours
> (`_colourLocked` in the Teams step), and **team colours unified to one hex palette** —
> `utils/cup_colors.dart` `cupTeamColor()` / `kCupTeamColours` is now the single source; the draft
> board's old `_teamColor` name→`Colors.*` switch and the wizard's private list both point at it,
> and the round-groups badges use it too, so a side's colour is the exact picked swatch everywhere.
> **Start Round blocker** is addressed by the round-groups Assign section (kept enabled at ≥1 group
> rather than hard-blocking sit-outs — see that row). **Deferred, not a quick win:** "tee menu
> covers its own row" is standard Material `DropdownButton` overlay behaviour; fixing it means
> converting the shared `TeePicker` to a bottom sheet (broad blast radius) — left for later.

- **`triple_cup` renders raw** — no entry in `_kCupGames` (`cup_round_setup_screen.dart:33`), so
  `_gameLabel('triple_cup')` returns the literal string; surfaces in the picker header (L987) and
  review title (L1475). Map to a display label.
- **Teams "Next" disabled despite default-2 highlight** — `_canAdvance` case 2 gates cup on the
  cup-name field (`new_round_wizard.dart:381`); with the name moving to event-details, Teams must
  not inherit a name-based gate.
- **Net double-bogey cap live for match play** — `_netMaxDoubleBogey` defaults `true` (L132), card
  shown for cups (L1527–37), value sent into every round (L519/544). Strike it.
- **Lock Draft enabled at zero players** — button renders whenever `!isLocked`
  (`ryder_cup_draft_screen.dart:452–461`) with no roster check.
- **Add-players header never names the side** — const `Text('Add players')` (L642); `team` is
  known at the launcher (L145) but never passed in.
- **Tee menu covers its own row** and **no golfer index on the pick screen** —
  `CheckboxListTile(title: Text(p.name))` shows name only (`cup_round_setup_screen.dart:1055–59`).
- **Start Round shows no blocker** — `_allPlayersAssigned` true on one foursome (L187).
- **Duplicate team colours allowed** — nothing enforces uniqueness (`_Step2CupDesign`).

---

## Phase 3 — play surfaces (can land after September)

Corrected file ownership (the handoff's guesses were off):

| Screen (after/) | Owner file | Becomes |
|---|---|---|
| `cup-hub` | `tournament_list_screen.dart` — `_TournamentCard` (~L594–770), `_openCupTab` L146–169 | Live score on the tournament card; **one primary action** (adapts: Enter Scores / Set Up Round N / View Result); six flat rows → one action + a grouped round-setup disclosure; merge the two trophy rows; Delete → ⋮ menu |
| `cup-round-hub` | `round_screen.dart` — `_FoursomeCard` L1561–2013, `_RoundInfoCard` L454–497 | Team **chips** replace tinted names (L1796–1813); aligned Tee/CH columns; **role-scoped entry** (player: own group + View card on others; TD: all); live tally on the header |
| `cup-leaderboard` | `leaderboard_screen.dart` — `_initTabs` L88–178, cup views ~L3633–3990 / ~L6015 | **Competition selector split from a fixed 4-view control** (Live/Overview/Details/Mine); segment results as labeled cells (Final / AS / dashed), not a comma run; points bar |
| `leaderboard-group-bets` | new tab in `leaderboard_screen.dart` `_initTabs` | Skins / Nassau / rabbit **settled from gross already entered**, grouped by foursome — a tab at group scope, **not a second scoring flow** |

**Two things to know:**

- The **leaderboard rebuild is coupled to Spine A/B landing first** — its tabs are derived from
  the runtime cup-type inference (`_initTabs` L94/112/144/151). Stable only once type is a stored
  fact.
- **cup-round-hub carries the one real behaviour gap** worth pulling forward: **Complete Round is
  ungated** — any in-progress viewer can close a round; it should be TD-only
  (`round_screen.dart` bottom bar L129–148). If any Phase-3 slice moves up, this one.

---

## Do NOT implement (per handoff)

- **Pairings** (two-man draft equivalent) — named by the wizard, no screen drawn. Same shape as
  the draft board, one side per pair. Do not invent it.
- **Group-bet attach mechanism** — `leaderboard-group-bets` specifies **settlement only**. How a
  bet attaches to a foursome from the group builder is undesigned. Do not implement the attach
  path from this handoff.

---

## Open product questions (settle before/while building)

1. ~~**One name or two?**~~ **Resolved: one name.** `_cupNameCtrl` removed; the cup persists
   under the single tournament `_nameCtrl` (done in Spine A).
2. **TD editing another group's card — attributed or silent?** Flagged in the round-hub notes;
   unresolved. "A card that changed after the group signed it is the kind of thing people argue
   about."
3. **Non-TD players — do they see the round-setup disclosure at all**, or a read-only summary?
   (cup-hub)

---

## Recommended sequencing

1. **Spine A** (wizard step-list) and **Spine B** (group-count derivation) — independent, in
   parallel. They unblock everything.
2. Knock out the **standalone bugs** opportunistically alongside.
3. **Phase 1** screens 1 → 7 in order.
4. **Phase 2** — draft (side size + Lock gate) → group builder → round-groups.
5. **Phase 3** waits, except possibly the Complete-Round gating.

---

## Design tokens (from `mobile/lib/theme/halved_brand.dart`)

- **Brand** — deepPine `#0B1F1A` · pine `#0F6E56` (structure, selected) · mint `#1D9E75` ·
  brightMint `#3BD89A` (CTA / live / "the hole", one per screen) · surface `#EEF3EE` ·
  card `#FFFFFF` · cardBorder `#D3DED6` · muted `#5C6B62` · cream `#F3F1EA` · ink `#06120E`
- **Semantic** — win `#3BD89A` · owe `#F0916E` · warning `#B24225` · disabledFill `#D3DAD5` ·
  disabledText `#93A099`
- **Team / game** — team1 `#1976D2` · team2 `#EF6C00` (colour-blind-safe). Green/red/grey mean
  win/loss/neutral and never identify a team.
- **Type** — headings Schibsted Grotesk, body/labels Spline Sans (both via `google_fonts`).
  Money and scores use tabular figures.
- **Radii** — chip 12 · CTA 16 · card 18 · pill 999. **Spacing** — 4-pt grid. **Borders** —
  cards / selected controls 1.5px cardBorder. **Buttons** — primary 52, bright-mint CTA 54.
- Selected chips and segments are **pine, never mint**.
