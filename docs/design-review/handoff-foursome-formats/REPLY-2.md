# Reply 2 — the standing row, on every casual game

This answers the biggest open item in the first reply:

> **§8.4 — The standing line for the other ten score-entry screens.** D2 says
> the strip appears in every round carrying that round's standing. Sixes
> answered what "the standing" means for Sixes; Wolf, Rabbit, Banker, Nassau,
> Points, Survivor, Skins, Quota Nassau, Triple Nassau and Match Play each need
> the same question answered. **This is the biggest remaining ask in the
> packet** and it is one line of copy per game, not a layout.

It is built, on **sixteen** games. It was not one line of copy per game. Each
game turned out to hold a different opinion about what a standing IS, and three
of those opinions contradicted rules we had already written down. Those are the
parts worth design's time; the copy is in the table at the end.

---

## 1 · The rule that decides everything else

Every game's row reduces to one question, and it is not "what is the score":

> **What does this game make a golfer ask on the tee?**

The answers are genuinely different, and the row is wrong whenever it answers
a different one:

| Game | The question | The row |
|---|---|---|
| Sixes, Nassau, Fourball, Sequoya, Triple Cup | where does my match stand | `2 UP thru 5` |
| Stroke Play, Stableford | where am I in the field | `2nd of 12 · −1 thru 4` |
| Wolf, Points 5-3-1 | how many points, and who is ahead | `2nd of 4 · 12 pts` |
| Rabbit | who is holding it | `Dave has it` |
| Survivor | am I still in it | `Alive · finals` |
| Skins | how many have I got | `3 skins` |
| Banker | what do I owe | `+$40` |
| Triple Nassau | up on WHOM | `v JS 2 UP` · `v DP ALL SQ` |
| Mini Singles | who am I playing, and where is it | `Semi 1 · Gunst 2 UP thru 4` |

Two of these are worth dwelling on because they break the pattern deliberately.

**Skins does not rank.** Every other ranked game leads with a place, because a
place is the answer. The skins pot is divided by skins won, so two men on three
each take the same share and neither is ahead of the other — `T-1 of 4` would
invent a contest the game does not hold. The count leads, and it is also the
number a golfer actually tracks.

**Survivor inverts halfway through a leg.** While all three are in, `Alive` is
true of everybody, so the row says what the HOLE does — `Low golfer out`. Once
two are left, being in the finals is the whole question and the word earns the
loud slot. One template with a phase swapped into it would have spent the loud
half of the row on a word true of everybody, and it also did not fit: the first
build shipped `Alive · elimi…`, truncated, on a real round.

---

## 2 · Three rules in the packet that turned out to be wrong

### 2.1 The glyph rule — confirmed, and now exercised

The first reply proposed rewording *"trophy for a place or a cup, money for a
casual game"* to:

> **A trophy when the standing is a RESULT — a place, a cup score, or a match
> status — and money when the standing IS a dollar figure.**

Sixteen games in, exactly **one** takes the money glyph: **Banker**. It has no
match to be up in, no field to place in and no points — a hole is three
one-on-one bets and the only thing it produces is dollars. Every other game's
money rides in the quiet slot as a qualifier, which is what the reworded rule
predicts. The original wording would have given the money bag to nine casual
games whose standing is a match or a place.

### 2.2 "The standing wears the reader's team colour" — true for two games, false for the rest

The first reply reported this as a Sixes addition. It does not generalise, and
getting it wrong produced a defect reported from a singles match:

> **The Nassau row read `1 DOWN` in the colour of the side that was 1 UP.**

The margin was written from the READER's side and coloured from the LEADER's.
On every hole the reader was behind, the two halves of the row contradicted
each other.

There are two coherent answers and a game may only use the one its colour can
promise:

- **Colour the READER's side, and say `1 DOWN`.** Requires that the reader's
  colour is stable and on screen. **Sixes** uses this — and has to, because its
  pairings re-draw every six holes, so a leader-coloured row would change
  meaning mid-round.
- **Neutral margin, coloured by the LEADER.** Requires fixed sides, or a
  per-golfer colour. **Nassau, Fourball, Vegas, Sequoya, Triple Cup, Triple
  Nassau** use this. One string reaches all four phones and the tint says whose.

> **Proposed rule for the packet: a direction word (`DOWN`, `lost`) may only
> appear on a row whose colour is the READER's. Everywhere else the margin is
> neutral and the colour names the leader.**

The test is sharpest in Triple Nassau, where the third match is between the two
OTHER men: there is no reader for a direction word to be relative to, so one
rule for all three matches is the only readable option. The lock-screen card
for that game had already reached this conclusion; the row now matches it.

### 2.3 "One fact, one place" — right, with one exception we had to find twice

The pass removed nine blocks that restated what the row now says. Then Triple
Cup produced a counter-example:

> **Nowhere does it say who is playing who in singles on the score entry
> screen. I have to go to the leaderboard to find that out.**

Removing the match grid took the SCORES out — and the PAIRINGS with them. Two
singles run at once over the same six holes, so four rows tinted blue and
orange cannot say which blue plays which orange.

We restored the grid below the scorecard, removed the one-line pairing strip we
had added above it as a duplicate, and then put the strip back:

> **A second copy is a problem when the two can DISAGREE. It is not a problem
> when one of them is below the fold.**

The grid is under an 18-column scorecard; a golfer who does not already know it
is there will not scroll to find his opponent, and he needs that BEFORE he
enters a number. The strip above carries names and colours only — no margin, no
cup — so nothing in it can contradict the row above it or the grid below.

---

## 3 · What the row displaced, and what it did not

Nine blocks came off score-entry screens because the row said the same thing in
27px:

Sixes' match strip · Nassau's team banner and F9/B9/ALL chip row · Rabbit's
banner and segment strip · Survivor's `Survivors` panel and phase banner ·
Vegas' team rows · Points 5-3-1's bespoke grid · Skins' standings card ·
Fourball's status card and progress grid · Sequoya's bet banner, six-match
strip and money card · Triple Cup's match grid · the bracket's footer bar.

**Three blocks stayed, and the reasons are the interesting part:**

- **Banker's `WHERE IT STANDS`** — four money rows in a four-way money game,
  and every one of them matters. Unlike Vegas, where two absolute point totals
  said nothing the gap did not.
- **Wolf's decision bar** — a control, not a status. Wolf is the only game
  where the row was purely additive.
- **The leaderboard's cards** — a round total stated on a BOARD has no per-hole
  dots beside it to be double-counted against.

---

## 4 · Two app-wide cleanups that came out of it

### 4.1 `gets N` is gone from the play screens

Seven screens carried a chip stating the ROUND's allocation beside dots stating
THIS hole's. Read together they hand a golfer the arithmetic for subtracting a
stroke he has already been given. Triple Nassau was the worst case — two pills
and two dot columns, the same double-subtraction twice, in two colours, on
every row.

**It survives in three places, and the distinction is worth stating:**

> `gets N` is wrong where it duplicates a per-hole allocation. It is right
> where **every stroke in the game is the GAP between two handicaps**, because
> then the number is one end of exactly one match and nothing else states it.

That is **Banker** (the raw playing handicap on all four rows, so the hole's
arithmetic can be checked without trusting the app) and **Triple Nassau** (a
different allowance against each of two opponents). We removed Triple Nassau's
in the sweep and had to put them back — reported as *"there is nowhere that I
can see the strokes in the matches"*. The third is the leaderboard, where there
are no dots to compete with.

### 4.2 The standard scorecard, on the screens that had none

Score entry now draws the app's shared card for Vegas, Points 5-3-1, Skins,
Fourball, Triple Cup, Banker and the Mini Singles Bracket — replacing five
bespoke grids. Two findings:

**Stableford's card was showing the stroke plan backwards.** Its holes came
from what had a gross on them and its strokes from gross-minus-net — both of
which exist only on a PLAYED hole. So the card grew a column at a time and the
dots appeared behind the golfer rather than in front. On the one game where
knowing which holes give a stroke is how you decide whether to go for a green.
It is prospective across all eighteen now, and a double stroke draws two dots.

**Triple Cup's foursomes cells show the DRIVER only.** Alternate shot is one
ball between two men, so a gross in both partners' cells is the same stroke
written twice — and the blank turns out to be the useful half, because it says
whose turn the next one is.

---

## 5 · Open, for design

1. **The 44px tap target** — unchanged from the first reply, and now sixteen
   games are riding on the 27px row. Still wants a drawing that works inside
   it, or a decision to rebuild the app bar as one widget.
2. **Triple Cup dropped `of 4`** from the cup score to make room for the
   format: `0–0 Fourball 1 UP thru 4`. How many points are available never
   changes all afternoon; which format the group is playing changes twice and
   changes what they are about to do on the tee. Confirm.
3. **Vegas carries no pending-carry indicator.** Arguably the most actionable
   fact in a carryover round, and the lock card has a chip for it — but both
   slots are spent on the margin and the money. Third slot, or drop it?
4. **A plum for Triple Nassau.** The packet specifies `#B48CF0`; the set
   already has `#C9A6E8` (Survivor's Zombieville). We used the existing token —
   two near-identical purples for one semantic slot is how a palette drifts —
   but it wants confirming.
5. **Stroke Play's leaderboard tab** shows strokes-off in a form the TD called
   *"not ideal, but we can work with it."* The fix is the same one Stableford
   just had: a prospective `scorecard` block and the standard card. Not
   scheduled.
6. **Tournament games are next** and none of them has a row yet.

---

## 6 · The copy, per game

| Game | Loud slot | Quiet slot | Colour |
|---|---|---|---|
| Sixes | `1 UP thru 3` / `Won 3&2` | money, on decision holes | reader's side; grey after a re-draw |
| Nassau | `F9 1 UP thru 5` | `Overall 1 UP` | leader's side |
| Stroke Play | `2nd of 38` | `−1 thru 4` | none |
| Stableford | `2nd of 12 · 27 pts` | money, when the round ends | none |
| Rabbit | `Dave has it` / `Loose` / `Halved` | `+$10 so far` | mint when it is his |
| Survivor | `Low golfer out` → `Alive · finals` | `+$4 so far` | mint alive, plum Zombie |
| Wolf | `2nd of 4 · 12 pts` | `+$6 so far` | none |
| Points 5-3-1 | `2nd of 3 · 27 pts` | `+$4 so far` | none |
| Skins | `3 skins` / `No skins` | `+$12 so far` | none |
| Las Vegas | `+12 pts` (signed) | `+$12 so far` | leader's side |
| Banker | `+$40` 💰 | `You bank` / `Capped` | none |
| Fourball | `2 UP thru 5` / `win 3&2` | the bet, when it settles | leader's side |
| Sequoya 3s | `M3 · 2 up` | `+$10 so far` | leader's side |
| Triple Cup | `0–0` | `Fourball 1 UP thru 4` | match leader's side |
| Triple Nassau | `v JS 2 UP` | `v DP ALL SQ` | each leader's own |
| Mini Singles | `Gunst 2 UP thru 4` | — | none |

Every one draws before the first score, as `Tee off`. That was a reported
defect on the first build: the row vanished on an unplayed hole, taking the
only named way to the leaderboard with it — exactly when a first-time player
goes looking for it.

---

## Commits

`1cae4ec` `b3cf171` `93b018a` `311bdc2` Sixes — names on a re-draw, grey,
notation · `0d2998a` `08b3df3` `33c3465` `865a9df` `ec49e74` Nassau — two bets,
the banner off, the `1 DOWN` fix · `45da5b5` `3308d09` `50f9f6a` Stroke Play ·
`fc324ee` Rabbit · `362e13f` `5d4465a` `057db54` `4b54ed6` Survivor ·
`fd7e20a` `00de625` `d20da50` Wolf · `940205c` `6d0826a` Las Vegas ·
`1ff0766` the `gets N` sweep · `aaf6e6e` `325d554` Banker ·
`9283888` `a97aedf` `5a3b48a` Points 5-3-1 · `000f0eb` `c9fa604` Skins ·
`7197e80` Fourball · `f211910` Sequoya 3s ·
`d3f4249` `52d71b5` `70569a7` `49f22e5` `d024466` `f4bda03` `fe4223a` Triple
Cup · `b032ec0` `3a6d558` `cfba982` Mini Singles Bracket ·
`f2c8728` `830e6f1` Stableford · `974013b` Triple Nassau
