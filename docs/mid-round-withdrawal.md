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
- **Skins:** per-hole expected set = real members not withdrawn before that hole;
  award among present scores. (A later hole with a single remaining player simply
  awards them that skin — acceptable; note it in code.)
- **Sixes:** completed segments stand. For the segment containing/after the WD,
  apply the TD's choice:
  - **Void** → set `SixesSegment.is_void`; 0 points, excluded.
  - **Partner-solo** → leave the segment active. Best-ball uses the lone ball
    automatically; high-low uses the lone net as both high and low for the short
    team.

---

## API

- `POST /api/foursomes/<id>/withdraw-player/`
  body `{player_id, after_hole, sixes_segment_action?: 'void'|'solo'}`.
  Sets `withdrew_after_hole`; for Sixes applies void/solo to the affected +
  remaining segments; recalculates; returns the refreshed round/summary.
  Auth via `foursome_for_scorer` (own-account or designated scorer).
- *(nice-to-have)* `POST .../reinstate-player/` — clears `withdrew_after_hole`
  and un-voids, to undo a mistaken WD.

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
