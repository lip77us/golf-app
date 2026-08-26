# Handoff — Skins lock screen (Live Activity)

**One shipping surface, five states.** `live-activity-skins.html` (card: **Skins — lock screen**, group **Live Activities**, lives at `screens/live-activity-skins.html`).

Companions: `HANDOFF.md` (the shared frame) and `sixes-HANDOFF.md` (the reference implementation). This document is about where Skins departs.

---

## What it is

An iOS Live Activity for a skins game: **what the hole in front of you is worth**, whether that figure is final, and your settled net. Plus one push, when a skin settles behind you and changes it.

Read-only. **No buttons, no CTA, no tap targets.**

Ships **only when skins is the primary game named at setup.** A foursome running skins alongside a Nassau gets the Nassau card. Side games do not get activities.

## The one big number is back

Nassau needed two rows because two matches are always live. Skins has exactly one thing that pays — **the hole you are standing on** — so the composition returns to Sixes' single 36px headline.

The number is **the pot on this hole**. Not your position, not the leaderboard: the figure that changes how the next tee shot gets played.

## Money in the headline — the documented exception

The other three cards push money to the footer, because a lock screen is a neutral board and personal money in the headline breaks it.

**Skins is the one game where the pot is not personal.** Everyone on the tee is playing for the same $18. So it holds the headline without breaking the rule. No other card may do this.

## Nobody is named

The sides slot is **empty and stays empty**. In skins the field is the opponent, and naming it would be a list — the thing a lock screen has least room for.

What the slot holds instead is **where the pot came from**: `3 skins, carried from the 10th`. That is the story of the hole and the reason the number is big. When a carry breaks, the slot carries the correction inline: `2 skins, carried from the 11th — was 3` (the struck-through fragment at 50%).

## Provisional vs ALL IN — the structural problem

This is what Skins has and the other three do not: **a skin is not decided until every group has played that hole.** Your group can tie the 10th and count on the carry while a group behind wins it.

So the pot on your current hole is **a forecast, not a fact**, and the card says so:

| State | Number | State slot | Sub-label |
| --- | --- | --- | --- |
| Outstanding groups | **white** | `PROVISIONAL` | `2 GROUPS OUT` |
| Field is through | **mint** | `ALL IN` | `FIELD IS THROUGH` |

Same slot, two truths, colour doing the work at a glance. `n GROUPS OUT` singularises (`1 GROUP OUT`).

Two consequences for code:

- **Pool mode is always mint.** The number there is the pool, fixed by the ante at setup — it cannot be provisional. What is uncertain in pool is your *share*, and that is the state slot's job (below).
- **`ALL IN` is not a synonym for the last hole.** It is `outstanding_groups == 0` for the hole being played, which can be true on the 3rd and false on the 17th.

## Pool mode inverts the arithmetic

Per-skin pays a fixed amount per hole won. **Pool divides one pot among however many skins get won, so every new skin makes yours worth less.** The card says it out loud rather than leaving the reader to divide:

`$60` headline (the pool) · state slot `$15` / `A SKIN, FALLING` · sub `4 skins won so far · 12 in the pool` · footer `+1 · $5 ante · 1 won`.

Nothing else about the composition changes. Header gains ` · POOL` after the game name.

## Par is in the header

`HOLE 12 · PAR 4`. Skins is the one game where par belongs on a lock screen: net skins turn on strokes, and whether a 4 is good enough is the question the number is asking. It also makes the footer's gross the other half of that sentence.

## The footer

`+2 · $2 a player · 6 settled` left, **net settled money** right.

`+$4` after six skins means two collected at $6 and four paid at $2 each. **Both directions, or it is not a position** — a gross count of skins won reads like a win when you are down.

Settled only, same rule as the rest of the family: a provisional pot has not paid anyone, so it is not in the figure.

## The push

One event: **a skin settles behind you and changes the pot in front of you.**

`The 10th went to Sam Reid` / `The carry breaks. This hole is $12, not $18.`

Skins passes the push test more cleanly than any of the others: it is the only game in the set where **the thing in front of you can change without you doing anything.** Money moved while you were standing somewhere else.

**Not every carry.** A hole carrying is normal, expected and already on the card — pushing it would be eighteen notifications a round. Only a settlement that moves the number is news.

## The states

1. **A live carry** — `$18`, white, `PROVISIONAL` / `2 GROUPS OUT`, `3 skins, carried from the 10th`.
2. **A skin settles behind you** — push above, card already corrected to `$12` with the struck-through `was 3`.
3. **Pool mode** — `$60` pool, `$15 a skin, falling`.
4. **Always-on** — `$36`, mint, `ALL IN` / `FIELD IS THROUGH`. One 36px number holds up under the brightness pull better than anything else drawn for this system.
5. **Quiet treatment + final state** — final is `+$4`, `Won 5 of 18 skins`, and the loss that matters: `Lost the 17th — it was worth $36`. Footer `+7 gross · nothing outstanding`. Auto-dismiss ~5 min.

The final state names **the biggest pot you lost**, which is the thing golfers actually talk about walking off. It is the only card in the family whose final state is not purely a collection instruction, because in skins there is nobody in particular to collect from.

## Dynamic Island

- **Minimal** — mark + mint dot.
- **Compact** — the pot + `hole n`; provisional shows the pot in white with an amber `prov` qualifier.
- **Expanded** — the lock card entire: pot, state, carry line, footer. Skins is the easiest of the four to fit here, because there is one number.

## Tokens

Inherited from the Sixes activity: panel `rgba(255,255,255,.13)` + `blur(20px)`, radius 24px; deep pine `#0B1F1A`, mint `#3BD89A`.

Skins-specific: pot 36px Schibsted Grotesk 700; **provisional white** `#fff` at ~92% vs **settled mint**; amber qualifier for `prov` in the Island; footer has a `.5px` top rule at 11% white — the only card in the family with a divider, because the headline is money and the footer is money and they are different money. Money figures are tabular-nums.

## Open questions for code

- **`n GROUPS OUT` needs live field data.** The other three cards need only the reader's group. This one needs to know how many groups have not yet played the hole in question — confirm the round model exposes it live, not just at settlement.
- **A skin settling behind you that does *not* change your pot.** Silent, presumably: it moves someone else's money and the card's number is unaffected. Confirm the push fires on the pot delta, not on the settlement event.
- **Net skins and provisional strokes.** If a group behind has strokes on the hole, the provisional pot depends on their allocation. Does the forecast assume they win, or does it show the pot as it stands?
- **Pool mode's final state.** `Won 5 of 18` is a per-skin sentence. Pool needs its share arithmetic in the same slot, and `A SKIN, FALLING` has no final form.
- **Carry cap.** If setup caps how far a skin can carry, the card should say so — an uncapped `$36` on a capped game is the worst kind of wrong number.
