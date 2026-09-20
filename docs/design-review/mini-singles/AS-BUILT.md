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

---

# Leaderboard — the standalone bracket

**Two unrelated things share this name.** The tournament Mini Singles
(`MiniSinglesConfig`, a bracket in every group on day 1 and a winners'
foursome on day 2, funded by a carve-out of the championship pool) does **not**
appear on the round leaderboard. What does is the **standalone** game — a
bracket inside one foursome, picked from the New Round wizard as
**"Mini Singles Bracket"** and stored as the game key `match_play`.

Engine: `services/match_play.py`. 4 golfers = two semis on the front 9, then
the winners' final and the losers' consolation on the back. 3 golfers = three
parallel 9-hole round-robin matches, then a 9-hole final between the top two on
points.

Card: `_MatchPlayGroupCard`. Web view: **yes** (`_has_casual_match_play`).
Lock screen: no.

## What the card draws

The card is a header and nothing else — it delegates the whole body to
**`MatchPlayDetailView`**, the same widget the dedicated Match Play screen
uses, so the leaderboard reads at exactly the depth of the play screen. The
source comment records this as deliberate, replacing a condensed one-line
summary per match.

Observed, on a 4-player round before any score:

| Block | Content |
|---|---|
| Status banner | `Waiting for scores to be entered.` in a pill |
| Handicap | A flag icon and `Strokes-Off-Low` |
| Round heading | `Front 9 — Semis`, sub-line `Holes 1–9 · Seed 1 vs 4 · Seed 2 vs 3` |
| Per-match card | A mint `Semi 1` chip, a `Pending` pill right-aligned |
| The pairing | Blue dot + name `vs` orange dot + name |
| State | `Waiting for scores` |
| Hole boxes | Nine empty boxes numbered 1–9 |
| Scorecard | `Scorecard · dots = strokes`, then Hole / Par / SI rows and an `OUT` column, one row per golfer with stroke dots and a `—` total |

Unconfigured groups get their own state: **`Mini Singles Bracket not set up for
this group. Use the Game Setup card on the round screen.`**

## Decisions taken with no rule to follow — Leaderboard

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **The leaderboard reuses the play screen's view wholesale** | One layout, one depth, no second thing to keep in step | ⚠ The best structural decision on this screen, and the only game that does it. Every other card is a second, shallower rendering of a game that already has a screen |
| 2 | **The empty state names the fix** | "Use the Game Setup card on the round screen" rather than "No data" | Good, and the only empty state in the set that tells the reader what to do |
| 3 | **Seeds are spelled out in the sub-line** | `Seed 1 vs 4 · Seed 2 vs 3` — the bracket's shape before it has any results | Good |
| 4 | **`_single_group` is honoured** | A casual bracket is one group by definition | Correct |
| 5 | **Empty hole boxes are drawn before any score** | The nine boxes are the shape of the match waiting to be filled | Worth a look — it is a lot of empty furniture above a scorecard that is also empty, and the card is tall before it says anything |

## Still open — Leaderboard

- **The name collision** with the tournament game. Two different objects,
  different economics, one label — and the wizard chip, the tab and this card
  all read `Mini Singles Bracket`.
- **Scorecard names mix first names and initials** — `Glenn` above `GL` in the
  same column (umbrella drift 5).
- Vertical cost of the pre-score state (decision 5).
