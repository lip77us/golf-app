# Banker — as built

What shipped from the `handoff-banker` packet, and every place it differs.
Written to go back to design. The engine, the API, setup, play, the leaderboard
and score entry are in and were played through the simulator over 5–7 September
2026. **The settlement receipt and the Live Activity card are not built** —
§6.

The packet largely survived contact. Its rules reproduce: the band, the hole
maximum, the golfer double, the par-3 triple, the banker's counter, the birdie
bonus and the exposure ladder all behave as drawn.

**One assumption did not survive**, and it moved every screen in the game. It is
the first section.

---

## 1. A golfer has one net. The banker has three.

> **This is the one to read.** It changes a rule the packet states in passing
> and every screen inherits.

The packet draws a hole as four scores and one net apiece. Under strokes-off
that is not true of the banker.

A Banker hole is **three separate one-on-one matches**, and strokes come off
inside each one. The banker can be giving a shot in one bet and taking one in
another on the same hole — so there is no single "his net", and every screen
that printed one was printing a figure untrue of two of the three bets.

| | Packet | Built |
|---|---|---|
| Banker's row | one gross, one net | one gross, then **three nets named by whose match each is** — `net versus Sean 4, RyanL 5, Paul 5` |
| Opponent's row | one net | unchanged — his own match is the only one he plays |
| Scorecard dot | field-wide allocation | his stroke in **this** match on **this** hole |
| `gets` chip | (not in the packet) | strokes off the **lowest-index golfer** |

The last two are different numbers on purpose: `gets` says where a golfer sits
in the group, the dot says what he is getting in the bet in front of him. Both
are needed and neither substitutes.

---

## 2. Differs from the packet

| # | Packet | Shipped | Why |
|---|---|---|---|
| 1 | `Lock bets — doubles only from here` | **`Increase Bets`** | Par 3s triple and the banker can counter, so "doubles" was wrong on a good many holes |
| 2 | `Calls stay open until the first score goes in` · `OPEN UNTIL THE FIRST SCORE` | **removed** | On the course the calls are settled when the ball lands; the score going in later is bookkeeping, not the deadline. The screen was describing its own plumbing |
| 3 | `-$80` on the banker's row | **`at risk: $80`** | Before the hole resolves nothing has been lost. The stake is the only figure that exists |
| 4 | one exposure total | **a range, `$X–$Y`**, birdie bonus excluded | Before all three bets are in, exposure is a range; the bonus is not a bet anyone declared |
| 5 | negative money in brown | **`red.shade700`** | Red is the app's loss colour everywhere else, and brown read as the banker-double bar, which is unrelated |
| 6 | a banner card above the hole | **no banner** — the banker leads the list | It repeated his name and pushed the hole itself off the fold |
| 7 | the resolved hole is skipped on a clean low-net winner | **always shown**, forward button reads `Proceed to hole N` | Skipping it means the last hole's result is never seen |
| 8 | the initial bet leads the row | **a bubble**, beside the golfer-double and banker-double bubbles | One vocabulary for all three multipliers on the row |
| 9 | the hole ceiling is picked from a list | **typed** | At a $15–$180 range in forty steps there is no `$100` to choose, and a ceiling nobody can state exactly is not one anybody agreed to |
| 10 | (no round-level cap) | **a per-golfer loss cap** | §3 |
| 11 | doubles row in bet order | **ordered by index**, matching the bets above it | Two rows of the same three men in two different orders is a misread waiting to happen when the button carries only a short name |
| 12 | (not stated) | **score entry puts the banker first**, then by index, with the bets and the group scorecard beneath | His score is the one all three bets are measured against |

---

## 3. Rulings taken during testing

Each departs from the packet, so each wants a look.

- **Rotation ranks on strokes off the low man, not full allocation.** Ranked on
  each golfer's own allocation, the app offered the bank on a tie the scorecard
  in the group's hands showed was not a tie. The cause is not arithmetic, it is
  the rule: **allocation is not linear**, so the two orderings genuinely differ.
  The card is what the group is looking at, so the card wins.
- **The loss cap is one number per golfer, and it is a threshold rather than a
  ceiling.** How much a man will lose over a round is his own question — a $500
  golfer and a $200 golfer are both making sensible calls, and one of four
  usually says none. Nothing already owed is forgiven, no total is scaled, and
  he can finish past his own number. What it changes is the future: floor bets
  only, no doubles his own or the banker's, the counter passes him by, and he
  cannot take the bank. It is irreversible — dropping back under the line does
  not re-open the action. The phrase that settled it: *cut off by the casino
  until next round.*
- **A clamp would have been wrong for a stated reason.** This game's receipt
  names who owes whom for which hole, and a round-level clamp rewrites holes
  the group has already read out.
- **The hole cap, by contrast, does scale.** One hole is a single closed
  settlement, so scaling every bet by the same factor stays zero-sum and
  rewrites nothing agreed elsewhere. A $300 hole under a $60 ceiling settles at
  $60 with each golfer keeping his share.
- **Both limits are printed on the leaderboard**, in a `THE LIMITS` block: the
  hole ceiling, each golfer's own number, and the hole a cut-off happened on.
  Typed once on a setup screen nobody returns to and then silently shaping every
  hole, they were rules the table could not check.
- **A cut-off golfer's floor bet is placed for him** when the banker names his
  maximum. He is the one golfer the "no silent floor bet" rule does not
  describe: that rule exists so the app never chooses somebody's stake, and he
  has no stake to choose. His bet phase carries a `CAPPED` tag, the ladder
  collapses to the floor chip, and his double button is greyed and reads
  `capped`.
- **Gold marks the ROLE and nothing else** — not a state, not a warning. The
  banker's row, his cell on the scorecard, the first-banker draw. Amber stays
  the counter and warnings; mint never means banker.
- **A slot-machine draw for the first banker**, matching Sixes. Not in the
  packet. The draw happens before the reel opens — the machine reveals a name
  that already exists, it never sources one.
- **Banker plays three-handed**, and the game selector now offers it on a
  three-player round.
- **The chip ladder drops to dollar increments on a small band.** A $1–$5 game
  should offer $1, $2, $3, $5 — four options. Rounding intermediates to
  multiples of five left exactly one chip on the row.

---

## 4. Defects found and fixed on the way

Found by playing it, not by reading it.

- **Neither cap ever saved.** Both fields parsed through a helper that required
  a positive number, so a typed `-500` was dropped and the round stored no cap
  at all. Both now read a leading minus as a magnitude, along with currency
  symbols and separators — they describe money going out, and that is how a
  golfer writes it.
- **The hole cap never reached the money.** It clamped the number in the
  exposure banner and nothing else, so the banner obeyed a ceiling the
  settlement had never heard of.
- **Edit configuration opened on the defaults**, not on the saved game — so it
  was not showing the round's settings, it was quietly proposing to replace
  them. The quietest of those was the worst: the first banker defaulted to the
  top of the roster, so editing the band on a round somebody else was banking
  would have reassigned hole 1 while the button read `Start — Paul banks the
  1st`. It now loads the game, and the first banker is fixed once a hole has
  bets or a result.
- **The draw's result was lost on a back-out.** Spin, land on Tyler, back out of
  the reel, and the screen showed the first golfer on the roster.
- **A capped golfer's double button was live** and answered the tap with a
  server error. The counter's subtitle also read "all three bets" while the
  settlement went past him.
- **Posting a hole walked into the next one**, past the banker and the bets, and
  there was no way back to a hole already scored.

---

## 5. Implementation notes design may care about

- **The scorecard is the shared `HoleGridScorecard`**, the same grid every other
  game draws, with the banker's cell in gold and the stroke plan drawn for all
  eighteen holes rather than only the played ones. The gold cell is inert for
  every other game. A bespoke Banker card was built first and deleted: a grid
  drawn only for this game drifts from the one on every other screen.
- **The scorecard under score entry fills in as scores are typed**, because the
  screen that follows does not show one.
- **The exposure ladder on setup is computed the same way the server computes
  it**, and rungs a switched-off rule cannot reach are dropped rather than
  greyed. A ladder overstating what this group can lose is not an argument.

---

## 6. Still open

- **The settlement receipt is not built.** `banker_settlement()` is written and
  tested — per-golfer receipts, the holes he banked itemised in full, the ones
  he played grouped by whose bank he was betting into — and no screen draws it.
- **The Live Activity card is not built.** It would go into `UNSHIPPED_KINDS`
  until a build can draw it, the same gate Sequoya used.
- **Stroke notation on the shared score-entry screen.** It still shows one dot
  per golfer. This is the only screen in the app carrying three simultaneous
  matches, and the right notation for that is deliberately left until the whole
  game can be seen running. Nothing is blocked on it, and it is design's call.
