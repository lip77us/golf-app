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
- `09` Championship tab · `10` Overview · `11` Details · `12` My Foursome

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
