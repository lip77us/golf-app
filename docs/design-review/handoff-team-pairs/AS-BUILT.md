# Pairs Play — as built

What shipped from the `handoff-team-pairs` packet, and every place it differs.
Written to go back to design, and a companion to
`../handoff-team-play/AS-BUILT.md`, which still stands. The shareable version
of this document is an Artifact; this file is the copy that lives with the
packet.

The build follows the packet closely and every worked figure reproduces:
Maiolini 4 and Yau 19 get **4** in a scramble, **3 / 16** in best ball, **12**
in an alternate shot and **10** in both Scotch and Chapman; the drawn field of
six pairs comes out 4, 5, 5, 5, 4, 7 and the balance strip reads **4 – 7**.

**One structural assumption did not survive contact with a real event**, and it
is the first section below. The rest is smaller.

---

## 1. The group is not the team

> **This is the one to read.** It changes a rule the packet inherits from the
> four-golfer flow and states as settled.

`handoff-team-play` says **the group IS the team**, and for fours that is true:
four golfers are both the scoring unit and the playing unit, so one Foursome is
one team, one tee time, one scorer and one card.

**It does not hold for pairs.** Two pairs go out together. They share a tee
time, they share a scorer, and one person keeps the card for all four — but
they are two separate teams on the board. Built literally, every pair became
its own group: its own tee time, its own scorer, its own card. A six-golfer
event produced three tee times for what is two groups of golf.

So a team is now a **slot inside the playing group**. Slot 1 *is* the team,
which is why the whole four-golfer flow is untouched by construction — all 138
of its tests pass unchanged — and pairs simply add a slot 2.

What follows from it:

| | Packet | Built |
|---|---|---|
| Groups | `[2, 2, 2]` for six golfers | **`[4, 2]`** — two pairs to a tee time, a twosome when the pair count is odd |
| Tee sheet | a row per pair | a row per **playing group** |
| Scorer | one per pair | **one for the foursome** |
| Card | one per pair | **one for the foursome**, carrying both pairs |
| Board | a row per pair | unchanged — a row per pair |

The card sends a block per team and the screen stacks them, sharing the hole
header, the rules and the hole navigation, because those belong to the four
golfers walking the course. Scores, drives and rotas each name their slot.

**The split is the order the TD dragged them into on Groups & Tees** — first
two golfers are one pair, next two the other — with an endpoint to change it
and a refusal once a score lands, since re-pairing then would move scores
between teams. Three golfers in **best ball** default to one team of three,
the packet's own odd-field way out and the only shape three can legally take.

**Consequence for the packet's claim that only steps 3 and 5 change.** They are
not the only two, and this is the third thing that makes it so — see §2.

---

## 2. Differs from the packet

| # | Packet | Shipped | Why |
|---|---|---|---|
| 1 | Pairs are a **team-size control on step 1** under one `Team Play` card | **Two picker cards** — `Foursome Play` and `Pairs Play` — routing into one flow | ⚠ *Still the one we would most like a ruling on.* The packet's argument is "do not duplicate seven screens to change two", and nothing is duplicated: same step flow, same config row, same widgets. But the shipped product name is **Foursome Play**, and "Foursome Play — team size: pairs" is a contradiction on screen. |
| 2 | A **build-pairs screen** with a tray and a balance strip | **No build step** | Carried over from the fours build: Groups & Tees already assigns. The balance strip and the per-golfer contribution live on the handicap step, and the odd-field block gates Next there. |
| 3 | Pair name **defaults to the two surnames** | Same, on the team's own row | It cannot live on the Foursome — that is the PLAYING group's name and two pairs share one. Cap raised to **24**: `Petersen & Reilly` is seventeen characters, so the ball game's 16 rejected most real pairs *and* silently kept a stale name in their place. |
| 4 | (not stated) | **Clearing a name resets to the default, not the colour** | Contradicted the fours decision that an unnamed team is `Group N`. **Changes fours behaviour too.** |
| 5 | *Maiolini plays the second shot* | Surname on the card, full name elsewhere | The packet is right; a full name wraps and reads nothing like the way a pair talks. |
| 6 | "Three of four / three of five formats reject a three-ball" | **Four of the five** | Best ball allows it; the other four do not. The packet gives the count three different ways and undercounts in all of them. The argument is unaffected. |
| 7 | "Only **two** steps behave differently" | **Three, and arguably four** | The drive step is the third — the packet's own §5 makes it so. Groups & Tees is the fourth, per §1. "Nothing else in the flow knows the team size" is otherwise the load-bearing claim. |

---

## 3. Rulings taken during testing

Each departs from the packet, so each wants a look rather than only a docstring.

- **No drive requirement, no asking who drove.** The packet argues the Scotch
  tap should be mandatory because picking the drive says who plays next. A pair
  on the tee already knows that, and recording it buys the app a sentence and
  the golfers nothing. Set a quota and the tap returns, sentence included,
  because then it is counting something.
- **The drive quota scales with the team size.** Two golfers sharing nine holes
  can be asked for **four drives each per nine**, and **nine each across
  eighteen**. The shipped 2-and-4 was four golfers' answer hardcoded; the real
  ceiling is the window's holes divided between them.
- **Twelve colours, and they recycle.** Team 13 is Pine again. Confirmed as
  wanted rather than widened: the palette already carries three greens and four
  ambers. **Colour is a finding aid, never an identifier** — every board row
  carries its name, and the scorecard labels its rows by initials. The one
  place it must hold is inside a playing group, where two pairs share a card;
  the ordinal is derived from `(group, slot)` so those two are always
  consecutive and never equal.
- **`gets N` came off the entry row and went onto the card and the board.**
  Beside one hole's dot it restated the round where nobody uses it. Removing it
  entirely went too far: two pairs post the same 6 on the same hole and come
  out a stroke apart, and nothing said why. It now sits above the scorecard,
  over the dots it accounts for, and on the board row beside the roster.
- **`gets` reads differently in best ball, and that is the point.** The four
  one-ball formats end off ONE figure — `gets 38`. Best ball keeps the
  allowance per golfer, so its team total is a balance number nobody receives;
  printing it would invite subtracting 64 from a ball scored off 30. It reads
  `gets 30 / 34`.
- **Three stroke dots, not two.** A pairs figure is big — alternate shot takes
  50% of the *combined* handicap, so two golfers off 35 and 40 get 38, which is
  three strokes on the two hardest holes. The card capped its dots at two and
  the entry box drew one dot off a boolean, so a hole carrying three looked
  like a hole carrying one while the net and the picker both worked off three.
  Three is the true ceiling: the largest playing handicap the app allows is 54,
  which is exactly three a hole.
- **One picker for the playing group.** Best ball opened one inside each pair's
  block and put two on screen at once, which nothing else in the app does.
  Scramble keeps two, correctly: there each pair enters ONE number, so they are
  two teams' scores rather than two cursors.
- **A named pair still shows its golfers' initials on the scorecard.** Name a
  pair "The Ringers" and the board and the entry block say so while the grid
  row says `B & P`. Deliberate: the card is where somebody enters scores for
  PEOPLE, and the label column is 58 pixels.
- **Golfers, not men.** Coed play is the expectation, so the copy does not
  assume otherwise anywhere in the flow. `men's` and `women's` survive in
  exactly one place — the names of the tee sets and their stroke indexes —
  because there the distinction is the meaning.
- **`plays off` is match-play language.** This is stroke play, so the copy says
  `gets`. Kept only where the app really does mean strokes off the low index,
  which is Cup-only.

---

## 4. Defects found and fixed on the way

Several of these predate pairs and affect the shipped four-golfer flow.

- **A one-ball round could not be completed — ever.** It posts a
  `TeamHoleScore` and no per-golfer scores, and both the completion check and
  the holes-remaining count read the per-golfer table. **Every scramble round
  shipped so far was permanently unfinishable.** Not a pairs bug; pairs
  quadrupled the formats that hit it.
- **The alternate-shot rota card is built, closing the fours gap.**
  `../handoff-team-play/AS-BUILT.md` lists it as still open — the endpoint was
  written and tested and nothing called it. The card now calls it at both
  sizes.
- **The tee sheet ignored the team's name**, making it the one surface that
  did. It now also names the event and lists who is in each group: a tee sheet
  with no names is a list of times, and finding your own group is the one thing
  anybody opens it for. (Twice during testing a sheet from a *different*
  tournament was read as a grouping bug.)
- **The review step labelled a finished pair "+ 1 phantom."** Nothing was ever
  created — "anything under four gets a phantom" was written out longhand
  wherever groups are drawn.
- **Expanding one pair on the board expanded the other** in the same foursome:
  the open row was keyed on the foursome id, which two pairs share.
- **Three of the six formats lost their scorecard.** Two checks tested the
  format *name* rather than the card it takes, so alternate shot, Scotch and
  Chapman fell down the own-ball branch and iterated a list the server
  correctly sends empty — no score line, no dots, only the net.

---

## 5. Implementation notes design may care about

- **Best ball is a shamble whose count is 1.** It reuses the whole own-ball
  path with two rows instead of four. Best-1 on a par 4 is a par of 4, which
  falls out of the existing arithmetic for free.
- **Nothing branches on a format name.** `plays_one_ball` / `plays_own_ball`
  replaced eleven checks; a seventh format is a table entry.
- **All four one-ball tables are positional**, so 50% of the combined is stored
  as `(50, 50)` and needs no special case. The screen still reads it back the
  packet's way.
- **The card lost two header rows a team.** It had three — the team heading,
  the score row's label, and a "Scorecard" bar — each naming the same team.
  Now one, and one scorecard for the foursome rather than one per pair, since
  Hole, Par and Index belong to the course.

---

## 6. Still open

- **Mid-round withdrawal** is not wired into this shape, unchanged from the
  fours build. An own-ball hole counts only when every ball is in, so a
  withdrawal stalls a pair as it stalls a shamble team.
- **The handicap dots on the card** remain the deliberate departure the fours
  as-built flagged, and still want a ruling.
- **Flights and multi-round team events** — deferred exactly as the packet
  leaves them.
- **Odd-field repair is not on the block.** It names the golfer and states the
  three ways out, and Next waits on it, but the fix happens back on Groups &
  Tees rather than by dragging.
- **The rest of the app still caps stroke dots at two**, in nine places
  including the shared net-score button. It only misreads for a golfer off 54,
  it is every game's notation, and changing it was not this build's business.
