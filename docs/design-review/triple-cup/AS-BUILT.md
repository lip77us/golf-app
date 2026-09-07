# One-Round Triple Cup — as built: Play

**Setup is drawn** (the cup-flow packets). **Play is not**, and it is the
largest undrawn screen in the set.

Screen: `mobile/lib/screens/triple_cup_screen.dart` (`/triple-cup`).
Engine: `services/triple_cup.py`.

---

## 1. It is a Ryder Cup compressed into one round, and the screen stacks four matches

> **This is the one to read.**

Four matches run simultaneously inside one foursome — **Fourball, Foursomes,
Singles 1, Singles 2** — and the screen is a vertical stack of all four plus a
cup total. Nothing else in the app draws four live matches at once.

| Element | Content |
|---|---|
| App bar | Title plus a handicap-mode badge |
| Top card | The cup score — `Team 1: 2.5 — Team 2: 1.5 of 4` |
| One card per match | Segment header, both rosters, live status (`2 UP thru 4`, `Halved`), and the per-hole grid scored so far |
| Money | Running dollars per golfer at the bottom |
| FAB | Jumps to the universal `/score-entry` |

Score entry knows about the cup too: rows are tinted by team colour, and a
**phantom inherits a team colour** so a three-handed group still reads as two
sides.

---

## 2. Decisions taken with no rule to follow

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **The cup score carries a decimal** — `2.5 — 1.5 of 4` | Halved matches are worth a half, as in the real thing | Settled, and it is the only score in the app with a decimal point |
| 2 | **All four matches are always drawn**, live or not | The shape of the cup is the point; hiding an unstarted match would make the reader count | Settled — but it is four cards plus a total plus money on one scroll |
| 3 | **The screen does not enter scores** — a FAB leaves for `/score-entry` | Four matches share one set of eighteen holes and four golfers; entering per match would ask for the same score four times | Settled, and worth stating on the screen, which currently just has a button |
| 4 | **A phantom gets a team colour** | Otherwise a three-handed cup has a colourless row in a game entirely about two sides | Settled |
| 5 | **Money sits below four match cards** | It is the least urgent thing on the screen | ⚠ It is also below the fold on every phone |

---

## 3. Still open

- **The whole screen.** Four match cards, a cup total, a money block and a FAB,
  never designed — the biggest single drawing job on the coverage table.
- **The FAB's destination** (decision 3) is unexplained on screen.
- **Money below the fold** (decision 5).
