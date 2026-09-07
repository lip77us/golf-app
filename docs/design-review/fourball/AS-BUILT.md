# Fourball — as built: Setup

**There is no packet for this game.** Design has never drawn its setup screen,
so this is not a packet-versus-shipped document: there is no rule of design's
that got broken. It is the other half — what the screen does today, and every
choice taken in the absence of a rule, so the next drawing starts from the
real thing rather than from the code.

Screen: `mobile/lib/screens/fourball_setup_screen.dart`.
Engine: `services/fourball.py`. Play is a separate document.

---

## 1. The play surface is under score entry, and that is the intended shape

> **This is the one to read**, and it corrects what the coverage table
> implies. Fourball's PLAY cell is empty because design has not drawn it —
> **not because there is nothing there.**

Sixes, Banker, Sequoya and Rabbit each own a screen where the game is played.
Fourball does not, and does not need one: setup hands off to the app's shared
score entry, which carries the whole game beneath the score boxes.

| Under score entry | What it draws |
|---|---|
| Match status card | Both teams in their colours, the margin, `thru N` (holes COMPLETED, so it reads right on a shotgun start) and the handicap label — `Gross`, `Net 90%`, `Strokes-off` |
| Per-hole progress grid | Hole, par, the four golfers grouped and tinted by team, and a **Won by** row. The score that actually won each hole — the winning team's best ball — is highlighted in that golfer's own cell |

That pair is the model for what a game without its own screen should look
like, and it is worth drawing as such rather than being treated as a gap.

The setup screen is therefore the entire surface of the game's
*configuration*, and the last thing it does is leave. Two consequences:

- A configured game **bounces straight past this screen** to score entry on
  the normal route. You only see the form again by coming from the hub's *Edit
  configuration*, which flips the title to `Edit Fourball` and the button to
  `Save Configuration`.
- There is no second place to change the stake or the teams mid-round. This
  form is it.

---

## 2. The screen, top to bottom

| Block | Control | Notes |
|---|---|---|
| Roster gate | — | Under or over four golfers the body is replaced by one sentence: *Fourball needs exactly four players (two teams of two).* No partial state, no disabled form |
| **Teams** | `TeamSplitter4` — drag to reorder, partners share a colour | Order is the assignment: slots 1–2 are team 1, 3–4 are team 2 |
| **Handicap** | `HandicapModeSelector` — `Net` / `Gross` / `SO Low` | A 50–130% slider appears only under Net |
| **The Match** | prose + `StakeField` | Labelled `Match stake ($ per player)`, with the *Play for fun — no stakes* opt-in |
| Action | `Start Fourball` / `Save Configuration` | Disabled until the roster is valid **and** a stake decision has been made |

---

## 3. Decisions taken with no rule to follow

Each of these is a choice somebody had to make on the way to shipping. They
are the ones worth a ruling.

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **Strokes-off-low is the default**, not net | A fourball is a MATCH, and a match is played off the low ball. Full net hands the high golfer his whole allowance inside a single 18-hole match | The other match games now agree, so probably settled |
| 2 | **Start stays disabled until a stake is chosen** — a number typed, or *Play for fun* ticked | A game that silently starts at $0 produces a leaderboard full of zeroes nobody meant. The gate forces a conscious answer once | ⚠ This is a house rule visible on several setup screens and design has never signed off on it |
| 3 | ~~The stake was the ROUND's bet unit~~ — **fixed** | Saving used to call `updateRoundBetUnit`, the figure Honors and Nassau read as their own stake, so a $20 fourball silently restaked every side game on the round. `FourballGame.bet_amount` is the game's own field and the only one its settlement reads | Fixed — the round's unit is left where the round set it. **The other eleven setup screens still do this**, and some of them must: a game with no stake field of its own has nowhere else to keep it |
| 4 | **Teams are fixed for all eighteen holes** | It is one match, so there is nothing to rotate. Contrast Sixes and Sequoya, whose pairings move and whose colours therefore belong to a segment rather than a golfer | Settled by the format |
| 5 | **One bet, no press and no carry** | The winning team collects the stake per player and a halved match is a push. Nothing on the screen offers more | Presses are drawn for Nassau and Sequoya; a fourball press is a real game and is simply not built |
| 6 | **The net-double-bogey cap is deliberately off** | Match play decides each hole on the actual net score. The cap is a stroke-play device and would quietly change who won a hole | Settled, but it is invisible on the screen |
| 7 | **The close-out is automatic and unannounced** | `3&2` falls out of the engine; holes after it do not count. Setup says so in one line of prose and nothing else in the app repeats it | ⚠ A golfer who does not read that line finds out at the leaderboard |

---

## 4. Shared components it already uses

Design gets these for free anywhere else, and changing one moves every screen
that draws it:

- `TeamSplitter4` — the drag-to-pair control (also Vegas, and the Cup builders)
- `HandicapModeSelector` — Net / Gross / SO Low plus the percent slider
- `StakeField` — the stake box and its *Play for fun* opt-in
- `SectionCard` — the bordered block every setup screen is made of

---

## 5. Still open

- **No How to Play.** Nothing in the app explains best-ball or the close-out
  beyond two sentences of prose on this form — and the close-out is the rule a
  golfer meets without warning.
- **No web view.** The watch page set does not include fourball.
- **The lock-screen card exists** — Fourball and Singles Match share one
  `match` card, since a single match over eighteen holes differs only in how
  many names sit on a side.
- **The stake's scope on the other eleven setup screens** (decision 3).
  Fourball is fixed; Sixes, Rabbit, Wolf, Honors, Survivor, Vegas, Skins,
  Points 5-3-1, Nassau, Triple Cup and the onboarding wizard all still write
  the round's unit. For some that is correct — Honors and Nassau read
  `Round.bet_unit` as their stake and have no field of their own — so it is a
  per-game question rather than one sweep.
