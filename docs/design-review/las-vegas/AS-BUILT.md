# Las Vegas — as built

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/vegas_setup_screen.dart`.
Engine: `services/vegas.py`. Setup is Part 1 below; Play follows it in the same file.

---

# Setup

## 1. The "number" is the game, and it is the one thing setup never shows

> **This is the one to read.**

Each hole a team's **number** is its two net scores written as digits — the
low score as the tens, the high as the ones. A 4 and a 5 is **45**. The lower
number wins the hole and scores **the difference between the two numbers**, so
a 45 against a 56 is eleven points, not one.

That is the whole game, it is unlike anything else in the app, and **the setup
screen never draws an example of it.** A group meeting Vegas for the first
time configures a birdie rule for a scoring system they have not seen.

Each digit is capped at 9, which matters more than it sounds: a 10 and a 4
is 49, not 410.

**Play surface:** score entry carries a `_VegasStatusCard`. There is no
dedicated play screen.

---

## 2. The screen, top to bottom

| Block | Control | Notes |
|---|---|---|
| **Teams** | `TeamSplitter4` — drag, partners share a colour | Exactly four golfers, two fixed teams |
| Handicap | `HandicapModeSelector` | Plus a **net max double bogey** switch, on by default |
| **Birdies** | `flip` / `multiply` | A gross birdie either flips the opponents' digits (a 67 becomes 76) or multiplies the points |
| Carry | switch, off | A tied hole carries its points into the next |
| Cap losses | switch + amount | Per side |
| Stake | `StakeField` | Money is the running point differential × stake |

---

## 3. Decisions taken with no rule to follow

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **`flip` is the default birdie rule**, not `multiply` | Flipping is the traditional Vegas punishment and scales with how bad the opponents' hole was; multiplying scales with how big the lead already is | Settled |
| 2 | **Net max double bogey is ON by default** | Without it a blow-up hole produces a three-digit number and a hole worth hundreds of points | Settled, and load-bearing — but it is a switch labelled in handicap language for a rule that protects the *stake* |
| 3 | **Carry is off by default** | Vegas holes are already high-variance; carrying compounds it | Settled |
| 4 | **Digits cap at 9** | A 10 and a 4 must be 49; the alternative is a 104 | Settled — and undrawn, so a golfer who makes 10 sees a number they cannot derive |
| 5 | **The loss cap is per SIDE, not per golfer** | The bet is team against team | Contrast Banker's per-golfer cap. Worth knowing the app now has both shapes |
| 6 | **The stake is the round's bet unit** | Vegas has no stake field of its own | Correct as built |

---

## 4. Shared components it already uses

- `TeamSplitter4` — the drag-to-pair control, shared with Fourball
- `HandicapModeSelector`, `StakeField`, `SectionCard`

---

## 5. Still open

- **An example of the number.** Decision 4 and the whole of §1 argue for one
  worked hole on the setup screen — `45 v 56 = 11 points` — which no amount of
  prose replaces.
- **The net-max-double-bogey switch is mislabelled for its job** (decision 2).
- **No play screen, no web view, no lock-screen card, no receipt, no How to
  Play.**

---

# Play

## 6. Where the game is played

Under shared score entry, as a `_VegasStatusCard`. No dedicated screen.

## 7. What the card draws

| Element | Content |
|---|---|
| Header | `Las Vegas`, the birdie rule (`Flip` / `Multiply`), and a `Carryover` marker when it is on |
| One row per team | Names in the team colour, `N pts`, and money — `—` at zero, otherwise `±$X.XX` |

**And that is all.** Which produces the finding of this document.

## 8. Decisions taken with no rule to follow — Play

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 7 | **The NUMBER is never shown** | The card reports points and money. The two-digit number that is the entire game — `45` against `56`, eleven points — appears nowhere in the app, on any screen, at any time | ⚠ **This is the one to fix.** A golfer cannot check the app's arithmetic against the game they just played, and the game is unlike anything else in the set so intuition does not cover for it |
| 8 | **No per-hole grid** | Every other game with a card under entry has one; Vegas has rows only | ⚠ Follows from 7 — a grid is where a per-hole number would live |
| 9 | **The birdie rule is shown as a word** | `Flip` / `Multiply` beside the title, so the reader can see which is on without opening setup | Good, and worth copying |
| 10 | **Money carries two decimal places** | The point differential × stake rarely lands on a dollar | Settled, though it is the only game in the set that shows cents |

## 9. Still open — Play

- **Show the number** (decision 7), per hole, per side. Everything else about
  this game is secondary to it.
- A per-hole grid to put it in (decision 8).
