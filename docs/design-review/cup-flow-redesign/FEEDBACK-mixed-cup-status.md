# Mixed cup (Phase 6) — engineering build status

**Engineering → Design.** Where the Mixed-cup implementation stands against the
`HANDOFF.md` Phase 6 spec, so design knows what's live vs. still drawn-only.

## Built and merged to `main`

- **Stage 1 — wizard step 1.** The cup branch is **Mixed cup** (default) vs
  **Triple Cup** (the exclusive preset). Singles/Fourball dropped as
  tournament-level formats; the derived step list + honest step counter drive
  off the choice. → `cup-wizard-step1.html`
- **Stage 2 — Games & points by round (mixed).** Count-is-the-pick (stepper for
  foursome/twosome games, On/Off for a one-match game), per-match/segment
  pricing, a per-side roster meter, and real round / cup / to-win totals derived
  from counts × price × multiplier. Persists through the existing
  `cup_group_counts` path so `total_possible` matches the drawn total.
  → `cup-games-by-round-mixed.html`

**A mixed cup of the scoreable games is functional end-to-end today** — create →
set up (via the existing per-foursome setup, which already works game-first for a
multi-game round) → play. The engine was already per-foursome and game-agnostic,
so no new scoring model was needed.

## Built as drawn, but scaffold ahead of scoring

Per the product call to build the mock as drawn:

- **One-ball formats — Fourball(as cup), Two-man Chapman, Two-man scramble,
  Scramble** — drawn and priced, tagged **SOON**, and excluded from persistence.
  The engine can't score a single card for two/four golfers yet (the handoff's
  own "one-ball formats need something the app does not have").
- **Singles counted in twosomes** as drawn; the engine prices per foursome (two
  singles each), so an **odd twosome** only half-reconciles until the backend
  gains that shape (handoff open item).
- **Roster-meter target** has no pre-draft source (the draft is later), so the TD
  sets "golfers per side" on the screen (default 16).

## Not built yet

- **Stage 3 — the worklist group-builder** (`group-builder-mixed.html`) and the
  **games-by-group** view (`round-game-assignment.html`). The existing
  per-foursome setup covers the function; the drawn worklist (game-first
  slot-filling, group numbers by tee time on save, Rumble = one row → two groups)
  is a UX reframe of a screen **shared with Triple Cup** and needs the Stage-2
  counts read back at setup time — a focused follow-up.

## Still open (design, from the handoff)

Half-points rule · per-game handicap allowance · point-unit fixed-vs-free ·
odd-twosome offer · whether the app proposes an assignment on games-by-group.
