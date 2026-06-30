# Irish Rumble — scoring logic

Reference for how Irish Rumble is scored, with particular attention to **mixed
group sizes** (threesomes competing against foursomes). Implementation lives in
[`services/irish_rumble.py`](../services/irish_rumble.py); this doc is the
human-readable companion to the docstring there.

## Overview

- A **tournament-round, cross-group team game**: *every* group in the round
  competes against every other group as a team (not just within a foursome).
- The round is split into **segments**; each segment counts the **best N
  (lowest) net scores per hole** for a group, summed across the segment's holes.
- **Lowest summed score wins** each segment; the **overall winner** is the group
  with the lowest cumulative score across all segments.
- Pool-based payout (entry fee × players), settled by overall rank — see the
  unified payout construct (`PayoutConfigField`).

## Segments (configurable per round)

`IrishRumbleConfig.segments` is fully editable; the default ramp is:

| Holes | Balls counted (N) |
|-------|-------------------|
| 1–6   | best **1** |
| 7–12  | best **2** |
| 13–17 | best **3** |
| 18    | best **4** (all) |

Per hole, the group's adjusted scores are sorted ascending and the **N lowest
are summed**; the segment total is the sum of those per-hole amounts.

## Scoring (per-hole adjusted score)

Set by `IrishRumbleConfig.handicap_mode` / `net_percent`:

- **net** — `gross − strokes`, strokes = `playing_handicap × net_percent/100`
  allocated by hole stroke index.
- **gross** — raw gross.
- **strokes_off** — `gross − max(0, own_handicap − low_handicap)`, allocated by
  stroke index. The reference low is the **lowest playing handicap across ALL
  groups in the round**, not just within a group.

**Net double-bogey cap** (`Round.net_max_double_bogey`, opt-in per round): each
adjusted per-hole score is capped at `par + 2`. Off → raw adjusted scores feed
the segment math.

Reported on the leaderboard as **net-to-par** (counting scores − hole pars).

## Mixed group sizes (threesome vs foursome)

The only place group size enters the math:

```python
balls = min(configured_balls_to_count, group_size)   # irish_rumble.py:382
```

`group_size` counts real players **plus a phantom if the group has one**
([irish_rumble.py:363](../services/irish_rumble.py)).

### Phantoms fill a short group to a full foursome

Phantom scores are injected per hole ([irish_rumble.py:276](../services/irish_rumble.py))
via `PhantomScoreProvider` (donor-based gross + the group's handicap math).
So a **3-real + 1-phantom** group has 4 scores on every hole and counts up to 4
balls — it competes as a normal foursome. **Adding a phantom is the existing
equalizer for a short group.**

### A *true* threesome (3 real, no phantom) is NOT normalized

When a group has exactly 3 real players and no phantom, `balls` is capped at 3,
and segment totals are compared **raw** — not averaged per ball or normalized to
group size. That produces a structural asymmetry that cuts both ways:

| Segment | Foursome counts | True threesome counts | Edge |
|---------|-----------------|------------------------|------|
| best 1  | best 1 of 4     | best 1 of 3            | **Foursome** — deeper pool to draw a low score from |
| best 2  | best 2 of 4     | best 2 of 3            | **Foursome** — deeper pool |
| best 3  | best 3 of 4 (drops its worst) | all 3 (can't drop) | **Foursome** — gets to discard a ball |
| best 4 (all) | sums 4     | sums 3                 | **Threesome** — one fewer score to add → lower total |

Net effect across a standard round usually **favors foursomes** (more depth on
14 of 18 holes), with the threesome clawing some back only on the all-balls
segment. This is an *emergent* consequence of the `min()` cap, **not a designed
equalizer**.

**Practical guidance today:** to keep mixed groups fair, give every short group
a **phantom** so all groups count the same number of balls. A true,
phantom-less threesome should be treated as a known imbalance.

## Options to level mixed groups (deferred — design notes)

If we want true-threesomes to compete fairly without requiring a phantom, the
candidates, roughly in order of preference:

1. **Phantom-fill automatically (recommended, smallest change).** When a group
   is short, auto-attach a phantom for Irish Rumble scoring so it always counts
   the full `configured` balls. Reuses the existing, already-tested
   `PhantomScoreProvider` path; no change to the comparison math. Decision to
   make: what donor scores the phantom uses (its current cross-group donor, or
   the group's own worst ball as a self-fill).

2. **Self-fill with the group's own worst ball.** For the all-balls segment,
   pad a short group up to `configured` by repeating its highest (worst) score.
   Removes the "fewer balls to add" advantage without inventing a donor. Simple
   and self-contained, but only addresses the all-balls segment, not the
   deeper-pool edge in best-1/2/3.

3. **Normalize segment totals to balls counted (per-ball average).** Rank on
   `total / balls` instead of `total`. Directly removes the sum-of-3-vs-4
   asymmetry in the all-balls segment, but changes the feel (you're comparing
   averages, not strokes) and still doesn't fix the deeper-pool selection edge.

4. **Par-relative normalization.** Rank on net-to-par per counted ball. Most
   "statistically fair," least intuitive to players reading a scoreboard.

None of these is implemented. **Recommendation: option 1** (auto phantom-fill) —
it makes every group a foursome for scoring, which both the math and the UI
already handle, and keeps strokes (not averages) on the board.

## Files

- Engine: [`services/irish_rumble.py`](../services/irish_rumble.py)
  (`calculate_irish_rumble`, `irish_rumble_summary`, `_build_ir_score_index`).
- Config: `games.IrishRumbleConfig` (segments, handicap_mode, net_percent,
  entry_fee, payouts, excluded_player_ids).
- Per-segment results: `games.IrishRumbleSegmentResult`.
- Setup UI: `mobile/lib/screens/irish_rumble_setup_screen.dart`.
