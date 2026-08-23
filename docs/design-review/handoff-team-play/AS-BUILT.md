# Foursome Play — as built

What shipped from the `handoff-team-play` packet, and every place it differs.
Written to go back to design. The shareable version of this document is an
Artifact; this file is the copy that lives with the packet.

The build follows the packet closely — one round, one pool, no side games, the
phantom 4th, ties combined and split, odd cents to the highest course handicap.
Every worked example reproduces: Pine 6.15 → 6, Clay 7.50 → 8, Slate 8.45 → 8,
Dune three men plus a phantom 16 → 10, and the drawn settlement to the cent
including which named golfer takes the odd pennies.

What follows is only the divergences. Most came out of playing real rounds;
a few want a design ruling rather than a note.

---

## Differs from the packet

| # | Packet | Shipped | Why |
|---|---|---|---|
| 1 | Team Play | **Foursome Play** | "Foursomes" is already `GameType.FOURSOMES` (alternate shot, in the Cup picker) and `Foursome` is the group model, ~300 refs. Code keeps `team_play`. |
| 2 | Step 2 tees, step 6 build teams | **No build-teams step; nine steps** | Groups & Tees already assigns, and the group IS the team. Asking twice let the second answer silently win. The allowance/balance moved to the handicap step. |
| 3 | Teams default to a colour name | **Group 1 … Group N** | Teams name themselves from the hub. The colour still identifies the row; it is not the name. |
| 4 | A bespoke full-screen stepper | **The app's standard card** | `InlineScorePicker` in the Survivor/Skins row pattern — the component every other game renders. A fourth idiom here bought nothing. |
| 5 | A drive row on the card | **A drive chip strip above the scores** | The drive is its own question; hanging the score off a driver's row says the score is his. All the packet's drive rules are intact. |
| 6 | "Net is not shown on the card" | **Stroke dots + a net-to-par line** | ⚠ Deliberate departure — *the one we would most like design to rule on.* Seeing which holes carry a stroke matters on the tee, and the dots are the app's existing notation. The round figure is never printed on a hole; the `gets 10` chip states it once. |
| 7 | Board columns Gross / Net as totals | **Net to par only; ranks on it** | Every other board in the app reads against par. Ranking on raw totals contradicted the column while teams were still out. Gross to par dropped — on a shamble it is a two-ball aggregate against a doubled par. Totals moved into the expanded row. |
| 8 | Rota illustration starts at hole 8 | **The rota starts at hole 1** | Both illustrations start their cycle at 8, which cannot be reconciled with hole 1 taking the first pair. Read as showing the pattern, not an offset. Easy to flip. |

## Added — implied by the packet but not written in it

- **A shamble's par is multiplied by the ball count.** Best-2 on a par 4 is a par
  of 8. Without it every shamble team read about +70.
- **Net counts only the strokes received so far.** Through 7 holes a team has had
  about half its allowance. At 18 it agrees exactly with `gross − allowance`.
- **The shamble allowance is a ceiling, and four balls takes 100%.** The packet's
  2.3 → 95% case implies a ceiling; the 4-ball figure is our extension and design
  may want a different one.
- **All four balls in a shamble's expanded board row**, counting ones tinted — a
  row showing only the team's figure cannot say whose scores made it.
- **Course handicap on the Groups & Tees rows** (`White · CH 12`) — the number the
  TD is grouping on and what the next three steps spend.
- **The round feed reports teams, not golfers.** A shamble was posting each
  golfer's front-nine gross; four balls go out and two count. Both recaps are now
  team to-par — at the turn once the whole field is through, and at the end.
  Consistent with "no side games", the Stroke Play tab and Skins-pool link are
  also suppressed for this shape.
- **The tee sheet learned to fill, warn and sort.** Not a Foursome Play screen,
  but the flow needs it: setting the first time offers to lay the rest out at a
  chosen interval, clashes are named, and the sheet reads in play order.

## Errors found in the packet

Both are `@dsCard` metadata, so a re-send would carry them forward.

- `12-flow-map.html` — subtitle says **six** setup steps; the body and every step
  chip say eight.
- `09-score-entry.html` — subtitle mentions **Irish Rumble**, which
  `13-decisions-log.html` records as removed as a team format.

## Still open

- **No on-course card for setting the alternating pairs.** The packet asks for a
  card on hole 1 before the first score. The endpoint is built and tested (set
  once, second attempt refused) but nothing calls it, so a team on that rule falls
  back to roster order.
- **Mid-round withdrawal is not wired into this shape.** A shamble hole counts
  only when every ball is in, so a withdrawal stalls the team's count. Other games
  use `withdrew_after_hole`. Worth doing before a real event.
- **Flights and multi-round team events** — deferred exactly as the packet leaves
  them.
