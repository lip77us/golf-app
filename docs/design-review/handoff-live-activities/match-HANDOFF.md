# Handoff — Match play Live Activity (singles · fourball)

**One shipping surface, two games, six states.** `live-activity-match.html` (card: **Match play — lock screen**, group **Live Activities**, lives at `screens/live-activity-match.html`).

Read `HANDOFF.md` first for the shared frame — the five slots, the colour rules, the lifecycle, the Dynamic Island sizes. This document is where match play departs from it. `sixes-HANDOFF.md` is the reference implementation.

---

## Why singles and fourball are one card

Both are a single match between two sides over eighteen holes, decided by holes won. Every slot answers the same question in both. The only difference is how many names sit on a side — one, or two joined by an ampersand.

Do not split them. Two cards differing by a conjunction drift apart within a release.

| | Singles | Fourball |
| --- | --- | --- |
| Header | `SINGLES MATCH` · `HOLE 7` | `FOURBALL` · `HOLE 13` |
| Sides line | `Paul Kelly` / `Sam Reid` | `Paul Kelly & Dave Moran` / `Sam Reid & Lee Naylor` |
| Big number | `2 UP` | `1 UP` |
| Everything else | identical | identical |

## This card never pushes

The push test in the umbrella packet is **could the reader have known this from the hole they are standing on?** In a two-side match played inside one group the answer is always yes — both sides are within earshot of every putt.

**No notifications, all round.** Not a hole won, not dormie, not the match closing out. The reader watched all of it.

This is a deliberate zero, not an oversight. Do not add `Dave won the 7th` later. If a state ever *does* need announcing on this card, it is a concession (see open questions) — nothing else.

## The five slots

| Slot | Holds | Notes |
| --- | --- | --- |
| **Header** | game name + `HOLE n` | Advances all round, including after the match closes |
| **Big number** | `2 UP` / `ALL SQ` / the result `4 & 3` | 36px, side colour |
| **Sides** | both sides in full, leader bold and coloured | Full names — two Pauls in a group is common |
| **State** | `DORMIE` / `n TO PLAY` / `CLOSED` | Match words only |
| **Footer** | `+2 · Thru 6 · $20 match`, money right | Gross leads; money is settled only |

### Colour

**Blue and orange are assigned once and hold to the 18th.** A single match never changes sides, unlike Sixes, which redraws pairings and must re-assign per match. The leading side takes the colour on both the number and the name; the trailing side is dimmed at 60%.

`ALL SQ` is **white at 90%**, never mint. Mint is the app's colour and cannot name a side.

### State slot

- `DORMIE` when the lead equals the holes remaining.
- `n TO PLAY` the rest of the time, counted **against the eighteen** — there are no segments in this format, so Sixes' nominal-range problem does not exist here.
- `CLOSED` when the match is decided, with the hole underneath: `ON THE 15TH`.

**Handicap is not on the card.** Strokes given are fixed at the first tee and never change — a setup fact, not news. `gets 4` beside a running match state invites subtracting it a second time.

## The state the format actually needs: a match that closes early

A match won **4 & 3** ends on the 15th and the group has three holes left.

The card does **not** dismiss and does **not** freeze:

- Big number becomes the **result** — `4 & 3` in the winner's colour.
- State slot reads `CLOSED` / `ON THE 15TH`.
- Money slot **finally fills** — a match pays when it closes, and this one just did.
- **Header keeps advancing** (`HOLE 16`, `HOLE 17`) because the group is still playing golf and the reader's gross is still moving.
- The match line never changes again.

**Nothing takes over the live line.** There is no bye in this format and no code for one. A press is Nassau's object and it presses a nine that is still running, not the tail of a finished match.

## Money is empty for most of the round

Settled money only, and a single match settles exactly once. On a straight singles match the money slot is **empty from the 1st to the 17th** and holds one figure at the end.

That is correct, not broken. An in-progress match is worth nothing yet, and `$0` reads as a match played for nothing. Never render a zero here.

## Gross against par is on every state

Stake or no stake, quiet or loud. It is the number a golfer checks without meaning to and the only personal figure a neutral board can afford.

Two states carry it in the **header** instead of the footer, because they have no footer:

| State | Footer | Header |
| --- | --- | --- |
| Normal, staked | `+2 · Thru 6 · $20 match` | `HOLE 7` |
| **No stake** | removed | `HOLE 5 · +2 THRU 4` |
| **Quiet treatment** | removed | `HOLE 16 · +9 THRU 15` |

**A no-stake round removes the footer, not the score.** Casual match play is often played for nothing; gross and thru rattling around a row built to end in money looks like a bug for eighteen holes, and a permanently blank right edge looks like a failed fetch. Remove the row, move the two figures up.

The quiet treatment takes the same route for the same reason — it gives up the stake and the money, which is the loud part.

The one reader with no gross is a **watcher**, who is not playing. Skins is the only card with watchers today; it trades that slot for `par` and the field size.

## Fourball specifics

- The sides line carries **both pairings in full**.
- **Whose ball counted is not on the card.** It fails the push test twice — the reader saw the hole, and it is history rather than state.
- The footer's gross is the **reader's own** score, never the team's better ball. A team figure on a neutral board is a number nobody can check against their own card.

## Dynamic Island

| Size | Content |
| --- | --- |
| Minimal | mark + mint dot |
| Compact | `2 UP` in the side colour + the leading side's surname |
| Compact, closed | `4 & 3` + the winner's surname |
| Expanded | lock card composition + an 18-hole run strip (blue/orange per hole won, blank for halved) |

The run strip lives only in expanded, where there is no footer competing for the row.

## Rules for code

1. **One activity per round, owned by the primary game named at setup.** A fourball with a skins side game gets this card and no skins card.
2. **Starts on the first score posted.** Not at tee time — it buys back the car park against the 8-hour iOS ceiling, and an abandoned round leaves no ghost.
3. **Sides and their colours are assigned once,** at setup, and are immutable for the round.
4. **`n TO PLAY` is `18 − holes played`,** not a segment remainder.
5. **The money slot renders nothing until the match closes.** Not `$0`, not `—`.
6. **No-stake and quiet states move gross into the header** rather than dropping it.
7. **Final state on round sign** — what you won and who to see, held ~5 minutes, then self-dismiss. `−$20 / Lost 3 & 2 / Pay Sam`.
8. **Always-on is the same composition,** display-dimmed by iOS. No separate layout.

## Open questions

- **Concession.** A conceded match is a result nobody scored, so it has no hole to attach to. Drawn as an ordinary close (`2 & 1` / `CLOSED`), which loses the fact that it was given. This is the one thing on the card that might earn a push — a golfer in the group behind cannot see a concession happen.
- **Halved matches.** Drawn as `ALL SQ` / `HALVED`, money slot empty. Confirm the stake is **voided** rather than banked at zero.
- **Presses in singles.** Nassau owns the press and there is no code for one on a straight eighteen-hole match. If casual singles can be pressed, this card needs Nassau's orange chip and its push, and the two cards start to converge.
- **Extra holes.** A match all square after 18 that plays on has no hole number left. `HOLE 19` is drawn nowhere yet.
- **Three-sided or odd groups.** Drawn as two sides only. A threesome playing singles matches against each other is three simultaneous matches and does not fit this card at all.
