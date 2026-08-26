# Handoff — Sixes lock screen (Live Activity)

**One shipping surface, five states.** `live-activity-sixes.html` (card: **Sixes — lock screen**, group **Live Activities**, lives at `screens/live-activity-sixes.html`).

Included for context: `live-activity-pattern.html` (the generalised five-slot pattern — read it if you are building the container rather than Sixes), `handoff-card-taxonomy.md`.

**Match count is not fixed.** A match ends when it is decided, not when its holes run out, and the next one starts on the next tee. So a round has **three matches at minimum and no ceiling** — see [Matches, not segments](#matches-not-segments). Earlier copy said the pairing changes twice at holes 7 and 13, then once at hole 7; both assumed fixed six-hole blocks and both are wrong. Nothing on the lock screen may assume three.

---

## What it is

An iOS Live Activity for a Sixes round: a neutral scoreboard that lives on the lock screen and in the Dynamic Island for the length of the round, plus **one push notification per new match**.

It is read-only. **No buttons, no CTA, no tap targets.** Every action in Sixes is group state that wants the app's confirmation, and a mis-tap on a lock screen is expensive.

## The four slots

Every state is the same four slots. Build one view; the states are data.

**Segment pips are cut.** Three bars only ever made sense if a round had three matches, which it does not; and the holes-remaining line plus the footer's segment result already answered the same question in words. They survive in the expanded Dynamic Island, which has no footer to carry it.

| Slot | Content | Rules |
| --- | --- | --- |
| **Header** | Mark · `SIXES` · match right-aligned | Game name gains ` · HIGH-LOW` when that variant is on. Right side reads `MATCH n · HOLES a–b` — the match's **nominal** block (1–6, 7–12, 13–18). A match that closes out early ends short of its last hole and the next one starts on the following tee, but the nominal range is still the honest label: it is what the group agreed to play, and it tells the reader where in the round they are better than a start hole alone. A match past 3 exists only because earlier matches closed out early, so it takes **the holes actually left** — `MATCH 4 · HOLES 17–18`, or `MATCH 4 · HOLE 18` when one hole is left. Short and late by definition. |
| **The number** | `2 UP` / `ALL SQ` / `+3 PTS` | Wears the **leading side's colour** (blue or orange). All square is white at 90% opacity. Never mint — mint is the app's colour, not a side's. |
| **The sides** | Both pairings, two lines, colour dot each | Leader is bold and coloured; the trailing side drops to 60% opacity. Never *you are 2 up* — four golfers read the same string. |
| **The state** | `DORMIE` / `—` + `n TO PLAY` | Right-aligned. Holds a match-state word when one applies, otherwise the em dash and the holes-remaining line beneath. `n` counts **the current match's** remaining holes, never the round's — one definition, all five states. **Not the money.** |
| **Footer** | Gross · thru · stake left, money right | `+2 · Thru 4 · $5 a match` / `+$5`. Gross leads — the one personal figure the neutral board can afford. Thru lives here, **not** on the sides line, where it breaks after "thru". Third slot is **always the stake**, never the last match's result. Money is **settled only**, and the slot is **empty** until the first match closes. |

### The footer, settled

Two rulings, both reversals of what the screens showed:

- **The third slot is always the stake.** It previously alternated with the last match's result (`blue won match 1`). That cannot work in Sixes: the teams change every match, so a result naming a side describes **a pairing that no longer exists** — printed directly beneath the current pairing, which shares golfers with it. The stake never goes stale.
- **The money is settled money.** A match pays when it closes, so the slot is **empty until the first match settles** — not `$0`, which implies a match was played for nothing. `+$5`, not `+$5 so far`: a figure that only counts closed matches needs no hedge.

## The states

1. **Ordinary** — match live, board current. This is 95% of the round.
2. **New match** — push notification above, activity already showing the new pairing underneath. The activity gets **no special state for it**: no banner, no waiting card, no "open to draw" button. It updates.
3. **High-Low** — same composition, number reads `+3 PTS`. **The low/high split does not ship to the lock screen** — a running total is the only thing the match is decided on; the breakdown belongs on a card in the app.
4. **Always-on** — identical composition. iOS pulls refresh rate and brightness; nothing is recomposed. The prototype renders it at roughly the real reduction (`brightness(.74) saturate(.82)`), not a near-black theoretical one.
5. **Final** — the one personal state: `+$10`, `Won 2, halved 1`, `Collect from Sam`. **The reader's own record, counted** — no side is named, because in Sixes no side survives the round: the pairing changes every match, so *Blue won 2* describes a team that existed for six holes. Blue and orange are **within-match colours only** and must never appear in a round summary. Counts, not a list of numbered matches, either — with no fixed match count, *won 1 and 3* names nothing the reader can place. Halves are counted explicitly; with no tie breaker they are common enough that a won/lost split would not add up.

A sixth treatment, **quiet**, is drawn in the prototype: dark slab instead of the frosted panel, number down to 22px, mint pulled back to the mark only. **Ship the loud one.** Quiet is the fallback if telemetry says people leave it running four hours and resent it.

## The push

Fires **once per new match**, when the new pairing lands — not when the draw sheet opens, not per hole. Three times in a clean round, more if it runs past match 3. **It fires on match 3 too**, which is forced rather than drawn: the reader still has new partners, and how the pairing was arrived at is not their problem.

- Title: `New partners — holes 7–12`
- Body: `Match 2: Paul Kelly & Sam Reid v. Dave Moran & Lee Naylor`
- App label: `HALVED`

A match past 3 names its real holes, which are whatever is left: `New partners — holes 17–18`, or `New partners — hole 18` for a single hole.

**Rate limit it.** Two matches decided on consecutive holes puts two pushes a few minutes apart, which is where an ambient thing starts to feel like a nag. Suppress or coalesce if a second push would land inside a few minutes of the first — worth watching in the first rounds.

**Never both.** The activity does not also flash or animate on the push — it is already showing the answer the push announced. Nothing else in Sixes pushes.

## Lifecycle

| Moment | Behaviour |
| --- | --- |
| Start | **First score posted**, not the tee time. Buys back the half hour on the range against the 8-hour iOS limit, and an abandoned round leaves no ghost. |
| Through the round | One activity per round, however many matches it contains. It belongs to the **primary game named at setup** — side games get none, and there is no runtime ranking to arbitrate. |
| 8-hour limit | A slow round with a turn is close to it. Decide the expiry behaviour: end silently, or end with the final state pre-empted. Not designed. |
| End | Final state on round sign, auto-dismiss after ~5 minutes. |

## Dynamic Island

Three sizes, all in the prototype.

- **Minimal** — mark + mint dot. 52px pill.
- **Compact** — mark + number in the leading side's colour + a two-word qualifier (`blue`, or `thru 9` when all square). This is what people actually see all round.
- **Expanded** — number, both pairings, state word, pips. Header reads `SIXES · MATCH 1`. The pips live on here only: three of them, sized to the matches actually played so far, since the island has no footer to carry the same fact in words.

## Tokens

Deep pine `#0B1F1A`, pine `#0F6E56`, mint `#3BD89A`, muted `#5C6B62`, blue `#5AA7F5`, orange `#F3A059`.

Panel is `rgba(255,255,255,.13)` with `blur(20px)` and a `.5px rgba(255,255,255,.14)` border, radius 24px. Quiet variant is `rgba(10,22,18,.55)`.

Schibsted Grotesk 600/700 for the number, state word and clock; Spline Sans 400–700 for everything else.

Sizes: number 36px/.94 tracking −1px; state word 17px; `n TO PLAY` 9px/700/.4px at 55% opacity; sides 12.5px on their own full-width rows beneath the number band; footer 11px at 66%.

## Matches, not segments

A match ends when it is decided. `4&2` means it is over on hole 4, and **the new pairing starts on the fifth tee** — the two holes are not spare holes appended to the old match, they are the first two of the next one. Three matches is the floor, not the shape: a round of decisive matches produces four, five, six.

What that costs the design:

- **Nominal ranges are fine; fixed *match* counts are not.** `MATCH 2 · HOLES 7–12` reads correctly even when match 2 actually starts on hole 5, because the range is the block the group agreed to, not a claim about what was played. What breaks is composing anything as thirds.
- **No fixed match count.** Nothing may be composed as thirds: no three pips, no "segment 3 of 3", no final state listing matches by number.
- **The header counts matches, not pairings.** `MATCH 4` — an open-ended integer that only goes up. There are three possible pairings of four golfers, so from match 4 the pairings repeat, but **the repeat is not a rule the screen can lean on**: from match 4 the group decides the pairing themselves, usually on who is winning. `PAIRING 1, AGAIN` would be both confusing and sometimes wrong. Code needs a match index, not just a pairing id.
- **A fourth match happens less than half the time**, and when it does it is **short and late** — 17–18, or 16–18. Three is the common case; four-plus is the exception the card must not break on, which is the difference between designing for it and designing around it. The header is an integer and the pips are gone; that is the whole cost of supporting it.
- **Any match can be halved, and there is no tie breaker.** No extra hole, no countback. A half is a result, and **it pays nothing — no carry-overs anywhere in Sixes.** Each match's stake stands alone, so the footer's running money simply does not move on a half: `+$5 so far` holds through the next match unchanged, which is correct and needs no explaining on the card. Nothing accumulates, nothing is at risk twice. The card must render it as one: `ALL SQ` in white at 90%, the match closes on the half, the next pairing starts. The footer's last-result string needs a halved form (`match 1 halved`), and the final state must count halves — `Won 2, halved 1` rather than a bare won/lost split. **`DORMIE` is still meaningful** (one side cannot lose, but can still be caught), and `ALL SQ` on the final hole is no longer a state waiting to resolve.
- **A one-hole match plays.** Match 3 decided on 17 leaves a single hole and that hole is its own match — new pairing, new push, settled on 18. It does not fold into the match that just ended. The header names the hole, not a range: **`MATCH 4 · HOLE 18`** — singular, no dash, never `HOLES 18–18`. Push reads `New partners — hole 18`. Code needs the singular string wherever it builds a range label.
- **`n TO PLAY` means the match, not the round** — the nominal block minus holes played. Counting the round was tried and dropped: `2 UP` and `14 TO PLAY` answer different questions, and the pair reads as a contradiction. Both numbers describe the same match. (The old justification — that a match's remaining holes are *unknowable* — died when nominal blocks came back: `HOLES 7–12` makes them arithmetic.)
- **`DORMIE` is computed the same way.** It is a match word; there is nothing else it could mean. Two up with two of the match's holes left.

**Teams change every match** — there is no match where the pairing carries over. Four golfers split three ways, and the first three matches walk through all three pairings:

| Match | Pairing | Sheet |
| --- | --- | --- |
| 1 | Set in setup, or spun | Optional |
| 2 | **Drawn** — two pairings left, 50/50 | Yes, automatic |
| 3 | **Forced** — the one unplayed pairing | No sheet; announced |
| 4+ | **Group decides**, on the standing — over whatever holes are left | No |

So there is exactly **one real draw per round.** Match 3 being forced is not an assumption that a round is three matches long — it holds because three pairings exist and two have been used. The lock screen still gets a new pairing at match 3 and still pushes for it; it simply was not drawn. The lock screen offers neither and never will — it is read-only, and a lock-screen button on group state strands the other three. Its job is to be correct the moment the pairing exists, however it was arrived at. Push copy is method-neutral for the same reason: *New partners*, never *drawn*.

## Open questions for code

- **Colour stability.** Blue/orange follow P1's side (per the draw packet). With an open-ended match count this matters more, not less: confirm the activity reads the fixed assignment and never recomputes per match.
- **Late score edits.** A corrected hole can flip the number after the fact. Does the activity animate the change, or just render the new value?
- **Player drops mid-round.** Sixes needs exactly four. If the round converts, the activity's whole composition is wrong — does it end, or switch game?
- **Where the packet still says segment.** `live-activity-pattern.html`'s Sixes row and parts of the notes in `live-activity-sixes.html` still describe fixed six-hole segments and a hole-7 draw. Ask and I will sweep them.
- **`handoff-sixes-draw/` contradicts this.** That packet has three fixed segments with match 3 forced and no sheet. Under open-ended matches it is wrong in the same way this one was. It needs the same pass before either goes to code.
