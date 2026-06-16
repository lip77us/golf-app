# Wager wizard — kickoff brief

**Problem that prompted this:** the app has many points/score games (Nassau with
presses, Skins, Wolf, Stroke, Stableford, Points 5-3-1, and Las Vegas coming).
Each can be paid off several different ways, and the **economics diverge wildly**
between methods. With a per-point rate especially, *the amount actually at risk
is unknown up front* and swings dramatically based on how points accumulate and
which settlement formula is in play. We want a **simple setup wizard** that makes
the money legible before the round starts and collects the wager in plain
English.

The discussion converged on a model where every decision falls out of **two
principles**:

1. **Table-wide (per-side) caps keep the match zero-sum** — which is the only
   reason a proportional ("pro-rata") settlement is even well-defined.
2. **A cap is required exactly when the game can escalate, and escalation must
   halt exactly when the cap is hit** — the same rule seen at setup time and at
   play time.

---

## The unifying model: points → money via two axes

Every game produces **points or a score per side** (a *side* = one player in an
individual game, a team in a team game). The wager is just a rule for turning
those into dollars. Two independent axes describe everything we listed:

**Axis 1 — Funding (where the money comes from):**
- **Pool** — every side antes a fixed entry. *Risk is bounded by the entry,
  known up front. The entry **is** the cap.*
- **Per-point** — `$rate` flows per point of difference. *Risk scales with the
  game; unbounded unless capped.*

**Axis 2 — Settlement (how the money flows):**

| Funding | **Standard (default)** | Advanced (behind "Change how it's settled") |
|---|---|---|
| **Pool** | Proportional split of the pool | — (nothing else is sensible) |
| **Per-point** | **Settle vs the field average** | Pay the winner the difference · Pay everyone above you |

The defaults are chosen so **most setups answer one question**: pick Pool and
there's no second question at all; pick Per-point and the standard (vs-average)
is pre-selected.

### Why "vs field average" is the standard — it's Points 5-3-1, generalized

The vs-average settlement is **not new**. It is exactly the existing **Points
5-3-1** economics. 5-3-1 settles (`services/points_531.py`, `points_531_summary`):

```python
money = (pts - par_per_hole * hp) * bet_unit   # par_per_hole = 3 = 9 pts / 3 players
```

`pts − 3·holes_played` is `(your points − field average) × rate`. 5-3-1 just
**hardcodes** the average as a constant `3/hole` because it always distributes
exactly 9 points/hole among 3 players.

Generalization for games whose field can award a *variable* total (Stableford
with a custom table, Wolf, Vegas): compute the baseline dynamically,
`baseline = total_points_awarded / n_sides`, instead of hardcoding it. **5-3-1 is
the constant-baseline special case.** This settlement is symmetric and
self-bounding (winners' winnings always equal losers' losses, no side is on the
hook to one specific rival), which is why it's the default rather than the two
lopsided per-point formulas.

> **Reference implementations:** Points 5-3-1 already implements the vs-average
> settlement (constant baseline). **Stableford** is migrated onto the shared
> model (it today has only `payout_style` pool|per_point + `per_point_mode`
> all|first, i.e. the two *advanced* formulas — it gains vs-average + caps).

---

## The cap

### Required iff the game can escalate (bounded vs unbounded)

The discriminator is **not** pool-vs-per-point, it's **bounded vs unbounded**:

- **Pool** → the entry is the ceiling. **No cap field.**
- **Bounded per-point** (a fixed, small number of bets with *no possible
  escalation*) → the max is computable, so **don't ask — derive it and show it
  read-only**:
  - **Nassau, no press + not Claremont** → exactly 3 bets → `max = bet × 3`
    (front / back / total).
  - **Sixes** → its fixed 3–5 segment bets, no escalation → `max = bet × 5`.
  - Display: *"Max liability: $30 (read-only — this format can't escalate)."*
- **Unbounded per-point** (Nassau **with** press or Claremont; Points 5-3-1;
  Stableford-per-point; Wolf; Vegas; stroke-per-point) → no computable ceiling →
  **cap required.**

So the wizard's rule is one line: *if the configuration admits any escalation,
require a cap; otherwise compute and display the fixed max.* Toggling Nassau's
"presses on" or "Claremont on" flips it live from read-only-max to cap-required.

### Cap unit = the side; one table-wide value

One cap **value**, set table-wide, **applied per side** (player in an individual
game, **team** in a team game). Per-player caps were rejected and are *incoherent*,
not merely unsupported: if you're at risk for more you must be able to win more,
but you can't if other sides have smaller caps — differing caps break the
zero-sum balance and would require a house to cover the gap. Table-wide is the
*correct* model, not a simplification.

For team games the cap is evaluated against the **team's** aggregate liability —
a team can press until the **team** is maxed, regardless of how the loss splits
between partners.

### Cap on the whole match, never per pot/side-bet

The cap applies to the **whole match** (all pots + presses + Claremont combined),
not to each Nassau pot or each press individually. Presses + Claremont can
generate a lot of points, and the point of the cap is the *total* exposure.

### Shortfall when a side clips → winners reduced pro-rata

When a losing side's raw obligation exceeds the cap, it clips at the cap; the
collected pot shrinks, and **winning sides' receipts are reduced in proportion to
what they were owed.** Worked example:

> `$1/point`, four players, "pay everyone above you," Dave capped at $20.
> Raw: Dave owes $30, Sue owes $8 → $38 pot to winners Ann ($28) + Bob ($10).
> (Two recipients ⇒ a multi-winner formula; "pay the winner" pays only one.)
> Dave clips to $20 → $10 shortfall → collected pot = $28.
> Each winner gets `28/38` of raw → Ann $20.63, Bob $7.37.

This never requires chasing money that isn't there, and the only settlement line
shown is *"Dave hit his cap; winners reduced pro-rata."* It generalizes across
all settlement formulas because each reduces to "a set of debits and a set of
credits that must balance" — the cap shrinks debits, we rescale credits to match.

### The cap fixes the original problem

Once a cap is set, the scary worst-case number collapses to a **known value — it
*is* the cap.** The exposure preview becomes honest and simple:

> `$1/point`, vs average · **Cap $40** → *"Typical swing ~$12. Most you can lose:
> **$40**."*

The cap is what turns per-point from "unbounded and unknowable" into "a pool with
extra texture."

---

## Play to conclusion + the press exploit

- **The match always finishes**, even after the cap is reached. Pro-rata is *why*
  that still matters: the cap freezes the *size* of the pie, not who gets which
  slice — winners are never capped (only losses clip; winnings are bounded by the
  clipped pot), so as long as relative standings can move, real money shifts on
  every remaining hole.

- **Escalation must halt at the cap.** Once a side is at its max loss, a press is
  a **free option**: zero downside for them, pure liability for the other side.
  And in Nassau the **down** team is the one that presses — precisely the side
  accumulating losses toward the cap — so this is the *main* case, not an edge.
  Rule: **disable any escalation action — manual press, Claremont auto-press, and
  any future Wolf double / Vegas flip — for a side once that side's liability has
  reached the cap.** Same predicate as "require a cap" at setup, enforced live:
  - Manual press button → greyed, *"You're at the cap — pressing would be free."*
  - Auto-press (Claremont) → simply doesn't fire once the side is maxed.
  - Team games: evaluate against the **team's** liability.
  - UI honesty: a capped, down-and-out team genuinely can't fight back in the last
    holes — the *correct* economic answer, but show *"capped — no more presses"*
    so it doesn't read as a bug.

---

## Contracts to implement against

### `WagerConfig` (normalized, shared by every game)

```
WagerConfig {
  funding:      'pool' | 'per_point'
  settlement:   'proportional'        # pool
              | 'vs_average'          # per-point, STANDARD (Points 5-3-1 economics)
              | 'pay_winner'          # per-point, advanced
              | 'pay_above'           # per-point, advanced (existing per_point_mode='all')
  entry:        Decimal?              # pool only — the per-side ante (and its own cap)
  rate:         Decimal?              # per-point only — $/point
  cap:          Decimal?             # per-point only; REQUIRED when the game can escalate,
                                     #   null for bounded games (max is derived + read-only)
  cap_unit:    'side'                # always per-side; side = team in team games
  # excluded_player_ids / payouts (places) carry over from the existing pool games
}
```

Carry the **cap independently of settlement** — Nassau/Skins/Sixes use a cap (or
a derived max) without using the Axis-2 settlement menu at all.

This is a superset of the current Stableford fields (`payout_style`,
`per_point_rate`, `per_point_mode`, `entry_fee`, `payouts`,
`excluded_player_ids`): `funding ← payout_style`, `rate ← per_point_rate`,
`pay_above ← per_point_mode='all'`, `pay_winner ← per_point_mode='first'`. New:
`vs_average` and `cap`.

### `settle(points_by_side, config) -> payouts_by_side`

Pure function, side-keyed. A side = 1+ players; individual games are the
degenerate one-player-per-side case. Algorithm:

1. Compute raw zero-sum debits/credits per the `settlement` formula.
   - `vs_average`: `raw = (side_points - baseline) * rate`, where
     `baseline = total_points / n_sides` (constant `3·holes` for 5-3-1).
   - `proportional`: split the pool by `side_points / total_points`.
   - `pay_winner` / `pay_above`: existing per-point formulas.
2. **Clip** each losing side at `cap` (if set); sum the shortfall.
3. **Rescale** winning sides' credits so the table balances (winners reduced
   pro-rata by `collected / owed`).
4. For team games, split each side's result among its players (even split, or
   per existing team rules).

### `validForGame(gameType) -> { funding[], settlement[], escalates, derivedMax? }`

Trims the wizard per game so it never offers a nonsensical option (mirrors the
existing `casual:`/mutex flags in `game_catalog.dart`):

| Game | Funding offered | Settlement | Cap |
|---|---|---|---|
| Points 5-3-1 | pool, per-point | vs-average (std) + advanced | required (per-point) |
| Stableford | pool, per-point | vs-average (std) + advanced | required (per-point) |
| Wolf, Vegas, Stroke | pool, per-point | vs-average (std) + advanced | required (per-point) |
| **Nassau** | per-point (native pots) | *native pot settlement* (not Axis-2) | derived `bet×3` if no press & not Claremont; else **required** |
| **Skins** | pool (skin value, native) | *native* | n/a (per-hole pots) |
| **Sixes** | per-point (native) | *native* | derived `bet×5` (no escalation) |

Nassau/Skins/Sixes keep their **own** settlement; what the wizard contributes to
them is **dollar sizing + the cap (or derived read-only max)**, plus the live
**press gate** for Nassau.

---

## Wizard UX (3 steps, defaults collapse it to ~1 question)

1. **"How do you want to settle up?"** (Axis 1, plain English)
   - *Everyone puts in a set amount* (pool) — "Simple. Most you can lose is your
     buy-in."
   - *Pay per point* — "Stakes scale with the round. We'll show you and make you
     set a cap."
2. **"How does the money move?"** (Axis 2) — only for full-wizard games; default
   pre-selected (proportional for pool, vs-average for per-point); the two
   advanced per-point formulas behind a "Change how it's settled" disclosure,
   each with a one-line example. *Skipped entirely for Nassau/Skins/Sixes.*
3. **"Set the stakes."**
   - Pool → entry amount → *"Total pool $X · most you can lose $entry."*
   - Bounded per-point → derived **read-only** max liability.
   - Unbounded per-point → `$rate` **and a required cap**, with a live exposure
     preview (*"Typical swing ~$Y · most you can lose: $cap"*). Optionally allow
     anchoring on the cap and deriving an implied view of the rate.

---

## Phasing

- **Phase 1 — model + settlement core.** `WagerConfig`, the side-keyed
  `settle()` with clip+rescale, and `validForGame()`. Land it first on the two
  natural references: **Points 5-3-1** (already vs-average — wrap it in
  `settle()` + add a cap) and **Stableford** (migrate `payout_style`/
  `per_point_mode` onto `WagerConfig`, add `vs_average` + cap). Tests:
  vs-average zero-sum, pool proportional, clip+pro-rata shortfall, bounded-max
  derivation.

  > **DONE — settlement core + Points 5-3-1 backend.**
  > - `services/wager.py` — `WagerConfig` + `settle()` (all four formulas, cap
  >   clip + pro-rata rescale, penny-exact zero-sum). `scoring/tests/test_wager.py`
  >   (19 pure `SimpleTestCase` tests, no DB).
  > - **Points 5-3-1 wired on** (no special-casing — confirmed `total/n` ≡
  >   `3 × holes`, since 5-3-1 only scores holes all three played, so
  >   `holes_played` is uniform): `Points531Game.loss_cap` (migration
  >   `games/0039`), `setup_points_531(loss_cap=…)`, summary money via
  >   `settle(vs_average, cap)`, `money.loss_cap` exposed; setup serializer/view
  >   accept `loss_cap`. `scoring/tests/test_points531.py`. Full `scoring`+`api`
  >   suites green (85 + 85).
  > - **Default cap (UI affordance, not yet built): `36 × bet_unit`** for 5-3-1 —
  >   the theoretical max loss `(max_pts_per_hole − mean) × holes × rate =
  >   (5−3)×18`. Game-specific; differs for custom Stableford tables. `loss_cap`
  >   is nullable and a null cap is *equivalent* to `36×rate` for 5-3-1 (never
  >   binds), so the wizard pre-fills `36×rate` and lets the user lower it.
  > - **Nassau — Phase A DONE (backend + mobile): cap settlement + bounded max.**
  >   With only 2 sides every settlement model collapses to "loser pays winner
  >   the difference", so Nassau has NO settlement menu — the cap is just a
  >   symmetric clamp of the net total to ±cap (`_clamp_to_cap` in
  >   `services/nassau.py`). `NassauGame.loss_cap` (migration `games/0042`);
  >   summary `payouts` gains `loss_cap` + `total_capped`. Bounded base (no press,
  >   not Claremont) shows a **read-only max** (bet × 3, or × 1 overall-only) via
  >   `MaxLiabilityNote`; escalating (press/Claremont) shows a cap switch. Mobile
  >   setup + leaderboard (capped team net + "Cap: $X"). `scoring/tests/test_nassau.py`
  >   cap test. Full `api`+`scoring` green (177).
  >   **Phase B — press gate (non-aggressive, concluded-loss rule).** A side can't
  >   press once its *already-decided (concluded-bet) net loss* ≥ cap — further
  >   loss is clamped so the press is downside-free. Helper `_press_blocked_by_cap`
  >   keys off the down side of the available nine + the concluded net.
  >   **DONE: manual gate** — `can_press` in `nassau_summary` (greys the button;
  >   mobile already reads it) + hard reject in `add_manual_press`.
  >   `scoring/tests/test_nassau.py` (closes at cap / stays open below). Full
  >   `api`+`scoring` green (179).
  >   **DONE: auto-press suppression** — threaded concluded-*dollar* bookkeeping
  >   into `calculate_nassau` (`_concluded_net()` from DECIDED main+bottom bets +
  >   COMPLETED presses × bet/press unit; `_auto_press_blocked()` gates both the
  >   top and bottom/Claremont auto-press triggers). Suppressed presses aren't
  >   marked fired, so they re-open if a later concluded win drops the side back
  >   under the cap (concluded loss isn't monotonic). Tests: suppressed at cap /
  >   fires below cap. **Nassau is fully done.** Full `api`+`scoring` green (181).
  >   Also: the leaderboard surfaces the real uncapped position — capped headline
  >   `−$10` + `(down $25)` suffix — so a buried side still sees the hole.
  > - **Sixes + One-Round Triple Cup — DONE (mobile only), bounded native.**
  >   Both are match/segment games whose money can't escalate: Sixes moves
  >   ±bet_unit per segment (max loss = 3 × stake, lose all 3 segments); Triple
  >   Cup is one cup payout (max loss = 1 × stake). The settlement model and the
  >   cap don't apply — per the brief, bounded games show a **read-only max
  >   liability** instead. Sixes max = **5 × stake**: an early close-out
  >   immediately starts the next match, so 3 standard segments can spawn up to
  >   2 extra matches (5 total, each its own ±stake). Triple Cup = 1 × stake.
  >   Added `widgets/max_liability_note.dart` (reactive "Most you can lose: $X",
  >   recomputes from the live stake) to both setup screens. No
  >   backend/migration/tests (pure display). Reusable for the Nassau-no-press
  >   path next.
  > - **Wolf — DONE (backend + mobile), native + cap only.** Wolf's per-hole
  >   points already net to zero (they *are* the pot payout: lone win = +3 /
  >   −1 / −1 / −1), so Wolf is a **native-settlement** game like Skins/Nassau,
  >   NOT a positive-score game. The four settlement models would *change* its
  >   traditional economics (vs-average on `{3,0,0,0}` → +2.25/−0.75, not
  >   +3/−1), so Wolf gets **sizing + cap only**, no settlement menu. Wired
  >   money through `settle(vs_average, cap)` — behavior-preserving because the
  >   zero-sum baseline is 0 — adding the cap clip/rescale. `WolfGame.loss_cap`
  >   (migration `games/0041`), setup/serializer/view + summary expose it;
  >   mobile setup has a "Cap losses" switch (off by default) + leaderboard
  >   footer shows the cap. `scoring/tests/test_wolf.py` gains cap tests. Full
  >   `api`+`scoring` green (175). *(Decision: positive-points refactor to unlock
  >   all models for Wolf was considered and rejected — it'd abandon the
  >   traditional pot payout.)*
  > - **Stableford — DONE (backend + mobile).** Its existing `'all'`/`'first'`
  >   modes already matched `settle()`'s `pay_above`/`pay_winner`, so the per-point
  >   block was refactored to call `settle()` (behavior-preserving) and gained the
  >   **`average` mode (now the default)** + **`loss_cap`** (migration `games/0040`,
  >   `per_point_mode` choices now `average|all|first`). Pool stays place-based
  >   prizes (NOT `settle`'s proportional) — unchanged. Summary/setup view/serializer
  >   expose `loss_cap`; `api/test_stableford.py` gains vs-average-default + cap
  >   tests. Mobile: setup screen has a 3-way mode segment (vs Average / Above you /
  >   Just first) + an optional "Cap losses" switch (off by default — editable table
  >   means no clean 36× to pre-fill, unlike 5-3-1); leaderboard chips + watch page
  >   show the mode and cap. Full `api`+`scoring` green (172).
  > - **5-3-1 mobile — DONE.** `Points531Summary.lossCap` +
  >   `postPoints531Setup(lossCap:)`; setup screen has a "Cap losses" switch
  >   (off = uncapped; on pre-fills `36 × stake`, editable) with a worst-case
  >   explainer; the leaderboard `_Points531GroupCard` footer shows
  >   "Loss cap $X/player" when set. `flutter analyze` clean (no new errors).
  >   5-3-1 is now end-to-end — demoable in the app.
- **Phase 2 — the wizard widget.** Shared `WagerWizard` Flutter widget driven by
  `validForGame()`, embedded in each game's setup screen. Exposure preview +
  required-cap enforcement.
- **Phase 3 — escalation gate.** Wire the live press gate (Nassau manual +
  Claremont auto-press) to `side_liability >= cap`. Generalize the predicate so
  future Wolf/Vegas escalations inherit it.
- **Then** roll `WagerConfig` across Wolf, Vegas, Stroke, and the Nassau/Skins/
  Sixes sizing+cap path.

### Supersedes / relates to

- Supersedes the deferred note in memory `skins-payout-styles-deferred` (per-skin
  cost + pay-first/pay-above) — that becomes the Skins slice of this model.
- The mid-round-withdrawal **segmented pool** already settles per-side per
  segment; `settle()` should be compatible with (or reuse) that side-keyed shape.
