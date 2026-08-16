# Spec: Survivor — Zombie Option

## Survivor recap (unchanged)

Three players. Every Survivor runs in two phases:

1. **Elimination** — the worst net score on the hole goes out. If the two worst tie, nobody goes
   out and the next hole eliminates instead.
2. **Decider** — the two remaining players play on; the low net of the two takes the Survivor.
   Tied, they carry to the next hole.

A settled Survivor pays, and a fresh one starts on the very next hole with all three back in — up
to nine per round. Everyone antes the stake per Survivor; the winner takes the pot (+2 / −1 / −1).

## The Zombie Option

Off by default. When on, the eliminated player — the **Zombie** — keeps playing and posting scores
through the decider instead of sitting out.

**Resurrection test, evaluated on every decider hole:** the Zombie must be **low outright** on the
hole (net, strictly lower than both deciders). A tie for low is not enough.

Resolution order for a decider hole with the option on:

1. **Zombie is low outright.** He is alive again. Compare the two deciders:
   - deciders split → the **higher** of the two goes to Zombieville and becomes the new Zombie.
     Two alive, one chasing. The Survivor keeps running.
   - deciders tie → there is nobody to send out. **All three are alive again**, and the Survivor
     keeps running from the next hole as a three-man elimination.
2. **Zombie ties for low, or is worse.** He stays out and the hole resolves normally: low of the
   two deciders takes the Survivor; tied, they carry to the next hole.

Worked examples (net scores, Zombie listed first):

| Zombie | Decider A | Decider B | Result |
|---|---|---|---|
| 5 | 5 | 6 | Zombie tied, not low outright → A wins the Survivor, it pays, next one starts |
| 4 | 5 | 6 | Zombie back in, B to Zombieville → 2 alive + 1 Zombie, Survivor continues |
| 4 | 6 | 6 | Zombie back in, deciders tie → all 3 alive, Survivor continues |

There is only ever **one** Zombie: with three players exactly one can be out at a time.

## Consequences

- A Survivor can run any number of holes. The **Survivor number does not increment** on a
  resurrection — it is the same Survivor still being decided.
- Because it can keep restarting, a Survivor can reach the 18th unsettled. That is **no blood**:
  it pays nothing and **nothing carries** into anything else. A whole round can finish with no
  payouts at all. Say so in the UI rather than implying a carry.
- **Hole 18 with a Zombie:** if the Zombie wins the hole (low outright), the Survivor is **killed** —
  it pays nothing, regardless of how the deciders finished. No resurrection, no settle.
- **Hole 18 without a Zombie win** behaves as already specified: with all three in, low ball takes
  it and any tie for low is no blood; with two left, a tie splits the eliminated player's entry.

## State

| Field | Where set | Notes |
|---|---|---|
| `zombieOption: bool` | Survivor setup | Default `false`. Stored on the game. Read-only once any hole is scored. |
| `survivor.zombiePlayerId` | Derived per hole | Null while all three are alive. |
| `survivor.alivePlayerIds` | Derived per hole | Two during a decider, three after a tie resurrection. |
| `survivor.startHole` / `endHole` | Derived | `endHole` stays open across resurrections. |
| `survivor.outcome` | Derived | `won(playerId)` · `noBlood` · `killedByZombie` · `split` |

The eliminated player's scores are **always recorded** either way — with the option off they simply
do not affect the Survivor. With it on they do. Do not branch score storage on the option.

## Screen behaviour

**Setup.** Toggle plus three cases, in this order: back-in-with-Zombieville, back-in-all-three,
no-change. Footnote carries the 18th-hole kill and the no-blood outcome. The base rules block below
it stays as plain Survivor — it does not change with the toggle.

**Play.** With the option on:
- The eliminated row shows a plum **ZOMBIE** badge, plum name, and a normal (editable) score box —
  not the greyed OUT row.
- On resurrection, the outcome banner is plum: "*Name* is alive again — *Name* goes to Zombieville.
  Survivor *n* carries on."
- The phase banner names the Zombie: "A v B for it · C is the Zombie. Low of the two takes it —
  unless C goes low outright and comes back in."
- The by-hole grid marks the resurrection hole plum on the Zombie's row, and the hole that sent a
  decider out red on his row, on the same hole.

**Leaderboard (Survivor tab).** Standings by trophies then money, dash while a Survivor is in play.
The Survivors strip lists each Survivor with its hole range, result and payout; the live one reads
"in play" and, if there is a Zombie, names him. The scorecard block carries par, index, stroke dots
and the three marks. Legend: *green = won it · red = knocked out · plum = Zombie back in*. Header
shows a "🧟 Zombie on" pill when the option is on.

## Open question — RESOLVED

Whether the trophy count should show a Survivor killed on 18 by the Zombie at all. Drawn as: not
counted, no trophy, no money. Flagged for product.

**Product answer (Paul, 2026-08-16): credit the Zombie a trophy.** Killing a Survivor on 18 is a
real achievement, so it counts — but it still pays nothing, since nothing settles. The trophy count
therefore means "Survivors you DECIDED", not "Survivors you won".

Built that way: `outcome = 'killed'` carries `winner_id = <the Zombie>` (so the standings count it)
while settlement skips it entirely, and the leg also reports `killed_by_id` / `killed_by_short` so
the strip can read "Killed by Sam on 18".
