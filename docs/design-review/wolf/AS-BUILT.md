# Wolf — as built

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/wolf_setup_screen.dart`.
Engine: `services/wolf.py`. Setup is Part 1 below; Play follows it in the same file.

---

# Setup

## 1. It has a play screen design has never seen, and the most setup of any game

> **This is the one to read.** The empty PLAY cell means *not drawn*.

`/wolf` is a dedicated play screen — the Wolf's choice each hole has to be
recorded somewhere, and that is where. Nothing under score entry.

And this is **the most configurable game in the app**: five sections, three
point values, four switches and a rotation order. Every one of them is a real
decision a group makes on the first tee, which is why they are all on the
screen — but nobody has ever looked at whether that is the right way to ask.

The game: each hole one golfer is the **Wolf**, taken from a rotation set at
setup. He tees last and chooses **Partner** (best ball, 2v2), **Lone Wolf**
(alone against the rest) or **Blind Wolf** (alone, declared *before* the
drives, for the biggest pot). Every hole nets to zero — the winning side
splits the pot, the losing side splits it back.

---

## 2. The screen, top to bottom

| Block | Control | Default |
|---|---|---|
| **Wolf rotation** | drag to order the golfers | Roster order. Wolf for hole H is `order[(H−1) % n]` |
| Handicap | `HandicapModeSelector` | SO Low |
| **Point values** | Lone / Blind / Team win | 3 / 6 / 1 |
| **Options** | *Wolf loses ties* · *Non-wolf bonus* · *Last place is Wolf on 17 & 18* · *Must go Lone or Blind* | off · off · **on** · off |
| **Cap losses** | switch + amount | off |
| Stake | `StakeField` | — |
| **How Wolf works** | prose | The only explanation in the app |

---

## 3. Decisions taken with no rule to follow

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **Zero-based scoring — every hole nets to zero** | The winning side splits the pot and the losing side splits it back, so no hole can leak points. It is what makes the money reconcile by inspection | Settled |
| 2 | **Last place takes the Wolf on 17 & 18, ON by default** | The catch-up twist most groups play. It is also the only default here that changes who does what, rather than what it pays | ⚠ On by default and buried in *Options*, four rows down |
| 3 | **Lone 3, Blind 6, Team 1** | Blind is double Lone because it is declared before anybody has hit | Settled |
| 4 | **The non-wolf bonus doubles a clean win against the Wolf**, off by default | It punishes a bad Partner choice, which some groups want and some think piles on | Settled as an option |
| 5 | **Rotation is fixed at setup, not drawn** | The order is a group decision, like Pink Ball's carrier order, and a draw would need a screen | ⚠ Sixes and Banker both got slot-machine draws. Wolf is the game where a draw would matter most and it has none |
| 6 | **Four switches, three numbers and an order on one screen** | Every one is a real rule a group sets | ⚠ The honest question for design: this is the most complex setup in the app and it has never been through a pass |
| 7 | **The stake is the round's bet unit** | Wolf has no stake field of its own | Correct as built |

---

## 4. Shared components it already uses

- `HandicapModeSelector`, `StakeField`
- `_SectionCard` — **note the underscore: Wolf has its OWN private copy** of
  the section card rather than the shared `SectionCard`, and it takes a
  `subtitle` the shared one does not. That divergence is worth closing in
  whichever direction design prefers

---

## 5. Still open

- **A draw for the rotation** (decision 5) — the pattern exists twice already.
- **A pass over the whole screen** (decision 6). If any setup screen in the app
  is going to be over-asked, it is this one.
- **`_SectionCard` versus `SectionCard`** — one of them should win.
- **No web view, no lock-screen card, no receipt, no How to Play** beyond the
  prose block.

---

# Play

## 6. Where the game is played

**`/wolf` — a dedicated screen**, and the most eventful one in the casual set.
Nothing under shared score entry.

## 7. What the screen draws, top to bottom

| Element | Content |
|---|---|
| Hole header | Par, yards, SI — and a **set rotation** action, so the order can be changed mid-round |
| **Wolf decision panel** | Who the Wolf is; the **reverse-honors tee order** (worst on the previous hole tees first, the Wolf last); and the choice — *take as partner* on each non-Wolf row (4-player only), **Lone Wolf**, or **Blind Wolf** |
| Score rows | Ordered to match the tee order, not the roster, with an inline net-centred picker on the hot row |
| Outcome | The hole's result once it is both decided and scored |
| Points grid | 18 holes |

Everything on it — the Wolf's identity, the tee order, the decision and the
results — comes from `wolf_summary` and is refreshed after every score and
every decision.

## 8. Decisions taken with no rule to follow — Play

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 8 | **The tee order is computed and shown** | Reverse honors is a real rule of the game and the only screen in the app that draws a tee order. It also orders the score rows, so entry follows the group up the tee | Settled, and the best idea on this screen |
| 9 | **Blind Wolf is not gated** | The rule is that it must be declared *before* the drives, and nothing in the app enforces or timestamps that — it is honour-system, like a called press before the app had one | ⚠ The one place this game can be cheated, and it pays double |
| 10 | **The rotation can be changed mid-round** from the hole header | Groups reorder | ⚠ No record of the change, so a rotation edited on the 12th silently rewrites who was Wolf on the holes behind it |
| 11 | **The outcome appears only when decided AND scored** | A hole with scores but no decision has no result to report | Settled |

## 9. Still open — Play

- **Gating or stamping Blind Wolf** (decision 9). At double the pot it is the
  one decision in the app with no record of when it was made.
- **A record when the rotation changes** (decision 10).
- Wolf has the most configuration and the most per-hole decision-making of any
  casual game, and neither its setup nor its play screen has been through a
  design pass.
