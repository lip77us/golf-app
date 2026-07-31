# Extra Rabbit — spec

Status: **proposed** (not yet built). Kickoff brief for the "extra rabbit"
option on the Rabbit game. Deliberately modelled on how **Sixes** handles
early close-outs and extra matches (`services/sixes.py`), **minus the teams** —
Rabbit is an individual game, so an extra rabbit simply starts *loose* and all
three players race for it, with no team-assignment step.

Related: `services/rabbit.py`, `games/models.py` (`RabbitGame`,
`RabbitHoleResult`), the Design cards `screens/rabbit-setup.html`,
`screens/rabbit-play.html`, `patterns/leaderboard-rabbit.html`.

---

## 1. Why

Today a Rabbit segment can be **mathematically decided before it ends** — in
accumulate mode, once the holder's lead is larger than the holes left in the
segment, nobody can catch them, so the remaining holes are "played for nothing."
Extra Rabbit turns those dead holes into a fresh contest: they start a **new
rabbit** (loose), exactly like the start of a segment. This mirrors Sixes, where
an early close-out immediately starts the next match and any leftover holes form
an extra match.

Opt-in per game via a **RabbitGame.extra_rabbits** toggle (recommended default
**off** — it's an add-on; the setup card surfaces it under "Extra rabbit").

> **Scope — accumulate only.** Extra rabbits exist *only* for accumulate legs.
> With "stop after one" there is no lead to run ahead of the field, so a segment
> is never mathematically decided before its last hole — there are **no leftover
> holes and never an extra rabbit**. The setup card should hide/disable the Extra
> Rabbit toggle when the mode is stop-after-one.

---

## 2. How Sixes does it (the template)

From `services/sixes.py`:

- Three standard 6-hole matches: 1–6, 7–12, 13–18 **if none ends early**.
- **Close-out:** a match ends the moment a team "leads by more holes than
  remain" — `abs(lead) > points_per_hole × holes_left_after_this_hole`
  (Classic: `points_per_hole = 1`, so `lead > holes_left`).
- On an early finish the **next match starts on the very next hole** (the
  schedule shifts earlier); each standard match still runs its full 6 holes.
- **Leftover holes after all three standard matches collect into one "extra"
  match** at the end; if that extra also closes out early, its leftover forms a
  second — **at most two extras → up to five matches total**.
- Sixes assigns the extra match's **teams** by "loser's choice" via a separate
  `/sixes/extra-teams/` step. **← the only part Rabbit drops.**

---

## 3. Rabbit rules (the analog)

### 3.1 Close-out (segment lock)
A segment is **locked** — its winner can no longer change — when, after a scored
hole, the accumulate holder's lead exceeds the holes remaining in that segment:

```
locked  ⇔  accumulate AND holder is not None AND lead > holes_left_in_segment
```

where `holes_left_in_segment` counts the still-unplayed holes of the segment
*after* the current hole (play-order aware, like Sixes). Exact analog of Sixes'
`lead > 1 × holes_left`.

- **Stop-after-one mode (`accumulate = False`):** lead is capped at 1, so
  `lead > holes_left` only when `holes_left == 0` — i.e. it never locks early.
  Extra rabbits therefore only arise in **accumulate** mode. (Consistent, no
  special-casing.)
- **Loose segment:** if the rabbit is loose (no holder), it is never locked — a
  late hole could still be grabbed. A segment that stays loose to its end is a
  **push** (unchanged), and produces **no** extra (there were no dead holes —
  every hole was live for a grab).

### 3.2 Scheduling (mirror Sixes)
Replace the fixed `segment_hole_lists` split with a dynamic scheduler in
`calculate_rabbit`:

1. Walk the group's play order. Run standard segment 1 from the first hole; when
   it **locks** (or reaches its natural length), record the segment winner and
   **start the next standard segment on the very next hole**.
2. Repeat for all `num_segments` standard segments.
3. Any holes remaining after the last standard segment form **extra rabbit #1**
   (loose start). If it locks early, its leftover forms **extra rabbit #2**.
   Stop after two extras (cap), matching Sixes' five-match ceiling.

A segment/extra that runs to the end of the round without locking simply settles
on its last scored hole (today's behaviour).

> Note on `num_segments`: with 1 segment (one 18-hole rabbit) a single early lock
> still spawns extra(s); with 3 segments the leftovers from all three collect
> into one extra then possibly a second — always **≤ 2 extras**. Max matches =
> `num_segments + 2` (5 at the default 3).

### 3.3 No teams (the difference)
An extra rabbit **starts loose**; the first player to win a hole outright grabs
it, exactly like a segment start. **No team/partner assignment, no extra-teams
endpoint, no "loser's choice" step.** This is the whole simplification vs Sixes.

---

## 4. Settlement

Per-segment stake stays **Sixes-style**: each match (standard *or* extra) is its
own bet worth `Round.bet_unit`, paid by the two non-holders to the holder
(zero-sum). One addition:

- **A rabbit that runs exactly one hole is worth half the stake** (`bet_unit / 2`
  — $2.50 at a $5 match). Two holes or more pays full. This only affects the
  1-hole extra case (a leftover of a single hole).
- **Single-hole extra, halved hole → push** (no outright winner on the one hole
  ⇒ loose ⇒ nobody holds ⇒ no money), same push rule as any segment.
- Zero-sum invariant holds: holder collects `value` from each of the two
  opponents (`+2·value` net), each opponent pays `value`. `value` ∈
  {`bet_unit`, `bet_unit/2`}.

**Max liability** = `num_segments + 2` matches, each up to a full `bet_unit`
(a single-hole extra is less), so **≤ (num_segments + 2) × bet_unit** — "up to
$25 at $5 a match" for the default three segments. Surface as the existing
`MaxLiabilityNote`.

---

## 5. Data model

- `RabbitGame.extra_rabbits = BooleanField(default=False)` — the toggle.
- Mark extra segments. Two options:
  - **(preferred, no new table)** derive `is_extra` from the computed segment
    index (`> num_segments`) and store the 1-based `segment` on
    `RabbitHoleResult` as today; add nothing to the model beyond the toggle.
    `calculate_rabbit` assigns extra holes segment indices `num_segments+1`,
    `num_segments+2`.
  - (heavier) introduce a `RabbitSegment` table mirroring `SixesSegment`
    (index, start/end, is_extra, holder, value). Only worth it if we later need
    to persist segment metadata independently. **Recommend deriving.**
- Migration: one field add (`games/00xx`). No enum/choices change.

---

## 6. Service changes (`services/rabbit.py`)

- `setup_rabbit(..., extra_rabbits=False)` persists the toggle.
- `calculate_rabbit`: replace the static `segment_hole_lists` loop with the
  dynamic scheduler (§3.2). When `extra_rabbits` is **off**, behaviour is
  identical to today (fixed segment ranges, no early re-slotting) — the lock/
  extra logic is gated on the toggle so existing games are untouched.
- `rabbit_summary`:
  - `segments[]` entries gain `is_extra: bool`, `holes: int` (length), and
    `value: float` (the per-segment stake: `bet_unit`, halved for a 1-hole
    extra). Keep `start_hole`/`end_hole`/`holder_short`/`complete`/`payout`.
  - `current` / banner: expose the active match ordinal and its range so the
    play screen can render **"Rabbit N of M · holes a–b"** (M = standard + live
    extras).
  - top-level `extra_rabbits: bool`; `money.max_liability`.
- Handicap allocation (already shipped) composes cleanly: the per-segment SO
  spread keys off the **standard** segment ranges; extras inherit the round-wide
  remainder (decision: allocate extra-hole strokes by round-wide SI — simplest,
  and an extra is at most a few holes).

---

## 7. Mobile

- **Setup** (`rabbit_setup_screen.dart`): an "Extra rabbit" `SwitchListTile`
  card with the rule blurb ("A leftover hole from an early-decided leg starts
  another rabbit; a single-hole rabbit pays half"), sent as `extra_rabbits` via
  `postRabbitSetup`; `RabbitSummary.extraRabbits`. Update `MaxLiabilityNote`.
  **Only shown in accumulate mode** — hidden/disabled (and forced off) under
  "stop after one", per the scope constraint above.
- **Play** (`rabbit_screen.dart`): banner reads "Rabbit N of M · holes a–b";
  the segment strip lists extras with a **½** marker on a single-hole extra
  (Design card `screens/rabbit-play.html` already shows `Hole 6 · extra →
  Rabbit: Dave (½) $3.00`).
- **Leaderboard** (`_RabbitGroupCard`): the segment breakdown + by-hole strip
  already iterate `segments[]`/`holes[]`; they pick up extras for free once the
  summary emits them (label extra rows, show ½ value).

---

## 8. Tests (`scoring/tests/test_rabbit.py`)

- Accumulate lock: lead > holes-left ends the segment early; the next segment
  starts on the next hole (boundary shift), leftover forms an extra.
- Two-extra cap: contrived early locks produce at most 2 extras (5 matches).
- Single-hole extra pays **half**; a halved single-hole extra pushes.
- Stop-mode never locks early (no extras).
- Loose segment → push, no extra.
- Zero-sum across all matches incl. extras; `max_liability` value.
- Toggle **off** ⇒ byte-for-byte the current segment behaviour (regression
  guard).
- Partial/back-9 + shotgun play-order still slot extras correctly.

---

## 9. Open decisions

1. **Default for `extra_rabbits`** — recommend **off** (opt-in add-on). The
   Design mock renders the switch on; confirm the product default.
2. **Extra-hole SO allocation** — round-wide remainder (recommended, simplest)
   vs. its own mini per-segment spread. Round-wide is fine for 1–few holes.
3. **"Deciding hole after the last match"** (Design copy) — interpreted here as
   the leftover→extra mechanic (Sixes has no separate tiebreak hole). If a true
   *tie-breaker* (equal segments won ⇒ sudden-death hole) is wanted, that's a
   different feature; flag it if so.
4. **Mid-round withdrawal** — an extra rabbit inherits the same
   universal-unblocker handling as segments; confirm no special settlement.
