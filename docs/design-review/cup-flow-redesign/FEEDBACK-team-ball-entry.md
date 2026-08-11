# One-ball formats need a team-ball entry surface — please draw it

**Engineering → Design.** This is a **build request**, not a confirm — a screen
we need drawn before we can ship the coming-soon one-ball games.

## Context

Phase 6/7 puts three one-ball formats in the mixed-cup game list:

- **Foursomes** (alternate shot) — 2 v 2 inside a foursome, one ball a pair
- **Two-man Chapman** — 2 v 2 inside a foursome, one ball a pair
- **Scramble** — one match, a blue foursome vs a red foursome (4 a side)

The game-list alignment is **done and merged** — `cup-games-by-round-mixed.html`
now matches the build (Foursomes added; Fourball dropped as a casual game;
Two-man scramble dropped). What's missing to make these actually *play* is the
one thing the handoff itself flagged: *"the one-ball formats need something the
app does not have."*

That something is a **way to enter one score per hole for a team.** Today every
score-entry surface in the app is **per golfer**. These formats share a single
ball, so there is no per-player gross — the group enters **one number per hole**.

## The product decision (settled with the TD)

Kept deliberately simple for v1:

- The app **collects one gross per hole per team.** It does **not** track who
  drove or who putted, and does **not** enforce alternate-shot rotation or a
  minimum number of drives per player — the group manages that themselves.
- (Drive-count requirements — "each player's drive used at least N times" — are
  a **later layer** that would sit on top of the same score field. Out of scope
  for v1; noted so the entry design leaves room for it.)
- Scoring is **match play, team net, hole by hole** (blue vs red), the same
  competition shape as Irish Rumble.

## What differs between the three — two entry shapes

| Format | Teams per group | Balls entered per hole |
| --- | --- | --- |
| **Scramble** | The whole group is **one** team; it plays a blue-group-vs-red-group match **across two groups** | **1** score per group |
| **Foursomes / Chapman** | **Two** pairs share one group (a blue pair + a red pair) | **2** scores per group — one per pair |

So the entry surface needs to handle **one team ball** (Scramble) and **two team
balls in the same foursome** (Foursomes/Chapman).

## What we're asking design to draw

1. **Score entry — team ball.** Where the single per-hole score box lives, how a
   pair/side is labelled on it (team colour + the two golfers' names), and how the
   two-pair case reads on one screen without looking like per-player entry.
2. **Leaderboard — team-ball match card.** The match-play result for a
   one-ball match. Likely the same card shape as the Singles/Nassau match cards,
   but with **one net row per side** instead of per player — and the per-hole
   Round Progress grid showing one row per team, not per golfer.
3. **Handicap for a pair (guidance, not a screen).** Scramble already has a team
   handicap (avg × %). Alt-shot pairs traditionally combine as 50/50 (Foursomes)
   or 60/40 (Chapman). Phase 7 said "one cup-wide allowance" — does that override
   these combinations, or does the pair-combination stand and the cup-wide
   allowance apply on top? A one-line ruling lets us score it correctly.

## Why we paused rather than improvise

We could invent a minimal single-box entry and refine later, but the team-ball
surface is a **new score-entry paradigm** that will also serve any future
alt-shot / scramble casual game — worth drawing once, deliberately, rather than
retrofitting. Once the mock lands we'll build Scramble first (most of its scoring
engine exists), then Foursomes, then Chapman.
