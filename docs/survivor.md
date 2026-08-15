# Survivor — design doc

**What it is:** a three-man **horse race**. On an **elimination hole** the worst
score is knocked out; the surviving two then play a **decider hole** head-to-head
for the pot. The moment a Survivor is decided a fresh one starts on the very next
hole, all three back in. **Exactly 3 players.** Primary game (owns the score-entry
screen). Up to **9 Survivors** in a normal 18.

Nothing in the library has this shape. The closest relatives are **Points 5-3-1**
(3 players, per-hole outright comparison, individual balls) for the scoring
scaffolding and **Rabbit** (`services/rabbit.py`) for the structural pattern —
a round chopped into a variable number of self-contained legs whose boundaries
fall out of the scores rather than being fixed up front. Survivor should be built
from those two, not from scratch.

---

## Decisions (from the product discussion)

- **Exactly 3 players.** Not a range — the format is defined by 3-down-to-2.
- **All three handicap modes** make sense: Net (with %), Gross, Strokes-Off-Low.
- **Each player antes the stake per Survivor.** Pot = 3 × stake; the winner takes
  it, so **+2 / −1 / −1**. Zero-sum, and it's what makes "split the loser's
  entry" coherent — every player has an entry in each Survivor.
- **A tied decider carries.** The same two keep playing head-to-head until one
  wins a hole outright. The eliminated player stays out for the whole Survivor.
  A Survivor is therefore *at least* two holes but has no upper bound.
- **The last hole is the only exception**, and it has two shapes (below).
- **No off-line playoff.** A chip-off / putt-off to settle a tied final hole was
  considered and rejected in favour of splitting the loser's entry — it keeps
  settlement inside the app and needs no extra capture UI.

---

## The engine

Walk the group's holes **in play order** (`services/hole_plan.play_order`, so a
back-9, a 9-hole round, and a shotgun all work). Carry `alive` (the players still
in the current Survivor) and `survivor_no`.

Only **fully-scored** holes advance the state; an unscored hole is skipped and
the state carries, matching `services/rabbit.py::_run_rabbit`.

### Elimination hole — three alive

| Situation | Result |
| --- | --- |
| One player is strictly worst | They're **eliminated**; the other two go to a decider |
| The two worst scores **tie** | **No elimination** — the Survivor continues on the next hole, all three still in |

A tie for *low* is irrelevant here — only the bottom of the board matters. All
three tied means the two worst tie, so nothing happens.

### Decider hole — two alive

| Situation | Result |
| --- | --- |
| One player is strictly lower | They **win the Survivor**; the pot settles |
| They tie | **Carry** — same two, next hole |

### The last hole in play

The round's final hole can't host an elimination *and* a decider, so it settles
whatever is standing:

| Alive on the last hole | Result |
| --- | --- |
| **Three** (a Survivor that started here, or one still un-eliminated) | Strictly low score **wins the Survivor**. Any tie for low → **no blood**, nobody pays |
| **Two** (elimination landed on the second-to-last hole) | Strictly low **wins**. A tie → **split the eliminated player's entry**: **+½ / +½ / −1** |

### Worked example

```
Survivor 1
  Hole 1   elim     Ann 4  Ben 5  Cal 6   → Cal worst, out
  Hole 2   decider  Ann 4  Ben 4          → tied, carry
  Hole 3   decider  Ann 4  Ben 5          → Ann wins        +2 / −1 / −1
Survivor 2   (all three back in)
  Hole 4   elim     Ann 5  Ben 5  Cal 4   → two worst tie, nobody out
  Hole 5   elim     Ann 4  Ben 6  Cal 5   → Ben out
  Hole 6   decider  Ann 5  Cal 4          → Cal wins        −1 / −1 / +2
…
Survivor 9
  Hole 17  elim     Ann 4  Ben 5  Cal 6   → Cal out
  Hole 18  decider  Ann 4  Ben 4          → tied on the last hole
                                            split Cal's entry  +½ / +½ / −1
```

### Counting

A Survivor takes a minimum of two holes, so an 18-hole round yields **at most 9**.
A 9-hole round yields at most 4 (four 2-hole Survivors, then a 1-hole Survivor on
the last hole under the three-alive rule — 5 in the best case). The engine derives
this; nothing is configured.

---

## Settlement

Per Survivor, every player antes `round.bet_unit`. Three outcomes:

| Outcome | Winner | Others |
| --- | --- | --- |
| Won outright | `+2 × stake` | `−1 × stake` each |
| Tied decider on the last hole | `+½ × stake` each survivor | `−1 × stake` (eliminated) |
| No blood (three alive, tied low, last hole) | `0` | `0` |

Zero-sum in every case. **Max liability** per player = `stake × number of
Survivors played` (up to 9 × stake on a full 18) — surface it in the setup screen
via the existing `MaxLiabilityNote`, the way Rabbit does.

A Survivor that is still **live** when the round ends can't happen: the last hole
always settles it. A Survivor that is live *mid-round* (round abandoned) simply
carries no money, like an incomplete Rabbit leg.

---

## Handicaps

Net (with %), Gross, and Strokes-Off-Low, resolved into a net index exactly as
Rabbit does — `scoring.handicap.build_score_index` for net/gross and
`services.points_531._build_so_score_index` for strokes-off.

**Full-round allocation only.** The per-segment spread that Rabbit and Sixes offer
has no meaning here: Survivors have no fixed ranges to spread across, and their
boundaries move with the scores. Trying to allocate per-Survivor would re-create
exactly the "strokes moved onto a played hole" bug just fixed in
`services/rabbit.py` — a Survivor's length isn't known until it ends. So: one
stroke on every hole whose stroke index ≤ the player's strokes-off, decided before
the round and never revisited. **No `handicap_allocation` field on this game.**

---

## Data model

Follows the Points 5-3-1 / Rabbit pattern — a config row plus per-hole results,
with the Survivor *legs* derived at summary time rather than stored (they move as
scores are edited, exactly like Rabbit's segments).

- `core.GameType.SURVIVOR = 'survivor'`
- `games.SurvivorGame` — OneToOne `foursome`; `status`, `handicap_mode`,
  `net_percent`. Stake comes from `round.bet_unit` (Rabbit's convention).
- `games.SurvivorHoleResult` — one row per **scored** hole:
  - `game`, `hole_number`
  - `survivor_index` (1-based)
  - `role` — `elimination` | `decider` | `final`
  - `eliminated` (FK, nullable) — set on the hole that knocked them out
  - `winner` (FK, nullable) — set on the hole that decided the Survivor
  - `event` — `eliminated` | `no_elimination` | `won` | `carried` | `split` |
    `no_blood`

Migrations: `games/00XX_survivor` plus the usual `tournament/00XX` enum refresh of
`rydercupfoursomeconfig.game_type` / `rydercupmatchpoints.game_type`.

---

## Service — `services/survivor.py`

`setup_survivor(foursome, handicap_mode, net_percent)` — create/replace, idempotent.
`calculate_survivor(foursome)` — rebuild `SurvivorHoleResult` from `HoleScore`.
`survivor_summary(foursome)` — the JSON the mobile screen + leaderboard consume:

```
{
  'status', 'handicap': {'mode', 'net_percent'},
  'survivors': [{'index', 'start_hole', 'end_hole', 'holes',
                 'eliminated_id', 'eliminated_short',
                 'winner_id', 'winner_short',
                 'outcome',            # won | split | no_blood | live
                 'complete', 'value', 'payout'}],
  'players':   [{'player_id', 'name', 'short_name',
                 'survivors_won', 'money', 'phcp_in_play'}],
  'holes':     [{'hole', 'survivor', 'role', 'par',
                 'eliminated_id', 'winner_id', 'event',
                 'entries': [{'player_id', 'short_name', 'net_score', 'gross',
                              'strokes', 'is_alive', 'is_eliminated',
                              'is_winner'}]}],
  'current':   {'survivor': n, 'alive_ids': [...], 'role': 'elimination'},
  'scorecard': {'players', 'holes', 'holes_in_play'},   # shared grid block
  'money':     {'bet_unit', 'pot', 'max_liability'},
}
```

Emit the `scorecard` block from day one — it's the Wolf/Sixes/Rabbit shape the
shared `_MsScorecard` widget renders, and the leaderboard card should use it
rather than growing a bespoke strip.

---

## Catalog / classification (`game_catalog.dart`)

```dart
GameIds.survivor: GameMeta(
  displayName: 'Survivor',
  casual: true, enabled: true,
  exactPlayers: 3,
  canBeSideGame: false,      // owns score entry
  allowsSideGames: true,     // individual-ball → can host Skins/Stableford/…
)
```

Individual-ball, so it joins the primaries that host overlays (Skins, Stableford,
Stroke Play, Spots, Honors) — the same list Rabbit and Wolf are on.

---

## API

- `GET  /api/foursomes/<id>/survivor/`        → summary
- `POST /api/foursomes/<id>/survivor/setup/`  → `{handicap_mode, net_percent}`

Auth via `foursome_for_scorer`. Add `calculate_survivor` to `_recalculate_games`
and a `survivor` block to `_build_leaderboard`; add `survivor_game` to
`FoursomeSerializer.get_configured_games`.

---

## Mobile

- Models `SurvivorSummary` / `SurvivorLeg` / `SurvivorHole` / `SurvivorPlayerTotal`;
  `client.getSurvivorSummary` / `postSurvivorSetup`; `RoundProvider.loadSurvivor`.
- `survivor_setup_screen.dart` (`/survivor-setup`) — `HandicapModeSelector` (all
  three) + `StakeField` + `MaxLiabilityNote`. Deliberately thin: there is nothing
  else to configure.
- `survivor_screen.dart` (`/survivor`) — dedicated play screen, modelled on
  `rabbit_screen.dart`:
  - banner: "Survivor 3 · elimination hole" / "· decider", and who's alive
  - eliminated player's row greyed with an **OUT** badge for the rest of that
    Survivor
  - Survivors strip: one row per Survivor — range, winner, payout
  - `SpotsCaptureMixin` wired in, like the other dedicated screens
- Leaderboard `_SurvivorGroupCard`: standings (Survivors won + money), the
  Survivors strip, and `_MsScorecard` with the hole winner tinted.
- Routes in `main.dart`, routing in `create_casual_round.dart` /
  `round_screen.dart` / `casual_rounds_list_screen.dart`, and the rotate-to-
  landscape wrapper (`RoundLandscapeScorecard`) for the new route.

---

## Phasing

1. **Engine + tests** — `services/survivor.py` and models, no API. The whole
   format is decided here; get it right in isolation.
2. **API + leaderboard block.**
3. **Mobile** — setup screen, play screen, leaderboard card.
4. **`seed_demo` round** so it's demoable and screenshot-able.

---

## Tests (`scoring/tests/test_survivor.py`)

- Elimination: unique worst is out; two worst tied → nobody out, carries.
- Decider: unique low wins; tie carries to the next hole with the same two.
- A Survivor spanning many holes (repeated no-elimination, then repeated carries).
- New Survivor starts on the very next hole with all three back in.
- Last hole, three alive: low wins / tied low = no blood.
- Last hole, two alive: low wins / tie = split (+½ / +½ / −1).
- Nine Survivors on a full 18 (the maximum), and the count on a 9-hole round.
- Zero-sum invariant across every outcome mix.
- All three handicap modes, including strokes-off with a 3-player anchor.
- Partial round / shotgun: "last hole" is the last in **play order**, not hole 18.

---

## Open / deferred

- **Mid-round withdrawal.** Three players is the format; losing one breaks it.
  The universal unblocker still lets the round complete, but per-Survivor
  settlement after a WD is deferred — same posture as Nassau / Points 5-3-1.
- **Tournament use.** Casual-only for v1.
- **Watch page renderer** (`watch/survivor.html`) deferred, as with Fourball.
