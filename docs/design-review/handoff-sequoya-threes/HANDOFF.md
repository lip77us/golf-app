# Handoff — Sequoya 3s

**Five screens, one game.** All under `screens/`:

| File | Card | Group |
|---|---|---|
| `sequoya-threes-setup.html` | Sequoya 3s (setup) | Games |
| `sequoya-threes-play.html` | Sequoya 3s (play) | Games |
| `sequoya-threes-leaderboard.html` | Sequoya 3s — leaderboard | Games |
| `sequoya-threes-settlement.html` | Sequoya 3s — settle up | Games |
| `live-activity-sequoya-threes.html` | Sequoya 3s — lock screen | Live Activities |

Visual vocabulary is lifted wholesale from the Sixes packet — same tokens, same phone frame, same neutral-scoreboard doctrine on the lock screen. Nothing new was invented that Sixes had already settled.

---

## The format

Four golfers. **Six matches of three holes.** 2 v. 2 best ball, net.

**Only match 1 is set up.** The group either assigns the first two teams themselves — the convention is the two long drives against the two short ones — or taps to draw them at random. Everything after that is derived: four golfers split into 2 v. 2 exactly three ways and there is no fourth way, so the rotation is fixed once match 1 is chosen.

| Match | Holes | Pairing | How chosen |
|---|---|---|---|
| 1 | 1–3 | A | **The only thing set at setup** — group picks or draws |
| 2 | 4–6 | B | Derived — next pairing in rotation |
| 3 | 7–9 | C | Derived — the last one |
| 4 | 10–12 | A | Repeat |
| 5 | 13–15 | B | Repeat |
| 6 | 16–18 | C | Repeat |

Matches 4–6 repeat 1–3 in the same order, so every golfer partners every other golfer exactly twice.

Do not build the draw as six independent selections. Build it as: set match 1, derive 2 and 3 from the rotation, then modulo.

**There are no format options.** No Classic vs. High-Low, no handicap-allocation choice. Handicap is Net / Gross / Strokes Off, allocated by full course stroke index; the setup screen carries nothing else.

## Stake and money

- **$5 a man, a match** (configurable). Not per pair.
- Lose a $5 match and you are down $5; your partner is also down $5. Two winners each collect $5.
- **Nothing in the format assigns one loser's money to a specific winner.** Only the four nets are real. See *Settlement* below.
- A halved match pays nothing and **does not carry** — carryover across a pairing change would mean a wager owed by a pair that no longer exists.

## Presses

**A press is a new bet at the same amount as the original, not a doubling.** Same model as Nassau. It runs over the holes that remain in that match and settles on its own.

Three options at setup:

| Option | Behaviour |
|---|---|
| **None** | No presses. Each match is one bet. |
| **Auto after 1st hole win** *(default)* | Win the first hole of a match and a second bet at the same amount opens on holes 2–3. Nobody calls it. |
| **Manual + Auto** | The above, plus the trailing side may call **one** press by hand from hole 2 onward. It opens a bet on the holes remaining after the call. |

- **Press amount = bet amount.** There is no separate press unit to configure.
- **Cap: one auto plus one manual**, so a match carries at most three bets.
- A match that closes early still pays its match bet; a press bet opened later can remain live on the last hole after the match itself is decided. This is the ordinary closing-hole press and the reason presses are modelled as bets rather than multipliers — doubling a wager already lost is a donation nobody would tap.

**Round exposure at a $5 stake:** $30 with no presses, **$60** with the auto press live in all six matches, **$90** at the Manual + Auto ceiling. Printed on the setup screen.

The auto press must be **visibly caused**. It opens a bet without anyone touching the phone, so it appears as its own line in the play banner and as a chip (`+ AUTO PRESS`) beside the total at risk everywhere the stake appears. It does **not** get a push.

The manual press is the only object in the game that **expires**, and the only one addressed to two of the four golfers. Both facts are printed on the offer card. All four see the card; only the eligible side can act on it.

## Resolution order, per hole

1. Enter four gross scores.
2. Apply strokes — **full course allocation by stroke index**, not spread across matches. A stroke falls where the card says it falls, whichever three-hole match that lands in. Matches are not equal in difficulty and pretending they are would be the larger distortion.
3. Best net per pair. Lower wins the hole; equal halves it.
4. Update match state. **Close the match early** when a side is up by more than the holes remaining (2 up with 1 to play, 3 up with 0).
5. Evaluate press triggers.

## The screens

**Setup.** Modelled on the Sixes setup screen: a hole-header card with four draggable rows split into Team A and Team B, plus a random-assign button. Then handicap, press option chips, stake, exposure ceiling. The rotation is stated explicitly — a group that does not know matches 2–6 are already determined will expect a second draw at the turn.

**Play.** The banner carries **one line per live bet** — match bet, auto press, hand-called press — each with its hole range, its amount and its own state, then the total at risk. Presses are separate bets with separate outcomes, so a multiplier would be a lie. By-hole strip is **this match only** — three cells. The other five matches are a money list, not a grid.

Two frames are drawn: the ordinary scoring state, and the offered press. The press frame is the one that carries the design — amber, expiring, addressed to two of four.

**Leaderboard.** Ranks by **money, not matches won**, because a match carrying three bets is worth three flat ones and a board that disagrees with settlement is worthless. The match record (`3–2–1`) sits on the row but does not sort. The card itemises all six matches with pairing, margin, **bet count** and money, plus a **partner record** — the one question this format generates that no other in the app can answer.

**Settlement.** Four nets, then the **fewest handovers that clear them** (two, for four golfers). Plus one golfer's itemised receipt. Hand-called presses are named with **who called them, when, and which holes they covered**; auto presses are counted in the match line as a second bet, because they have no author.

**Lock screen.** A state word appears only when it is true of the position: **DORMIE** means up by exactly the holes remaining, **CLOSED** when a bet is decided early, and an em dash over the holes left otherwise. 1 UP with 2 to play is not dormie and must never be labelled it.

**Observers.** A golfer invited to follow the round gets the leaderboard and, optionally, the activity — **no separate card**. The neutral-scoreboard rule already did the work; two slots come out (the running money, and the ±Y half of the locked corner, keeping THRU X), and the final state reads the match record rather than who to collect from. Pairing-change pushes still go out; the press offer does not.

**Lock screen anatomy.** Structurally the Sixes card — same three rows, same locked corners (`HOLE X · PAR Y · YDS` upper right, `THRU X · ±Y` lower right), same ~135pt budget. Two differences: the press chip and total-at-risk in the footer, and more news.

## Pushes

| Event | Count/round | Colour | Notes |
|---|---|---|---|
| New pairing | 5 | mint | On the 4th, 7th, 10th, 13th, 16th tees. Names both new sides. |
| Press offered | 0–6 | amber | Manual + Auto only. The only push that expires. Sent to all four; says which two can act. |
| Auto press | **none** | — | No decision in it. Rides the activity update and the footer chip. |

The auto-press exclusion is deliberate and worth defending: it fires on most matches, and a notification arriving six times a round to report a rule the group already agreed to is noise. **The chip is the receipt; the push is for decisions.**

## Segment pips

Sixes cut them because a round has no fixed match count. **This round has exactly six, always** — so six pips would be honest here. They still do not ship on the lock card: no room for a fourth row inside the height budget. They ship in the **expanded Dynamic Island**, where there is no footer, and there they earn it — the second half repeats the first, and the strip is where a golfer sees he is about to replay the pairing that beat him.

## Tokens

Identical to the Sixes packet. Deep pine `#0B1F1A`, pine `#0F6E56`, mint `#3BD89A`, muted `#5C6B62`, blue `#1976D2` (in-app) / `#5AA7F5` (lock screen), orange `#EF6C00` / `#F3A059`. Amber for the press: border `#E8D6BC`, fill `#FDF3E7`, text `#8A5216`; on the lock screen `#F0C070`.

Type: Schibsted Grotesk 600/700 for numbers and headings, Spline Sans 400–700 for everything else.

Colour follows the **pairing side**, fixed at the draw, never recomputed per hole.

## Open questions for code

- Whether a group can re-draw the order at the turn. Drawn as **no** — the repeat is the point of the format.
- Whether the **partner record** (every golfer partners every other exactly twice) belongs anywhere. The leaderboard is now a chronological ledger with no partner block; it survives only as "best with Lee" on the settlement rows. Drawn as **not on the leaderboard**.
- Scorecard cells show **gross with a stroke dot**, but the boxed cell is chosen on **net**. A small inconsistency worth a decision.
- Whether the money table should be **sortable by column**. Drawn as **no** — sorting a ledger destroys its only order.
- Whether the press offer should **push to observers**. Drawn as **no** — it is a decision addressed to two golfers, and buzzing a spectator about a bet they cannot take is noise.
- Tie-break when two golfers finish level on money. Drawn as **match record, then gross**.
- Whether a halved match should be offered a **sudden-death extra hole**. Not drawn. Would break the fixed 3/6/9/12/15/18 boundaries the whole format depends on.
