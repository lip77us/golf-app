# Wolf — as built: Setup

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/wolf_setup_screen.dart`.
Engine: `services/wolf.py`. Play is a separate document.

---

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
