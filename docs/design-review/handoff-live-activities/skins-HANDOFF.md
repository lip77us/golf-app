# Handoff — Skins lock screen (Live Activity)

**One shipping surface, two games, eight states.** `live-activity-skins.html` (card: **Skins — lock screen**, group **Live Activities**, lives at `screens/live-activity-skins.html`).

Companions: `HANDOFF.md` (the shared frame) and `sixes-HANDOFF.md` (the reference implementation). This document is about where Skins departs.

> Supersedes the earlier draft of this file, which described a *provisional pot* treatment for multi-group. That design was abandoned — see **What changed and why** at the end.

---

## What it is

An iOS Live Activity for a skins game. Read-only. **No buttons, no CTA, no tap targets.**

Ships **only when skins is the primary game named at setup.** A foursome running skins alongside a Nassau gets the Nassau card. Side games do not get activities.

## Two games, four shapes

Skins is run two ways and they are different games. The header says which, and the presence of the word **MULTI-GROUP** is the whole signal.

| Header | Game |
| --- | --- |
| `SKINS · CARRYOVERS` | Single group, per-skin money, ties carry into the next hole |
| `SKINS · POOL` | Single group, one ante, one pot |
| `SKINS · POOL + JUNK` | Single group, one pot, junk points worth the same as skins |
| `MULTI-GROUP SKINS` | Field-scored, one pot, **no carries** |

Anything starting `SKINS ·` is the game in front of you. No badge, no group number.

## Single group is personal; multi-group is not

**Single group** — four players, a hole decided the moment those four have played it, three opponents within earshot. The card is personal: the reader's skin count, his standing, his money.

**Multi-group** — sixteen golfers, the same hole scored across the field. The card carries **no gross, no standing and no running total**, because the reader already knows his own round: the leaderboard has it and the entry screen is open at least once a hole. What he cannot see is a hole closing out behind him, so that is what the card reports.

This is the single most consequential decision in the design. Everything else follows from it.

---

## Single group

### Carryovers — the pot is the headline until it is won

`$36` on the 17th, six skins deep, `6 skins, carried from the 12th`. Four players at $2 a player, so a skin pays **$6** and a six-skin carry pays $36.

The state slot has **three readings of one state**, and only the second line changes:

| Reader | State b | State u | Footer left | Money |
| --- | --- | --- | --- | --- |
| Leader | `5 SKINS` | `YOU LEAD` | `+6 · $2 a player · 11 settled` | `+$18` |
| Chaser | `2 SKINS` | `M. ALVAREZ +3` | `+9 · $2 a player · 11 settled` | `−$6` |
| Watcher | `M. ALVAREZ` | `LEADS · 5` | `Par 5 · 11 settled` | `4 playing` |

**A gap, not a placing.** `+3` is how many holes the chaser has to take to draw level; with $36 sitting on the 17th it can close in one swing. An earlier draft read `1ST OF 4`, which looks like a stroke-play finishing position and means nothing of the kind. Ties resolve to the **most recent winner**, so the chaser always reads a name rather than a tie to unpick.

Net money is `8W − 2S` (W skins won, S skins settled): win $6, lose $2 on every settled skin.

### Carryovers — the slots reorder when the carry breaks

Push: **`S. Reid won $36 on the 17th`** / `Six holes of carry, gone in one. $6 on the 18th.`

Card: headline `S. REID`, state `WON $36` / `ON THE 17TH`, sub `$6 on the line on the 18th — no carry`, footer `5 skins · S. Reid leads — 6` / `+$6`.

A running card leads with **money at stake**. A card one minute after a payout leads with **the golfer who took it**, and the next hole's pot drops to the sub-line. Six dollars after thirty-six is a footnote.

**A carry of _n_ skins awards _n_ skins to its winner**, so the lead turns over in the same instant: Reid goes 0 → 6, past the reader's 5.

### Pool — the divisor and the price

`4 SKINS` headline, state `$15` / `A SKIN NOW`, sub `Sam Reid took the 6th`, footer `$60 pot · 1 skin · $15 ante` / `$0`.

- Per-skin value is `pot ÷ skins won so far` and it **falls** all round. The word **`NOW`** carries that. An earlier draft read `EACH, AND FALLING`, which spent a slot explaining a mechanism the reader already understands.
- **The pot is a footer stat.** $60 is fixed at the ante and never changes; what changes is the divisor above it.
- **The named line persists.** `Sam Reid took the 6th` still reads on the 7th, 8th and 9th if nobody wins in between. The last skin taken is the standing state of the game, not a flash that expires — a card that blanked it on the next tee would hide the answer to the question it raises.
- Money = `(skins held ÷ skins won) × pot − ante`. One of four is $15 back against a $15 ante, so `$0`.

The **watcher** keeps both headline figures, since neither is personal, and trades the reader's count and money for par and the field size.

### Pool + junk — junk is a skin by another name

**One pot, not two.** A junk point — birdie, sandy, greenie — is worth exactly what a skin is worth and divides the same money. **4 skins + 2 junk = 6 shares**; $60 ÷ 6 = `$10`.

`4 SKINS` headline, state `2 JUNK` / `$10 EACH NOW`, sub `Sam Reid took the 6th — 1 skin, 1 junk`, footer `$60 pot · 1 skin · 1 junk` / `+$5`.

Both counts take the headline. An earlier draft buried junk in the sub-line as a second, smaller pot, which made it look like a side bet and understated what the round is dividing. The named line carries the split because **one hole can produce two shares** — the thing about this variation a reader has to see once to understand.

---

## Multi-group

### The card reports closures, not the hole you are on

`FULL FIELD THRU 9` in the header. Headline `SAM REID`, state `HOLE 9` / `WON THE SKIN`, sub `4 skins awarded · 5 halved`, footer `5 leaders on open holes` / `D. Kerr leads · 2 skins`.

- **No carries.** A hole nobody wins is halved and produces no skin.
- **Groups play in order**, so settled holes are a contiguous block behind the last group. The header names the **boundary** rather than a bare count, and the reader subtracts his own hole number from it: on the 12th with the field through 9, three of his own holes are still open. `awarded + halved = the boundary number`.
- **No dollar figure on a hole and no winning score.** One pot divided at the end, so what a hole paid cannot be stated mid-round — four skins into $192 is $48 apiece, six makes it $32. A number against hole 9 would be a guess dressed as a receipt. The winning score goes too: the hole is closed and nobody is chasing it.
- **`5 leaders on open holes`** = open holes where exactly one golfer currently holds the low score outright. Those are the skins about to happen, and the reason the divisor is going up.
- Footer right names one golfer with a count, `skins` spelled out because a bare 2 is ambiguous.

### Halved holes are results too

Push: **`Hole 10 was halved`** / `No skin. Three golfers tied at net 4.`

Same card shape with the name slot greyed: headline `HALVED` at `#fff` / `.5`, state `HOLE 10` / `NO SKIN`. **Not dimmed mint** — mint is the win colour everywhere in this system and a faded win is the wrong read.

Ties are the normal case in a sixteen-golfer field, so halves outnumber skins most of the day. In a pool a halve is good news for anyone holding a skin: one fewer way to divide the money.

### Round complete is the result, not a receipt

Every golfer and every watcher wants this card at the same moment, so it reports **the game**, not the reader.

- `Round complete` at **21px in the display face** — the only card in the set that opens with a sentence rather than a value. The fact that it is over is the news.
- `$32` `per skin — 6 won` beneath it. That figure was a moving target all afternoon; here it is finally a number.
- `Winners: D. Kerr 2 · M. Alvarez 2 · S. Reid 1 · T. Ochoa 1`. **No ranking and no tiebreak** — in a pool there is no overall winner, only golfers holding skins.
- Footer `16 golfers · $192 pot · 12 halved` — the ante, the divisor, and why the divisor stayed small.

**Nothing on this card says "you".** A shared result that personalises one line reads differently to every person looking at it, which is the opposite of what it is for. Every golfer is named the same way, the reader included.

### Watchers

Multi-group watchers get **the player card unchanged** — once the personal figures came off, there was nothing left to strip. Single-group watchers get a modified card, because that one is personal.

---

## The push

| Game | Trigger | Copy |
| --- | --- | --- |
| Multi-group | Last group clears a hole and it is won | `Hole 9 goes to Sam Reid` / `His 1st of the day. Nobody matched it.` |
| Multi-group | Last group clears a hole and it is halved | `Hole 10 was halved` / `No skin. Three golfers tied at net 4.` |
| Carryovers | A carry is taken | `S. Reid won $36 on the 17th` / `Six holes of carry, gone in one. $6 on the 18th.` |

**Never both.** The activity does not flash — it is already showing what the push announced.

**Not pushed:** a hole merely carrying. Normal, expected, already on the card; pushing it would be eighteen notifications a round.

Up to eighteen closures a round in multi-group is real volume. If it proves too many the honest lever is **a floor on value**, not softer copy.

## Quiet treatment and always-on

**Quiet** pulls the panel down to `rgba(10,22,18,.55)`, the headline to 22px and the sub to 12px at 60%, and greys the mark — but **keeps the mint on the headline**. The colour is load-bearing, not decoration.

**Always-on** renders at `brightness(.74) saturate(.82)`. The **pool + junk** card is the one drawn in it, because it is the busiest of the set: if two counts and a price survive the dimming, everything simpler will.

Starts on the **first score posted**, ends on round sign with the round-complete state, dismisses after ~5 minutes.

## Dynamic Island

- **Minimal** — mark + mint dot.
- **Compact, single group** — `$36` + `5 skins`.
- **Compact, multi-group** — `Reid` + `hole 9`.
- **Expanded** — the multi-group lock card entire.

The compact pill has room for one value and one qualifier, so **the game name waits for the expanded state** — the one place on the whole sheet where it is not beside the mark.

## Tokens

Inherited from the Sixes activity: panel `rgba(255,255,255,.13)` + `blur(20px)`, radius 24px; deep pine `#0B1F1A`, mint `#3BD89A`.

Skins-specific: headline 36px Schibsted Grotesk 700; round-complete line 21px, final value 42px; **halved headline** `#fff` at 50%; footer has a `.5px` top rule at 11% white. All money and counts are `tabular-nums`. In the winners row **each name and its count sit in a `white-space:nowrap` span**, so a wrap can only fall at a `·` and a count can never orphan.

## Invariants to assert in code

The prototype was corrected repeatedly for breaking these:

- `skinsAwarded + holesHalved == fullFieldThruHole`
- the sum of every per-golfer skin count ≤ `skinsAwarded`
- `openHolesWithSoleLow ≤ 18 − fullFieldThruHole`
- a carry of _n_ skins awards _n_ skins to its winner, and may turn the lead over in one hole
- three readings of one state (leader / chaser / watcher) must agree on who leads and on how many skins exist

## Open questions for code

- **`5 leaders on open holes` needs live field data**, computed across every posted card rather than the reader's group. Confirm the round model exposes it live, not just at settlement.
- **Net skins and sole-low.** If a golfer yet to play a hole has strokes on it, does he already reduce the leader count for that hole?
- **Pool + junk claim disputes.** Junk is claimed hole by hole; a reversed claim changes the divisor retroactively. Restate silently, or push a correction?
- **Carry cap.** If setup caps how far a skin may carry, the card must say so — an uncapped `$36` on a capped game is the worst kind of wrong number.
- **Watcher scope in multi-group.** The watcher gets the player card unchanged; confirm a watcher following one group does not expect that group's progress on it.

## What changed and why

The previous version of this document specified a **provisional pot** for multi-group: the hole in front of you in the headline, white instead of mint, marked `PROVISIONAL` with an `n GROUPS OUT` counter, turning mint and `ALL IN` once the field was through.

It was dropped for three reasons, in order of weight:

1. **The reader does not need it.** A scorer knows what hole he is on and reads his own position on the leaderboard and the entry screen. Spending the headline on a forecast of his current hole spent the best surface in the app on the thing he could not fail to know.
2. **Multi-group has no carries**, so there was less to forecast than the design assumed.
3. **Nothing needs to be provisional if the card only reports closed holes.** Showing settled holes only removes the hedge entirely — which is why no state in the current design is anything but mint.

Also retired along the way: `1ST OF 4` (a placing where a gap was meant), money and standing on the multi-group card, the separate watcher composition for multi-group, junk as a second pot, and `EACH, AND FALLING`.
