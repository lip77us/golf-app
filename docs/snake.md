# Snake — design doc

**What it is:** a gambling **add-on** that tracks the **owner of the snake** —
the last player to **three-putt**. The snake passes to whoever three-putts next
and **escalates** in value each time it's reissued. Whoever is holding it at the
end **pays**. The app can't detect putts (it only stores gross score), so the
scorer **tells it who took the snake**, per hole — a manual capture, like Spots
and junk. **2–4 players** (any casual group size).

Snake is the second **capture add-on**. It reuses the score-entry capture slot
introduced for **Spots** (see `docs/spots.md`) and the token-passing model of
**Pink Ball** (`PinkBallScreen` / `pink_ball`).

---

## Decisions (from the product discussion)

- **Always a separate payout.** Same rule as Spots — capture add-ons settle on
  their own, never folded into the main game.
- **2–4 players** (any casual group size), per-foursome game model.
- **Captured, not detected.** No putt data exists, so the scorer marks the
  **holder transition** each hole. We only need *who holds it leaving the hole*,
  which sidesteps "the app can't know putt counts or intra-hole order" entirely.
  If two players three-putt the same hole, the scorer taps whoever got it last —
  one tap, unambiguous.
- **Escalation** (from the original suggestion note):
  - cost mode: **locked** (flat `bet_unit`) | **step** (+`bet_unit` each
    reissue) | **double** (×2 each reissue);
  - a **reissue** = any hole where a three-putt occurs (snake moves to a new
    holder, OR the current holder three-putts again);
  - optional **bump-on-repeat**: if the current holder three-putts again, it
    still escalates (on by default — matches "if you have the snake and three
    putt, that can increase the snake cost").
- **Segments** ("can be played over 6 or 9 holes"): `segment` = **full 18**
  (default) | **per-9** | **per-6**. At each segment boundary the holder pays,
  the snake **resets** (unowned, cost back to base) for the next segment. v1 may
  ship full-18 only and add per-9/per-6 in v2 — flagged below.
- **Settlement = pay-around.** The final holder of each segment pays the
  segment's running cost to **every other player** (one payer, n−1 receivers).
  A player who never held it simply collects.

---

## Reuses (de-risk)

- **The `capturesInScoreEntry` slot** built for Spots — Snake adds its capture
  control to the same per-hole strip beneath the score boxes. No new
  architectural change; this is why Spots is built first.
- **Pink Ball** is the token-passing precedent: a single marker that moves
  per hole by a manual assignment. Crib its per-hole assignment model + UI.
- **Per-foursome game pattern:** Points 5-3-1 template (per CLAUDE.md).
- **Pay-around math** + **withdrawal roster** handling from Skins / Spots.

---

## Data model

`games.models.SnakeGame` (OneToOne → `Foursome`):
- `bet_unit` — base value (defaults to round `bet_unit`).
- `cost_mode` — `locked` | `step` (default) | `double`.
- `bump_on_repeat` — bool (default true).
- `segment` — `full` (default) | `nines` | `sixes`.

`games.models.SnakeHoleResult`:
- FK `game`, `hole_number`.
- `holder` — FK `Player`, **nullable** (null = nobody has it yet / carried with
  no change is represented by repeating the prior holder, or store only the
  *transition* — see note).
- `three_putt` — bool (a reissue happened this hole). Drives escalation count.

Implementation note: store **only transition holes** (a row when a three-putt
occurs, naming the new holder) and derive the per-hole holder + cost by walking
forward. Simpler than a row per hole and matches how the scorer thinks ("mark it
when it moves"). Carry = no row.

Migration under `games/`. Reads nothing from `HoleScore`.

---

## Settlement (`services/snake.py`)

Walk holes in order, per segment:
- maintain `current_holder` and `reissues` (count of three-putt holes in the
  segment so far);
- `cost` = `locked → bet_unit`; `step → bet_unit × (1 + reissues)`;
  `double → bet_unit × 2^reissues` (cap sensibly);
- at the segment's last **played** hole, the `current_holder` pays `cost` to
  each other active player (pay-around, zero-sum within the segment).
- No holder in a segment (nobody three-putted) → no money that segment.
- Honors **mid-round withdrawal** (only players active at settlement pay/收;
  reuse the roster check, as Skins/Spots do). If the holder withdrew, the snake
  passes back to the previous holder at withdrawal (decision to confirm).

`snake_summary(foursome)` → per-player `{net, holding?}`, current holder + cost,
per-segment results, and a per-hole holder trail for the leaderboard/watch tab.

---

## Catalog / classification (`game_catalog.dart`)

```
GameMeta(
  id: GameIds.snake,
  displayName: 'Snake',
  casual: true,
  minPlayers: 2,
  maxPlayers: 4,
  canBeSideGame: true,          // it's an add-on, never a primary
  capturesInScoreEntry: true,   // renders its capture control in score entry
  // no Skins exclusion — Snake is orthogonal to junk (different event)
)
```
- Never a primary (always an add-on); `primaryGameOf` keeps it out of the
  primary role since it's side-eligible.
- Unlike Spots, **no Skins exclusion** — Snake tracks three-putts, junk tracks
  achievements; no conceptual overlap. Snake can ride alongside Skins, Nassau,
  Stableford, Spots, etc.

---

## API

- `GET/POST /api/foursomes/<id>/snake/setup/` — configure + start
  (`bet_unit`, `cost_mode`, `bump_on_repeat`, `segment`).
- `POST /api/foursomes/<id>/snake/holder/` — set the holder transition for a
  hole (`{hole_number, holder_player_id | null}`; null clears/carries).
- `GET  /api/foursomes/<id>/snake/` — `snake_summary`.
- Auth via `foursome_for_scorer`.
- Leaderboard block under `snake`.

---

## Mobile

- **Catalog entry** + `GameIds.snake`.
- **Capture control in score entry** (the `capturesInScoreEntry` slot): a single
  compact "Snake" row beneath the score boxes — shows the current holder and a
  "took it" affordance to tap the player who three-putted this hole (or
  "carry / nobody"). Saves via `client.setSnakeHolder(...)`; refresh summary
  after save.
- **Setup screen** `/snake-setup` → `SnakeSetupScreen`: bet unit, cost mode
  (locked/step/double), bump-on-repeat toggle, segment (full/nines/sixes).
  Reached from the casual hub's side-game buttons.
- **Leaderboard** `_SnakeGroupCard`: current holder + running cost, per-player
  net, segment results, hole-by-hole holder trail.
- Routing wired in `create_casual_round.dart` (side-game, no entry hijack),
  `round_screen.dart`, `main.dart`.

---

## Phasing

1. **Snake v1** — full-18 segment, step/locked/double escalation, pay-around,
   the capture control on the shared score-entry slot. (Depends on the Spots
   carve-out landing first.)
2. **Snake v2** — per-9 / per-6 segments (reset + settle at boundaries).

---

## Tests

- `scoring/tests/test_snake.py` — holder walk + carry; escalation per mode
  (locked / step / double); bump-on-repeat; pay-around zero-sum (2–4 players);
  no-three-putt segment pays nothing; withdrawal roster; (v2) per-9/per-6 reset.
- `api/test_snake.py` — setup, holder upsert (idempotent, clear/carry), summary
  shape, scorer auth.
- Mobile: the capture control renders for a non-primary Snake add-on (reuses the
  Spots carve-out; this is a regression guard on the score-entry assumption).

---

## Open questions (confirm at build time)

- **Withdrawal + holder:** if the snake's holder withdraws mid-round, does it
  pass back to the previous holder, or stay (and they pay anyway)? Proposed:
  pass back to the previous holder at the withdrawal hole.
- **Double cap:** `double` mode can blow up over 18 holes — cap at a configurable
  max, or trust the group. Proposed: soft cap shown in setup.
- **Segment boundary on a withdrawn/killed hole** (v2): settle on the last hole
  actually played in the segment.
