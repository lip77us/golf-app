# Fourball — as built: Setup

**There is no packet for this game.** Design has never drawn its setup screen,
so this is not a packet-versus-shipped document: there is no rule of design's
that got broken. It is the other half — what the screen does today, and every
choice taken in the absence of a rule, so the next drawing starts from the
real thing rather than from the code.

Screen: `mobile/lib/screens/fourball_setup_screen.dart`.
Engine: `services/fourball.py`. Play is a separate document.

---

## 1. Fourball does not own a play screen, and that shapes setup

> **This is the one to read.** It explains why the setup screen ends by
> launching something else.

Sixes, Banker, Sequoya and Rabbit each own a screen where the game is played.
**Fourball does not.** Setup hands off to the app's shared score entry
(`/score-entry`), and the match state lives on the leaderboard.

So this screen is the *entire* surface of the game's configuration, and the
last thing it does is leave. Two consequences design should know before
drawing anything:

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
| 3 | **The stake is the ROUND's bet unit, not the game's** | Saving here calls `updateRoundBetUnit`, so it moves the figure every other game in the round reads | ⚠ Real risk on a multi-game round: setting the Fourball stake silently restakes the side games |
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
  beyond two sentences of prose on this form.
- **No web view.** The watch page set does not include fourball.
- **The lock-screen card exists** — Fourball and Singles Match share one
  `match` card, since a single match over eighteen holes differs only in how
  many names sit on a side.
- **The stake's scope** (decision 3) is the one item here I would put in front
  of design before it is drawn, because the fix is a screen change rather than
  a copy change.
