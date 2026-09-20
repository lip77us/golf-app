# Honors — as built

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/honors_setup_screen.dart`.
Engine: `services/honors.py`. Setup is Part 1 below; Play follows it in the same file.

---

# Setup

## 1. Honors is the one game with no play surface at all

> **This is the one to read.** Every other empty PLAY cell in the coverage
> table is a screen design has not drawn. This one is genuinely bare.

No play screen, no card under score entry, no strip, nothing. A golfer plays
an entire round of Honors and the app shows them the state of it only on the
leaderboard. Given that the whole game is *who is holding the token right
now*, that is the gap most worth a drawing in this batch.

And the game is more subtle than it looks, which makes the silence worse. **A
single token, the honor, goes to the lowest score on each hole**, and the tie
rules are the game:

- An outright low takes or keeps it.
- **A tie for low that includes the current holder is kept by the holder** —
  a tie does not beat you.
- A tie among golfers who all *beat* the holder is broken by walking BACK
  through prior holes, most recent first, until one is lower.
- If they are never separated, **the honor dies** — it goes loose. It does
  not return to the beaten holder.

A golfer holds it for a hole, they score a point. Points are holes held.

---

## 2. The screen, top to bottom

| Block | Control | Notes |
|---|---|---|
| Participants | checklist of the roster | **Everyone by default**, or pick a subset for a side bet. Minimum two |
| Handicap | `HandicapModeSelector` — Net / Gross / SO Low | Percent slider under Net |
| How Honors works | prose | The only place the tie rules are written down for a golfer |
| Stake | `StakeField` | One point is worth one stake |
| How the money settles | segmented: `vs Average` · `Above you` · `Just leader` | Defaults to `vs Average`. Pool exists in the engine but is not offered here |
| Advanced (collapsed) | *Cap each player's losses* | Off by default |

---

## 3. Decisions taken with no rule to follow

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **A tie does not beat you** — the holder keeps it | Nobody scored strictly below them. The alternative hands the token around on halved holes, which is most holes | Settled, and it is the rule golfers argue about |
| 2 | **A contested tie is broken by walking back through prior holes** | It settles on golf already played rather than a coin | ⚠ Invisible: the app never shows the walk-back that decided it |
| 3 | **The honor can DIE** rather than staying with a beaten holder | He was beaten; keeping it would pay him for losing | ⚠ Nothing in the app announces this when it happens |
| 4 | **A subset of the roster can play** | It is a side bet as often as a group game | Settled — and it is the only casual game here with a participant picker |
| 5 | **Pool settlement is in the engine but not on the screen** | Only the three per-point modes are offered | ⚠ Either surface it or delete it; a settlement style nobody can choose is dead weight |
| 6 | **`vs Average` is the default** | Matches Points 5-3-1; Spots differs | ⚠ One ruling across all three |
| 7 | **The stake is the round's bet unit** | Honors reads `Round.bet_unit` directly as the value of one point and has no field of its own | Correct as built |

---

## 4. Shared components it already uses

- `HandicapModeSelector`, `StakeField`, `SectionCard`, `GolfAppBar`
- **The settlement trio** shared with Points 5-3-1 and Spots
- The participant checklist is bespoke to this screen

---

## 5. Still open

- **A play surface of any kind.** Who holds the honor, how long they have held
  it, and when it died. This is the recommendation of the batch.
- **The walk-back and the death** (decisions 2 and 3) are the two moments the
  game turns on and the app narrates neither.
- **Pool settlement** (decision 5) — surface or delete.
- **No web view, no lock-screen card, no receipt, no How to Play** beyond the
  prose block.

---

# Play

## 6. There is no play surface. This is the whole document.

Honors has **no play screen, no card under score entry, no strip and no
indicator anywhere in the round.** A golfer plays eighteen holes and learns the
state of the game only by leaving score entry for the leaderboard.

That is a gap in a way the other seven are not. Points 5-3-1 and Wolf have
screens design has not drawn; Fourball, Vegas and Singles Match have cards;
Spots has its stepper. Honors has nothing.

## 7. What a surface would have to carry

Written here because the game's own rules dictate it, and because they are the
argument for building one:

| Fact | Why it cannot live only on the leaderboard |
|---|---|
| **Who holds the honor right now** | It is the entire state of the game, and it changes on a hole a golfer may not have watched |
| **How many holes they have held it** | Points are holes held — the score IS this number |
| **That a tie was kept rather than won** | "A tie doesn't beat you" is the rule golfers argue about, and the app currently resolves it in silence |
| **That a contested tie was broken by walking back** | The winner was decided by a hole played earlier. Nothing shows which |
| **That the honor DIED** | Two golfers beat the holder, could not be separated, and the token went loose. Nobody is told |
| **That it is still loose** | Before anybody wins a hole outright, no point is awarded at all |

## 8. Decisions taken with no rule to follow — Play

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 8 | **No surface was built** | Honors shipped as a side game whose state the leaderboard could report | ⚠ This is the recommendation of the whole batch |
| 9 | **The three silent moments** — the kept tie, the walk-back, the death | Each is derived correctly by the engine and reported nowhere | ⚠ These are what a card would be FOR |

## 9. Still open — Play

Everything. The smallest useful thing is a one-line strip under score entry:
who holds it, for how long, and a word when it changes hands or dies.

---

# Leaderboard

Card: `_HonorsGroupCard`, one per group. Web view: **no**. Lock screen: no.

## What the card draws

| Block | Content |
|---|---|
| Header | `Group N`, and right-aligned `Honors · Pool` (or `Pay leader` / `Above you` / `vs Average`) |
| Status line | The raw slug, and right-aligned **`Holds honor: SR`** in the primary colour when somebody does |
| One row per golfer | Name, `N pts`, money — always signed `+$X` / `−$X` in win/loss colour, including `+$0.00` |
| Field average | `Field average: 4.5 pts` — the number the `vs Average` payout settles against |
| **Honor by hole** | `_HonorsHoleStrip` — one chip per hole that had a holder: hole number and who held it after that hole. A hole **won outright** is bold and tinted; a **carried** hole (tie, held on) is muted. Holes with no holder are dropped entirely |

## Decisions taken with no rule to follow — Leaderboard

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **Who currently holds the honor is in the header, not just the strip** | It is the one live fact in the game and the strip is history | Good |
| 2 | **Won outright and carried are drawn differently** | Bold-tinted against muted. Holding by tie is not the same achievement as taking it | ⚠ The best per-hole treatment in the set, and undocumented anywhere — there is no legend saying what muted means |
| 3 | **Field average is printed** | `vs Average` settles against it, and otherwise the reader cannot check the money | Good, and the same argument as Stableford's points table |
| 4 | **Money is always signed, even at zero** | `+$0.00` | Drift — three cards, three treatments of zero (umbrella finding 2) |
| 5 | **Holes with no holder vanish from the strip** | Only `holder_short != null` holes are kept | Worth revisiting: a gap in the hole numbers is unexplained, and a hole nobody took is a fact about the round |
| 6 | **`Group 1` prints on a one-group round** | No `_single_group` | Fix |

## Still open — Leaderboard

- **A legend for the muted chips** (decision 2). The distinction is the best
  thing on the card and nothing tells the reader it exists.
- **No web view.**
- Holes with no holder (decision 5), zero money (4), `_single_group` (6).
