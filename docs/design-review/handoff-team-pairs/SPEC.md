# Spec: Pairs Play — two-golfer teams, one round, one leaderboard

> **Read `../handoff-team-play/SPEC.md` first.** Everything it decides still
> holds. This file covers only what pairs change, and the places the shipped
> Foursome Play code has to be generalised to carry them.

Build-from document for the `handoff-team-pairs` packet. The HTML files are
design reference (Flutter is the target; `lib/theme/halved_brand.dart` holds the
live palette). `05-decisions-log.html` carries the eighty calls; `04-flow-map.html`
carries the argument. This file restates the pairs section as rules, state and
edge cases, plus the calls made at build time against the code that shipped for
fours.

**The governing rule is unchanged.** This is the simplest of the three
tournament shapes. Most of the packet is a decision *not* to build something,
and pairs adds no dimension to the flow — it adds three formats and one number.

---

## 0. The structural call, and where it lands in this codebase

The packet says pairs are **a team-size control on step 1, not a fourth
tournament shape** — a separate "Two-Man Tournament" entry would duplicate seven
screens to change two.

**The requirement is met exactly; the control is not drawn where the packet
draws it.** Pairs run the *same* `_stepFlow`, the same `TeamPlayConfig` row, the
same handicap/drive/payout steps, the same card component, board, settlement and
receipt. Nothing is duplicated. What differs is the entry point:

| | Packet | Built |
|---|---|---|
| Step 1 | One `Team Play` card + a `Fours / Pairs` segmented control | Two cards: `Foursome Play` and `Pairs Play` |

Two reasons, both about the name the product already shipped:

1. **The shape is called Foursome Play**, not Team Play (`handoff-team-play/SPEC.md`
   header — `GameType.FOURSOMES` and the `Foursome` model both had the other
   name first). "Foursome Play — team size: pairs" is a contradiction on screen.
2. **The picker already draws the card.** `_EventType.pair` exists in
   `new_round_wizard.dart` with the body *"Pairs against the field. Chapman,
   alternate shot, best ball."*, disabled pending a two-golfer scoring engine.
   This is that engine. Enabling the card costs nothing; it routes into
   `_isTeamPlay` with `team_size = 2` and every step after it is the same widget.

The packet's actual argument — *do not duplicate seven screens* — is honoured.
One extra radio card on a screen the TD sees once is not a duplicated screen.
Flagged in AS-BUILT for a ruling.

---

## 1. What changes, and what does not

Two steps behave differently. **Nothing else in the flow knows the team size.**

| Step | Fours | Pairs |
|---|---|---|
| 1 Type & format | `Foursome Play` | `Pairs Play` |
| 2 Players | same | same |
| 3 Groups & tees | groups of 4 (the group IS the team) | **groups of 2** |
| 4 How the team scores | scramble \| shamble | **scramble \| best ball \| alternate shot \| Scotch \| Chapman** |
| 5 Drives | 4 rules | **decided by the format** (§5) |
| 6 Handicap & allowance | 25/20/15/10 or a shamble % | **a different table per format** (§4) |
| 7 Entry & payout | same | same |
| 8 Review | same | same |

Unchanged and not re-litigated: one round, no side games, one pool, whole-stroke
handicaps rounded once on the total, ties combined and split with no countback,
the TD sets fee and places, odd cents to the team's highest course handicap,
the score picker, the leaderboard card, settlement and the receipt.

---

## 2. Data model

### 2.1 `TeamPlayConfig.team_size`

```
team_size = PositiveSmallIntegerField(default=4)   # 4 | 2
```

Default 4, so every existing row and every existing test reads unchanged. It is
the only new column on the config.

### 2.2 Five more formats on one field

`team_format` grows from two choices to six. The team size decides which are
legal, and the setup endpoint refuses an illegal pair:

| format | sizes | card | allowance |
|---|---|---|---|
| `scramble` | 4, 2 | one ball | 25/20/15/10 (fours) · **35/15** (pairs) |
| `shamble` | 4 | own ball, best N | % of each own |
| `best_ball` | 2 | own ball, **best 1 of 2** | **85% of each own** |
| `alternate_shot` | 2 | one ball | **50% of combined** |
| `scotch` | 2 | one ball | **60/40** |
| `chapman` | 2 | one ball | **60/40** |

**`scramble` is shared and its allowance is not.** The table is keyed on
`(team_size, format)`, never on format alone.

### 2.3 The card shape is a property, not a format check

The shipped scoring branches on `config.is_scramble` in eleven places. Four of
the five pair formats end in one ball and want that branch; best ball wants the
other. Two new properties carry it, and every scoring branch moves to them:

```python
@property
def plays_one_ball(self):     # scramble, alternate_shot, scotch, chapman
@property
def plays_own_ball(self):     # shamble, best_ball
```

`is_scramble` / `is_shamble` stay for the wizard strings that genuinely mean
those two formats.

**Best ball is a shamble whose count is 1.** `resolved_counts` returns
`{hole: 1}` for all eighteen and every downstream consumer — `shamble_hole`,
`team_round`, `golfers_by_hole`, the par-times-count arithmetic — works
untouched. Best-1 on a par 4 is a par of 4, which is right.

### 2.4 No phantom, ever

`ensure_phantom_fourth` returns `None` and deletes a stale row whenever
`team_size == 2`. In fours the phantom is a handicap device for a team that
still hits four balls; in pairs it would be an imaginary partner taking half the
shots in an alternate shot.

### 2.5 The rota reuses `drive_pairs`

An alternate-shot tee rota is odd/even for two golfers. Stored in the existing
`TeamPlayTeamState.drive_pairs` as **two singleton entries** —
`[[odd_player_id], [even_player_id]]`. `pair_on_hole` then returns the golfer who
tees on that hole with no change, `TeamPlayPairsView` already refuses a second
POST (which is the "fixed for eighteen" rule), and `drive_state` already emits
per-hole names.

---

## 3. Building the pairs (step 3, Groups & Tees)

The four-golfer build screen was not built as drawn (`handoff-team-play/SPEC.md`
§3) because **Groups & Tees already assigns and the group IS the team**. That
holds for pairs, with three changes.

1. **Group sizes default to twos.** `groupSizes(n)` fills foursomes; a pairs
   field wants `[2, 2, 2, …]` and a trailing `[1]` when the field is odd. New
   `pairSizes(n)` in `utils/grouping.dart`; the size override clamps to
   `{2}` — or `{2, 3}` in best ball, see below.
2. **The balance strip and the per-golfer contribution** live on the handicap step,
   as they do for fours. The argument is *stronger* here and the screen is the
   same: four handicaps average out, two do not — a scramble pair of 3 and 22
   plays off 4 and a pair of 9 and 23 plays off 7, three strokes apart on a card
   the field finishes inside six.
3. **The odd field is blocked, and the block names the golfer.**

### 3.1 The odd-field block

`team_play_summary` gains a `field.blocking` list. Two kinds:

```
{'kind': 'unpaired',   'golfer': {...}, 'foursome_id': n}   a group of one
{'kind': 'three_ball', 'team': '…',     'foursome_id': n}   a group of three,
                                                            outside best ball
```

The handicap step draws it and **Next waits on it** — the same gate the fours
flow puts on an empty tray, for the same reason: balance is advice, a golfer
with no partner is a broken tournament. The button names the golfer
(*"Dave Kwan has no partner"*), not a count, because the fix is about one golfer
and the TD needs to know which one is standing there.

**Three ways out, offered on the block** — nothing is disabled without saying
why: add a golfer, take them out, or **let one team play three**. The third is
**best-ball only and hidden otherwise**. A third ball is another option to
count; alternate shot and Chapman cannot honour it at all and in a scramble it
is a straight advantage. Offering a choice four of the five formats reject is
worse than not offering it.

### 3.2 Names

**A pair defaults to the two surnames** — `Maiolini & Yau`. Colour names are
right for fours, where four surnames fit nowhere; two fit on a leaderboard row
and golfers say a pair that way out loud.

*Divergence from the fours build, deliberately.* Foursome Play ships
`Group 1 … Group N` because a colour the TD never chose is one more thing on
screen — but *a pair's own two surnames are not an invented name*, they are the
only thing anybody calls it. So pairs get `Maiolini & Yau` from the roster,
16 characters, free text over it, colour still assigned for the card. A pair
whose surnames overflow 16 characters falls back to `Group N`.

---

## 4. The allowance is doing enormous work (step 6)

**This is the finding to act on.** The same pair — Maiolini 4, Yau 19 — plays
off 4 in a scramble and 12 in alternate shot. Three times the strokes for the
same two golfers, purely from the format.

| Format | Rule | Maiolini 4 · Yau 19 | Card |
|---|---|---|---|
| Scramble | 35% low + 15% high | `1.40 + 2.85 = 4.25` → **4** | one number |
| Best ball | 85% of each, own ball | `3.40 → 3` · `16.15 → 16` | **two scores** |
| Alternate shot | 50% of combined | `23 × 0.50 = 11.50` → **12** | one number |
| Scotch | 60% low + 40% high | `2.40 + 7.60 = 10.00` → **10** | one number |
| Chapman | 60% low + 40% high | **10** | one number |

All four one-ball tables are **positional percentages, lowest first, summed,
rounded once**, which is exactly what `scramble_allowance` already does. It
generalises to `positional_allowance(handicaps, table, …)`; the fours table
becomes one caller.

**50% of combined ≡ 50% low + 50% high**, so alternate shot is the table
`(50, 50)` and the screen still reads it back the packet's way — `4`, `19`,
`23 COMBINED`, `50% ALLOWANCE`, `12 PAIR`.

**Best ball is not a team figure.** Each golfer plays their own strokes at 85% and
the better net counts. It is the only pairs format whose allowance is per
golfer and the only one entering two scores. The summed figure exists solely as
a balance number for the strip, exactly as the shamble's does.

**Scotch and Chapman share a table, and that is the honest answer.** Both are
two drives then one ball; Chapman buys one extra shot of position, which is not
worth a stroke. Stated plainly rather than manufacturing a difference.

**The figure shows on every option before it is chosen.** The format step
computes all five for the TD's *own* first pair and prints them on the radio
rows — a TD picking Chapman because it sounds fun should see that it more than
doubles their field's strokes against a scramble. Picking alternate shot raises a
note saying so.

Unchanged: whole strokes, half up, rounded **once on the total**, computed off
**course** handicap with the tee named. Members sort low to high, always — the
percentage is positional, so a manual order would be a lie. The flat override
still applies to both golfers.

---

## 5. The tee-shot control does three different jobs (step 5)

Every format that chooses a tee shot has the same control on the card. **What it
does differs, and that is the part to get right in code.**

| Format | The control | Drive rules offered | Default |
|---|---|---|---|
| Scramble | **A record** — compliance against a quota | none · per nine · per eighteen | `none` |
| Scotch | **An instruction** — it says who hits next | none · per nine · per eighteen | `none`, tap still required |
| Alternate shot | **A rota** — odd/even, set on the 1st tee | `alternating` only | forced |
| Best ball, Chapman | **Absent** — both golfers drive every hole | `none` only | forced |

1. **`alternating` means something different at each size.** In fours it is the
   driving *pairs*; in pairs it is the odd/even *tee order*. Same field, same
   immutability, same one-line-on-the-tee UI.
2. **A pairs quota is two golfers' worth, not four.** `BALLS_PER_HOLE` is replaced
   by `config.team_size` throughout `services/team_play.py`: `required =
   team_size × drives_required`. One each per nine is `2 of 9`, seven free —
   *"two golfers and eighteen holes is a lot of slack"*, which is why one each per
   nine is the usual rule and the default when a quota is chosen.
3. **The floating share is zero in pairs.** It exists to cover a phantom, and
   there is no phantom. A three-golfer best-ball pair owes three golfers' worth.
4. **Scotch requires the tap on every hole even with no quota**, because the tap
   is the instruction. The card's completion gate reads *"Pick whose drive to
   continue"* for Scotch regardless of `drive_rule`.
5. **Alternate shot has no quota, no warning and no penalty setting.** There is
   nothing to fall short of. The penalty control is hidden, not disabled-with-a-
   reason, because the concept does not apply.
6. Everything else is the fours rule: warn when `owed > holes left in the
   window`, never block the tap, no penalty by default.

### 5.1 The two sentences the card has to say

Both come from the server on the card payload so the client never re-derives
them.

* **Scotch, after the drive is picked** —
  `Maiolini plays the second shot, then alternate.`
  (The partner whose drive was *not* taken plays the second shot.)
* **Alternate shot, on every tee** —
  `Maiolini tees.`
  **Named on every hole, without exception.** A pair that loses track plays a
  hole out of order and the round is gone.

### 5.2 Setting the rota

The rota card is the fours mechanic with two names instead of four: *who tees on
the odd holes*, asked once before the first score, then fixed. `TeamPlayPairsView`
already refuses the second POST with the right sentence.

**This closes the fours gap too.** `handoff-team-play/AS-BUILT.md` lists "no
on-course card for setting the alternating pairs" as still open — the endpoint
was built and nothing called it. The card built here calls it for both sizes.

---

## 6. Play and money

### 6.1 The card

**One-ball formats** — the shipped scramble card, unchanged: one `TEAM` row, the
picker always open, opening on par. The header names the format and the
allowance (`Scotch · 10`).

**Best ball** — the shipped shamble card with **two rows instead of four** and
`1 of 2 counts` in the header. The counting score tints and the other greys as
they land, for the same reason: a golfer who shot 5 must see instantly that it was
not used.

**The drive control** sits above the rows on scramble and Scotch, and is absent
on best ball and Chapman. On alternate shot it is replaced by the rota line.

Net is not printed as a round figure on a hole; the stroke dots and the
`gets N` chip stay as shipped (the deliberate departure the fours as-built
already flagged for a ruling).

### 6.2 Board, pool, settlement

**Unchanged.** A pair is what sits in the name column. The only generalisations
needed are the ones that were hardcoded to four:

* `seats_open = max(0, team_size − real − phantom)`
* `team_handicap` is published once the team is full at **`team_size`**, not 4
* a prize divides **two ways**, which `split_to_cents` already does generically

### 6.3 Watch / share surfaces

No change. Team rows are already name-and-figure.

---

## 7. What must not be touched

Everything `handoff-team-play/SPEC.md` §11 protects, plus:

* **`GameType.FOURSOMES` is not this.** It is the Cup's alternate-shot segment
  (2v2, one ball a pair) and keeps its own scoring. Pairs Play's
  `alternate_shot` is a tournament format on the team layer. Same golf, two
  places, and the Cup one is not moved.
* **The casual `scramble` game** keeps `average × 20%` and its own drive count.
* **Existing Foursome Play rows** must read identically: `team_size` defaults to
  4 and every fours code path is reached through the same values it is reached
  through today. The fours test suites are the regression gate.

---

## 8. Deferred

Nothing new. Flights stay deferred; multi-round team events are still answered
by "run two tournaments"; extra formats are still a count moved.
