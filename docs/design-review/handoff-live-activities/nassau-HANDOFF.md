# Handoff — Nassau lock screen (Live Activity)

**One shipping surface, five states.** `live-activity-nassau.html` (card: **Nassau — lock screen**, group **Live Activities**, lives at `screens/live-activity-nassau.html`).

Companion: `handoff-sixes-lock/HANDOFF.md`. Read it first if you are building the container — the two activities share a frame, and this document is mostly about **where Nassau departs from it**.

---

## What it is

An iOS Live Activity for a Nassau: a neutral scoreboard for the two matches that are always live, plus a push when a press is called or a nine closes out.

Read-only. **No buttons, no CTA, no tap targets.** A press is a person's decision about money and it wants the app's confirmation; a mis-tap on a lock screen is expensive.

Covers **1v1 and 2v2**. Triple Nassau (3-player) is not in scope here — three simultaneous pairings will not fit this composition and needs its own pass.

## The one structural break from Sixes

Sixes had one match at a time, so it got one 36px number. **Nassau always has two matches live** — the nine you are playing and the eighteen — and there is no honest way to nominate one as the headline. So:

- **Two equal rows at 25px.** Nothing on the card is 36px. Both numbers are still the largest thing on the panel.
- **The sides are named once, at the top.** This is what pays for the second row. Sixes had to restate both pairings on every update because the pairing changed every match; **Nassau's sides are fixed at setup and never move**, so they are named once above the matches. Colour is stable for the whole round — blue is blue on the 1st and the 18th, in both matches — so a number can wear its side's colour and the reader never re-learns it.
- **The header names the hole, not the thru count.** `HOLE 12`. Two live matches means two remaining-hole counts, so one *thru* figure no longer does the work; each row carries its own `n TO PLAY`.

## The slots

| Slot | Content | Rules |
| --- | --- | --- |
| **Header** | Mark · `NASSAU` · `HOLE n` | Gains ` · 2v2` in the team variant. Right side is the hole being played, not holes completed. |
| **Sides** | Both sides, one line, colour dot each | Named once. Full names in 1v1; surnames in 2v2 (`Kelly & Moran v. Reid & Naylor`) — shrink-to-fit, and this is the longest string the design has to hold. |
| **Row 1** | Current nine: `FRONT 9` / `BACK 9` | Label, number in the leading side's colour, press chip if any, then leader surname or state word + `n TO PLAY`. |
| **Row 2** | `OVERALL` | Same shape. Always present until it settles. |
| **Footer** | Gross · stake left, **exposure range** right | `+2 · $5 a match` / `−$10 to +$20`. |

`ALL SQ` is white at 90% — never mint, which is the app's colour, not a side's.

## The exposure range

The slot the design is built around, and the answer to the question people actually have on the 14th — not *where am I* but **how bad can this get**.

**`settled ± the sum of every live stake`, presses included.** Midpoint is money already banked; half-span is what is still on the table. Both ends move on every settlement and every press.

**All three bets are live from the 1st tee.** The back nine has not been played but it is at stake, so a $5 Nassau opens at `−$15 to +$15`. Counting only the matches under way (`−$10`) is wrong — the slot is about money at risk.

Why a running total cannot do it: presses mean the amount at stake is not fixed at setup. Three open bets at $5 is a $30 swing; the same round after two presses is a $50 swing, and a running total reads identically in both.

Two properties worth preserving:

- **It includes settled money**, so it is a forecast rather than a bracket around zero. Win the front nine and the floor rises with you.
- **It converges.** Every bet that settles pulls the ends together, until on the 18th green they meet at the single number that is the final state. Same slot all round — no special final treatment.

**It must reconcile against the rows above it.** The rows make the arithmetic checkable, and a range that contradicts them is worse than no range at all. Four of the five states in the prototype had to be corrected for exactly this; treat it as a test in code.

## The states

1. **Front nine, 1v1** — nothing settled, range symmetric about zero at the full `±$15`.
2. **A press** — push above, activity already showing it: `+1 PRESS` chip on the row, range widened.
3. **2v2** — four names on one line, every other slot identical.
4. **Late, one row** — both nines settled, only the eighteen live. The card built for two rows holds one; the row keeps its size and nothing stretches to fill the gap. **The only point in a round where the floor is positive** ($10 banked against a single $5 bet), so the round cannot be lost.
5. **Final** — the range has converged: `+$15`, `Won the back nine, the press and the eighteen`, `Collect from Dave`. Holds a few minutes, then dismisses.

A **quiet** treatment is drawn (dark slab, numbers to 21px). Ship the loud one; quiet is the fallback if telemetry says people resent it running four hours.

## The settled nine leaves the card

It does **not** stay as a third row. It is over, its money is in the exposure figure, and a row that cannot change spends space on history. The footer picks up `both nines in` when both are done.

## Presses

**The press chip lives on the row that owns the bet**, not in the header. A press is a bet on one match; floating the count to the top would say the round has presses without saying which match carries them, which is the whole content. Orange, not mint — a press is not neutral, someone did it. Two presses on one match read `+2 PRESS`, not two chips.

## The pushes

Two events, and only two.

| Event | Copy |
| --- | --- |
| **A press** | `Dave pressed the back nine` / `A new $5 bet from hole 13. The back nine now carries $10.` |
| **A nine closes out** | `Front nine to blue, 3&2` |

Both are things nobody can infer from the hole they are standing on — the same test Sixes applied to the draw. The activity does not also flash: it already shows what the push announced.

## Dynamic Island

- **Minimal** — mark + mint dot.
- **Compact** — **the current nine only.** Compact holds one number and Nassau has two; the nine settles sooner and moves more. A live press shows as an orange `+1` in place of the qualifier.
- **Expanded** — both rows, sides, hole, and the range. Must be kept in step with the lock card; it drifted once already.

## Lifecycle

Same as Sixes: the activity belongs to the **primary game named at setup** (a Nassau with a side skins game gets this card and no skins card); starts on the **first score posted** (buys back the range and the car park against the 8-hour iOS limit; an abandoned round leaves no ghost), one activity per round, final state on sign, auto-dismiss after ~5 minutes.

## Tokens

Inherited unchanged from the Sixes activity: deep pine `#0B1F1A`, pine `#0F6E56`, mint `#3BD89A`, blue `#5AA7F5`, orange `#F3A059`; panel `rgba(255,255,255,.13)` + `blur(20px)`, radius 24px.

Nassau-specific: row numbers 25px Schibsted Grotesk 700, tracking −.6px; row labels 9.5px/700/.5px at 52%; `n TO PLAY` 9px/700/.4px at 55%; sides 12.5px; press chip 8.5px/700 on `rgba(243,160,89,.2)`. Exposure range is tabular-nums so the ends do not jitter as they move.

## Open questions for code

- **Automatic presses.** If the group has auto-press enabled (press when 2 down), a press arrives with no person behind it. Does it still push? `Dave pressed` is wrong copy for it, and a silent stake change is the thing the range exists to prevent.
- **A halved nine.** Pays nothing, per the Sixes ruling on halves. Confirm the range's midpoint drops the stake rather than banking it, and decide the push copy — `Front nine halved` has no winner to name.
- **Loss cap.** `nassau-setup.html` has a loss cap. A cap truncates the range's floor, which is most of its value — does the card show the capped floor, or the uncapped one? Showing the cap is almost certainly right and needs a data field.
- **The 2v2 reader.** Gross score and the range are personal; the sides line is neutral. In 2v2 the range is the reader's own share, not the team's — confirm which the data layer returns.
- **Triple Nassau.** Not designed. Three pairings will not fit two rows.
