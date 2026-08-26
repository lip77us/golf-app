# Handoff — Rabbit lock screen (Live Activity)

**One shipping surface, five states.** `live-activity-rabbit.html` (card: **Rabbit — lock screen**, group **Live Activities**, lives at `screens/live-activity-rabbit.html`).

Companion: `handoff-sixes-lock/HANDOFF.md`. Read it first — Rabbit reuses the Sixes frame almost unchanged, and this document is about **where it departs**.

---

## What it is

An iOS Live Activity for a Rabbit game: who holds the rabbit, how clear they are, how many holes are left in the current rabbit, and the settled money — plus one push, when a new rabbit starts.

Read-only. **No buttons, no CTA, no tap targets.**

Drawn for the **3-player** game, which is how Rabbit is played in this system (`rabbit-setup.html` gates on a 3-player group). 4-player is an open question below.

## The three departures from Sixes

1. **There are no sides.** Three golfers, one holder. Sixes could not use mint for its number because mint is the app's colour and picks neither side; Rabbit has exactly one distinguished party and one binary question — held or loose — so **mint carries "held"** and does it alone. Two chasers in dim white.
2. **The number is a lead, not a score.** `+2` is *how many holes the holder can lose before the rabbit runs free*. It is not a margin over anyone in particular.
3. **The shape of the round is not knowable at setup.** This is the one that costs code work. See below.

## Rabbit geometry — the rule the card is built on

A rabbit is **six holes from wherever it starts**, and it starts on the hole after the previous one was decided.

```
rabbit.start  = previous.end + 1            (rabbit 1 starts at hole 1)
rabbit.end    = min(start + 5, 18)
decided_at    = the hole where  lead > holes_remaining_in_this_rabbit
                (or rabbit.end, if it was never locked)
```

So a lock on the 11th makes the next rabbit **holes 12–17** — a full six playing for a full stake — not 13–18. Every rabbit after an early lock slides.

**The tail is what is left at the end of the round**, once the sixes have run: the `EXTRA RABBIT`. One hole pays **half stake**; two or more pays full. A deciding hole played after the 18th is also an extra.

Consequences for code:

- **Ranges are computed, never scheduled.** There is no `segments[3]` in the model. `rabbit_index` is a counter, not an index into a fixed array.
- **Never print a denominator.** The header is `RABBIT 2 · HOLES 7–12`, never `2 of 3`. A round that opens as three rabbits can finish as five. (Sixes cut its segment pips for the same reason: nothing on this card may be composed as thirds.)
- **Stop-after-one cannot lock.** One beaten hole frees the rabbit, so no lead can outrun the holes left. That variant plays three fixed sixes, ranges never slide, and its only possible extra is a deciding hole. Worth a fast path.

## The slots

| Slot | Content | Rules |
| --- | --- | --- |
| **Header** | Mark · `RABBIT` · `RABBIT n · HOLES a–b` | Gains the variant name in place of the range label in stop-after-one. Range is the rabbit's real holes. Extras read `EXTRA RABBIT · HOLES 17–18` / `· HOLE 18`, in orange. |
| **Big number** | `+2` mint, or `LOOSE` white at 90% | The lead. `LOOSE` is 31px, not 36px — it is a word in a number's slot and matching the digits' size makes it shout. |
| **Names** | Holder on line 1 (mint, mint dot), the two chasers on line 2 (dim) | When loose, all three go on one dim line. There is no leader to name and the card should not imply one. |
| **State** | `HELD` / `LOOSE` / `LOCKED` / `EXTRA` + holes remaining | Same slot as Sixes' `DORMIE`. `½ STAKE` replaces the hole count on a single-hole extra. |
| **Footer** | Gross · thru · stake left, **settled money** right | `+2 · Thru 4 · $5 a rabbit`. |

`LOCKED` is the Sixes `DORMIE` analogue: `lead > holes_remaining`. It is the one state that changes what the group does next, because the next six starts on the next tee.

## Money

**Settled only.** A rabbit pays when it closes, so the slot is **empty until the first one settles** — not `$0`. An in-progress rabbit is worth nothing yet and a zero implies it was played for nothing.

Arithmetic behind the slot: **the holder takes the stake from each of the other two** — `+$10 / −$5 / −$5` at $5 a rabbit — and a single-hole extra pays half of that. The five drawn states are a consistent ladder for one reader (Paul): `—`, `−$5`, `−$10`, `+$5`, final `+$5`. Treat the ladder as a test in code; it had to be corrected twice in the prototype.

**A loose rabbit at its last hole moves nothing** under the setup default (*zero it out*), which is why the number can sit still for six holes and be right. The *carry the stake forward* option doubles the next rabbit's pot and has **no drawn treatment** — see open questions.

## The states

1. **Rabbit 1, held** — `+2`, `HELD`, `3 TO PLAY`, money slot empty.
2. **A new rabbit** — push above, activity already showing it. `LOOSE`, all three names dim, `6 TO PLAY`.
3. **Locked early** — push says the holes have moved: *Rabbit 2 is safe — new rabbit, holes 12–17*. Card is already on rabbit 3, in mint.
4. **The extra, always-on** — `EXTRA RABBIT · HOLE 18`, orange, `LOCKED` + `½ STAKE`. Drawn at roughly the real AOD reduction, not the theoretical one.
5. **Stop-after-one (quiet treatment) + final state** — `HELD` with no lead; final is `+$5`, *Won rabbit 3 and the last extra*, *Collect from Dave*, auto-dismiss.

## Colour

- **Mint** — a six-hole rabbit and its holder, wherever it starts.
- **Orange** — the extra only: the tail at the end of the round. It is the one playing for a different amount, which is what earns it a different colour.
- **White at 90%** — `LOOSE`.

An early-lock rabbit is **mint, not orange**. It is a full six for a full stake; only its numbers moved.

## The push

One event: **a new rabbit starts.** At the end of a six, or the moment a lock starts the next one early. Three or four in a round.

| Event | Copy |
| --- | --- |
| **End of a six** | `New rabbit — holes 7–12` / `Rabbit 1 went to Sam Reid. Nobody holds this one yet.` |
| **Early lock** | `New rabbit — holes 12–17` / `Rabbit 2 is safe: Dave Moran is 3 clear with 1 to play. The next six start here.` |

**Silent:** catches, escapes, halved holes. Everybody in the group watched them happen, and a push for a catch would fire on half the holes of the round. The activity updates; it does not also flash.

## Dynamic Island

- **Minimal** — mark + mint dot.
- **Compact** — `+2` mint + holder forename; `LOOSE` + `thru n` when nobody has it.
- **Expanded** — lead, holder, chasers, state, and the **run strip**: one bar per rabbit, mint for the live one, a short orange bar for the extra. The strip is the only place the shape of the round is drawn, since the lock card has no room for it and a fixed set of pips would be a lie. Bars are generated from the computed rabbit list, so a round with five rabbits shows five.

## Lifecycle

Same as Sixes: one activity per round, owned by the **primary game named at setup**; starts on the **first score posted** (buys back the car park against the 8-hour iOS limit; an abandoned round leaves no ghost); final state on sign, auto-dismiss after ~5 minutes.

## Tokens

Inherited from the Sixes activity unchanged: deep pine `#0B1F1A`, pine `#0F6E56`, mint `#3BD89A`, orange `#F3A059`; panel `rgba(255,255,255,.13)` + `blur(20px)`, radius 24px, 14px side margins.

Rabbit-specific: big number 36px Schibsted Grotesk 700 tracking −1px (`LOOSE` 31px); name lines 12.5px, holder 700; state word 17px, sub-label 9px/700/.4px at 55%; header labels **`white-space: nowrap` on both** — the variant string is longer than Sixes' and wrapped the row before it was pinned. Money and lead are tabular-nums.

## Open questions for code

- **4-player Rabbit.** Setup gates on three. Four means a third chaser on the dim line and a wider spread of ways to lose the rabbit; the card holds it, the stake arithmetic (`+$15 / −$5 ×3`) needs confirming.
- **Carry the stake forward.** The alternative to *zero it out* doubles the next rabbit's pot. The header has no room for a stake, so either the footer stake reads `$10 a rabbit` for that one rabbit, or the card stays silent about it — and silence on a doubled pot is exactly the thing the money slot exists to prevent.
- **Handicaps.** *Spread across the ranges* was designed for three fixed sixes. When a lock slides the ranges, do the allocated strokes slide with them or stay on the holes they were assigned to? The second is much easier to explain on the tee.
- **Extra rabbit off.** With the toggle off the tail is played for nothing. Does the card show `HOLES 17–18 · NO RABBIT`, or does the activity go to its final state on the last rabbit's close?
- **Lead sign on a loss.** In accumulate mode a lead can be run down to zero and the rabbit freed on the same hole. Confirm the card never shows `+0` — that state is `LOOSE`.
- **Push on the extra.** An extra is a new rabbit and gets a push by the rule above. On the 18th tee that may be one push too many; worth a flag.
