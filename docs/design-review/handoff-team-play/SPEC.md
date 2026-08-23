# Spec: Foursome Play — four-golfer teams, one round, one leaderboard

> **Naming.** The packet calls this shape **Team Play**; the product calls it
> **Foursome Play**. The code keeps the packet's name throughout — `team_play`,
> `TeamPlayConfig`, `services/team_play*.py`, `widgets/team_play/` — and only
> the strings a TD reads say "Foursome Play".
>
> The split is deliberate. **"Foursomes" was already taken twice**: it is
> `GameType.FOURSOMES`, the alternate-shot format (2v2, one ball a pair) shown
> in the Cup game picker and as a Triple Cup segment label — which is that
> format's correct golf name and should not move — and `Foursome` is the core
> model for a group of golfers, 300-odd references deep. "Foursome Play" reads
> naturally here because, as §2.1 sets out, the team IS the foursome; renaming
> the code to match would collide with both.

Build-from document for the `handoff-team-play` packet. The HTML files are design
reference (Flutter is the target; `lib/theme/halved_brand.dart` holds the live palette).
`13-decisions-log.html` is the sixty-six decisions in summary form and `12-flow-map.html`
carries the argument behind each step; this file restates both as rules, state and edge
cases, plus the calls made at build time against the existing codebase.

**Scope.** Team-play tournaments only — the `_EventType.quad` branch already stubbed and
disabled in `new_round_wizard.dart`. Cup play (`team_cup`) and individual play
(`_EventType.solo`) are untouched. Casual rounds are untouched, including the existing
casual `scramble` game, which is a **different** game and keeps its own maths (see §11).

**The governing rule.** This is the simplest of the three tournament shapes and must stay
that way. Most decisions in the packet are decisions *not* to build something; a change
that adds a dimension here (a round column, a second pot, a side-game tab) is wrong even
when it is easy.

---

## 1. Shape

| | Cup | Individual | **Team Play** |
|---|---|---|---|
| Unit | Two sides, a match | One golfer, a card | **A team of four, a card** |
| Rounds | Multi-day | Multi-day, best-N | **One. Not a setting.** |
| Games | Cup + secondary | Championship + 4 side games | **One. The championship.** |
| Handicap | Net / gross / strokes off | Full net, allowance % | **Allowance set by format — a team figure** |
| Hard part | Pairings, no-shows | Money across seven pots | **Drive requirements** |

**One round is stated, not chosen.** Nothing downstream has a round dimension: no round
columns, no `rounds_to_count`, no per-round pot, no cross-round board. A club wanting two
days runs two tournaments.

**No side games.** The team *is* the foursome, so there is no field to run a ball game
against. The TD's surfaces never offer one and settlement has no second pot. A foursome
wanting a bet among its own golfers still has the casual games.

**One pool** — the team championship, flat per-golfer entry taken at signup.

**Field size sets the team count, not the reverse.** The TD adds golfers; the app reports
`6 teams — five of four, one of three`. He is never asked to divide before they have a
headcount.

---

## 2. Data model — the calls made at build time

### 2.1 A team is a Foursome

The team is the foursome. `Foursome` already carries `name`, `has_phantom`, `tee_time`,
memberships with a stored `course_handicap`, delegated scoring (`is_scorer`), withdrawal
and watcher plumbing. A Team Play team is one `Foursome` in the tournament's single
`Round`, and every one of those comes free.

**`TournamentTeam` / `TeamTournament` are NOT reused.** They are the Cup roster layer —
`cup_name`, `players_per_team`, `draft_complete`, two big sides drafted before rounds
exist. Six small teams that each *are* a playing group are a different thing, and pointing
them at a `TeamTournament` row whose fields are all inapplicable buys only the `colour`
field.

### 2.2 New models

```
TeamPlayConfig            OneToOne → Tournament     the TD's settings, one row
TeamPlayTeamState         OneToOne → Foursome       per-team state: colour, allowance, rota
TeamDrivePick             FK → Foursome             one row per team per hole
```

**`TeamPlayConfig`** (`tournament/`):

| field | | |
|---|---|---|
| `tournament` | OneToOne | |
| `team_format` | `scramble` \| `shamble` | locked at first score |
| `ball_count_mode` | `fixed` \| `escalating` \| `par_based` \| `per_hole` | shamble only |
| `ball_count_fixed` | 1–4, default 2 | `fixed` mode |
| `ball_counts` | JSON `{hole: n}` | `per_hole` mode; resolved for all modes on read |
| `drive_rule` | `none` \| `per_nine` \| `per_eighteen` \| `alternating` | |
| `drives_required` | small int | per-golfer, per window |
| `drive_penalty` | `warn` \| `two_strokes` | default `warn` |
| `handicap_mode` | `net` \| `gross` | |
| `allowance_override_pct` | null \| int | null = the format's table |
| `entry_fee` | decimal, $5 steps | |
| `places_paid` | 1–4, capped at team count | |
| `split_pcts` | JSON list, must total 100 | |
| `format_locked_at` | datetime, null | set by the first score |

**`TeamPlayTeamState`**: `foursome` OneToOne, `colour` (assigned always, even when the TD
renames), `team_handicap` (the rounded whole number), `team_handicap_raw` (the full-precision
sum, shown under it), `drive_pairs` JSON (alternating rule only, set once on hole 1, then
immutable).

**`TeamDrivePick`**: `foursome`, `hole_number`, `player` — `unique_together(foursome,
hole_number)`. **One model serves both formats.** The legacy `ScrambleHoleScore.chosen_player`
is not used for this: shamble has no `ScrambleHoleScore` row, and a single source makes the
tracker one query in both formats.

### 2.3 Scores

**Scramble** — one gross per team per hole. Use **`TeamHoleScore`** (already in
`games/models.py`, from the Cup team-ball Phase A work) keyed `foursome + team +
hole_number`, with `team` … *and here is the one wrinkle*: that model FKs `TournamentTeam`,
which §2.1 declines to create. **Call: widen `TeamHoleScore.team` to nullable and key Team
Play rows on `foursome` alone** (`unique_together` already includes `foursome`; a null team
is unambiguous because a Team Play foursome IS the side). The alternative — reviving
`ScrambleHoleScore` — is rejected: it exists for the casual scramble whose handicap maths
differs, and two writers on one table invite exactly the confusion §11 is guarding.

**Shamble** — four gross scores per hole, i.e. ordinary per-golfer `HoleScore` rows. No new
score storage. The counting subset is derived, never stored.

### 2.4 The type switch — a defect to fix first

`Tournament.is_individual_play` is currently `'team_cup' not in active_games`. A Team Play
tournament would satisfy that and pick up the individual-play rules: the always-on net
double-bogey cap, field-wide allowance, best-N counting. **Add `GameIds.teamPlay` to
`active_games`, add `Tournament.is_team_play`, and narrow `is_individual_play` to exclude
it.** Do this before anything else — every downstream board reads it.

---

## 3. Setup — eight steps

| # | Step | Screen | Built? |
|---|---|---|---|
| 1 | Format, rounds, field | `01-wizard-step1` | new — enable `_EventType.quad` |
| 2 | Players | — | **existing, unchanged** |
| 3 | Groups & tees | `02-set-tees` | **existing, unchanged** — and it builds the teams (see below) |
| 4 | How the team scores | `03-team-format`, `04-shamble-counts` | new |
| 5 | Drive requirement | `05-drive-requirement` | new |
| 6 | Handicap & allowance | `06-handicap` | new — carries the balance the build screen would have shown |
| 7 | Entry & payout | `08-payout` | new |
| 8 | Review & create | existing review step | **existing, unchanged** |

**There is no separate build-teams step** (`07-build-teams` is not built as drawn).
The packet assumes step 2 sets tees only and step 6 assigns golfers, but this app's
**Groups & Tees** screen already does both — drag to reorder, "Edit sizes" to change the
breakdown — and in this shape the group IS the team. A second assignment screen would make
the TD do the same job twice and let the second answer silently win.

What the build screen uniquely offered — **the allowance per team, moving as golfers move, and
the spread across the field** — lives on the handicap step instead, which was already
listing every team with its worked figure. The tray gate goes away with it: the group
sizes slice the whole field, so no golfer can be left unassigned.

**No colours, and no names, in the wizard.** Teams arrive as `Group 1`…`Group N` and name
themselves from the round hub. A TD inventing six names for golfers who have not turned up yet
is work nobody asked for, and a colour they never chose is one more thing on screen that
does not help them.

House rule inherited from the Cup: **nothing is disabled without saying why.** Next is live
from the moment the defaults are on screen — a one-round scramble is one tap per step.

---

## 4. Format and ball counts (step 3)

**Scramble** — all four hit, best ball played. One score per hole. Handicap is a single team
figure.

**Shamble** — best drive, then each golfer plays their own ball in. Four scores per hole.
Handicap stays per golfer.

They share one thing: **the tee shot is chosen.** That is why the drive requirement applies
to both.

**The ball-count controls expand in place under the Shamble radio.** House rule from the
Irish Rumble work: no game gets a second rules screen. Picking Scramble collapses them.

| Mode | Rule |
|---|---|
| Fixed | The same count all 18. **Best 2 of 4 is the default.** |
| Escalating | 1 ball on 1–6, 2 on 7–12, 3 on 13–18 |
| Par-based | Par 3 = 3 balls, par 4 = 2, par 5 = 1 |
| Per hole | 18-cell grid, tap to cycle 1→2→3→4 |

**Escalating is a preset, not a grid recipe.** It is the shape people describe in words
("sixes"); making them tap eighteen cells for it is the app failing to listen.

**The preview reads back in sentences, collapsed into runs** — `Holes 1–6, best 1 net` —
and reports **total balls counted**: `36 counted of 72 played`, plus the average per hole.
Fixed-at-2 and escalating both total 36, distributed differently; seeing that is what makes
the choice read as character rather than difficulty.

**A hole set to 4 is legal and flagged** — no drop score, so one blow-up is the team's.
Deliberate on a closing hole, an accident anywhere else.

**A short team counts the phantom.** Its ball is one of the four available. Nothing about
the count changes — that is the point of handicapping a team of three as four.

**Format and counts lock at the first score** (`format_locked_at`). A one-number card cannot
be re-read as four; a hole scored under "best 2" cannot be re-read as "best 1".

**Not offered:** Irish Rumble as a team format, and a "modified — pick the count" option.
Both are a shamble with the count moved, which the count chip already says.

---

## 5. Drives (step 4)

Four rules, and they are **not four settings of one thing**. Three are quotas and one is a
schedule. That split decides the UI.

| Rule | Kind | On screen |
|---|---|---|
| None | — | Nothing. The screen never appears again. |
| Per nine | Quota | **Two independent windows** |
| Per eighteen | Quota | One window, most slack |
| Alternating pairs | Schedule | One line on the tee: *Gunst and Yau are up* |

1. **A quota shows its slack.** `4 required / nine · 9 holes · 5 free / nine`. That figure
   tells a captain whether they can let their long hitter drive the par 5.
2. **Warn when owed > holes remaining in the window** — not on 18. The failure every group
   has had: three holes left, five drives owed; it became impossible two holes ago and
   nobody noticed. Amber the moment the two cross.
3. **Per nine is two windows.** The front does not carry to the back. A tracker that only
   totals eighteen says a golfer is fine until the 18th green.
4. **Never block the tap.** The team may knowingly take the shortfall.
5. **The card warns every hole, in a sentence** — *Taking Gunst's or Detomasi's drive here
   leaves the front nine short.* The consequence, on the tee.
6. **Falling short costs nothing by default.** `warn` is the default; `two_strokes` per
   missing drive is opt-in, applied to the team's gross **at the end of the round**.
   Silently disqualifying a team over a drive count would be the worst outcome the app
   could produce.
7. **Alternating pairs are the team's, set on the 1st tee** — a card before the first score
   asking for the split, then **fixed for eighteen holes** (`drive_pairs`, immutable once
   written). Not derived from handicap: four golfers decide in ten seconds and would override a
   computed pairing anyway. A rota that can be re-cut mid-round is not a rota.
8. **Three golfers run AB → BC → AC, repeating.** Two drivers every hole; each golfer sits out
   every third and plays the phantom's ball (1st and 4th shots).
9. **A short team owes four golfers' worth**, not three — it fields a phantom, and the
   phantom's share rotates through the three real golfers.
10. **The penalty does not apply to a schedule.** There is nothing to fall short of.

---

## 6. Handicap and allowance (step 5)

**The allowance is a table, not a preference.** The screen states what the format uses,
shows it applied to the TD's own teams, and offers one flat override. Presenting a table as
an open question invites a guess.

- **Scramble: 25 / 20 / 15 / 10** of course handicap, **lowest first**, summed → one team
  figure.
- **Shamble: one percentage of each golfer's own** course handicap, tracking the ball-count
  average — **85% at two balls, 75% at one, 95% at three**. A per-hole grid averaging 2.3
  gets 95% suggested.
- **Override:** one flat percentage applied to all four, with the worked result still shown.

Three rules:

1. **Round once, on the total.** Rounding each contribution first turns
   `1.00 + 1.60 + 1.65 + 1.90` into 7; rounding the sum gives **6**. Compute at full
   precision, round at the end, show the raw total underneath.
2. **Half rounds up.** 7.50 → 8.
3. **Whole strokes, never fractions.** 6.15 on a card looks like a spreadsheet error at the
   scoring table. **Which makes ties normal** — see §9.

**Course handicap, not index.** The allowance applies to `FoursomeMembership.course_handicap`
(after the tee adjustment), and the screen **names the tee** it computed from so nobody
applies 25% to the wrong number.

**Members sort low to high, always.** The percentage is positional, so a manual order would
be a lie.

**Where it lives:** `services/team_handicap.py`. Do not extend `services/scramble.py` (§11).

---

## 7. The phantom 4th

A team of three fields a **phantom 4th**: a fourth slot handicapped at the **average of the
three real golfers**, whose ball is played by whoever is not driving.

Bellini 9, Kwan 15, Ortega 23 → phantom **16** → the team plays off **10**.

- **Nobody is ever borrowed.** A golfer from another team would be hitting shots for a
  rival, and every good one costs their own team the pot. The option does not exist.
- **Fewer balls must never mean fewer strokes.** Dropping the table's bottom row (25/20/15
  on three) gives 9; a 30/20/10 table gives 8. Both take a stroke *away* from a team already
  short a ball. The rule that avoids it: **the allowance follows the roster, not the number
  of balls hit.** "Play short" therefore carries the **same 10** — the only thing it changes
  is whether anyone hits the phantom's ball.
- **The phantom is a row, everywhere** — italic and undraggable on the team card, named on
  the leaderboard row (`Bellini · Kwan · Ortega · phantom 4th`), listed unpaid in settlement.
  Hiding it makes all three look like special cases.
- **It cannot be paid.** A team of three divides its share three ways and takes more each.

**Build note.** `Player.is_phantom`, `Foursome.has_phantom` and the pluggable framework in
`scoring/phantom.py` already exist. The existing algorithms *derive* a phantom's gross from
the real players' scores; **the Team Play phantom does not need that** — in a shamble its
ball is physically played and entered like any other, and in a scramble there is one team
score. What is needed from the framework is `compute_playing_handicap` = average of the
three real golfers. Register a `team_play_average` algorithm rather than bending
`rotating_player_scores`, whose score derivation must not fire here.

---

## 8. Build teams (step 6)

**The TD assigns manually.** No draft, no auto-balance, no random draw — they already knows
who wants to play with whom.

- **Allowance appears per team the moment a fourth golfer lands**, with the raw sum under the
  rounded figure, and a **balance strip** across the header showing the spread (`6 – 10`).
  Manual does not mean blind: a hand-built scramble is unbalanced by accident and normally
  discovered on the leaderboard.
- **Each member row carries their contribution** — `Maiolini 4 → 1.00`, with their percentage
  badge. Showing only the team total hides why moving one golfer swings a team by two strokes.
- **Members sort low to high automatically.**
- **Unassigned tray at the bottom, always visible, with a count.**
- **Empty seats are named** — `2 seats open` — not an invisible gap.
- **Team names**: colour default (Pine, Clay, Slate, Dune, Fern, Rust), free text over it,
  **16 chars**. Colour is assigned regardless — it does real work on the board and the card.
- **The team of three carries the phantom row**, italic and undraggable, sorted into the
  order and taking its percentage like anyone else, with a `Playing three — drop a golfer
  here to replace the phantom` affordance.
- **Next waits on an empty tray** — not on balance, not on six full teams. Balance is
  advice; a golfer with no team is a broken tournament. The button says which it is waiting
  on.

---

## 9. Entry and payout (step 7)

Fee, places and split are all TD-settable on **one screen**, **after teams** — it needs the
field size for the pot and the team count to cap the places.

- **Every control shows dollars as it moves, including a per-golfer figure.** A TD setting
  50/30/20 is choosing what third place gets; the percentage is the mechanism.
- **Fee steps in $5.** Nobody charges $23.
- **Places 1–4, capped at the team count.** Half the field cashing is **advice on the
  screen, not a rule** — winner-takes-all is a legitimate preset. Presets first
  (winner-takes-all, 60/40, 50/30/20), custom underneath.
- **The split must total 100**, checked live, amber off 100, **Save blocked with the reason
  on the button** and the shortfall named in dollars (`5% unassigned — $46.00`).
- **A place paying less than entry is allowed and flagged** (`$23 vs $40`). Nothing here is
  disqualified by cashing, unlike the Individual day bet, so it is worth knowing rather than
  blocking.
- **Ties are warned about here**, where it is cheap: *three places is three prizes, not
  three teams paid.*
- **Per-golfer figures assume four**, with a line saying the team of three divides three ways
  and pays more each.

---

## 10. Play and money

### 10.1 Score entry (`09-score-entry`)

**Scramble — a stepper, one huge number.** Four boxes with three ignored is the easiest way
to get a scramble card wrong, and it is tapped by a golfer on the next tee holding a beer.

- **Opens on par.** A scramble team makes par more than anything else, and a wrong default
  beats no default when the alternative is a keypad.
- The value shows what it **is** — birdie, par, bogey — not just the digit.
- The **18-hole strip** sits across the bottom, filled holes solid.

**Shamble — four scores, counting ones tinted live**, the rest greyed, as they are entered.
Two men's cards do nothing on a given hole; a golfer who shot 5 must see instantly that it was
not used, or the total looks wrong and someone re-enters it. **The count is stated in the
header on every hole** — `2 of 4 count` — even though it does not change; one line settles
the recurring question at the green. Under an escalating count it changes at 7 and again at
13, which is exactly why it is stated.

**The drive row is on both cards** (below the one number, above the four scores). Whose
drive did you take, anyone short marked, the arithmetic live, the consequence in a sentence.
It **never blocks the tap**.

**Auto-advance waits for both** the score and the drive — the hole is not complete until the
drive is picked, and the button names what is outstanding (`Pick whose drive to continue`).

**Net is not shown on the card.** A whole-number team figure applied to the round is not a
stroke on a hole; showing 6 invites subtracting it per hole. Gross on the card, net on the
leaderboard, and the header names the allowance so it is not hidden.

**Anyone on the team can enter.** No designated scorer — six teams entering their own hole
keeps the board live; one scorer means the board is dark until 18.

### 10.2 Drive tracker

Off the card: per-window pips for each golfer (`✓ h2` / `owes 1`), both nines shown
independently, and the pair rota when the rule is alternating (`HOLE 8 — Maiolini & Yau
UP`). For a team of three the rota also names who covers the phantom
(`Ortega → phantom`). Warns; never blocks.

### 10.3 Leaderboard (`10-leaderboard`)

**The standard card** — rank / team / gross / net, the hole-grid strip under an expanded
row, circled birdies and boxed bogeys. A team is just what sits in the name column. A golfer
who reads three leaderboards a month should not have to learn a fourth layout.

- **Sorted on net, ascending. One column, no segmented control.**
- **Ties marked `T`, drawn adjacent, never silently ordered.**
- **The phantom is named on the row.**
- **Teams still out are marked, not sorted away** — amber dot and `thru 14`. A team leading
  through fourteen is not leading.
- **Colour identifies.** Six unfamiliar one-syllable names; the colour block matches the
  card the team is holding.
- **The pool sits under the board, not on it** — one card, `$575, three places, projected
  until every team is in`, muted italic until then. Money on the rows would put a dollar
  figure next to a team with four holes left.
- **No tabs.** With no side games there is nothing to tab between; the bar does not sit
  there empty waiting to be useful.

### 10.4 Settlement (`11-settlement`)

One pot against twenty-three golfers. **No tabs, no per-game sections, no cross-game balance
check** — one number in, three payments out. The entry side is one line: everyone paid the
same and nothing was optional.

- **Prizes are earned by teams and settled to people.** Every paid place expands to its
  members with each golfer's figure. `Fern — $287.50` is unactionable at the scoring table.
- **Ties combine the places they occupy and split what those places pay.** No countback, no
  card-off. **Draw each tie as one block with both teams inside it** — two rows each reading
  $143.75 hides that it was one prize. The drawn case has two ties behaving differently:
  Slate and Dune tied for 2nd combine 2nd *and* 3rd into $287.50 split two ways; Pine and
  Clay tied for 4th combine two places that pay nothing, so the tie costs nothing and is
  left unresolved.
- **Odd cents to the team's highest course handicap.** $287.50 over four is $71.875; split
  to the cent and the remainder is assigned, not lost, so the pool balances to zero. Stated
  on the screen under the split (`· +2¢`), not left as an unexplained $71.89 beside three
  $71.87s.
- **A team of three splits three ways and takes more each** — $47.91 against Slate's $35.93
  for the identical placing — with `3 ways` on the row so nobody has to work out why. The
  phantom earned the strokes and cannot be paid. Same rule as the Irish Rumble levelled
  group.
- **A drive shortfall is recorded on the team row** (`1 drive short`). It changes the money
  only under the stroke penalty, and then it already changed the gross upstream.
- **Settle is gated on every team signed for 18.** Money does not move while a score can.
  Until then every figure is muted italic and the button says what it is waiting on.
- **The receipt and the texting flow are the Individual ones, reused unchanged.** A team
  receipt is a short one: one entry line, one prize line if they cashed.

**Reuse:** `services/payout.py` already implements the two hard rules — `split_tied_places`
pools the places a tie occupies, and `per_person_share` divides a group prize among its
**real** golfers only, which is the phantom rule. **Gap to build:** both `round(x, 2)`, so
neither assigns odd cents deterministically. Add `split_to_cents(total, recipients_ordered)`
returning exact cents with the remainder to the first recipient, and order by course
handicap descending. (The same rounding gap exists in individual play today — out of scope
here, worth a follow-up.)

---

## 11. What must not be touched

**The casual `scramble` game is a different game.** `GameType.SCRAMBLE`,
`ScrambleHoleScore`, `ScrambleResult`, `Round.scramble_config` and `services/scramble.py`
implement a team handicap of **average × 20%** and a `min_drives_per_player` count. Team
Play uses the **25/20/15/10 table** and the four drive rules in §5. Do not "unify" them and
do not change the casual maths — a casual scramble that starts producing different strokes
is a regression a user will read as a bug. New code lives in `services/team_play.py` and
`services/team_handicap.py`.

**Cup and individual play are untouched** beyond the `is_individual_play` narrowing in §2.4
and the additive `TeamHoleScore.team` nullability in §2.3.

---

## 12. Deferred

- **Flights.** Deferred with the Individual flow. Six teams is under the size where
  flighting means anything.
- **Multi-round team events.** Answered by "run two tournaments." Revisit only if clubs ask.
- **Extra formats.** Irish Rumble, modified counts, best-ball variants — all a shamble with
  the count moved.

---

## 13. Packet inconsistencies noted at build time

Two stale strings in the design files, flagged rather than acted on:

- `12-flow-map.html`'s `@dsCard` subtitle says **six** setup steps; the document body and
  every step chip say **eight**.
- `09-score-entry.html`'s `@dsCard` subtitle mentions **Irish Rumble**, which
  `13-decisions-log.html` records as removed as a team format.
