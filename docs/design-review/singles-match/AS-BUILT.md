# Singles Match — as built: Setup

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/nassau_setup_screen.dart` — **not a screen of its
own.** Engine: `services/nassau.py`. Play is a separate document.

---

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
