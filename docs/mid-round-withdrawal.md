# Mid-round withdrawal ("player can't continue") — kickoff brief

**Scenario that prompted this:** a golfer hurt his back on **hole 13 of a Sixes
round** and couldn't continue. The app requires a score for *every* player to
advance to the next hole and to complete the round, so there was no way to
proceed — the group cancelled the third Sixes match by hand.

We need a **withdrawal (WD)** flow: let the rest of the group keep scoring, let
the round complete, keep the injured player's earlier scores, and settle the
games correctly.

---

## Decisions (from the product discussion)

- **Sixes WD = per-WD choice.** At withdrawal time the TD picks, for the
  affected + remaining segment(s): **void** them, or have the **remaining
  partner play solo**.
- **First-pass scope:** universal unblocker **+ Sixes + Skins** settlement.
  Nassau / Points 5-3-1 / Match Play settlement deferred to a follow-up.
- **Timing:** this is a backend change (migration + calculators), so it ships
  with the next push **after Twilio clears** — not a same-day prod hotfix. The
  incident is already resolved, so that timing is fine.

---

## Two layers

1. **Universal unblocker (every game).** Mark a player "withdrew after hole N":
   remaining players keep scoring, the round can complete, and the WD player's
   stored scores (holes 1..N) are untouched.
2. **Per-game settlement (game-specific money/match).**

---

## Key code findings (these de-risk the build)

- **Advance gate** is `_allScored` in `mobile/lib/screens/score_entry_screen.dart`
  (~L827). It *already* excludes the dimmed alt-shot partner via
  `_isInactiveAltShotPlayer`. The WD exclusion is the same pattern — exclude any
  player whose `withdrew_after_hole < hole`.
- **WD is not "remove."** The pre-scoring `FoursomeRemovePlayerView`
  (`api/views.py` ~L2956) explicitly **refuses once any HoleScore exists** and
  calls mid-round removal "not in scope." WD is that deferred piece, but it
  *keeps* the player and their posted scores rather than deleting them.
- **Sixes best-ball:** `_best_net_for_team` (`services/sixes.py` ~L176) takes the
  `min` of *present* scores → **"partner plays solo" works with no calculator
  change** for classic best-ball (the lone ball is the team's ball).
- **Sixes high-low:** `_high_low_nets_for_team` (~L192) needs **both** partners'
  scores (returns `(None, None)` → the segment stops). So high-low can't do
  partner-solo without a rule. Cleanest: **void** the segment, OR use the lone
  remaining net as *both* high and low for the short team (one-line rule).
- **Skins:** `calculate_skins` (`services/skins.py` ~L205) **skips any hole where
  not all real players scored**. So post-WD it would blank holes 13–18 for
  everyone. **Fix:** per-hole "expected participants" = real members **not
  withdrawn before that hole**; award among present scores as today. Earlier
  fully-scored holes are unaffected; the WD player's skins freeze.

  > **IMPLEMENTED — richer than the note above.** After the product discussion
  > the Skins settlement became a **segmented pool** (see "Skins (segmented
  > pool)" below). The "expected participants" idea is the foundation, but the
  > money is split per segment by hole-fraction, not as one global pool.

---

## Data model

- `FoursomeMembership.withdrew_after_hole` — `SmallIntegerField(null=True)`.
  `null` = played all 18; `N` = completed holes 1..N, out for N+1..18.
  Migration: next `tournament/00XX`.
- `SixesSegment.is_void` — `BooleanField(default=False)`. A voided segment awards
  0 points and is excluded from totals + closeout. Partner-solo segments stay
  normal (the calculator handles the missing ball).

---

## Per-game semantics

- **Universal:** a WD player is dropped from the per-hole "everyone scored?"
  check and the round-completion check for holes `> withdrew_after_hole`. Stored
  scores untouched.
- **Skins (segmented pool) — IMPLEMENTED:** a WD partitions the round into
  constant-roster **segments**. Each player antes one `bet_unit` spread evenly
  over 18 holes (`bet_unit/18` per hole) and **a withdrawn player stops
  contributing the moment they leave**, so a segment's pot is funded only by
  the players still in it: `seg_pot = holes_in_segment × roster_size ×
  bet_unit / 18`. It's split *within* the segment proportional to skins won
  there (regular + junk) — today's `pool × skins/total` math, scoped. A round
  with no WD is one segment over all 18 holes with the full roster → unchanged.
  - **Killed hole (a question at WD time):** if the group abandoned the hole in
    progress when the player went down, that hole is voided for everyone and its
    `1/18` of the pool **evaporates**. The withdraw flow asks this (`kill_next_hole`).
  - **Carries die at every boundary** (killed hole / roster change).
  - **Lone survivor → game over:** once fewer than two players remain the pool
    is reduced by the unplayed fraction (those holes evaporate); the completed
    segment(s) still settle.
  - **Worked example** (4 players, $10 ante, WD completes hole 9, hole 10 killed):
    holes 1–9 = `9 × 4 × $10/18 = $20` among 4; hole 10 evaporates; holes 11–18
    = `8 × 3 × $10/18 = $13.33` among the 3 survivors (the withdrawn player no
    longer contributes). A single skin on a 3-player hole is worth less than on
    a 4-player hole — exactly the fix from testing.
  - **Future per-skin styles** (pay-the-winner / pay-those-above): no
    fractioning — settle the completed segment as a closed game, void the killed
    hole, fresh-calc the survivor segment. Documented in `_skins_withdrawal_plan`.
- **Sixes:** completed segments stand. For the segment containing/after the WD,
  apply the TD's choice:
  - **Void** → set `SixesSegment.is_void`; 0 points, excluded.
  - **Partner-solo** → leave the segment active. Best-ball uses the lone ball
    automatically; high-low uses the lone net as both high and low for the short
    team.

---

## API

- `POST /api/foursomes/<id>/withdraw-player/` — **IMPLEMENTED**
  body `{player_id, after_hole, kill_next_hole?, sixes_segment_action?: 'void'|'solo'}`.
  Sets `withdrew_after_hole` (+ `withdrew_killed_next_hole`); for Sixes applies
  void/solo to the affected + remaining segments; recalculates; returns the
  refreshed summary. Auth via `foursome_for_scorer` (own-account or scorer).
- `POST .../reinstate-player/` — **IMPLEMENTED** — clears the WD fields and
  un-voids Sixes segments, to undo a mistaken WD.

---

## Mobile (`score_entry_screen.dart` + `api/`)

- Add `withdrewAfterHole` to `Membership` (`api/models.dart`).
- Per-player **"Mark as withdrawn (can't continue)"** in the TD/scorer menu
  (long-press the player row, or an overflow on the row). Confirm dialog: prior
  scores stand, they're out for the rest. For **Sixes**, follow with a
  void-vs-solo prompt for the affected/remaining segments.
- `_allScored` / `_allHolesScored` / `_firstMissingHole`: also exclude players
  with `withdrewAfterHole != null && withdrewAfterHole < hole`.
- Render: WD players show a **WD** badge and no score buttons for holes
  `> withdrewAfterHole`; earlier holes stay visible/editable.
- Client: `withdrawPlayer(foursomeId, playerId, afterHole, {sixesAction})`.

---

## Phasing

- **Phase 1** (foundation, all games): field + migration + universal
  score-entry/completion unblock + WD badge + the withdraw API. Includes the
  small **Skins** per-hole-expected fix.
- **Phase 2** (this same pass, per scope): **Sixes** void/solo — `is_void`,
  the high-low lone-net rule, and the void/solo prompt.
- **Deferred:** Nassau / Points 5-3-1 / Match Play settlement; reinstate.

---

## Tests

- `services/sixes`: WD mid-segment → **void** (0 pts, excluded) and **solo**
  (best-ball lone ball; high-low lone net both ends). Completed segments
  unchanged.
- `services/skins`: WD after hole N → holes 1..N unchanged; N+1..18 contested
  among the remaining players; WD player's total skins frozen.
- Round completion allowed with a WD player missing later-hole scores.
