# Reply — foursome formats, the Live Activity set, and the leaderboard door

Against `handoff-foursome-formats/HANDOFF.md` and `RULINGS-team-cup-lock.md`,
both 22 Sep 2026. Written as the work landed, so the order below is the
packet's rather than the commits'.

**The packet is buildable as written.** Everything below is either a place the
code disagreed with the drawing, a question the packet left open that the build
had to answer, or a measurement that did not reconcile. Nothing here is a
request to redraw.

---

## 1 · Things the packet asked for that were already built

**Irish Rumble's setup screen is the redraw.** `Fixed` was never a shipped
variant — `IrishRumbleConfig.VARIANT_CHOICES` has exactly the four you drew
(Classic, Arizona Shuffle, Shuffle, Custom), the card is already titled
`Variant`, the preview is already `Segment Preview`, the all-four warning is
already red, and the per-hole grid already cycles 1→2→3→4. The only new thing
in §2 was the allowance card.

So the stale copy was staler than the packet thought: it was describing a build
that never existed rather than one that had moved on.

---

## 2 · The allowance ladder — closed, and not the way the packet proposed

> ⚠ The packet: *"the four allowance percentages need a committee ruling… 85%
> at two balls is the published four-ball figure and should not move; the other
> three are a sensible ladder around it."*

**There was no blank to fill.** The ladder already ships, in both languages, in
agreement, and it is the published WHS table rather than a sensible ladder
around one anchor:

| Balls counted | Shipping (`SHAMBLE_PCT_BY_BALLS` / `kShamblePctByBalls`) | Packet proposed |
|---|---|---|
| 1 | **75%** | 80% |
| 2 | **85%** | 85% |
| 3 | **95%** | 90% |
| 4 | **100%** | 95% |

The packet's figures agree at two balls and are invented at the other three —
which it says itself. Adopting them would have replaced a published table with
a second one, in a game whose output is money, and left the app paying two
different amounts for one format depending on which screen set it up.

**Decided (Paul, 22 Sep): keep the published table as a DEFAULT, not a rule.**
Better Ball's allowance follows the ball count, tagged `Auto`, and stops
following the moment the TD moves it. Irish Rumble's is a flat 85% with no
ladder at all — the packet's own finding is that all four shipped variants
average ≈2 balls and land on 85% regardless, so the average-indexed ladder was
machinery that could never move.

**What that means for §1's readback copy:** *"Set by you — N% instead of the
recommended M% at this count"* ships unchanged, with the published numbers
behind it. And at four balls the ladder gives **100%**, which lands exactly on
the amber `Aggregate` state — every net counts, nobody drops a bad one, full
handicap. The two halves of that screen agree without being made to.

---

## 3 · Better Ball — where it actually lives

The packet is right that it is not a variant of Rumble. It is, however,
**Rumble's engine**: `IrishRumbleConfig.segments` is already a generic
`{start_hole, end_hole, balls_to_count}` list that the scoring walk reads
blind, so Better Ball is one flat segment through the same code. The money
model, the borrowed 4th and the tie rule came with it unchanged, as §1 asks.

Two consequences worth knowing:

**One round runs one of them.** They rank the same groups off the same cards
into the same kind of pool, so a round carrying both would take two entry fees
for one competition and print two boards a golfer cannot tell apart. Enforced
in both services and in the wizard, which turns the other OFF rather than
greying it out — a TD who picks the second one has changed his mind, not made a
mistake.

**A shipped defect found on the way.** The Irish Rumble leaderboard tab's
explainer read *"One ball per group, no replacements. The last group still
holding it wins"* — which is **Pink Ball**. It has been describing a different
game on that tab since it was written (`_RedBallView` carries the identical
paragraph, where it is true). Both games have their own sentence now.

---

## 4 · Team cup lock screen — the rulings, and one number that does not add up

§1, §2, §4, §4b and §6 all shipped as ruled. Three notes.

**§4's fallback case cannot fire.** The ruling says split digits should retire
to a single colour "where the two side colours collide (Red v. Orange) or only
one is drawable". `_cup_palette` already resolves that earlier: a collision
falls back to POSITION (team 1 blue, team 2 orange), so the palette always
returns two distinct drawable colours and the split always applies. The card
was already drawing Red in blue on such a cup — the needle and the side dot
have done so since Red became an alias for orange — so the digits are now
consistent with the rest of the card rather than newly wrong. No special case
was built. Say if you want one.

**§3's arithmetic does not reconcile with the layout.** The ruling costs the
card at 147 against a 136 budget and attributes the 11pt gap to "padding 13/16
with an 11pt rhythm". `TripleCupBoardView`'s rhythm was **already 9**, with 6
inside the headline block — exactly what the budget allows. The only deviation
was 1pt of vertical padding a side.

So the 12/9 pass was worth 2pt, not 11, and the remaining ~9pt is in the audit
rather than in the layout. **The band fitting at 157 rests on those numbers.**
The ruling asks for a device measurement anyway; we would treat it as required
rather than confirmatory before 10 Oct.

**The band is NEW on this card, not a redraw.** `triple_cup` never sent a
`ribbon` key — it is the one card in the set with no `stroke_ribbon` call — so
the 147 in the audit is the bandless height and the card has never shown a
popping band at all. The 31pt "as shipped" figure is the shared band's cost on
the cards that do send one.

---

## 5 · The popping band — one shape the packet does not cover

**Alternate shot.** Triple Cup's middle segment (holes 7–12) is Foursomes,
where the engine allocates a **team** stroke and mirrors it onto both partners.
Naming golfers there would put two names up for one stroke on the ball — and
four names when both sides pop, which says nothing.

That segment falls back to the shared personal band (`POPPING ON HOLE 10`),
which stays true: the reader's own ball gets a stroke on this hole. It needs a
team form, and we did not invent one.

Everything else in §5 shipped: `YOU` first, short names capped at 5, `×2` on
the name, filled versus gold outline, no band when nobody pops, no hole number.

---

## 6 · The four new cards — three of them

Scramble, Better Ball and Irish Rumble draw the 120pt card as specified.
**Shamble does not, and cannot yet.**

A shamble in this app is a **Team Play** format, and `team_play` is a marker on
`tournament.active_games` with no `GameMeta` and no round-level slug — so
`primary_game(rnd)` can never return `shamble` and a builder keyed on it is a
branch nothing reaches. The card would serve it unchanged; what is missing is
the prior question: **what slug owns a Team Play round's lock screen?** That is
a Team Play decision rather than a foursome-formats one. The adapter is written
against the Team Play board, so it is one line on the day it is answered.

Two smaller notes:

- **`ALL 4` in gold** is built, on its own payload field, so answering the open
  question the other way is deleting a line rather than unpicking a string.
- **The empty-needle rule moved into the widget.** The payload keeps sending
  `{blue: 0, orange: 0}` because the key is required; the widget now reads the
  zeros as "no track" rather than drawing an empty one.

---

## 7 · D2 — built on casual Sixes, and it works

> Reported after using it: *"I am now able to see the scorecard and the score
> entry and the match status without scrolling."*

Which is D2's whole argument, confirmed on a real round. Four departures.

**The 44px tap target is not built, and the reason is structural.** The design
asks for 44px of area the pill does not visually occupy, padded above and below
into the bar. While the ribbon is the AppBar's `bottom`, a child painted
outside its parent's box does not receive taps — so 44px needs the toolbar row
and the standing row to be one render object. Worse, the 17px it would reach
upward lands under the overflow button, which is its own 48px target: two
overlapping targets at the same corner is a worse defect than a short one. The
pill takes the row's full 27px plus horizontal padding. **This wants a redraw
or a rebuilt app bar; flagging rather than guessing.**

**`Leaderboard ›` is also in the overflow menu.** The pill is the named target
the proposal exists to provide, but the overflow is a menu rather than a
competing visible control, so duplicating the destination costs no screen and
no attention. That is the distinction the pill-versus-icon argument turns on:
two *visible* targets at one corner compete, a menu item does not.

**The glyph rule needs rewording.** The packet writes it as *"trophy for a
place or a cup, money for a casual game"*, which maps the icon to the round
TYPE. Sixes breaks that: it is a casual money game whose standing is a **match
status**, and a money bag over `1 UP thru 2` labels the number as the one thing
it is not.

> **Proposed rule: a trophy when the standing is a RESULT — a place, a cup
> score, or a match status — and money when the standing IS a dollar figure.**
> A money qualifier beside a result does not change the glyph. The icon answers
> what the headline number is, not whether the round has stakes.

**The standing carries `thru N`, and wears the reader's team colour.** Two
additions the casual-money row does not have:

- `ALL SQUARE thru 1`, not `ALL SQUARE`. Sixes cuts the round into six-hole
  matches and can add EXTRA segments, so the hole number in the header does not
  say how far into THIS match he is. N counts the match, not the course.
- The standing is drawn in his side's colour — the same blue and orange the
  player rows below already carry. Sixes repairs the teams every six holes, so
  which side he is on is not something he can carry over from the last match,
  and the row is the one element that answers it without spending a word.

A decided segment takes golf's own notation — `WON 3 AND 2`, not `3 UP thru 4`
about a match that is over.

**One correction to our own first build.** The row read `1 UP · Even so far`
on the second hole. Sixes settles per SEGMENT, so nothing had settled and the
figure was literally true — and it reads as a contradiction beside a live
margin. Nothing settled now says nothing at all. Worth carrying into the
design: **the money figure needs a "nothing yet" state, and it is silence.**

---

## 8 · Open, for design

1. **`ALL 4` in gold** — the packet's own open question. Built; say the word
   and it goes white.
2. **The 44px target** — needs a drawing that works inside a 27px bar, or a
   decision to rebuild the app bar as one widget.
3. **The team form of the popping band**, for alternate shot.
4. **The standing line for the other ten score-entry screens.** D2 says the
   strip appears in every round carrying that round's standing. Sixes answered
   what "the standing" means for Sixes; Wolf, Rabbit, Banker, Nassau, Points,
   Survivor, Skins, Quota Nassau, Triple Nassau and Match Play each need the
   same question answered. **This is the biggest remaining ask in the packet**
   and it is one line of copy per game, not a layout.
5. **`thru` vs `through`** — the app says `thru` everywhere (`All Square thru
   3` on the Sixes card and leaderboard). Kept for consistency.

---

## Commits

| | |
|---|---|
| `f3b65f1` | Team cup card: split digits, push copy, footer, popping band (server) |
| `dbc8222` | Better Ball engine, model, endpoints |
| `9535d47` | Better Ball setup screen, wizard, leaderboard |
| `9d88e8a` | Widget: split digits, two-fill band, the foursome card |
| `b62e893` | D2 standing ribbon, casual Sixes |
| `5855b81` | Match strip removed; `thru N` added |
| `0ee7405` | Team colour; the `Even so far` fix; trophy |
| `92fa450` | Leaderboard in the overflow |
