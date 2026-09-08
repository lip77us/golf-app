# Handoff to design — four play surfaces that were never drawn

**This is a request, not a record.** The four games below have shipped Setup
and shipped Play; only the Play half has never been through design. Each has an
`AS-BUILT.md` beside it describing what is there today — this document is the
brief for what to draw, and the decisions that are design's rather than code's.

One file rather than four, deliberately, and against the one-file-per-game rule
we agreed for as-builts. That rule exists because an as-built is re-read every
time its game changes; a brief is read once and scoped as a batch, and these
four compete for the same hours. Say the word and I will split it.

| Game | Where it lives now | Detail |
|---|---|---|
| One-Round Triple Cup | its own screen, `/triple-cup` | [`triple-cup/AS-BUILT.md`](triple-cup/AS-BUILT.md) |
| Mini-singles Bracket | its own screen, `/match-play` | [`mini-singles/AS-BUILT.md`](mini-singles/AS-BUILT.md) |
| Skins | two bands inside shared score entry | [`skins/AS-BUILT.md`](skins/AS-BUILT.md) |
| Stableford | one grid inside shared score entry | [`stableford/AS-BUILT.md`](stableford/AS-BUILT.md) |

**Recommended order is that order** — the two own-screen games first, because
they are the ones where a drawing changes the most, and Skins and Stableford
last because both are close to right and want a pass rather than a design.

---

## What NOT to redraw

The shipped furniture wins, as it did in the Banker and Sequoya packets: the
app bar, the score card, the hole navigation, the inline picker and the
scorecard grid are all shared and drawn already. A change to any of them is a
change to every game, and worth raising as its own decision rather than
arriving inside one game's screen.

Available and free to compose with:

- `GameColors.team1` / `team2` — the two side colours, used by every team game
- `HoleGridScorecard` — the shared 18-hole grid with a pinned label column
- `SectionCard`, `GolfAppBar`, `InlineScorePicker`, `NetScoreButton`
- The Halved palette: deep pine, pine, mint (CTAs and live only), muted; and
  from the Banker packet, gold for a role, blue for a player's double, amber
  for a warning

**One collision to rule on while you are here.** Amber now means *the carry* on
the Skins band and *the counter-double* in Banker. Both shipped. One of them
should move.

---

## 1. One-Round Triple Cup — the biggest drawing on the board

**The screen:** four matches run at once inside one foursome — Fourball,
Foursomes, Singles 1, Singles 2 — and the screen is a vertical stack of all
four, plus a cup total, plus per-golfer money. Nothing else in the app draws
four simultaneous matches.

Today it is: a header card with the cup score (`Team 1: 2.5 — Team 2: 1.5 of
4`), then one card per match carrying a segment header, both rosters, a live
status (`2 UP thru 4`, `Halved`) and the per-hole grid, then the money, then a
FAB out to score entry.

**What we would like drawn:** the whole screen. Specifically —

- **The stack.** Four match cards is a long scroll and every one of them is
  live. Is there a denser composition — a summary strip with the four states
  and one expanded match — or is the stack right and the cards need to shrink?
- **The cup total.** It is the only score in the app with a decimal point,
  because a halved match is worth a half. It currently reads as a scoreline
  and could read as a target: 2.5 of 4 means 2.5 wins it.
- **Money below four cards** is below the fold on every phone. It is the least
  urgent thing on the screen and it is also the thing a golfer opens it for at
  the end.
- **The FAB leaves the screen.** Scores are entered in the universal screen,
  because four matches share one set of four golfers and eighteen holes —
  entering per match would ask for the same score four times. The button
  currently does not say that.

## 2. Mini-singles Bracket — one screen, two brackets

**The screen:** four golfers play two semi-finals on the front nine; the
winners meet in a final on the back and the losers play a consolation
alongside it. All four matches draw from the start, with the back-nine pair
dimmed until both semis finish.

**Three golfers play a different competition on the same screen**: three
parallel nine-hole round-robin matches, 2 points a win and 1 a half, top two
into a nine-hole final.

**What we would like drawn:**

- **The dimmed final.** It is the best idea on the screen — a golfer on the 3rd
  can see what he is playing towards — and it is currently an opacity value. It
  deserves a real treatment for *earned but not yet started*.
- **The round-robin variant.** `Front 9 — Semis` currently heads a bracket that
  has no semis. Either it gets its own headings or the headings go.
- **The hole-by-hole strip** is nine coloured squares per match. With four
  matches that is 36 squares on one screen; check it survives.
- **The money card** shows the result of two rules the reader cannot see: how
  much of the pot the bracket carved out, and what happened to an unfilled
  seat. Both are set by the TD at setup and never mentioned again.

## 3. Skins — two bands, and one colour collision

**What it is:** the game is one fact per hole — did anybody win it outright,
and if not how big is the pot now — so it draws as two full-bleed tinted bands
**inside the score list** rather than as a card. Green with a golf ball for the
outcome (`Skins: PK wins (3 skins incl. carry)`), amber with a flame for the
carry (`3 skins on the line`).

**We think this is right** and want it drawn rather than replaced: the answer
belongs against the scores that produced it. What we would like:

- **The pair treated as a pattern**, named and specified, because it is the
  only place in the app where two different tinted strips can stack under one
  golfer's row — and the next game that wants this shape should inherit it.
- **The amber ruling** (see above). Banker's counter-double has the stronger
  claim on amber; the carry may want its own colour.
- **The carry chip appears only when the pot is above 1.** A plain hole shows
  nothing, which is correct and makes the band's arrival meaningful. Confirm.

## 4. Stableford — a grid that is nearly right

**What it is:** one grid under score entry. Every cell is the **server's**
points for that hole rather than the client's arithmetic, because the points
table is configurable and a grid that re-derived them would disagree with the
leaderboard the first time a group changed it.

Two behaviours worth keeping and specifying: it **draws empty rows from hole
one**, so the shape of the round is visible before anybody tees off; and it
**auto-scrolls to park the current hole about seven columns from the left**.

**What we would like:**

- **A way to see what the points mean.** The grid shows `3` and never says why.
  This is the first question a new Stableford golfer asks, and the app has no
  answer anywhere in play.
- **The auto-scroll offset** — seven columns is a number nobody has checked on
  a small phone.
- **Whether the empty-rows-from-hole-one behaviour should be the house rule**
  for every grid in the app. It is currently Stableford's and Stroke Play's.

---

## What we are not asking for

- **Honors**, which has no play surface at all and is a separate and larger
  question — see [`honors/AS-BUILT.md`](honors/AS-BUILT.md) §6. It is the one
  we would put first if you had appetite for a fifth.
- **A Live Activity for any of these four.** Skins already has a card;
  Triple Cup, Stableford and the bracket do not, and none of them is blocked
  on one.
