# Spec: Individual play — tournament setup and play

Build-from document for the `handoff-individual-play` packet. The HTML files are design
reference (Flutter is the target; `lib/theme/halved_brand.dart` holds the live palette).
`15-decisions-log.html` is the summary of decisions; this file is the same content
restated as rules, state and edge cases, plus the calls made at build time.

**Scope.** Individual-play tournaments only — `_EventType.solo` in the wizard. Cup play
(`team_cup`) is untouched. Casual rounds are untouched except where a screen is
deliberately reused (Stableford points, spots capture).

---

## 1. Scope boundary — who sets what

The TD sets **four games only**:

| Game | Key | Scope | Pays |
|---|---|---|---|
| Irish Rumble | `irish_rumble` | field | a foursome, split among its real golfers |
| The ball game | `pink_ball` | field | a foursome, split among its real golfers |
| Mini Singles Bracket | `match_play` | per group (day 1) + champions' foursome (day 2) | golfers |
| Day bet | `day_bet` | field, final round only | golfers |

Plus the **championship** itself (`low_net` or `stableford_championship`).

Everything a foursome plays among itself — skins, Nassau, rabbit, survivor, sixes — is the
**foursome's** to configure, exactly as in a casual round. Consequences that must hold:

- The TD's setup surfaces never list them.
- They read the tournament's score entry. No second card, and none of the specialised
  entry surfaces those games have casually (the rabbit card, the survivor board).
- **They never appear in tournament settlement totals.** The TD never set them and never
  collected for them.
- The one exception is **spots**, which needs capture on the hole: a `−/+` stepper per
  golfer per hole, a **count and never a type**, rendered only when this group chose spots
  and only on golfers who opted in. No-steppers is the default card.

---

## 2. Scoring

**Method** is per tournament: Stroke play or Stableford. Set on step 1, editable on the
Scoring step. One method, one board — a Stableford tournament does not also draw a net
stroke board.

**The net double-bogey cap is always on.** Not a toggle. Stated once where scores are
explained, and shown on the card as a tinted cell.

    cap = par + 2 + strokes received on that hole

Gross boards ignore it; net boards apply it; Stableford reads points off the capped net.
On a standard Stableford table (double or worse = 0) the cap changes nothing; on a table
with negatives it bites, and the setup screen says so.

**Handicap** is Net or Gross with an allowance percentage, defaulting to 100%.
**Strokes off low does not render on this type** — it needs a single opponent to anchor
to. It survives in exactly one place: Mini Singles, where it is the default.

**Rounds counted** appears only when the tournament has **more than two rounds**. All
rounds / best 3 of 4 / best 4 of 6. The board strikes the dropped column through rather
than hiding it, and the selection moves as scores land.

**A round in progress does not compete for a counted place.** Four holes at level par
would otherwise knock out a finished 73. The live round joins the selection only when it
is complete; it is still shown, in amber, and its holes are still on the card.

**Flights are deferred.** Not built. When they land the intent is an **even split of the
field**, not index ranges, and they ride on the Payout step rather than earning one.

---

## 3. Money

**Entry is flat, per side game, taken at signup.** A golfer's games are known before round
one and the side-game step never reopens mid-tournament.

Pools:

- **Championship pool** — from entry, pays up to three places. The Mini Singles day-2 pot
  is a **percentage carve-out off the top**, set at tournament setup. There is no separate
  day-2 entry.
- **Side-game pools** — one per game, from that game's entry. Scope is stated on the pool
  line: `$10 × 4 in this foursome = $40` vs `$10 × 8 in the field = $80`.
- **Day bet** — final round only.

Three rules the payout step must enforce:

1. **Ties split the money for the places they occupy.** A T2 shares 2nd and 3rd — $16
   each, not $20 each. There are no countbacks anywhere in this spec.
2. **A levelled group splits its place among its real golfers.** The borrowed 4th is not a
   person and cannot be paid: three winners take $23.33 where four would take $17.50.
3. **Last paying championship place ≥ day bet 1st.** Winning 36-hole money disqualifies a
   golfer from the day bet, so a smaller last place would mean finishing in the money
   costs him money. Validate at the payout step and block Save **with the reason shown**.

**Money is a projection until the round closes** — muted italic throughout, with one line
under the table saying so. Full weight only once the round is closed.

**Nothing is disabled without saying why.** Applies to Save Configuration, the next-hole
button, and every balance check.

---

## 4. Mini Singles Bracket

Optional, at the TD's discretion, switched on at the side-game step. **Nothing downstream
may assume it**: no carve-out, no reserved day-2 foursome, unless it is on.

### Shape

Four matches per group: two semis on the front (1–9), final *and* 3rd place together on
the back (10–18). Every group runs its own bracket on day 1; the four group champions play
day 2 as **one foursome** for the title. Everyone else plays a normal stroke-play round.

### Field

| Golfers | Groups | Shape |
|---|---|---|
| ≤ 8 | 2 | A final with no semis — not a bracket. **Not offered.** |
| 9–12 | 3 | Full bracket day 1; day 2 takes the empty-seat rule. |
| 13–16 | 4 | Full bracket, both days identical in shape. |
| > 16 | 5+ | Five winners need a third day. **Not offered** on a two-day tournament. |

### Seeding

Day 1 seeds from handicap — lowest index is seed 1 and meets seed 4 — and the TD can drag
to reorder; pairings derive from the order. Day 2 seeds by **day-1 margin**, then lowest
index (which will be needed: two 2&1 winners is an ordinary Saturday).

### Handicap

Opens on **strokes off low** — a match has two players and a low man to anchor to.
Overridable to full net. Set once, governs both days. The field games inherit full net
from the tournament.

### Halved matches — the same rule both days

The distinction is not Saturday vs Sunday, it is what the match still has to produce.
Money can always be split; a name cannot.

- **Semi** — plays on. Never splits. Play continues and the match is back-calculated
  against the finals pairing, **reading back from hole 10**. Nobody waits: the resolved
  pair tee off on 10 on schedule and score under `1 UP vs. TBD`. No ambiguity is possible
  — the pair in overtime can only halve, since the first hole they do not halve ends the
  semi and names the opponent. The label is `1 UP vs. TBD`, never `Pending`.
- **Final** — money splits between 1st and 2nd. The trophy, and the Sunday seat on day 1,
  goes to the **last hole won**: read the card backwards to the most recent hole either
  golfer took outright.
- **3rd place** — splits. Nothing depends on the order, so nothing needs breaking.

A tie in the points round also plays on — never a card-off. Play points until 1st and 2nd
are clear, then back-calculate the match from the 10th.

### Empty seat — short field or withdrawal

One rule, set once at setup, never asked on Sunday morning:

1. **Promote best runner-up (default)** — the lowest net beaten finalist fills the seat.
   Tiebreak: lowest net over the day-1 round. He still has to win two matches.
2. **Points, then a match** — all three play points over the front; the two leaders play
   the back nine as a match.
3. **Short-handed** — nobody is refilled. Three play points then a match; two play a
   straight nine-hole match. No byes.

### Money

Two pots, funded differently:

- **Day 1** — a side bet entered per golfer, paid inside each group. It exists so the
  3rd-place match is worth playing. Auto-suggest 60/25/15 (the existing `suggestPayouts`
  split — already aligned, no new percentages). 3rd does **not** get his entry back.
- **Day 2** — the championship carve-out, a percentage of the championship pool set at
  tournament setup. **Read-only on this screen** — it reports it, it does not set it.
  4th takes nothing and that is fine: there is no day-2 entry to refund.

Guards, stated in the balance line rather than enforced silently: the places must add to
the pot, and each must pay less than the one above.

### Sunday consequences

- Finalists **keep their side games** — the champions' foursome plays the ball game and
  Irish Rumble as normal.
- Finalists are **out of the day-2 stroke bet**. They are playing a match, not a card.
- Match play and stroke play money are **independent**. Both prizes can go to one man.
- The day-2 foursome is **derived, never set**. The groups step must reserve it — the TD
  cannot know the four winners when he builds Sunday's tee times.

---

## 5. Irish Rumble

**Re-drawn each round** — a new entry, a new pool, a new winning group every day. A
two-day tournament runs it twice and settles it twice; the leaderboard tab names the round.

Mode picker (Fixed / Shuffle / Custom) **expands in place** — Custom opens its 18-cell
editor under the radio. Rules first, money last, one Save. No game gets a second rules
screen.

**Borrowed 4th** (already built): a threesome borrows a 4th from the field — automatic,
only when another group has four, donors rotate across every other golfer in one fixed
rotation, and the donor's own net on his own tee counts. Called **Borrowed 4th**
everywhere, never *phantom*; **4th** on hole-by-hole cards. A group waiting on a donor
shows a **provisional total on three balls** (`F*` in amber beside the group name), never
a wrong one on four.

Ties split the place, no countback. A levelled group's place splits among its **real**
golfers. The chip must read the real rule — never `Winner takes all` over a silent split.

---

## 6. The ball game

**The TD names it.** Free text, **16 characters** (the iPhone 13 mini cap from the Cup
work), carried to the tab, the carrier badge, the lost-ball control, the chat string and
the settlement line. **No default and no memory of last week** — Save does not fire until
it has a name. The app never asks the colour.

Rules stated on the setup screen: one ball per group, no replacements; it rotates in the
order the group sets on the first tee and that order repeats all 18; the last group still
holding it wins; low net breaks a tie between groups that finish 18 with it alive.

**Re-drawn each round.** The name carries across; the pot does not.

**Ranking is by survival, not by score:**

1. Still alive at 18 — top of the board. Among survivors, the **ball's own net** (the
   carrier's net against par, not a four-man aggregate) separates them.
2. Lost — ranked by the hole the ball died on, **latest first**.

Ball net shows only for groups still alive; an eliminated group reads `–` on that column
and its real total is on its card. The board names the **carrier and the hole**.

---

## 7. Day bet

The final round's 18-hole stroke play side bet — a separate pot on that round alone, and
the only board whose result is not knowable while it is being played.

Two ways out, and only one of them is italic:

- **Not here at all** — the Mini Singles finalists. Playing a match, not posting a stroke
  card, so they are neither charged nor ranked. An absence, not an exclusion.
- **Here but italic** — the championship money winners. They play the round and appear on
  the board but cannot collect, and **do not contribute**: their entry is returned at
  settlement. Only known when the championship closes, which is why they stay visible.

Worked: 16 − 4 finalists − 2 money winners = **10** who fund the pot and can win it. Ten
pays three places; a smaller field drops to two, then one. **Places scale with the round,
not the entry list.**

The pool is provisional for the same reason and reads from the current 36-hole leaders.
Nothing is collected until the championship closes, so no refund is ever handed back.

The DQ **follows the tournament's handicap setting** — net event, net winners; gross
event, gross. The line reads "Winners of 36-hole net money are not eligible."

Ties share a position, carry `T`, and split the money for the places they occupy.
**Ineligible rows hold a position but do not consume a paid place** — prize is shown
against the first three *eligible* golfers, not the first three rows.

---

## 8. Leaderboards

- **Tabs are named for what they pay**: Championship, each side game under the name the TD
  set, then `Day bet · R<n>`. Never a tournament name beside a cut-off word.
- **Four round columns, then the strip scrolls.** Round columns are their own horizontal
  strip; every row scrolls with the header, and the board opens **scrolled to the most
  recent round**.
- Every round gets a column. Best-N counting **strikes the dropped round through** rather
  than hiding it, and it moves as scores land. The chip strip shows the counting rule.
- **Expanded rows open all 18** — par, stroke index, gross with a dot per stroke received,
  and the net being ranked. Capped holes are a tinted cell. Never a two-column fragment.
- **Rows still on the course are marked.** A leader thru 11 must not read like a finished
  one. `Thru` sits under the name, not in a sorted column.
- A **Stableford card shows gross and points**, not per-hole net, with the stroke
  allocation on the card.
- **Full names on summary rows, short names on hole-by-hole cards** — five characters,
  defaulting to initials. The borrowed ball is `Borrowed 4th` on the summary and `4th` on
  the card.
- Match summaries use the **surname alone** — *Detomasi vs Gunst*. Collisions fall back to
  a first initial.
- **CH** is the handicap label everywhere — not `HCP`, not a bare parenthesis.
- Projected money is muted italic with one line under the table.
- The cap footnote is one line, on every net board: *No hole counts for more than net
  double bogey — par + 2, plus any strokes you get on that hole.*

---

## 9. Settlement

Tournament-scope games only. One net number per golfer; the card is the itemisation —
each entry a debit, each prize a credit, each naming the game that caused it.

- Collects first, green, sorted by amount. Pays muted.
- Group prizes show the **golfer's share with the group named** — *Irish Rumble, Group 2
  (3 ways)*.
- Irish Rumble and the ball game appear **twice** on a two-round event (R1 and R2).
- Not everybody staked the same: the six out of the day bet list six entries, the ten who
  can win it list seven.
- **Foursome side bets are excluded** and the screen says so.
- **By game** is the TD's check: entries in, prizes out, difference. A game that does not
  balance **blocks the whole settlement and names the game**.
- The carve-out makes this less obvious than it sounds: Mini Singles day 2 takes its pot
  *out of* the championship pool rather than charging an entry, so the championship shows
  $640 in and $640 out with $160 of that leaving for another game's table.
- The day bet resolves last — Settle stays off until every round is closed.
- **Collected minus paid must be zero.** Any other answer is an arithmetic bug.

---

## 10. Create flow — the eight steps

| # | Step | Change |
|---|---|---|
| 1 | Type & format | Keep. Add the consequence strip and the derived step list. |
| 2 | Event details | Keep. Header says **Tournament**, not Round. |
| 3 | Scoring | Drop SO Low. Cap stated as a rule. Allowance. Rounds counted (> 2 rounds only). |
| 3a | Stableford points | The **casual** setup screen, reused. Only when the method is Stableford. Adds a scope chip, drops per-point settlement, marks the active preset. |
| 4 | Select players | Keep. |
| 5 | Groups & tees | Keep, tee labels normalised. Reserves the day-2 champions' foursome when Mini Singles is on. |
| 6 | Payouts | Championship pot only. Balance check + auto-suggest kept. Carve-out % set here. |
| 7 | Side games | Pink Ball / Irish Rumble / Mini Singles Bracket, + day bet on multi-round. **Fee per game, here.** |
| 8 | Review → Create tournament | One name per game, each with its fee. |

Eight steps counted, seven shown for a one-round stroke-play event. Post-creation is a
**confirmation, not a to-do list** — every game already has its fee. Rows show state in
words (`✓ $10` / `Not set`), and Done names what is missing.

Renames: `New Round (x of 7)` → `New Tournament`, `Create Round` → `Create Tournament`,
`Match Play Foursome` → **Mini Singles Bracket** everywhere.

---

## 11. Build order

| Phase | Content |
|---|---|
| P1 | Tournament scoring settings + best-N-of-M (§2) |
| P2 | Money model — pools, tie splits, payout guards (§3) |
| P3 | Mini Singles Bracket engine, two-stage (§4) |
| P4 | Day bet engine (§7) |
| P5 | Irish Rumble refresh (§5) |
| P6 | Ball game — TD-named, ranked by survival (§6) |
| P7 | Tournament settlement (§9) |
| P8 | Leaderboards (§8) |
| P9 | Tournament score entry (§1 spots, lost-ball, pager) |
| P10 | Wizard restructure (§10) |

Backend engines and API land first, per the sequencing call; mobile follows against a
working API.

---

## 12. Calls made at build time

Decisions taken here that the packet left to code:

- **Mini Singles extends `match_play` in place.** The existing per-foursome
  `MatchPlayBracket` stays and becomes day 1; day 2 is an additive tournament-level stage.
  Existing tournaments keep working. Not a new game key.
- **Field floor is 9**, so the three-group short-field rule is built as a real setup
  option rather than deferred.
- **Auto-suggest percentages already match.** `mobile/lib/widgets/payout_config_field.dart`
  `suggestPayouts` ships 60/25/15 for three places — the same split the packet asks for.
  No fourth vocabulary is introduced.
- **The day bet DQ check lives in the payout reducer**, not only the UI, so an API caller
  cannot post a championship table that under-pays its last place.

## 13. Deferred

- Flights (§2). Nothing here depends on them.
- Mini Singles above 16 golfers — needs a third day; not offered.
- Per-golfer settle marking (drawn as all-at-once) and a text export of settlement.
- Whether Irish Rumble ever pays two places — the stepper is live, drawn at one.
