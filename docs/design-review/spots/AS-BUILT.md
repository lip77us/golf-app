# Spots — as built

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/spots_setup_screen.dart`.
Engine: `services/spots.py`. Setup is Part 1 below; Play follows it in the same file.

---

# Setup

## 1. Spots is not a game, it is a capture add-on

> **This is the one to read.** Everything odd about this screen follows from
> it.

A "spot" is a **user-defined per-hole achievement** the app cannot detect —
one-putt, sandy, barky, whatever the group calls it. The scorer tallies them
by hand, per golfer per hole, and **the count IS the data**: nothing is
derived from gross scores, so there is no recalculation step and no way for a
spot to be wrong except by being typed wrong.

Two consequences design should hold on to:

- **It settles on its own pot and is never folded into the main game.** A
  Spots pot rides alongside Skins, Nassau, anything.
- **Its play surface is the capture control**, not a board: score entry draws
  an inline `⊖ N spots ⊕` stepper under each golfer. That is why its PLAY cell
  is filled while everything else about it is empty, and it is the right
  shape — a tally needs a thumb, not a screen.

---

## 2. The screen, top to bottom

| Block | Control | Notes |
|---|---|---|
| Stake | `StakeField` | Under `pool` this is the **ante**, not a per-spot rate — same field, two meanings |
| How the money settles | segmented: `Pool` · `Per spot` | Only Spots has the Pool option of the three points games |
| (under Per spot) | `vs Average` · `Above you` · `Just leader` | Defaults to **Above you** |
| Advanced (collapsed) | *Cap each player's losses* | Off by default |
| How Spots works | prose | The only explanation anywhere in the app |
| Action | `Start` / `Save Configuration` | |

**No handicap selector.** There is nothing to adjust — a spot is a spot.

---

## 3. Decisions taken with no rule to follow

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **`pay_around` is the historical default** — each spot pays the achiever one stake from every OTHER active golfer on that hole | Zero-sum within the hole's roster, and it is how the game is played in a car park | Settled |
| 2 | **`Above you` is the default settlement here**, where Points 5-3-1 and Honors default to `vs Average` | Nobody chose the difference; the three screens grew separately | ⚠ Same trio, three screens, two defaults. One ruling fixes all three |
| 3 | **The stake field means two different things** | Under `pool` it is the ante; under `per spot` it is the rate. The label does not change | ⚠ The cheapest real fix on this screen |
| 4 | **A golfer only pays or collects on holes they were active for** | Mirrors Skins for mid-round withdrawal | Settled |
| 5 | **Spots owns its own `bet_unit` field** and does NOT write the round's | Correct, and the exception among the casual games — it is an add-on riding alongside a main game whose stake is none of its business | Correct as built, and the model the others cannot follow because they have no field of their own |
| 6 | **The spot itself is never named in setup** | The group knows what they are counting; the app just counts | ⚠ A named spot would make the receipt readable — `3 sandies` beats `3 spots` |

---

## 4. Shared components it already uses

- `StakeField`, `SectionCard`, `GolfAppBar`
- **The settlement trio** (`vs Average` / `Above you` / `Just leader` + the
  loss cap) shared with Points 5-3-1 and Honors — the largest undrawn pattern
  in the set
- `SpotsCapture` — the inline stepper, and the only capture add-on in the app

---

## 5. Still open

- **Naming a spot** (decision 6) is the one feature request this game has.
- **The stake label** (decision 3).
- **No web view, no lock-screen card, no How to Play** beyond the prose block.

---

# Play

## 6. Where the game is played

**Inside every score-entry screen there is.** `SpotsCapture` is a shared widget
used by the universal score entry *and* by the dedicated Wolf and Rabbit
screens, so a group can tally spots whatever else they are playing.

## 7. What it draws

An inline `⊖ N spots ⊕` control under each golfer's name. Nothing else — no
board, no strip, no card.

| Detail | Behaviour |
|---|---|
| Starting state | `0 spots` |
| The minus is always shown | Even at zero — **spots can go negative** |
| Writing | Optimistic local tally, then a debounced POST |

## 8. Decisions taken with no rule to follow — Play

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 7 | **A spot count can go negative** | The count IS the data and there is no recalculation to correct it, so the only way back from a mis-tap is down. Hiding the minus at zero would trap a golfer who tapped ⊕ twice | Settled, and worth understanding before anyone tidies it away |
| 8 | **Optimistic, then debounced** | A tally is tapped standing on a green with one thumb; a spinner per tap would be unusable | Settled |
| 9 | **It rides inside other screens rather than owning one** | It is an add-on to whatever is being played | Settled — and it is why this game's PLAY cell is the only filled one among the eight |
| 10 | **The control never says what a spot IS** | The group defines it out loud | ⚠ Pairs with the setup-side request to name the spot |

## 9. Still open — Play

- **Naming the spot** would change this control's label from `N spots` to
  `N sandies`, which is the whole difference between a tally and a game.
- No running total is visible while playing — a golfer sees their count for
  *this hole* and nothing else.
