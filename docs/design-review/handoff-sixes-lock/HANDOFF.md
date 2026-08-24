# Handoff — Sixes lock screen (Live Activity)

**One shipping surface, five states.** `live-activity-sixes.html` (card: **Sixes — lock screen**, group **Live Activities**, lives at `screens/live-activity-sixes.html`).

Included for context: `live-activity-pattern.html` (the generalised five-slot pattern — read it if you are building the container rather than Sixes), `handoff-card-taxonomy.md`.

**Draw count, settled:** the pairing is drawn **once at hole 7**. If a match ends early, the extra holes get their own pairing too — spun or set by hand, the group's choice, in the app. Earlier copy in these screens said *twice, at holes 7 and 13* — corrected. Segment 3 is not drawn; with four golfers, drawing the second pairing forces the third.

---

## What it is

An iOS Live Activity for a Sixes round: a neutral scoreboard that lives on the lock screen and in the Dynamic Island for the length of the round, plus **one push notification per pairing draw**.

It is read-only. **No buttons, no CTA, no tap targets.** Every action in Sixes is group state that wants the app's confirmation, and a mis-tap on a lock screen is expensive.

## The five slots

Every state is the same five slots. Build one view; the states are data.

| Slot | Content | Rules |
| --- | --- | --- |
| **Header** | Mark · `SIXES` · segment right-aligned | Game name gains ` · HIGH-LOW` when that variant is on. Segment reads `SEGMENT n · HOLES a–b`. |
| **The number** | `2 UP` / `ALL SQ` / `+3 PTS` | Wears the **leading side's colour** (blue or orange). All square is white at 90% opacity. Never mint — mint is the app's colour, not a side's. |
| **The sides** | Both pairings, two lines, colour dot each | Leader is bold and coloured; the trailing side drops to 60% opacity. Never *you are 2 up* — four golfers read the same string. |
| **The state** | `DORMIE` / `—` + `n TO PLAY` | Right-aligned. Holds a match-state word when one applies, otherwise the em dash and the holes-remaining line beneath. **Not the money.** |
| **Pips** | Three bars: segment 1, 2, 3 | Won segments take the winning side's colour; the live segment is white at 62%; unplayed is white at 20%. Identical in every state — the eye learns where to look. |
| **Footer** | Round context left, money right | e.g. `Thru 4 · $5 a match` / `+$5 so far`. Thru lives here, **not** on the sides line — it does not fit in the headline band and breaks after "thru". |

## The states

1. **Ordinary** — segment live, board current. This is 95% of the round.
2. **Draw** — push notification above, activity already showing the new pairing underneath. The activity gets **no special draw state**: no banner, no waiting card, no "open to draw" button. It updates.
3. **High-Low** — same composition, number reads `+3 PTS`. **The low/high split does not ship to the lock screen** — a running total is the only thing the match is decided on; the breakdown belongs on a card in the app.
4. **Always-on** — identical composition. iOS pulls refresh rate and brightness; nothing is recomposed. The prototype renders it at roughly the real reduction (`brightness(.74) saturate(.82)`), not a near-black theoretical one.
5. **Final** — the one personal state: `+$10`, `Blue won 1 and 3`, `Collect from Sam`. Holds a few minutes, then dismisses itself.

A sixth treatment, **quiet**, is drawn in the prototype: dark slab instead of the frosted panel, number down to 22px, mint pulled back to the pips only. **Ship the loud one.** Quiet is the fallback if telemetry says people leave it running four hours and resent it.

## The push

Fires **once per draw**, when the new pairing lands — not when the draw sheet opens, not per hole. That is one push in a normal round, at hole 7. Extra holes push as well, on the same rule — see below.

- Title: `New partners — holes 7–12`
- Body: `Pairing 2: Paul & Sam v. Dave & Lee`
- App label: `HALVED`

**Never both.** The activity does not also flash or animate on the push — it is already showing the answer the push announced. Nothing else in Sixes pushes.

## Lifecycle

| Moment | Behaviour |
| --- | --- |
| Start | **First score posted**, not the tee time. Buys back the half hour on the range against the 8-hour iOS limit, and an abandoned round leaves no ghost. |
| Through the round | One activity per round. If the group is also running skins, skins does **not** get one — Sixes is the game with news. Ranking is fixed at setup, never fought over at runtime. |
| 8-hour limit | A slow round with a turn is close to it. Decide the expiry behaviour: end silently, or end with the final state pre-empted. Not designed. |
| End | Final state on round sign, auto-dismiss after ~5 minutes. |

## Dynamic Island

Three sizes, all in the prototype.

- **Minimal** — mark + mint dot. 52px pill.
- **Compact** — mark + number in the leading side's colour + a two-word qualifier (`blue`, or `thru 9` when all square). This is what people actually see all round.
- **Expanded** — number, both pairings, state word, pips. Header reads `SIXES · SEGMENT 1`.

## Tokens

Deep pine `#0B1F1A`, pine `#0F6E56`, mint `#3BD89A`, muted `#5C6B62`, blue `#5AA7F5`, orange `#F3A059`.

Panel is `rgba(255,255,255,.13)` with `blur(20px)` and a `.5px rgba(255,255,255,.14)` border, radius 24px. Quiet variant is `rgba(10,22,18,.55)`.

Schibsted Grotesk 600/700 for the number, state word and clock; Spline Sans 400–700 for everything else.

Sizes: number 36px/.94 tracking −1px; state word 17px; `n TO PLAY` 9px/700/.4px at 55% opacity; sides 12px; footer 11px at 66%; pips 4px tall, 5px gap.

## Extra holes

When a segment match closes out early (`Segment 1 won by blue, 4&2`), the leftover holes get their own pairing. In the app the group chooses: **spin the wheel, or set the teams by hand.** Both paths land the same object — a pairing for a named stretch of holes.

The lock screen does not offer that choice and never will: it is read-only, and a lock-screen button on group state strands the other three. The activity's job is to be correct the moment the pairing exists, however it was arrived at.

- **Push copy is method-neutral.** Title `New partners — extra holes`, body `Extra holes 5–6: Paul & Sam v. Dave & Lee`. Not *drawn* — half the time nothing was drawn. Fires on the pairing landing, same as the hole-7 draw.
- **Segment slot** reads `EXTRA HOLES · 5–6`, replacing `SEGMENT n · HOLES a–b` for the duration.
- **Everything else is unchanged.** Number, sides, state, footer all behave normally against the extra-holes pairing.

**Still open: the pips.** Three pips are the shape of Sixes, and an extra-holes stretch is not a fourth segment. Two candidates: the finished segment's pip splits to show its extra-holes tail, or the stretch borrows the live pip and the segment count is unaffected. Not drawn — tell me which and I will.

## Open questions for code

- **Colour stability.** Blue/orange follow P1's side across all three segments (per the draw packet). Confirm the activity reads the same assignment and does not recompute per segment.
- **Late score edits.** A corrected hole can flip the number after the fact. Does the activity animate the change, or just render the new value?
- **Player drops mid-round.** Sixes needs exactly four. If the round converts, the activity's whole composition is wrong — does it end, or switch game?
- **Thru vs. segment context in the footer.** The prototype alternates `Thru 4 · $5 a match` and `Segment 1 won by blue, 4&2`. Rule: show the last segment result for the first two holes of a new segment, then revert to thru? Not specified.
