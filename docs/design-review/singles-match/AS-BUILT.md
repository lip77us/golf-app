# Singles Match — as built

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/nassau_setup_screen.dart` — **not a screen of its
own.** Engine: `services/nassau.py`. Setup is Part 1 below; Play follows it in the same file.

---

# Setup

## 1. It is Nassau's setup screen wearing a different name

> **This is the one to read**, because it means design cannot draw this screen
> without deciding what happens to two others.

One screen configures three games, and which one it is comes from the **route
flag**, never from a runtime toggle:

| Route flag | `game_type` sent | Title shown | Bets |
|---|---|---|---|
| — | `nassau` | Nassau | Front 9, Back 9, Overall |
| `overallOnly` | `match_18` | **Singles Match** | Overall only — one bet |
| `singleMatch` | `nassau_nine` | Nassau Nine | One nine |

Deriving it from the route rather than the toggles is deliberate: a team
Nassau where somebody happens to switch off both nines still saves as
`nassau`, so a Singles Match and a team Nassau can coexist on one foursome
without either one's identity depending on how its bets were left.

The consequence for design: **the Singles Match screen is a mode, not a
page.** Anything drawn for it that Nassau does not also want has to be
conditioned on the flag.

---

## 2. The screen, top to bottom

| Block | Control | In Singles Match |
|---|---|---|
| Teams | side assignment, 1–2 golfers a side | Two golfers, one each side |
| Handicap | `HandicapModeSelector` | Same |
| Bets | Front / Back / Overall toggles | **Overall only**; `_baseMultiple` drops from 3 to 1 |
| Presses | `none` / auto / manual + press unit | Available, and the same code as Nassau's |
| Variant | `none` / `tiebreak_2nd` / `claremont` | Offered, though Claremont's bottom bet is a fours idea |
| Stake | `StakeField` | Same |
| Advanced | *Cap each player's losses* | Same |

---

## 3. Decisions taken with no rule to follow

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **Three games, one screen** | The bet layout is the only real difference, and three screens differing by a toggle drift apart within a release | Settled, but it is invisible to a reader of the coverage table — three rows, one screen |
| 2 | **Identity comes from the route, not the form** | Otherwise a Nassau becomes a Singles Match by accident when somebody unticks two bets | Settled, and load-bearing |
| 3 | **Claremont and `tiebreak_2nd` are offered here too** | Neither was designed for a singles match — the second-ball comparison needs a second ball | ⚠ A two-golfer match always halves a tied hole, so `tiebreak_2nd` is a no-op the screen still offers |
| 4 | **Presses are available on a single 18-hole bet** | It is a real way to play | Settled |
| 5 | **The stake is the round's bet unit** | Nassau has no stake field of its own; the round's unit is the bet | Correct as built |

---

## 4. Shared components it already uses

- The whole of Nassau's setup screen, including its press and variant blocks
- `HandicapModeSelector`, `StakeField`, `SectionCard`
- **The `match` lock-screen card**, shared with Fourball — one card for a
  single match over eighteen holes, differing only in how many names sit on a
  side. This is why Singles Match's LOCK SCREEN cell is filled while its Setup
  and Play cells are empty

---

## 5. Still open

- **Its play surface is Nassau's**, and score entry carries the Nassau
  progress grid and hole-outcome strip. Neither has been drawn.
- **`tiebreak_2nd` should probably be hidden** in this mode (decision 3).
- **No How to Play, no web view, no receipt.**

---

# Play

## 6. Where the game is played

**Nassau's play screen**, `/nassau`, and Nassau's progress grid under shared
score entry. As with setup, this game has no surface of its own.

## 7. What the screen draws

| Element | In a Singles Match |
|---|---|
| Team banner | Two golfers rather than two sides — blue and orange dots with names |
| Entry pattern | The shared one: per-hole card, hot-spot row with an inline picker, 18-hole summary grid with a per-hole winner indicator, bottom hole navigation |
| Presses strip | Active and completed presses |
| Match chips | `F9` · `B9` · `Overall` + `Call Press` — **but only Overall is a live bet here** |

## 8. Decisions taken with no rule to follow — Play

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 6 | **The Nassau chip row is reused unchanged** | One screen, three games | ⚠ Two of the three chips describe bets that do not exist in this mode. This is the single most likely thing to look broken to a golfer |
| 7 | **Presses run on the one bet** | A press on an 18-hole match is a real bet | Settled |
| 8 | **The winner indicator is per hole, not per bet** | The grid answers "who won this hole", which is the same question in every mode | Settled |

## 9. Still open — Play

- **The F9 / B9 chips** (decision 6) — hide them, or say why they are dark.
- The whole screen has never been drawn in this mode, only in Nassau's.

---

# Leaderboard

Card: `_NassauGroupCard` — Singles Match, Nassau Nine and the parent Nassau all
share one card, which reads the game's live bets and draws only those. Web
view: **no** (`_has_casual_nassau` tests the literal string `'nassau'`, so the
two variants are excluded). Lock screen: yes.

## What the card draws

A Singles Match is an 18-hole Overall-only Nassau, so of the card's three
possible bet rows **only `Overall` is drawn** — `playFront` and `playBack` are
false and their rows are skipped rather than rendered empty.

| Block | Content |
|---|---|
| Header | Both sides, short names, in team colours — or the cup team names and colours when the match is a cup match |
| `Overall` row | The margin, `All Square` when level, `Not started` before play |
| Presses | `Auto` / `Manual` markers where presses exist |
| Money | Signed `+$X` / `−$X`, green above zero and red below, `$0.00` at zero; a loss cap truncates the figure when set |
| Thru | From `overall.holesPlayed` |
| Scorecard | `HoleGridScorecard` with stroke dots and the SI row |

## Decisions taken with no rule to follow — Leaderboard

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **Only live bets get a row** | An Overall-only game is an 18-hole match and two empty nine rows would be furniture | Correct, and the source comment says so |
| 2 | **The card is shared across three games** | Nassau, Nassau Nine and Singles Match are one engine with different bets switched on | Good — and the reason all three behave identically, which is worth keeping |
| 3 | **Cup matches recolour to the cup teams** | A cup singles match belongs to a side, not to a blue/orange convention | Correct |
| 4 | **Zero money prints `$0.00`** | Unlike Vegas and Points, which print `—` | Drift (umbrella finding 2) |

## Still open — Leaderboard

- **No web view**, purely because the gate tests `'nassau'` and this game's key
  is `match_18`. That looks like an oversight rather than a decision.
- Zero money (decision 4).
