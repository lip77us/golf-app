# Handoff — Individual play tournaments

Twelve screens plus three reference documents. Everything is new; nothing in this folder modifies an existing surface.

Files are numbered in build order (create flow, then play, then reference). All are self-contained HTML — open them in a browser. `handoff-card-taxonomy.md` is included unchanged for the `@dsCard` filing rules; these cards sit in a new group, **Individual play**.

| # | File | What it is |
| --- | --- | --- |
| 01 | `01-wizard-step1.html` | Tournament wizard step 1 — format, rounds, side-game entry pricing |
| 02 | `02-scoring.html` | Scoring step — method, handicap, allowance, rounds counted |
| 03 | `03-stableford-setup.html` | Stableford points table (reuses the casual screen) |
| 04 | `04-mini-singles-setup.html` | Mini Singles Bracket — seeds, short-field rule, allocation, carve-out |
| 05 | `05-irish-rumble-setup.html` | Irish Rumble — rules, borrowed 4th, payout |
| 06 | `06-ball-game-setup.html` | The ball game — TD-named, rules, payout |
| 07 | `07-score-entry.html` | Score entry inside a tournament round |
| 08 | `08-championship-leaderboard.html` | Cross-round championship board — the primary play surface |
| 09 | `09-rumble-leaderboard.html` | Irish Rumble board — per-group, by-hole |
| 10 | `10-ball-leaderboard.html` | Ball game board — ranked by survival |
| 11 | `11-daybet-leaderboard.html` | Day bet board — per-round, with DQ marking |
| 12 | `12-settlement.html` | Settlement — every tournament-scope game, one total per golfer |
| 13 | `13-create-flow-map.html` | The create flow, screen by screen, with the reasoning |
| 14 | `14-play-flow-map.html` | The play surfaces, same treatment |
| 15 | `15-decisions-log.html` | Fifty-five decisions, one line each, linked to the screen they live on |

**Read 15 first.** It is the spec in summary form — every call made, why, and where it is drawn. 13 and 14 carry the argument behind each line. This document covers only what a reader of those three still needs.

---

## Scope boundary — read this before anything else

The TD sets **four games only**: Irish Rumble, the ball game, Mini Singles Bracket, and the day bet.

Everything a foursome plays among itself — skins, Nassau, rabbit, survivor, sixes — is the **foursome's** to configure, exactly as in a casual round. Consequences that must hold in code:

- The TD's setup surfaces never list them.
- They read the tournament's score entry. No second card, and none of the specialised entry surfaces those games have casually.
- **They do not appear in settlement totals.** The TD never set them and never collected for them. Foursome bets settle inside the foursome.
- The one exception is **spots**, which need capture: a `−/+` stepper per golfer per hole, a **count and never a type**, shown only if this group chose spots and only on golfers who opted in. No-steppers is the default card.

## Money model

**Entry is flat, per side game, taken at signup.** A golfer's games are therefore known before round one, and the side-game step never reopens mid-tournament.

The pools:

- **Championship pool** — from entry. Pays up to three places. The Mini Singles pot is a **percentage carve-out off the top**, set at event setup; there is no separate bracket entry.
- **Side-game pools** — one per game, from that game's entry. Scope is stated on the pool line: `$10 × 4 in this foursome = $40` vs `$10 × 8 in the field = $80`.
- **Day bet** — final round only. Pays **two places** on a ten-eligible field (16 minus four finalists minus the two 36-hole money winners).

Three rules the payout step must enforce:

1. **Ties split the money for the places they occupy.** A T2 shares 2nd and 3rd — $16 each, not $20 each. Indexing prize by position overpays the pool. There are no countbacks.
2. **A levelled group splits its place among its real golfers.** The borrowed 4th is not a person and cannot be paid: three winners take $23.33 where four would take $17.50.
3. **Last paying championship place ≥ day bet 1st.** Winning 36-hole money disqualifies a golfer from the day bet, so if the last paying place paid less than day bet 1st, finishing in the money would cost him money. Validate at the payout step, block Save with the reason shown.

Money is a **projection until the round closes** — muted italic throughout, with one line under the table saying so.

## Mini Singles Bracket — the part with the most rules

Optional, at the TD's discretion. Nothing downstream may assume it: no carve-out, no reserved day-2 foursome, unless it is on.

**Shape.** Four matches per group: two semis on the front, final *and* 3rd place together on the back. Every group runs its own bracket on day 1; the four group champions play day 2 as **one foursome** for the title. Everyone else plays a normal stroke-play round.

**Field.** 9–16 golfers. 13–16 is four groups and the full bracket; 9–12 is three groups and takes the short-field rule. Eight or fewer gives a final with no semis. Over 16 needs a third day, so it is not offered on a two-day tournament.

**Seeding.** Day 1 seeds from handicap — lowest index is seed 1, meets seed 4 — and the TD can drag to reorder; pairings derive from the order. Day 2 seeds by **day 1 margin**, then lowest index.

**Allocation.** Opens on **strokes off low** (it is a two-player match), overridable to full net. The field games inherit full net — there is no low man to anchor to against a field.

**A halved match plays on; it never splits.** Play continues and the match is back-calculated against the finals pairing, **reading back from hole 10**. Nobody waits: the resolved pair tee off on 10 on schedule and score under `1 UP vs. TBD`. No ambiguity is possible — the pair in overtime can only halve, since the first hole they do not halve ends the semi.

A halved **final** splits 1st and 2nd money, with the trophy and the Sunday seat going to the **last hole won**. A halved **3rd place** simply splits.

A tie in the points round also plays on — never a card-off. Play points until 1st and 2nd are clear, then back-calculate the match from the 10th.

**Short field and withdrawal take the same rule, set once at setup** and never asked on Sunday morning: promote the lowest net beaten finalist (default), points then a match over nine, or play short-handed.

**Payout.** 4th breaks even (entry back); the other three split the rest. Day-1 splits are 60/25/15.

**Finalists keep their side games** — the champions' foursome plays the ball game and Irish Rumble as normal on Sunday — but are **out of the day-2 stroke bet**. They are playing a match, not a card against the field.

## Other game rules

**Irish Rumble** and the ball game are **re-drawn each round**.

**Ball game.** The TD names it — free text, **16 characters** (the iPhone 13 mini cap from the Cup work), carried to the tab, the carrier badge and the chat string. **No default and no memory of last week**; Save does not fire until it has a name. Rules on the setup screen: one ball, no replacements, last group holding it wins, low net breaks a tie at 18. It ranks **by survival**: still alive first, then by the hole the ball died on, latest first. Net shows on every row but decides nothing unless two groups finish 18 with it alive.

**Irish Rumble.** A threesome borrows a 4th from the field — automatic, only when another group has four, donors rotate across every other golfer, and the donor's own net on his own tee counts. Called **Borrowed 4th** everywhere (**4th** on hole-by-hole cards). A group waiting on a donor shows a provisional total on three balls.

**Scoring.** The net double-bogey cap is **always on** — a rule, not a toggle, stated once where scores are entered and shown on the card as a tinted cell. Stableford is chosen per tournament and its points table is the TD's to set: negatives, unusual scales, zero for par are all valid; the screen reports what a negative table implies for the cap but does not argue. Net allowance defaults to 100%. **Rounds counted** appears only when the tournament has more than two rounds.

## Leaderboard behaviour

- **Four round columns, then the strip scrolls.** Round columns are their own horizontal strip; every row scrolls with the header, and the board opens **scrolled to the most recent round**.
- Every round gets a column. Best-N counting strikes the dropped round through rather than hiding it, and it **moves as scores land**. The board shows the counting rule ("Best 3 of 4").
- Expanded rows open **all 18** — par, stroke index, gross with a dot per stroke received, and the net being ranked.
- Rows still on the course are marked. A leader thru 11 must not read like a finished one.
- A Stableford card shows **gross and points**, not per-hole net, with the stroke allocation on the card. One method, one board.
- Tabs are named for **what they pay**: Championship, each side game, then `Day bet · Round 1`.
- The Round 2 day bet board shows 36-hole money leaders in **italics** rather than hiding them — eligibility is not knowable until the last round ends. The DQ follows the tournament's handicap setting: net event, net winners.

## Labels

**Mini Singles Bracket** everywhere (it was "Match Play Foursome" at setup). **CH** is the handicap label. Match summaries use the **surname alone** — *Detomasi vs Gunst*; six of eight first names in the test field start with A. Full names on summary rows, **short names** (five characters, defaulting to initials) on hole-by-hole cards. Every paid place names its recipient: *1st — golfer* or *1st — foursome, splits to $20.00 each*.

**Nothing is disabled without saying why** — inherited from the Cup work, and it applies to Save Configuration, the next-hole button, and every balance check in these screens.

## Open questions for code

- **Mini Singles with five or more groups.** Three groups is settled; five group winners still will not fit a foursome. Not resolvable in design without knowing whether a third day is ever on the table. Currently the bracket is simply not offered above 16.
- **Championship third place.** Drawn as up to three places, gated on the last place clearing day bet 1st ($100 in the sample). Confirm the check belongs in the payout reducer and not just the UI.
- **Flights are deferred.** Not built; nothing here depends on them. When they land the intent is an **even split of the field**, not index ranges, riding on the Payout step rather than earning one.
