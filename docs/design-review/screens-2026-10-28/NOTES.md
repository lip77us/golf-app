# Leaderboard: what changed — 28 Oct 2026

Three screens off the iPhone 17 Pro Max simulator, against a live local
server. Real rounds, real scores — nothing mocked.

Two of these came out of playing a round, not out of a packet, so they are
offered for review rather than built to a spec.

---

## 01 · Nassau, Claremont — `01-nassau-claremont.png`

### a. The settings strip (new)

`Strokes off · Claremont · Auto presses`, under the game switcher.

Asked for as *"it would be good to know the settings that I am playing with
in the leaderboard — in all games."* It appears on **every** board, not just
Nassau: the handicap mode and allowance, the variant, presses, carry, the
payout style, and a loss cap when there is one.

- **Neutral outline chips, never filled or coloured.** Green is the app's
  voice for something happening *to* you — strokes, bets, doubles — and a
  handicap allowance is a fact about the round. Same reasoning as the
  combo-tee chip.
- **The words come from the server**, one writer for the whole app, so two
  boards cannot describe the same rule differently.
- **The stake is deliberately not there.** Its unit changes per game — a
  hole, a skin, a point, a ball — and every board already carries its own
  money line.
- Where two groups in one round play different allowances, the strip moves
  off the tab and onto each group's own card, rather than stating one
  group's rules over both.

### b. Claremont's two balls (new)

`BALLS · LOW / 2ND`, two rows under the hole tiles, then the hole's points.

Reported from the course: *"I don't see the bottom row with the high and low
balls."* Claremont's bottom bet is two points a hole — one for the lower low
ball, one for the lower second ball — and the board showed the points total
without the numbers it is made of, which makes it a figure nobody can check.

- A row per side, in that side's own colour, in the same order as the sides
  card above. **No label column**, deliberately: the nine-wide alignment
  with the tiles is the point, because a hole is read straight down.
- The ball a side **won** is bold in its colour; a lost or halved ball stays
  plain, so the two points on the hole are legible without a legend.
- Unplayed holes keep an empty outlined cell, so the row still reads as
  nine holes.

**Open question for you:** three rows (two sides + points) is the densest
block on this card. It earns the space on Claremont, where it is the whole
bet — but if it reads heavy at 390pt we could drop the points row and let
the `Points` line above carry it alone.

---

## 02 · Stroke Play — `02-stroke-play-no-strip.png`

**No strip here, on purpose.** That board already owns an explicit
Gross / Net / Strokes-off selector, and the chip states the game's
*configured* mode — a different fact on the same axis. Side by side they
read as a contradiction: the first build drew `Net` directly above a
highlighted `Strokes-off`.

The one exception is an **allowance below 100%**, which the three selectors
cannot express. `Net 90%` is a fact about the money that nothing else on
that board carries, so there the strip stays.

**Known, not fixed:** the `gets 1` / `gets 10` chips under each name are on
your existing cleanup list — about fifteen call sites across the app.

---

## 03 · Skins — `03-skins-board.png`

The skins board built from your packet, in production use. Showing it here
mainly for two things:

- The settings strip in a second context — `Strokes off · Carries on · Pool`.
- **The validation rules sit under `HOLES`**, as a footnote on the grid
  rather than as their own chip: they decide what it takes for a tile to be
  won at all, which is why a hole can carry with nobody tied. The second
  line states the consequence, because that is the part a golfer cannot
  infer.

Also fixed in this pass: the group header read `Pool: $40.0` — money with a
stray decimal, beside a ledger that formats every other figure properly.

---

## The game switcher

Visible at the top of all three. Built this pass from the shared spec that
four separate packets had each asked for — segmented, sized to each label,
scrolling and centring past five games, and the thumb tracks a swipe between
boards rather than jumping. It replaced the Material underline tabs the app
had been using, which that spec rules out by name.
