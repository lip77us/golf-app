# Handoff — Team Play (four-man teams)

Eleven screens plus two reference documents. `team-kit.css` is the shared stylesheet every screen links; keep it alongside them. `handoff-card-taxonomy.md` is the unchanged filing rules — these cards sit in a new group, **Team play**.

Files are numbered in flow order. All are self-contained HTML; the Contents link on each goes to the flow map.

| # | File | What it is |
| --- | --- | --- |
| 01 | `01-wizard-step1.html` | Step 1 — format, one round, field |
| 02 | `02-set-tees.html` | Step 2 — **the existing Set tees screen, unchanged** (reference only) |
| 03 | `03-team-format.html` | Step 3 — scramble or shamble |
| 04 | `04-shamble-counts.html` | Step 3, shamble state — balls that count, per hole. Interactive |
| 05 | `05-drive-requirement.html` | Step 4 — the four drive rules, plus the live tracker |
| 06 | `06-handicap.html` | Step 5 — allowance, worked on the TD's own teams |
| 07 | `07-build-teams.html` | Step 6 — manual assignment with live balance |
| 08 | `08-payout.html` | Step 7 — fee, places, split. Two states: balanced, and blocked at 95% |
| 09 | `09-score-entry.html` | Both scorecards — scramble and shamble |
| 10 | `10-leaderboard.html` | The standard leaderboard card, with two ties |
| 11 | `11-settlement.html` | One pool, three places, a tied second |
| 12 | `12-flow-map.html` | Eight setup steps and three play surfaces, with the reasoning |
| 13 | `13-decisions-log.html` | Sixty-six decisions, one line each, linked to the screen |

**Read 13 first.** It is the spec in summary form. 12 carries the argument behind each step. This document covers what a reader of those two still needs.

---

## What this is, and what it is not

The third tournament shape. **Cup** is two big sides and the unit is a match. **Individual** is a field of singles and the unit is a card. **Team Play** is many small teams, one leaderboard, one score per team per hole.

It is the shape a club runs most often — a Saturday scramble with six teams and a pot — and it is deliberately the **simplest** of the three. Most decisions in the log are decisions *not* to build something:

- **One round.** Stated, not chosen. No round dimension exists anywhere downstream — no round columns, no best-N counting, no per-round pot. A club wanting two days runs two tournaments.
- **No side games.** The team *is* the foursome, so there is no field to run a ball game against. A foursome wanting a bet among its own men still has the casual games.
- **One pool.** The team championship.
- **Two screens reused unchanged** — Set tees (step 2) and the settlement receipt / texting flow. Nothing new was built for either.

## Two formats, two scorecards

**Scramble** — all four hit, the best ball is played. **One score per hole**, entered on the standard score picker. Handicap is a single team figure.

**Shamble** — best drive, then each man plays his own ball in. **Four scores per hole**, with the counting ones tinted live and the rest greyed. Handicap stays per golfer.

They share one thing — the tee shot is chosen — which is why the drive requirement applies to both. Format locks at the first score: a one-number card cannot be re-read as four.

**Shamble ball counts expand in place under the radio.** House rule from the Irish Rumble work: no game gets a second rules screen. Four modes:

| Mode | Rule |
| --- | --- |
| Fixed | The same count all eighteen. Best 2 of 4 default |
| Escalating | 1 ball on 1–6, 2 on 7–12, 3 on 13–18 |
| Par-based | Par 3 = 3 balls, par 4 = 2, par 5 = 1 |
| Per hole | The 18-cell grid, tap to cycle 1→2→3→4 |

Escalating is a **preset, not something built in the grid** — it is the shape people describe in words ("sixes"), and making them tap eighteen cells for it is the app failing to listen.

The preview reads back in sentences, collapsed into runs, and reports **total balls counted** — 36 of 72. Fixed-at-2 and escalating both total 36, distributed differently; seeing that is what makes the choice read as character rather than difficulty. A hole set to all four is flagged: no drop score.

## Drives — the actually complicated part

Four rules, and they are **not four settings of one thing**. Three are quotas and one is a schedule. That split decides the UI.

| Rule | Kind | What it needs on screen |
| --- | --- | --- |
| None | — | Nothing. The screen never appears again |
| Per nine | Quota | Two independent windows |
| Per eighteen | Quota | One window, most slack |
| Alternating pairs | Schedule | One line on the tee: *Gunst and Yau are up* |

Rules for code:

1. **A quota needs slack shown** — twelve required of eighteen means six free. That figure tells a captain whether he can let his long hitter drive the par 5.
2. **Warn when owed exceeds holes remaining in the window**, not on 18. The failure every group has had: three holes left, five drives owed — it became impossible two holes ago and nobody noticed. The card says the consequence in a sentence on every hole.
3. **Per nine is two windows.** A man short on the front is already short; a tracker that only totals eighteen says he is fine until the 18th green.
4. **Never block the tap.** The team may knowingly take the shortfall.
5. **Falling short costs nothing by default.** Two strokes per missing drive is opt-in. Silently disqualifying a team over a drive count would be the worst outcome the app could produce.
6. **Alternating pairs are set by the team on the 1st tee**, then fixed for eighteen holes. Not derived from handicap — four men decide in ten seconds and would override a computed pairing anyway. A rota that can be re-cut mid-round is not a rota.
7. **Three men run AB → BC → AC**, repeating. Two drivers every hole; each man sits out every third and covers the phantom's 1st and 4th shots.

## Handicap

**The allowance is a table, not a preference.** The screen states what the format uses, shows it applied to the TD's own teams, and offers one flat override for a group with its own tradition. Presenting a table as an open question invites a guess.

- Scramble: **25 / 20 / 15 / 10** of course handicap, lowest first, summed → one team figure.
- Shamble: a single percentage of each golfer's own — 85% at two balls a hole, 75% at one, 95% at three. It tracks the ball-count average, so a per-hole grid averaging 2.3 gets 95% suggested.

Three rules:

1. **Round once, on the total.** Rounding each contribution first turns 1.00 + 1.60 + 1.65 + 1.90 into 7; rounding the sum gives 6. Compute at full precision, round at the end, show the raw total underneath. Half rounds up.
2. **Whole strokes, never fractions.** Golfers do not play 6.15, and it looks like a spreadsheet error at the scoring table.
3. **Which makes ties normal.** Whole strokes across six teams tie most weeks. There is no countback and no card-off — see below.

## The phantom 4th

A three-man team fields a **phantom 4th**: a fourth slot handicapped at the **average of the three real men**, whose ball is played by whoever is not driving.

This keeps everything downstream identical — four handicaps, so the ordinary table applies; four balls, so the format is unchanged. Bellini 9, Kwan 15, Ortega 23 → phantom 16 → the team plays off **10**.

- **Nobody is ever borrowed.** A golfer from another team would be hitting shots for a rival, and every good one costs his own team the pot. The option does not exist.
- **Fewer balls must never mean fewer strokes.** Dropping the bottom row of the table (25/20/15 on three) gives 9; the standard 30/20/10 gives 8. Both take a stroke *away* from a team already short a ball. The rule that avoids it: **the allowance follows the roster, not the number of balls hit.** "Play short" therefore carries the same 10 — the only thing it changes is whether anyone hits the phantom's ball.
- **The phantom is a row, everywhere** — italic and undraggable on the team card, named on the leaderboard row, listed unpaid in settlement. Hiding it makes all three look like special cases.
- **It cannot be paid.** A three-man team divides its share three ways and takes more each.

## Money

Fee, places and split are all TD-settable, on **one screen at step 7** — they are the only numbers anybody argues about afterwards, and changing one changes the others' meaning. It sits after teams because it needs the field size for the pot and the team count to cap the places.

- **Every control shows dollars as it moves, including a per-man figure.** A TD setting 50/30/20 is choosing what third place gets; the percentage is the mechanism.
- **The split must total 100**, checked live, with Save blocked and the shortfall named in dollars. 95% leaves money in the TD's pocket with no line explaining it.
- **Rounding is not the TD's problem.** He works in whole percentages; the app handles cents and settlement states where the odd ones went — **to the team's highest course handicap**, so the pool balances to zero.
- **Places cap at the team count.** Half the field cashing is advice on the screen, not a rule.
- **A place paying less than entry is allowed and flagged.** Unlike the Individual day bet, nothing here is disqualified by cashing, so it is worth knowing rather than blocking.

**Ties combine the places they occupy and split what those places pay.** No countback. The drawn settlement has two, behaving differently: Slate and Dune tied for 2nd combine 2nd *and* 3rd into $287.50 split two ways; Pine and Clay tied for 4th combine two places that pay nothing, so the tie costs nothing and is left unresolved. Draw each tie as **one block with both teams inside it** — two rows each reading $143.75 hides that it was one prize.

## Reuse, not reinvention

Three places where the answer was an existing component:

- **The score picker** on the scramble card is the same 3/4/5/6 picker as every other game. Auto-advance waits for **both** the score and the drive — the hole is not complete until the drive is picked, and the button says which is outstanding.
- **The leaderboard** is the standard card: rank / team / gross / net, the hole-grid strip under an expanded row, circled birdies and boxed bogeys. A team is just what sits in the name column. A golfer who reads three leaderboards a month should not have to learn a fourth layout.
- **Set tees and the settlement receipt** are existing screens, referenced not rebuilt.

## Open

- **Flights.** Deferred with the Individual flow. Six teams is under the size where flighting means anything.
- **Multi-round team events.** Currently answered by "run two tournaments." Revisit only if clubs ask.
