# Mixed cup — reworked during live testing (Aug 2026)

**Engineering → Design.** A live-testing pass on a **two-game mixed cup**
(Four Ball Nassau + Singles Nassau, strokes-off) drove a round of changes across
the cup **wizard**, **round setup**, **scoring**, and the **leaderboard /
score-entry grids**. Everything below is **built, verified on device, and merged
to `main`** — so this is a *confirm-or-redraw* list, not a build request. Each
item says what it **was**, what it is **now**, and the **call** we need.

> Companions: `FEEDBACK-testing-rework.md` (cup leaderboard, Tilden pass) and
> `FEEDBACK-mixed-cup-status.md` (Phase 6 build status).

---

## Setup / wizard

### 1 · No "Tournament side game" step in cup play
- **Was:** the cup wizard included a field-wide side-game step (Irish Rumble /
  Pink Ball), struck only for Triple Cup.
- **Now:** the step is **gone from cup play entirely** — field-wide side games
  belong to individual tournaments. A cup's point-bearing games (including Irish
  Rumble) are set on the games-by-round plan.
- **Call:** confirm side games are individual-tournament-only, not a cup concept.

### 2 · Round Format preset not re-offered at setup
- **Was:** round-1 setup showed the "Round Format" toggle (Custom vs **Triple
  Cup**) even for a mixed cup that had already chosen its formats in the wizard —
  picking Triple Cup there silently overrode the whole plan.
- **Now:** the toggle is **suppressed once a mixed plan exists**; setup goes
  straight to the game picker (filtered to what's left to build).
- **Call:** confirm — a mixed cup should never be able to re-pick Triple Cup at
  setup.

### 3 · Irish Rumble variant picker at group setup
- **Now:** building an Irish Rumble group offers the **full variant picker**
  (Classic / Arizona Shuffle / Shuffle-by-par / Custom per-hole) + a live segment
  preview — the same control the standalone game uses (extracted to a shared
  widget). The choice drives the round-level `IrishRumbleConfig` instead of a
  hardcoded 1/2/3/4 escalation.
- **Call:** confirm group-setup is the right place for the balls variant (it's
  round-level, chosen once).

### 4 · Setup back-loop fixed (bug)
- **Was:** on the review step, **Back** ran "add another group" (a forward
  action), bouncing group ↔ review with no way to leave the screen.
- **Now:** Back on review exits the setup flow. Not a design item — flagging so
  the mocks don't reintroduce it.

---

## Scoring

### 5 · Strokes-off anchors on the competition unit
- **Was:** the Stroke Play "Strokes Off" view anchored every player on the whole
  **field** low.
- **Now:** it anchors on the **unit each golfer actually competes in** — the
  **foursome** low for team games, and the **1-v-1 pairing** low for singles
  (the low player in the match plays to 0). So the Stroke Play tab shows the same
  strokes a golfer gets in their match. Single-foursome casual rounds unchanged.
- **Call:** confirm this "anchor = your competition" rule; it's the canonical
  strokes-off reading and matches the match games, but it does mean two players
  in one singles foursome can have different anchors.

---

## Leaderboard

### 6 · One "Stroke Play" tab, not two
- **Was:** a cup showed a blank/redundant **Stroke Play** championship tab *and*
  the per-round scores tab (also labeled "Stroke Play").
- **Now:** the championship tab is suppressed on cup rounds — the cup **is** the
  championship; only the per-round scores remain.

### 7 · Full names, and no redundant roster row
- **Now:** the cup board's Four Ball card, the **Nassau** tab, and the **Singles
  Nassau** tab name each side **in full** (e.g. "Al Bronson vs Alex Brown" — this
  also disambiguates shared initials like "AB vs AB"). The Singles card's
  "who's-in-the-group" roster header was dropped as redundant with the per-match
  rows.
- **Call:** confirm full-names-in-header for the match cards.

### 8 · Per-hole "Round Progress" grid on Nassau & Singles tabs
- **Was:** the Nassau tab was just the F9/B9/All card ("no additional info"); the
  Singles tab likewise.
- **Now:** each match card is followed by the **per-hole grid** (Hole · Par ·
  Index · a divider · per-player rows) — the same shape score entry and sixes
  casual use.
- **Call:** confirm the leaderboard should carry the full scorecard grid, not
  just the match result.

### 9 · Forward (prospective) stroke dots
- **Was:** stroke dots only rendered on **played** holes (strokes derived from
  gross − net), so with few holes entered you saw almost nothing.
- **Now:** dots show the **full stroke plan up front** — allocated by stroke
  index across every hole a stroke falls, played or not (Nassau and Singles).
- **Call:** confirm we want the prospective plan visible before play (matches
  score entry / sixes).

### 10 · Stroke dots are neutral green everywhere
- **Was:** leaderboard stroke dots were red (clashed on team-colored rows).
- **Now:** **green** (`colorScheme.primary`) across score entry, the shared
  scorecard grid (Nassau / Sixes / Skins / Multi-Skins), the singles strip, and
  Wolf — matching the score-entry convention. Team colors and "won-by" markers
  stay as-is.

### 11 · Singles rows read "AB (N)"
- **Now:** the singles progress rows label each player by **abbreviation +
  strokes issued** in parens (e.g. "AY (12)"), with full names still in the
  header. Mirrors the Nassau grid's "(strokes-in-play)" convention.

---

## Still design's call (from the handoff — not yet built)

- **Half-points rule** · **per-game handicap allowance** · **point-unit
  fixed-vs-free** · **odd-twosome offer** (a twosome that can't be evenly paired).
- **Stage 3 "games-by-group" reframe** (`round-game-assignment.html`): a
  game-first, slot-filling build where **Irish Rumble is one row that produces
  two groups** (blue foursome vs red foursome). The current per-foursome setup
  covers the function; this is a nicer-flow rework of a screen **shared with
  Triple Cup**, and it needs the Stage-2 counts read back at setup time. We'd
  like design's steer before building it.

## Known small gap (engineering, low value)
- The **score-entry** *singles* progress card shows dots on **played** holes
  only; the leaderboard now shows the prospective plan on both. Easy to close if
  it matters — not blocking.
