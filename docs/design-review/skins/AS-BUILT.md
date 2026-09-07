# Skins — as built: Play

**Setup is drawn** (`screens/game-setup-skins.html`), and so is the lock-screen
card. **Play is not**, and this is what is there.

Surfaces: three widgets inside shared score entry
(`mobile/lib/screens/score_entry_screen.dart`). Engine: `services/skins.py`.

---

## 1. Skins has no screen, and does not want one

> **This is the one to read.**

The game is one fact per hole — *did anybody win it outright, and if not how big
is the pot now* — so it is drawn as **two coloured bands inside the score list**
rather than a card above or below it. That is unlike every other game in the
app, and it is right: the answer belongs beside the scores that produced it.

| Widget | When it draws | What it says |
|---|---|---|
| `_SkinsHoleOutcome` | The hole has a winner | Green band, golf-ball icon — `Skins: PK wins hole`, or `Skins: PK wins (3 skins incl. carry)` |
| `_SkinsCarryChip` | The hole is unresolved **and** the pot is above 1 | Amber band, flame icon — `3 skins on the line` |
| `_SkinsStandingsCard` | Always | Horizontally scrolling standings |

---

## 2. Decisions taken with no rule to follow

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **Full-bleed coloured bands, not cards** | The outcome belongs against the hole, not in a panel below it. Nothing else in the app draws an edge-to-edge tinted strip inside the entry list | Settled, and it is a pattern worth naming rather than leaving as Skins' quirk |
| 2 | **The carry chip appears only when the pot is above 1** | On a hole carrying nothing there is nothing at stake beyond the ordinary skin, and a chip reading `1 skin on the line` on fourteen holes is furniture | Settled |
| 3 | **A flame icon for the carry** — `Icons.local_fire_department` | It is the only fire in the app, and a carry IS the heat of a skins round | ⚠ It is also the only place the app uses amber for excitement rather than warning; Banker's amber means the counter-double |
| 4 | **The outcome band names the winner in SHORT name** | The band is one line inside a list of rows already carrying full names | Settled |
| 5 | **The carry count is spelled out in the win** — `wins (3 skins incl. carry)` | The number a golfer wants at settlement is what the hole actually paid, not that it was a carry | Settled |

---

## 3. Still open

- **The two bands are the design**, and neither has been drawn. If anything in
  this document deserves a pass it is the pair of them together — they are the
  only place in the app where two different tinted strips can stack under one
  golfer's row.
- **Amber's second meaning** (decision 3) is worth one ruling now that Banker
  has claimed amber for the counter.
