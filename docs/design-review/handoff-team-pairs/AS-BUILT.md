# Pairs Play — as built

What shipped from the `handoff-team-pairs` packet, and every place it differs.
Written to go back to design, and a companion to
`../handoff-team-play/AS-BUILT.md`, which still stands.

The build follows the packet closely. **Pairs are the same flow with the size
set to two** — same wizard, same groups screen, same payout, same board, same
settlement, same receipt, and not one screen duplicated. Every worked figure
reproduces: Maiolini 4 and Yau 19 get **4** in a scramble, **3 / 16** in
best ball, **12** in an alternate shot and **10** in both Scotch and Chapman;
the drawn field of six pairs comes out 4, 5, 5, 5, 4, 7 and the balance strip
reads **4 – 7**.

What follows is only the divergences. Two want a design ruling; the rest are
notes.

---

## Differs from the packet

| # | Packet | Shipped | Why |
|---|---|---|---|
| 1 | Pairs are a **team-size control on step 1** under one `Team Play` card | **Two picker cards** — `Foursome Play` and `Pairs Play` — routing into one flow | ⚠ *The one we would most like a ruling on.* The packet's argument is "do not duplicate seven screens to change two", and nothing is duplicated: same `_stepFlow`, same `TeamPlayConfig` row, same widgets. But the product name that shipped is **Foursome Play**, and "Foursome Play — team size: pairs" is a contradiction on screen. The picker also already drew a `Two-golfer team` card, disabled pending this engine. One extra radio on a screen the TD sees once is not a duplicated screen. |
| 2 | A **build-pairs screen** with a tray, drag-to-move and a balance strip | **No build step** | Carried over from the fours build for the same reason: Groups & Tees already assigns, and the group IS the team. Sizes default to twos, the balance strip and the per-golfer contribution live on the handicap step, and the odd-field block gates Next there. The repair is "go back to Groups & Tees", not drag-from-a-tray. |
| 3 | Pair name **defaults to the two surnames** | Same, and it is **written to the team**, not just displayed | The hub, the tee sheet and the chat header know nothing about Team Play, so a derived-only name would have left the board saying `Maiolini & Yau` while the hub said `Group 1`. `TeamPlayTeamState.name_is_default` lets the name follow a roster change until the TD types over it. A foursome is untouched — `Group N` is a label, not a name. |
| 4 | (not stated) | **Clearing a name resets to the default, not the colour** | The rename endpoint set a blank name to the colour, which contradicts the fours decision that "an unnamed team is `Group N`, the colour identifies the row". Now blank gives back `Group N` for a foursome and the two surnames for a pair. **This changes fours behaviour too.** |
| 5 | *Maiolini plays the second shot* | Surname on the card, full name everywhere else | The packet writes both tee sentences in surnames, and it is right: `Anna Maiolini plays the second shot, then alternate.` wraps to two lines and reads nothing like the way a pair talks. The drive tracker, the roster and settlement keep full names. |
| 6 | Three of four / three of five formats reject a three-ball | **Four of the five** | Best ball allows it; scramble, alternate shot, Scotch and Chapman do not. The packet gives the count three different ways (`three of five` in HANDOFF, `three of the four` twice in the HTML) and undercounts in all of them. The argument is unaffected. |
| 7 | "Only **two** steps behave differently — the format list and the allowance table" | **Three** | The drive step is the third, and the packet's own §5 is what makes it so: Scotch turns the tap into an instruction, alternate shot replaces the quota with a rota, and best ball and Chapman remove the control entirely. Worth correcting in the decisions log, because "nothing else in the flow knows the team size" is otherwise the load-bearing claim. |

## Added — implied by the packet but not written in it

- **A one-ball round can now be completed.** A scramble, alternate shot, Scotch
  or Chapman posts one `TeamHoleScore` per hole and no per-golfer scores at
  all; the round-completion check and the `holes remaining` count both read the
  per-golfer table, so **every scramble round shipped so far was permanently
  unfinishable**. Both now read the team table for a one-ball format. Not a
  pairs bug — pairs just quadrupled the formats that hit it.
- **The alternate-shot rota card is built, and it closes the fours gap.**
  `../handoff-team-play/AS-BUILT.md` lists "no on-course card for setting the
  alternating pairs" as still open — the endpoint was written and tested and
  nothing called it. The card now calls it at **both** sizes: two ways to split
  a pair, three ways to split a foursome, AB/BC/AC for three golfers.
- **The card carries the drive roster even with no quota.** Scotch needs the
  tap on every hole because it is the instruction, and a no-quota rule has no
  windows to draw chips from. `drive_options` sends the roster and the pick.
- **The two sentences are computed on the server** (`tee_note`), as is what the
  control does (`drive_control`: `record` / `instruction` / `rota` / `none`).
  A client re-deriving "who plays the second shot" is a rule in two places.
- **The format list and the drive-rule list are server-owned.** A two-golfer
  shamble and a four-golfer Chapman are refused, and a drive rule the new format
  cannot honour is **coerced rather than refused** — a TD switching to best
  ball should not have to go back and un-set a quota that no longer exists.
- **The size locks with the format at the first score.** A card that entered
  two numbers a hole cannot be re-read as one.
- **A three-golfer best-ball pair owes three golfers' worth of drives**, not two.
  The quota follows the roster when the roster is bigger than the size; the
  phantom's floating share falls out at zero, because pairs have no phantom.

## Rulings taken during testing

- **Twelve colours, and they recycle.** A twenty-team field gives team 13 Pine
  again. Confirmed as the wanted behaviour rather than widened: the palette
  already carries three greens and four ambers, and a fourth green nobody can
  separate on a phone in sunlight is worse than an honest repeat. So **colour
  is a finding aid, never an identifier** — every board row carries its name
  beside the swatch, and the scorecard labels its rows `B & P` rather than
  leaning on colour. The one place it must hold is INSIDE a playing group,
  where two pairs share a card; the colour ordinal is derived from
  `(group, slot)`, which keeps those two consecutive and so never equal.
- **No drive requirement, no asking who drove.** The packet argues the Scotch
  tap should be mandatory because picking the drive says who plays next. A pair
  on the tee already knows that, and recording it buys the app a sentence and
  the golfers nothing. Set a quota and the tap returns, sentence included,
  because then it is counting something.
- **A named pair still shows its golfers' initials on the scorecard.** Name a
  pair "The Ringers" and the board says The Ringers, the entry block above the
  grid says The Ringers, and the grid row says `B & P`. Kept deliberately: the
  card is where somebody enters scores for PEOPLE, so the golfers' initials are
  the more useful thing in a 58-pixel column — a nickname's initials would tell
  the scorer less. The colour bar ties the row to the named block above it.

- **No `gets N` chip on either card.** It restates the round's total where
  nobody uses it; the dots already answer the question somebody standing
  on a tee is asking, which is which holes carry a stroke.
- **Golfers, not men.** Coed play is the expectation, so the copy does not
  assume otherwise anywhere in the flow. `men's` and `women's` survive in
  exactly one place — the names of the tee sets and their stroke indexes —
  because there the distinction is the meaning.

## Implementation notes design may care about

- **Best ball is a shamble whose count is 1.** It reuses the whole own-ball
  path — the card, the counting-net subset, the expanded board row — with two
  rows instead of four. Best-1 on a par 4 is a par of 4, which is right, and
  falls out of the existing par-times-count arithmetic for free.
- **Nothing branches on a format name any more.** `plays_one_ball` and
  `plays_own_ball` replaced eleven `is_scramble` checks; adding a seventh
  format is a table entry rather than eleven edits.
- **All four one-ball pair tables are positional**, so 50% of the combined is
  stored as `(50, 50)` and needs no special case. The screen still reads it
  back the packet's way — *50% of the combined course handicap*.

## Still open

- **Mid-round withdrawal** is still not wired into this shape, unchanged from
  the fours build. An own-ball hole counts only when every ball is in, so a
  withdrawal stalls a best-ball pair exactly as it stalls a shamble team.
- **The handicap dots on the card** remain the deliberate departure the fours
  as-built flagged, and still want a ruling.
- **Flights and multi-round team events** — deferred exactly as the packet
  leaves them.
- **Odd-field repair is not on the block.** The block names the golfer and
  states the three ways out, and Next waits on it — but the fix happens back on
  Groups & Tees rather than by dragging them into a seventh pair, because that
  is where this app assigns golfers.
