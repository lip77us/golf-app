# Built from REPLY-design.md — 28 Oct 2026

All nine items and both adoptions. Two screens off the simulator against a
live local server; real round, real scores.

---

## The one that wasn't cosmetic — item 7

The steal was **wrong in the engine**, not just worded wrong. Any natural
birdie won outright, so a 3 on a par 4 beat a 3 made with a stroke on a par
5 — a net eagle, and the better score. `decide` now applies the steal only
when the best ball on the hole is a net birdie. Exactly one test pinned the
old behaviour, and it was the case you named.

**The wording moved to the server, because there were five copies** — the
board footnote, two strings in the setup card, two doc comments — and they
had already drifted: the published note said a gross birdie `beats a lower
net score`, which the engine never did. `skin_rules` now owns the sentences
and the option catalogue; a test greps four client files for any sentence
about this rule, right or wrong. Being right is not the point; being the
only copy is.

## 01 · Nassau, Claremont

- **Money (item 1).** `All square · now $0` is gone — it reads
  `Paul & Larry, each · now +$40`. The settled figures read a stored result
  that is only written when a bet CLOSES, so for most of a round they were
  all zero. The server now also emits `live_total`: every bet with a live
  margin counted to whoever is ahead, clamped to the cap. A nine that has
  not started counts nothing, which is what keeps the unplayed back nine out
  of the figure rather than guessing at it. **The client does not compute
  this** — same rule as the rest of the money on these boards.
- **Sides (item 2)** take teamPine and teamClay. A cup match keeps its own
  declared colours; overriding those would make a cup read in a palette its
  TD did not choose.
- **The not-started nine (item 3)** is dashed, unfilled, with dashed tiles
  and no ball rows. One painter does this and the carried skins tile, or
  they drift to different dash lengths.
- **No outer card (item 4)**, and the scorecard below has its own rather
  than a divider inside a shared one.
- **Ball rows keep both sides and lose the points row**, as adopted.

## 02 · Stroke Play (item 9)

`# · Player · Thru · Gross · Tot`, Tot a filled box — pine under, deep pine
level, grey over. No `S-Off` column, no chevrons, one row open at a time.
`Prize` appears only when there is a pot, which this round has not, so the
column is absent here rather than empty.

**One reading I had to choose.** "The switch changes Tot and Gross
together" — I built Tot as the figure the board RANKS on (so in Strokes-off
mode it is the strokes-off value, which is why the `S-Off` column could go)
and Gross as the raw gross-to-par beside it. That makes every other
constraint in the item true. Say if you meant both columns to change.

## Skins — items 5, 6, 8

Not shown here (the screens went over in the last packet), but built:
carried holes are dashed; with a pool the ledger header reads `$40 pool`
and Up next shows skins riding with no dollar figure; the group card loses
its outer card and its `Status:` line, with the group name as a plain label
above the board on multi-group boards only.

---

## Open

- The `gets N` chips are still on the row subtitles — your cleanup list, as
  noted both ways.
- `patterns/stroke-play-board.html` was not in the files I could read, so
  item 9 is built from the written spec. Worth a look against the pattern.
