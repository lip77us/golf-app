# Handoff — Banker

**Five screens, one game.** The HTML files in this folder are **design references**
— prototypes showing intended look and behaviour, not production code to port.
Recreate them in the target codebase; treat the HTML as a specification of
layout, type, colour and states. The lock-screen file is iOS-only (SwiftUI +
ActivityKit) and has no web equivalent.

| File | Card | Group |
|---|---|---|
| `banker-setup.html` | Banker (setup) | Games |
| `banker-play.html` | Banker (play) | Games |
| `banker-leaderboard.html` | Banker — leaderboard | Games |
| `banker-settlement.html` | Banker — settle up | Games |
| `live-activity-banker.html` | Banker — lock screen | Live Activities |

`banker-scorecard.js` renders the net scorecard shared by the play screen and
the leaderboard. One implementation, two consumers.

## Screenshots

| File | State |
|---|---|
| `01-setup.png` | Wager band, first banker, rotation, action rules |
| `02-play-tee-bets.png` | On the tee — max set, two bets in, one to come |
| `03-play-locked-countered.png` | Bets locked, banker countered — the moment of the hole |
| `04-play-score-entry.png` | Score entry — three in, one open, nothing resolved |
| `05-play-resolved.png` | Resolved — the chain shown on every row |
| `06-play-tie-for-bank.png` | A tie for low net — the group settles it |
| `07-leaderboard.png` | The eighteen-hole ledger, splits, swings, net card |
| `08-settlement-handovers.png` | Fifty-four bets, three handovers |
| `09-settlement-receipt.png` | Banking itemised, betting grouped by opponent |
| `10-la-banker-exposure.png` | Lock screen — the banker's phone |
| `11-la-counter-double-push.png` | Lock screen — the counter-double push |
| `12-la-rotation-push.png` | Lock screen — rotation push |
| `13-la-always-on-par3.png` | Always-on — a par 3 with three triples standing |
| `14-la-final.png` | Final state — the money and the hole that made it |
| `15-la-dynamic-island.png` | Dynamic Island — minimal, compact, expanded |

---

## The format

One golfer banks each hole and plays **each opponent separately, net**. Beat the banker and he pays you your bet; **lose and you pay him**. **A tie is no action** — the bet is void and nobody pays, whatever it had grown to. He tees off last.

This is the only game in the app where **money is fixed before anybody swings**, and the order in which it is fixed *is* the game.

## Sequence per hole — the app must enforce this, not merely record it

| Step | Who | What |
|---|---|---|
| 1 | Banker | Announces a **maximum for this hole**, at or under the round ceiling. |
| 2 | Each opponent | Picks his own bet, from the round **floor** to the banker's max. |
| 3 | App | **Locks the bets.** |
| 4 | Banker | Tees off — **last**, knowing all three numbers. |
| 5 | Players | May **double on their own shot**, while the ball is in the air. |
| 6 | Banker | May **counter-double** after his own shot — doubles **every standing bet**. |
| 7 | All | Scores entered. Three one-on-ones resolve. |
| 8 | App | Lowest net takes the bank for the next hole. |

**Step 3 is the load-bearing one.** A banker who can still see bets moving after his tee shot is playing a different game. The play screen has an explicit lock and the button names what it unlocks: *Lock bets — Paul tees off.* Nothing above the lock is editable afterwards without a visible correction.

## Resolution

For each opponent *o* against banker *b* on hole *h*:

```
stake = bet(o) × ownMultiplier(o) × counterMultiplier
   ownMultiplier    = 1, or 2 (double), or 3 (triple, par 3 only)
   counterMultiplier = 1, or 2 (banker countered)

if net(o) < net(b):        banker pays o   stake × (grossBirdie(o) ? 2 : 1)
else:                      o pays banker   stake
```

Note the asymmetries, all deliberate:

- **Ties are no action.** The banker does not win ties. The row reads `TIED — NO ACTION` and pays `$0`, but **the chain still prints what the bet had reached** — *"$40 — void, matched the banker"* — because a doubled bet that paid nothing is a fact the group wants to see, not an omission. This is also what makes the counter a real gamble: a counter-double that runs into two halves collects on neither.
- **Birdie bonus pays out only.** A player's birdie doubles his own payout. It never applies to a tied row (which pays nothing) and never to the banker — one against three is already lopsided, and letting him double three collections at once would make the role unplayable.
- **Par 3s replace the double with a triple.** There is no double available on a par 3 — the button changes label rather than adding a fourth option. The banker's counter still doubles what stands.

Handicap: **net**, full allocation by stroke index. Every one-on-one settles on net, including the banker's.

## Rotation

Lowest net on the hole banks the next one.

The traditional tiebreak is *low score, holed out first* — and **a phone cannot see who holed out first.** So the default is not a rule at all: **the app asks.** On a tie it shows a picker on the tee naming the tied golfers, the group taps whoever holed out first, and the next hole cannot start until it is answered. The answer is recorded **with its reason** — *holed out first*, *drawn*, *banker kept it* — and carried to the receipt.

Three setup options: **The group says who** (default), **Tied low scores are drawn**, **Current banker keeps it**. A drawn result stays changeable until a score is posted; the app's guess must never outrank the group's memory.

The original reasoning, which still applies to the draw option: Asking four golfers to remember would be worse than guessing. So a tie for low net is **drawn at random**, and the draw is **announced as a draw**, naming the tie and the outcome. A role that silently changed hands means two golfers both think they are banking the 8th.

The alternative offered in setup — *current banker keeps it* — concentrates the role and the exposure with whoever is playing well, which is the opposite of what rotation is for. Not the default.

## Exposure — the most important thing on the setup screen

The banker faces three bets at once and **both sides can double them**. At a $50 ceiling:

| | |
|---|---|
| Three opponents at the max | $150 |
| All three double off the tee | $300 |
| Banker counter-doubles | $600 |
| On a par 3, tripled instead | $900 |
| Three birdies against him | **$1,800** |

Nobody setting up a "$5 to $50 game" is picturing eighteen hundred dollars. The setup screen shows the **whole ladder** rather than one worst case — the point is not that the top number is likely, it is that it exists, and a golfer who reads the second line will set his ceiling differently.

**Suggested addition, not in your spec:** a **hole cap** — one ceiling on the total exposure for a hole, all bets and doubles included. Drawn in the prototype as a switch, **off by default**, with the ladder above it as the argument for switching it on. It is not a traditional rule and a safety rail enabled without being asked reads as the app setting the stakes. Shown, argued, left to the group. **Confirm whether you want it at all.**

The play screen carries a live version of the same number in the banker's banner: *what this hole can cost him at the multipliers currently standing.* It updates when a double lands. It is the only live worst case anywhere in the app, because it is the only place one exists.

## The screens

**Setup.** Wager band as a **two-handle track**, not two fields — the width of the band is the decision, and two boxes hide it. First banker (group picks, or flip). Rotation. Four action rules as switches, all on, plus *bogey-or-better to win* available and **off** (it turns a won hole into a no-pay, the game's most confusing outcome). Then the exposure ladder.

**Play.** Two frames. The first is **the moment of the hole**: bets locked, balls in the air, double controls live, the banker's counter as a single full-width control — one decision landing on all three bets, so drawing it as three toggles would suggest he can pick.

Doubles are called in about four seconds at a ball in flight. The controls are not really live; they are **a fast way to record what was just shouted**, built for a thumb at walking pace — one tap, no confirmation. They stay open until the first score is entered, then close. The window is generous on purpose: the alternative is a golfer arguing at settlement that he called it and the app having no row to put it in.

The second frame resolves the hole and shows **the chain on every row** — `$10 bet · ×2 his double · ×2 counter = $40`. This is the only screen in the app that shows arithmetic and it earns it: three bets with two independent doublers produce a number no golfer can verify from memory, and the argument is always about the chain rather than the outcome.

**Leaderboard.** Ranks by money only. The card leads with **two numbers, not one** — what he made *banking* versus *betting*. Those are different games played by the same man, and a golfer can finish level having been wildly up in one and wildly down in the other. The ledger below is an 18-hole **strip** in the existing scorecard idiom: par, who banked, what he had on, what it paid. Gold where he banked; a blue outline where a bet was multiplied, because **the doubled holes are where the round was decided** and they are a minority of them. Then the three biggest swings, named.

**Settlement.** Unlike Sequoya 3s, **Banker's debts really are pairwise** — every bet was one named golfer against one named golfer for an agreed number. The app can honestly itemise. It still collapses to the **fewest handovers**, because nobody settles fifty-four transactions in a car park, and keeps the real detail one tap away.

The receipt itemises the **six holes he banked** in full (three bets each) and **groups the twelve he played by whose bank he was betting into**, with subtotals. Twelve five-dollar lines would bury the six that matter, and the grouping answers what a golfer actually asks: *who took my money.*

Zero-value lines **stay when the stake was large.** The 14th is on the receipt at zero — a par 3 where all three tripled into a $180 hole, two lost, one birdied, and the banker came out exactly level. A golfer who remembers a $180 hole and cannot find it does not trust the receipt.

**Lock screen.** This is the strongest Live Activity case in the app, for a reason the others do not have: *who is banking, what you bet, and whether somebody doubled it* were all **spoken aloud on a tee box and written down nowhere.**

## The lock card is personal — a departure

Sixes and Sequoya 3s put a **neutral scoreboard** on the lock screen: the same string on four phones. **Banker cannot.** There is no shared state on a Banker hole; there are three separate one-on-ones with three different numbers, and *the score* is not a thing that exists.

So the card reads from the holder's side — **two compositions of one card**:

| Phone | Headline | State slot | Sub |
|---|---|---|---|
| Banker's | `$90` at stake | `BANKING` (gold) | the three bets itemised, and that he countered |
| Player's | `$40` at stake | `V. PAUL` | his bet and what multiplied it |

Neither shows anyone else's bet. A player has no business reading Sam's number off Dave's phone. The **exception** is a hole *you* banked — then every bet against you was your business and your own card shows all three.

The 36pt number is **the hole, not the round.** The running total goes in the footer with the stake, as everywhere in the set. A round total in the headline would be the safer choice and the wrong one: it is the number you already know, and it does not change while you are walking.

**Gold appears nowhere else in the set and does one job: it marks the role.** Mint stays the app's colour and never means *banker*.

## Pushes

| Event | Count/round | Colour | Notes |
|---|---|---|---|
| New banker | up to 17 | gold | Names who banks and **what max he set** — you cannot choose a bet without it. |
| Counter-double | 0–18 | amber | **Your bet just doubled and you did not agree to it.** |
| Your own double | none | — | You called it. You know. |

The counter-double push justifies the whole activity. It is the single event in this game where a golfer's money changes **without his consent or his knowledge**, it is entirely legal, and it happens while three balls are in the air and nobody is looking at a phone. Learning about it at settlement is how groups stop playing Banker.

**Seventeen rotation pushes is a lot** and it is the honest count — the role rotates every hole. One per hole is defensible only because *the hole is unplayable without it*. If field testing says it is too many, the fallback is a silent activity update plus a push only when the banker **changes his maximum** from the previous hole.

## Tokens

Deep pine `#0B1F1A`, pine `#0F6E56`, mint `#3BD89A`, muted `#5C6B62`. New to this packet:

- **Gold (the role)** — in-app `#B8860B` on `#FBF0D6`, borders `#E4D3A8`, panels `#FDF8EC`. Lock screen `#E8C46A`.
- **Blue (a double)** — `#1A5490` on `#F1F7FD`, borders `#B8CFE8`.
- **Amber (the counter, and warnings)** — `#8A5216` on `#FDF3E7`, borders `#E8D6BC`. Lock screen `#F0C070`.

Three action colours is one more than any other packet carries, and each maps to exactly one concept: **gold = the role, blue = a player's double, amber = the banker's counter.** Do not reuse them for anything else.

## Strokes: a dot, never the word "gets"

Every bet settles on net, so **who gets a shot on this hole** is load-bearing on
every screen. Two rules, both corrections to an earlier pass:

- **"Gets N" is an eighteen-hole quantity** — how many strokes a golfer receives
  over the round — and it never appears against a single hole. Where a chip is
  needed at all it reads **`Strokes`**.
- **On the score-entry screen the stroke is a dot on the golfer's score box**,
  top-right corner, pine. No chip. The scorecard below repeats it: a solid dot
  on played holes where a stroke was received, and **a muted dot on future holes
  where one is coming** — a golfer planning a bet needs to see the shots ahead of
  him, not only the ones spent.
- **On the lock screen the strokes go in a ribbon** above the card header, in
  **blue** (`#94C0EE` → `#BBD9F7`, ink `#0C2438`) — gold is the role and nothing
  else, and a stroke is a fact of the hole rather than an alarm. The stroke index
  sits on the ribbon's trailing edge. The banker's card names all three
  opponents' strokes and dots the bet lines ahead of the name; a player's card
  names **only the two men in his bet**. When neither strokes, the ribbon reads
  *scratch hole* rather than disappearing.

## Full names at the top of the leaderboard

Short names are capped at **five characters** and a group may use initials, so
the ledger's column headers carry the **full name** — surname in ink, given name
beneath. The scorecard rows below stay on the five-character short name; there is
no room for more, and the header has already answered which golfer is which.

## Open questions for code

- **The hole cap** — ship it as an option, or not at all?
- Whether the banker's lock-screen headline should be **his exposure** (drawn) or **his net position on the hole** once scores start landing. The second is more useful late in a hole and undefined early.
- Whether a player should see the **total** on a hole without the split. Probably yes — it is the banker's risk, not a private number — but it invites arithmetic.
- Whether the seventeen rotation pushes survive a real round.
- Whether one phone runs the hole or all four do. Drawn as **one**, matching the rest of the app, but it makes every double a relayed shout.
- Whether a bet can be corrected after the lock. Drawn as **yes, with a visible correction** — refusing outright means a mistyped bet ends the game.
- Whether the banker's hole maximum should **default to his last one**. Probably yes; most bankers repeat.
- Whether **bogey-or-better to win** ships at all.
