# Sequoya 3s — as built

What shipped from the `handoff-sequoya-threes` packet, and every place it
differs. Written to go back to design. Setup, play, presses, the leaderboard,
settlement and the Live Activity card are all in; the card came off
`UNSHIPPED_KINDS` in the 2.8.1+32 build. **The pushes are not built** — §6.

The packet held up unusually well. Six three-hole 2v2 matches on one foursome,
the pairing rotating every third hole, presses as separate bets rather than
multipliers, the auto press visibly caused — all as drawn.

**One rule did not survive the course**, and one took three passes to get right.
They are the first two sections.

---

## 1. A press covers the hole being played

> **This is the one to read.** The packet's rule makes the classic press
> impossible in a three-hole match.

The packet: *the trailing side may call one press by hand from hole 2 onward.
It opens a bet on the holes remaining after the call.*

Reported from the course, standing two down on the 9th tee with no press on
offer. In a three-hole match "the holes after the call" means the last hole can
never be pressed — hole 10 belongs to the next match and a different pairing —
which leaves exactly one pressable hole per match, always covering exactly one
hole.

**A press is called on the tee, so it covers the hole being played.** Called
while looking back at a hole already in the book it still starts on the next
one: nobody may press a result they have seen.

---

## 2. The press duplication rule, and the exposure ceiling that moved twice

Worth recording in full, because two intermediate states shipped and each
changed the setup screen's own exposure line.

1. **A called press could sit on top of an auto press.** Reported from testing:
   Paul won hole 1, which opens the auto press over holes 2–3, and Aldo was
   still offered a press over the same holes. Two bets over the same holes can
   only settle the same way. That is a double, not a press.
2. **A blanket ban was then too narrow.** Lose the first two holes and the match
   bet is closed out while the auto press sits dormie, so a fresh level bet over
   the last hole repeats neither — a real press, and unreachable. The setup
   screen said **2×** during this period.
3. **Where it landed: refuse for DUPLICATION.** Refuse when a live bet is
   *level* with exactly the holes this press would cover still to play, because
   two level bets over one set of holes settle identically. A bet carrying a
   margin is not a twin.

So a match carries three bets again and **the Manual + Auto ceiling is back to
3× — the packet's own $90 at a $5 stake.** The packet's number was right; the
rule that reaches it is not the one the packet describes.

On the second hole of a match, where the auto press genuinely is the twin, the
press card says **"Auto press on"** and greys out. There is nothing more to
explain than that a press is already in play over those holes.

---

## 3. Differs from the packet

| # | Packet | Shipped | Why |
|---|---|---|---|
| 1 | the offered-press frame is **amber** — "the one that carries the design" | **the calling side's own blue or orange**, with the side bar the score rows carry | Amber said only *something is on offer*, and being orange-ish it read as the ORANGE side's — a coin-flip lie on a card belonging to exactly one pair. The **auto** press card stays grey: it opened by itself and belongs to the match |
| 2 | all four see the card, **only the eligible side can act** | the card **names the pair** — `Paul & AB can press — covers hole 6` — and anybody may call it for them | One phone scores the group and the man who is UP usually holds it, so gating on the reader's own side hid the offer precisely when it was wanted. The call is *attributed* only when the reader is on that side |
| 3 | the manual press **expires** | it is derived from the position — it appears when a press is legal and goes when it stops being | Nothing is issued and timed; the position does the work "expiring" was doing |
| 4 | **Team A / Team B** | **Side 1 / Side 2** | The pairing rotates every third hole, so a side is a side for this match only. "Team" implies something that lasts the round |
| 5 | handicap is Net / Gross / Strokes Off, no default named | **strokes off the low ball by default** | Six 2v2 matches are a match game; full net hands the high golfer his whole allowance inside three holes |
| 6 | the by-hole side tint follows the golfer | **per hole** — the side rides on each score | Every other team game puts a golfer on one side all round |
| 7 | the play banner header | plainer — `Match 1 · holes 1–3`, `$5 per golfer · 1 bet`, states in sentence case; `OF 6` gone | The strip below already shows all six; the header's job is the match being played |
| 8 | a per-match money total | **removed** | Three bets on one match can be a win, a loss and a half — $0 — so "$15 per golfer" claimed what the rows underneath contradicted. Each row carries its own stake |
| 9 | (not stated) | **the field is named once, in full, at the top of the card**, initials everywhere below | Pairings appear six times over; four full names will not fit beside each other that often |

---

## 4. Rulings taken during testing

- **Score entry does not re-sort the group.** It grouped the rows into side 1
  and side 2, so a rotating pairing meant hunting for your own name on every
  fourth green — and Sixes, which this card is modelled on, does not do it. The
  rows sit in one order all round, the same order the scorecard draws, and the
  **side moves under them**: a coloured bar down the left of each row, the
  pairing named once above in the two colours. Partners are the two rows
  sharing a colour, which is matching rather than reading.
- **Side names are always the side's colour, win or lose.** Tinting only the
  winner made blue mean "won here" in the match list and "side 1" in the
  scorecard on the same page — one colour saying two things. Who won is in the
  state column.
- **The match box loses a row.** The match label moved into the middle of the
  pairing row, where the "v" was; it separates the two sides exactly as well and
  costs no row of its own.
- **A press in play is a state, not an error.** `Press already called in this
  match` read as a rejection of something the group had just deliberately done.
  Both cards now report: what is in play, over which holes, and whether it can
  still be taken back.
- **A press called by mistake can be taken back**, but only before a hole it
  covers has been played. The tap was free; the bet is not, and a bet the group
  has played is a settlement question rather than an undo.
- **The standings count every BET, not every match.** A golfer read 2–1 up and
  $0 richer, which looks like an arithmetic error rather than what it was: a
  press that went the other way. Won–lost–halved is over all bets, so net
  reconciles by inspection, and ties break on the bet record — the record the
  money is made of. The match record is still shown, in the Matches pane, where
  a match record belongs.
- **The scorecard sits under both leaderboard panes**, not behind a third tab.
  It is the shared reference the Matches and Standings panes argue about.
- **One vocabulary throughout: "per golfer", never "a man".**

---

## 5. Settlement and the Live Activity

**Settlement** is built as drawn, with one departure and one clarification.

- *The departure:* the packet assumes a hand-called press has a caller. On one
  phone the scorer routinely calls a press **for** the pair that is down, so no
  author is recorded and the line read "called by the trailing side" — naming
  nobody, which defeats the point of listing it. It names the pressing **pair**
  in that case.
- *The clarification, stated on the screen:* nets are real, pairwise debts are
  not. The stake is a man a match, so two losers owe twenty and two winners are
  owed ten each, and nothing in the format says *which* winner a given ten
  dollars belongs to. The four nets are the assertion; the handovers below them
  are the shortest way to make those numbers true, never a record of who beat
  whom. The ticks are local and cosmetic and say so: the app does not move
  money.
- A halved match still appears on the receipt at zero. Six matches were played,
  and a receipt showing five invites the question the receipt exists to prevent.

**The Live Activity** follows the packet's anatomy — Sixes' three rows, both
locked corners, the neutral scoreboard. Two differences, both from the
three-hole match:

- **The press rides with the money, not the headline.** A match that quietly
  picks up a second bet is the one number a reader cannot derive from anything
  else. It cannot go in the top row, which is locked to hole/par/yards across
  the set, and it must not take the headline, which belongs to the match state.
  So it sits in the footer beside the total at risk, cause printed with effect.
- **The sides belong to the match, not the round** — blue means side 1 of the
  match being played, not a colour held for eighteen holes.

The state word is only ever true of the position: `DORMIE` when the lead equals
the holes left, `CLOSED` when the match is decided early, an em dash otherwise.
One up with two to play is not dormie. **The press offer deliberately does not
take that slot** — an activity showing an offer with no way to accept it is
worse than one that stays quiet. The final frame answers the question only this
format produces: you partner every other golfer exactly twice, so the round
knows the record and the partner you did best with.

---

## 6. Defects found and fixed on the way

Two of these are not Sequoya's and affect every game.

- **The scorecard's label column scrolled away**, so by hole 12 the rows were
  anonymous. The grid is now a pinned label column beside a scrolling cell
  column. This is the shared `HoleGridScorecard`, so **every game gets it**.
- **Foursome memberships came back in no order at all** — no `ordering` on the
  model — so two queries genuinely disagreed. That is how the scorecard listed
  the four golfers in one order while score entry, reading the same foursome
  through the serializer, listed them in another.
- **The scorecard showed strokes only on holes already played.** It inferred the
  allocation from gross minus net, so a stroke appeared once the hole was in the
  book — by which point the golfer no longer needed to know.
- **The score-entry hot spot followed roster order**, jumping a golfer to his
  opponent and then his partner. It now walks the order the screen draws.
- **A close-out reverted to "1 up · final".** The match bet closed 2 & 1 on hole
  5 and hole 6 was then played for the press, so the margin kept moving. Unique
  to this game — elsewhere the holes after a close-out are not played. The label
  reads off the hole it closed on.
- **Spots had no capture control** on a Sequoya round: `allowsSideGames: false`
  blocks overlays but not capture add-ons.
- **`sequoya_threes` was not wired into `services/settlement.py`**, so the
  round-level tab and the casual receipt were blind to a Sequoya round's money.

---

## 7. Still open

- **The pushes are not built.** The packet wants five pairing-change pushes and
  an expiring press offer, and rules the auto press out of pushing entirely.
  Six-plus pushes a round needs its own pass against the umbrella packet's
  budget first — the auto-press exclusion is the packet's own reasoning applied
  to the rest of the list.
- **The picker still offers a subset Nassau / Singles Match beside Sequoya.**
  That is the system's rule for a structure-owning primary (Sixes behaves the
  same), not an oversight — noted here in case design reads it as one.
