# Handoff — Pairs (two-man teams)

**An increment on Team Play, not a new flow.** Read `handoff-team-play/HANDOFF.md` first — everything it says still holds. This document covers only what pairs change.

Three screens are new or changed; the flow map and decisions log are the same documents, updated. `team-kit.css` is the shared stylesheet — it has changed since the Team Play handoff (`.blk.off` moved into it), so **use this copy**.

| # | File | Status |
| --- | --- | --- |
| 01 | `01-wizard-step1.html` | **Changed** — gains the team-size control |
| 02 | `02-pairs-format.html` | **New** — the five pair formats, and the Scotch scorecard |
| 03 | `03-pairs-teams.html` | **New** — building pairs, and the odd-field block |
| 04 | `04-flow-map.html` | Updated — pairs table added |
| 05 | `05-decisions-log.html` | Updated — eighty decisions, pairs section added |

---

## The structural call

**Pairs are a team-size control on step 1, not a fourth tournament shape.**

Fours or pairs changes the format list on step 3 and the allowance table on step 5. **Nothing else in the flow knows the team size** — same leaderboard card, same payout screen, same settlement, same receipt, same score picker. A separate "Two-Man Tournament" entry in the format list would have duplicated seven screens to change two.

Everything the four-man flow decided still applies and is not re-litigated: one round, no side games, whole-stroke handicaps rounded once on the total, ties combine and split with no countback, the TD sets fee and places himself, odd cents to the team's highest course handicap.

## Five formats, and the allowance is doing enormous work

This is the finding to act on. The **same pair** — Maiolini 4, Yau 19 — plays off:

| Format | Allowance | This pair | Card |
| --- | --- | --- | --- |
| Scramble | 35% low + 15% high | **4** | One number |
| Best ball | 85% of each, own ball | **3 / 16** | Two scores, better net counts |
| Alternate shot | 50% of combined | **12** | One number |
| Scotch | 60% low + 40% high | **10** | One number |
| Chapman | 60% low + 40% high | **10** | One number |

Three times the strokes from the format alone. So **the pair's figure shows on every option before it is chosen** — a TD picking Chapman because it sounds fun should see that it more than doubles his field's strokes against a scramble.

Two notes on the table:

- **Scotch and Chapman share an allowance**, and that is the honest answer rather than a manufactured difference. Both are two drives then one ball; Chapman buys one extra shot of position, which is not worth a stroke.
- **Best ball is not a team figure.** Each man plays his own strokes at 85% and the better net counts — it is the only pairs format whose allowance is per golfer, and the only one entering two scores.

## The tee-shot control does three different jobs

Every format that chooses a tee shot has the same control on the card. What it *does* differs, and this is the part to get right in code:

| Format | The control | Why |
| --- | --- | --- |
| Scramble | **A record** | Compliance against a quota. Usually one drive each per nine — two men and eighteen holes is a lot of slack |
| Scotch | **An instruction** | Picking the drive says who hits next. The card answers with a sentence: *Maiolini plays the second shot, then alternate.* A quota is available on top, off by default, because the tap is already there |
| Alternate shot | **A rota** | Odd/even, set by the pair on the 1st tee, fixed for eighteen. Not a quota — nothing to fall short of, so no warning and no penalty setting |
| Best ball, Chapman | **Absent** | Both men drive every hole with no choice to record |

The alternate-shot rota must be **named on every tee**. A pair that loses track plays a hole out of order and the round is gone. Same mechanic as alternating pairs in the four-man flow, and the same rule: a rota that can be re-cut mid-round is not a rota.

## Building pairs

The four-man builder with two men to a card. Manual assignment, live allowance, balance strip, Next waiting on an empty tray. Three differences:

1. **Balance matters more, not less.** Four handicaps average out; two do not. A scramble pair of 3 and 22 plays off 4 and a pair of 9 and 23 plays off 7 — three strokes on a card where the field finishes inside six. The strip is the same and the argument is stronger.
2. **Pair names default to the two surnames** — *Maiolini & Yau*, not Pine. Colour names are right for fours, where four surnames fit nowhere; two fit on a leaderboard row and golfers say a pair that way out loud. Free text over it, 16 characters, colour still assigned for the card.
3. **The field must be even**, and the block **names the unpaired golfer** rather than reporting a count — the fix is about one man and the TD needs to know which one is standing there.

**No phantom partner.** In fours the phantom is a handicap device for a team that still hits four balls; in pairs it would be an imaginary man taking half the shots in an alternate shot. The three ways out are offered on the block: add a golfer, remove one, or let one team play three — and **the third is best-ball only and hidden otherwise**. A third ball is just another option to count; alternate shot and Chapman cannot honour it at all, and in a scramble it is a straight advantage. Offering a choice three of five formats reject is worse than not offering it.

## Open

Nothing new. The Team Play open items still stand — flights deferred, multi-round answered by "run two tournaments."
