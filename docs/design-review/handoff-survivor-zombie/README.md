# Handoff: Survivor — Zombie Option

## Overview

Survivor is the 3-player game already specified in Halved. This packet adds one setting to it,
the **Zombie Option**, plus the Survivor tab on the leaderboard. Everything else in Survivor is
unchanged.

Files in this bundle:

```
README.md                    this file
SPEC.md                      the rules, state and edge cases — build from this
survivor-setup.html          setup screen, Zombie Option card added (default OFF)
survivor-play.html           play screen, Zombie row + resurrection state
leaderboard-survivor.html    Survivor tab on the leaderboard, with zombie colouring
```

## About the design files

The HTML is a **design reference**, not production code. The app is Flutter/Dart
(`lib/theme/halved_brand.dart` holds the live palette); recreate these screens with the app's
existing widgets and theme. Each file opens standalone in a browser. The 390 × 812 phone frame is
presentation scaffolding. The "← Contents" link in the corner will 404 in this bundle — ignore it.

**Fidelity: high.** Colours, type, spacing and copy are final. The one new colour is the zombie
plum, below.

## Screens

| File | What changed |
|---|---|
| `survivor-setup.html` | New **Zombie Option** card between Stake and How Survivor works: a toggle (**off by default**) and three worked cases showing the outcomes. Base "How Survivor works" copy is unchanged and describes plain Survivor. |
| `survivor-play.html` | The knocked-out player's row becomes a **ZOMBIE** row when the option is on: plum wash, plum name, live score box (not the dimmed OUT row). Outcome banner announces the resurrection and who goes to Zombieville. The by-hole grid gains a plum mark for the resurrection hole, and the Survivor band does **not** increment (the same Survivor keeps running). |
| `leaderboard-survivor.html` | New Survivor tab: standings (trophies won + money), the Survivors strip with one row per Survivor, and the by-hole scorecard with par/index rows, stroke dots and green / red / plum marks. |

The play screen is drawn in the on state so the behaviour is visible; setup is drawn in the
default off state.

## New token

**zombie `#6E4B8E`** — the only colour added. Usage: name text, badge, score-box border, grid cell
mark (15% tint), and the "Zombie on" pill. It must never read as green (won) or red (out); a zombie
is neither. All other colours come from the existing brand and semantic sets — win `#388E3C`,
out/loss `#C62828` / `#D32F2F`, pine `#0F6E56`, muted `#5C6B62`.

## Notes for build

- The option is a **per-game setting on Survivor setup**, stored with the game, not a global
  preference. Default `false`.
- The toggle is only meaningful before the round starts; once holes are scored it should be
  read-only (changing it mid-round rewrites history).
- The eliminated player keeps entering scores every hole while the option is on, so **score entry
  must not lock the OUT row**. That is the main behavioural difference on the play screen.
- Nothing about handicap changes: strokes still fall on the hardest holes across the whole round,
  and the zombie's score is a **net** score like everyone else's.

See `SPEC.md` for the rules, the resolution order and every edge case, including the 18th hole and
the no-blood outcome.
