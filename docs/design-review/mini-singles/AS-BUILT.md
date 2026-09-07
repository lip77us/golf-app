# Mini-singles Bracket — as built: Play

**Setup is drawn** (`handoff-individual-play/04-mini-singles-setup.html`).
**Play is not.**

Screen: `mobile/lib/screens/match_play_screen.dart` (`/match-play`), plus a
status card under shared score entry. Engine: `services/match_play.py`.

---

## 1. It is a bracket, and the screen draws the whole bracket from hole one

> **This is the one to read.**

Four golfers play **two semi-finals on the front nine**, and the winners meet
in a **final on the back**, with the losers playing a consolation alongside it.
The screen draws all four matches from the start:

| Element | Content |
|---|---|
| Status banner | Overall winner, or in progress |
| `── Front 9 — Semis ──` | Semi 1 card, Semi 2 card |
| `── Back 9 — Final & 3rd Place ──` | Final card and 3rd-place card, **dimmed until both semis finish** |
| Money | Payouts card |
| Each match card | Names with colour swatches, a live line (`Paul 2 Up thru 7`, `Paul wins 3&2`), and a hole-by-hole strip of coloured squares for the nine |

**Three golfers play a different bracket on the same screen**: three parallel
nine-hole round-robin matches, 2 points a win and 1 a half, and the top two by
points play a nine-hole final.

---

## 2. Decisions taken with no rule to follow

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **The final is dimmed, not hidden** | The shape of the bracket is the appeal, and a golfer on the 3rd tee should be able to see what he is playing towards | Settled, and the best idea on the screen — worth drawing properly rather than as an opacity |
| 2 | **The three-golfer round robin reuses the four-golfer screen** | Both resolve to matches with a live line and a hole strip | ⚠ A round robin has no semis and no final until it does, so two section headings describe a bracket that is not one |
| 3 | **A match concludes early and says so** — `wins 3&2` | Match play notation, unexplained anywhere | Settled |
| 4 | **The carve percentage and the empty-seat rule are invisible during play** | Both are set by the TD at setup — how much of the pot the bracket carves out, and what happens to an unfilled seat | ⚠ The money card shows the result of rules the reader cannot see |
| 5 | **Reload is manual** — pull-to-refresh or an app-bar icon | It reads a bracket rather than driving one | Settled |

---

## 3. Still open

- **The round-robin variant** (decision 2) shares a screen designed for a
  knockout. Either it gets its own headings or the headings go.
- **The carved pot** (decision 4) — the money card should probably say what was
  carved and why.
- **`3&2` is never explained** anywhere in the app.
