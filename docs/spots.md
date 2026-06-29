# Spots — design doc

**What it is:** a gambling **add-on** that layers on top of any main game. A
"spot" is a user-defined per-hole achievement the app can't detect — one-putt,
hit-the-flag, sandy par, barky (hit a tree and still made par), greenie, etc.
The group decides what counts; the scorer **tallies them by hand** during score
entry, exactly the way junk is entered today. **2–4 players** (any casual group
size).

Spots is the first **capture add-on** built on the general mechanism (junk is
the pre-existing one); **Snake** (a separate doc) will reuse the same
score-entry slot.

---

## Decisions (from the product discussion)

- **Always a separate payout.** Spots never feeds the main game's points/pool.
  "Additive" only coheres for homogeneous-unit games (Skins, 5-3-1) and is
  incoherent for Stableford / match play / Vegas — so we don't generalize it.
  A standalone pot settles identically under any primary, which is the whole
  value of a standalone add-on.
- **Spots excludes Skins (in any role — primary or side).** Skins already has
  its own per-hole extras (**junk**), which fold into the skins pool. Keeping
  the two apart removes any "junk vs spots" confusion. Junk stays Skins-only and
  unchanged (a friend plays it that way). Rule of thumb:
  - achievements should **boost the skins pot** → junk;
  - achievements as their **own pot**, on any non-Skins game → Spots.
  - The exclusion is symmetric and easily relaxed later (it's just a catalog
    flag). If "Skins + a separate pot" is ever wanted, the cleaner fix is a
    "junk pays its own pot" toggle *inside* Skins — not opening Spots to overlap.
- **Settlement = pay-around by default.** Each spot: everyone else pays the
  achiever one bet unit, scaling with group size (P1's spot in a foursome = +3
  to P1, −1 to each other; in a 2-player game = +1 / −1). A **pool** style is a
  secondary option (configurable).
- **2–4 players** (any casual group size), per-foursome game model (like Skins).
- **v1 captures a generic count** (like junk — "2 spots this hole for P3").
  **Named spot types** (Sandy / Barky / Greenie …) are a v2 enhancement.

---

## The one architectural change

The casual side-game model assumed side games are **pure leaderboard overlays
with no score-entry effect**. That holds for *overlay accumulators* (Skins,
Stableford, Low Net — they re-read gross scores). It was never true for **junk**,
which is a score-entry modifier. Spots and Snake are the same species:
**capture add-ons** that need a small per-hole manual input.

So we promote junk's mechanism to first-class:

- New `GameMeta` flag **`capturesInScoreEntry`** (true for `spots`, later
  `snake`).
- **Score-entry suppression carve-out.** Today a game's section renders only
  when it is the *primary* (`_GameStatusSection` gated on `primaryGame` in
  `score_entry_screen.dart`). New rule: **also** render an active game's
  **capture widget** when `capturesInScoreEntry` is set, even though it's not
  the primary. Everything else (leaderboard tabs, settlement) is unchanged. The
  primary still owns the score boxes; add-ons append a compact strip beneath
  them.

That's the entire structural delta — localized and reversible.

---

## Key code findings (reuse / de-risk)

- **Junk is the working template** for capture + storage + UI:
  - storage: `SkinsPlayerHoleResult.junk` (per-player, per-hole integer);
  - upsert: `SkinsJunkView` (`POST …/skins/junk/`, body `{hole_number,
    junk_entries:[{player_id, junk_count}]}`);
  - UI: the junk stepper in `score_entry_screen.dart` (+/- per player), gated by
    `allow_junk`.
  Spots = this pattern, extracted into its own per-foursome game with its own
  settlement.
- **Per-foursome game pattern:** follow the Points 5-3-1 template (CLAUDE.md
  says new games mirror it) — `games.models` row keyed to `Foursome`,
  `services/spots.py`, serializer, setup + result views, leaderboard block.
- **Pay-around / pool settlement** math already exists in spirit in the Skins /
  Nassau services to crib from.
- **Catalog classification** lives in `mobile/lib/game_catalog.dart`
  (`canBeSideGame`, `allowsSideGames`, `excludes`, `sideGamesFor`).

---

## Data model

`games.models.SpotsGame` (OneToOne → `Foursome`):
- `handicap_mode` — **N/A**; spots are gross achievements, no handicap. Omit.
- `bet_unit` — value of one spot (defaults to round `bet_unit`).
- `payout_style` — `pay_around` (default) | `pool`.
- `allow_negative` / future knobs — out of scope v1.
- (v2) `spot_types` — JSON list of named types, e.g. `["Sandy","Barky"]`.

`games.models.SpotsPlayerHoleResult` (mirror `SkinsPlayerHoleResult`):
- FK `game`, FK `player`, `hole_number`, `count` (PositiveSmallInteger).
- (v2) `type` or a per-type count map if named types land.

Migration under `games/`. No change to score storage — spots live entirely in
their own tables, read nothing from `HoleScore`.

---

## Settlement (`services/spots.py`)

- **pay-around:** for each spot, achiever collects `bet_unit` from every other
  active player. Player net = `bet_unit × (spots_i × (n−1) − Σ_{j≠i} spots_j)`.
  Zero-sum across the foursome. Honors mid-round withdrawal (only players active
  on that hole pay — reuse the withdrawal roster check, as Skins does).
- **pool:** total spots × bet_unit forms a pot, split proportional to spots won
  (degenerate but offered for parity with Skins).
- `spots_summary(foursome)` → per-player `{spots, payout}` + per-hole tallies,
  shaped like `skins_summary` so the leaderboard card + watch tab are easy.

---

## Catalog / classification (`game_catalog.dart`)

```
GameMeta(
  id: GameIds.spots,
  displayName: 'Spots',
  casual: true,
  minPlayers: 2,
  maxPlayers: 4,
  canBeSideGame: true,          // it's an add-on
  capturesInScoreEntry: true,   // NEW — renders a capture strip in score entry
  excludes: { GameIds.skins },  // symmetric; junk is the Skins way
)
```
- It is **never a primary** — always an add-on. `primaryGameOf` already prefers
  a non-side-eligible game; Spots being side-eligible keeps it out of the
  primary role. A Spots-only round is nonsensical (it's an add-on) — the picker
  should require a primary, which it already does.
- `sideGamesFor(primary, size, …)` offers Spots whenever the primary isn't Skins
  (the exclusion), at any casual size 2–4.

---

## API

- `GET/POST /api/foursomes/<id>/spots/setup/` — configure + start
  (`bet_unit`, `payout_style`).
- `POST /api/foursomes/<id>/spots/tally/` — upsert per-hole counts
  (`{hole_number, entries:[{player_id, count}]}`) — mirrors `SkinsJunkView`.
- `GET  /api/foursomes/<id>/spots/` — `spots_summary`.
- Auth via `foursome_for_scorer` (same as other per-foursome score writes, so a
  delegated scorer can tally).
- Leaderboard block spread under `spots` in `_build_leaderboard` /
  `TournamentLeaderboardView` (casual only for now).

---

## Mobile

- **Catalog entry** + `GameIds.spots` (above).
- **Capture strip in score entry:** a per-player spots stepper (the junk stepper,
  reused) rendered under the score boxes **whenever Spots is active**, via the
  new `capturesInScoreEntry` carve-out in `_GameStatusSection`. Saves through
  `client.tallySpots(...)`; refresh the summary after save like Stableford does.
- **Setup screen** `/spots-setup` → `SpotsSetupScreen`: bet unit + payout style
  (+ v2 named-type editor). Reached from the casual hub's side-game buttons
  (`_sideGamePerFoursomeTargets`, same as side Skins).
- **Leaderboard** `_SpotsGroupCard` (clone `_SkinsGroupCard` shape: per-player
  spots + money).
- Routing wired in `create_casual_round.dart` (side-game, so no entry route
  hijack), `round_screen.dart`, `main.dart`.

---

## Spot types (v2)

v1 ships a **generic count** (proves the wiring with the least surface). v2:
let the group **name spot types** in setup and tally per type, so the
leaderboard can break down "3 Sandies, 1 Barky." Storage extends
`SpotsPlayerHoleResult` to carry a type (or a per-type count map). No settlement
change — every spot is still one bet unit.

---

## Phasing

1. **Spots v1** — generic count, pay-around, exclude Skins, the
   `capturesInScoreEntry` carve-out end-to-end. This proves the architecture.
2. **Spots v2** — named spot types + leaderboard breakdown.
3. **Snake** — reuses the score-entry slot; new token-passing model +
   escalation settlement (separate doc).

Build Spots v1 first so the carve-out is small and proven before Snake's novel
settlement.

---

## Tests

- `scoring/tests/test_spots.py` — pay-around zero-sum (2–4 players), pool split,
  multi-spot hole, withdrawal roster (inactive players don't pay), bet-unit math.
- `api/test_spots.py` — setup, tally upsert (idempotent), summary shape, scorer
  auth, **Skins-exclusion** (can't add Spots alongside Skins).
- Mobile: the capture strip renders for a non-primary Spots add-on (the carve-out
  regression — guards the score-entry assumption change).

---

## Related — Snake (future, shares the slot)

Snake tracks the **owner of the snake** (last player to 3-putt). The app can't
detect putts, so the scorer marks the holder transition per hole (carry forward,
or tap the player who took it). Final holder (hole 18) pays; cost **escalates**
per reissue (config). Token-passing model mirrors **Pink Ball**
(`PinkBallScreen` / `pink_ball`). Also a separate payout — same consistent rule
as Spots: capture add-ons settle on their own.
