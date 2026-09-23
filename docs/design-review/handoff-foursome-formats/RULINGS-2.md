# Standing row — rulings

The decisions taken while building D2's standing row on sixteen games, stated
as rules so each can be accepted or overridden on its own. The narrative is in
`REPLY-2.md`; this is only what now governs the row.

Written 23 Sep 2026, against the row as shipped on this branch.

Each ruling says what it decides, why, and **what overriding it costs** —
because several of these are cheap to reverse and two are not.

---

## §1 — What the standing IS, per game

**Ruling: the row answers the question the GAME makes a golfer ask on the tee,
not "the score".**

Sixteen games gave nine different answers. The row is wrong whenever it answers
a different question, and three games proved that by being wrong first:

| The question | Games | Form |
|---|---|---|
| where does my match stand | Sixes, Nassau, Fourball, Sequoya, Triple Cup | `2 UP thru 5` |
| where am I in the field | Stroke Play, Stableford | `2nd of 12 · 27 pts` |
| how many points | Wolf, Points 5-3-1 | `2nd of 4 · 12 pts` |
| who is holding it | Rabbit | `Dave has it` |
| am I still in it | Survivor | `Alive · finals` |
| how many have I got | Skins | `3 skins` |
| what do I owe | Banker | `+$40` |
| up on WHOM | Triple Nassau | `v JS 2 UP` · `v DP ALL SQ` |
| who am I playing, and where is it | Mini Singles | `Semi 1 · Gunst 2 UP thru 4` |

**Two deliberate breaks from the pattern**, both of which a uniform template
would have got wrong:

- **Skins does not rank.** The pot is divided by skins won, so two men on three
  each take the same share. `T-1 of 4` would invent a contest the game does not
  hold.
- **Survivor inverts mid-leg.** While all three are in, `Alive` is true of
  everybody, so the row says what the HOLE does — `Low golfer out`. Once two
  are left, being in the finals is the question and the word earns the loud
  slot.

**Overriding this** is per-game copy and costs nothing structural.

---

## §2 — The glyph. **Confirmed, and now exercised.**

**Ruling: a trophy when the standing is a RESULT — a place, a cup score, or a
match status — and money when the standing IS a dollar figure. A money
qualifier beside a result does not change the glyph.**

This was proposed in the first reply against the packet's *"trophy for a place
or a cup, money for a casual game"*, which maps the icon to the round TYPE.
Sixteen games in, exactly **one** takes the money bag: Banker, which has no
match, no field and no points. The packet's original wording would have given
it to nine casual games whose standing is a match or a place.

**Overriding this** means naming which games get the money bag; the code takes
it as a per-game argument.

---

## §3 — Direction words. **This one produced a defect on the course.**

**Ruling: a direction word (`DOWN`, `lost`) may appear only on a row whose
colour is the READER's. Everywhere else the margin is neutral and the colour
names the LEADER.**

The first reply reported "the standing wears the reader's team colour" as a
Sixes addition. It does not generalise. Nassau wrote its margin from the
reader's side and coloured it from the leader's, and on every hole the reader
was behind the two halves of the row contradicted each other:

> `1 DOWN` in the colour of the side that was 1 UP.

There are two coherent schemes and a game may use only the one its colour can
promise:

- **Reader-coloured, says `1 DOWN`.** Needs the reader's colour stable and on
  screen. **Sixes only** — and it must, because its pairings re-draw every six
  holes, so a leader-coloured row would change meaning mid-round.
- **Neutral, coloured by the leader.** Needs fixed sides or a per-golfer
  colour. **Nassau, Fourball, Vegas, Sequoya, Triple Cup, Triple Nassau.**

The test is sharpest in Triple Nassau, where the third match is between the two
OTHER men: there is no reader for a direction word to be relative to.

**Overriding this** is not advisable without answering that case.

---

## §4 — Las Vegas may sign its margin; nothing else may

**Ruling: Vegas states `+12 pts` / `−12 pts` from the reader's side. Every
other margin on the row is neutral.**

Vegas has no perspective problem: the two sides are fixed at setup and never
change, and the row's money figure is signed from the same side. A neutral
margin beside a signed money figure is the disagreement §3 is about, one slot
over.

The colour is still the LEADER's, not the reader's, because the player rows
below are tinted team 1 blue and team 2 orange, fixed. **So the sign is the
reader's and the colour is the leader's, and neither contradicts the screen.**

---

## §5 — The row draws before the first score

**Ruling: every game's row draws from the first tee, as `Tee off`.**

The first build hid the row on an unplayed hole. That takes the only NAMED way
to the leaderboard off the screen exactly when a first-time player goes looking
for it — which is the problem D2 exists to solve. A row with nothing to report
still has a pill.

**Overriding this** re-opens the wayfinding problem and is not recommended.

---

## §6 — Money is settled, or silent

**Ruling: the money figure reports money already owed. Nothing settled shows
nothing — never `$0`.**

`1 UP · Even so far` on the second hole reads as a contradiction; `$0` reads as
a settled nothing rather than nothing settled.

Which games can speak, and when:

| Live from hole one | Wolf, Points 5-3-1, Las Vegas, Banker — a hole IS its own settlement |
| On a decision hole | Sixes, Rabbit, Survivor, Sequoya — a segment, leg or match settles |
| At the end | Fourball (one match), Stableford (a prize projection until the last putt) |
| Never on this row | Nassau, Stroke Play, Mini Singles |

---

## §7 — When a second copy of a fact is allowed

**Ruling: a second copy is a problem when the two can DISAGREE. It is not a
problem when one of them is below the fold.**

Nine blocks came off score-entry screens for restating the row. Then Triple Cup
produced the counter-example:

> Nowhere does it say who is playing who in singles on the score entry screen.

Removing the match grid took the scores out and the PAIRINGS with them. We
restored the grid under the scorecard, removed the pairings strip above it as a
duplicate, and then put the strip back — because the grid is below an 18-column
card and a golfer who does not know it is there will not scroll to find his
opponent, which he needs BEFORE entering a number.

The strip carries names and colours only, no margin and no cup, so it cannot
contradict the row above it or the grid below.

---

## §8 — `gets N` survives in exactly two kinds of place

**Ruling: `gets N` is wrong where it duplicates a per-hole allocation, and
right where every stroke in the game is the GAP between two handicaps.**

Removed from seven play screens, where a round-total chip sat beside dots
stating the hole's and the pair handed a golfer the arithmetic for subtracting
a stroke he had already been given.

Kept on **Banker** (the raw playing handicap on all four rows, so the hole's
arithmetic is checkable) and **Triple Nassau** (a different allowance against
each of two opponents). We removed Triple Nassau's in the sweep and had to put
them back — reported as *"there is nowhere that I can see the strokes in the
matches"*. Also kept on the leaderboard, where there are no dots to compete
with.

---

## §9 — Counting rules that are not negotiable

These are shotgun-safety, not preference. Each was wrong once.

- **`thru N` is a COUNT of holes played, never a hole number.** A group that
  played 7 through 12 is thru 6.
- **The `M` in `3&2` ships from the SERVER.** It is holes left in the match's
  own window along the group's play order; `18 − finishedOnHole` printed
  `3&11` off a shotgun.
- **`thru` counts the MATCH, not the course**, where a game cuts the round into
  segments — Sixes, Triple Cup, Sequoya, Mini Singles.

---

## §10 — Triple Cup

**§10.1 — The cup is the headline, including `0–0`.** Triple Cup exists to
produce a cup score; the match in front of you is a way of earning a point in
it and gets the smaller slot. An earlier pass swapped the two to avoid showing
`0–0`: **a headline that means one thing before the first point and another
after is a slot nobody can learn.**

**§10.2 — `of 4` gave its width to the FORMAT.** `0–0 Fourball 1 UP thru 4`.
How many points are available never changes all afternoon; which format the
group is playing changes twice, and it changes what they are about to do on the
tee. *(TD's call, 22 Sep. Confirm.)*

**§10.3 — On a CUP round the headline is the TOURNAMENT's cup**, not the
foursome's: `6½–4½ · 12½ to win`. On a Ryder-Cup round the foursome is one of
several and the golfer is playing for the twenty-four. `to win` is the one
figure a foursome's four points cannot provide, because a cup is CLINCHED
rather than played out.

**§10.4 — The figure reports the group's match when the reader is not in one.**
A TD opening a foursome he is not playing in gets a screen entirely about that
group; a row that went blank there reported nothing about the thing on screen.

---

## §11 — The row is casual-only, except Triple Cup

**Ruling: on a tournament round the row draws for Triple Cup and for nothing
else, for now.**

Every other row was written against a casual round and says what a casual round
means — a place `of 4` is a place in the FOURSOME, which on a tournament field
would be four golfers wearing the words of a place in the field. Turning them
all on would ship nine untested rows.

**This is the first thing to revisit on the tournament side**, and it is a
per-game question, not a switch.

---

## Open, for design

1. **The 44px tap target.** Unchanged from the first reply, and sixteen games
   now ride on the 27px row. Needs a drawing that works inside it, or a
   decision to rebuild the app bar as one widget so a child can paint outside
   its parent's box.
2. **§10.2** — confirm `of 4` staying off.
3. **Las Vegas carries no pending-carry indicator.** Arguably the most
   actionable fact in a carryover round and the lock card has a chip for it,
   but both slots are spent. Third slot, or drop it?
4. **Two plums.** The Triple Nassau packet specifies `#B48CF0`; the set already
   has `#C9A6E8` (Survivor's Zombieville). We used the existing token — two
   near-identical purples for one semantic slot is how a palette drifts — but
   it wants confirming.
5. **Stroke Play's leaderboard tab** shows strokes-off in a form the TD called
   *"not ideal, but we can work with it."* The fix is the one Stableford just
   had: a prospective `scorecard` block and the standard card.
6. **Tournament games**, per §11.
