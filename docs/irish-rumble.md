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

## Leveling mixed groups — chosen design (borrowed-4th phantom)

A true threesome is automatically given a **phantom 4th team member** whose
per-hole score is **borrowed from real players across the whole field**. This
makes every group score the full `configured` balls, so the field competes on
equal footing without inventing or averaging anything.

**Rules:**

1. **Automatic, only when sizes are mixed** — an IR group with exactly 3 real
   players (and no existing phantom) gets one **only when some other group has 4
   real players** to level up to. When the whole field is the same size (e.g. a
   9-golfer **3-on-3-on-3** round), there is no ball-count asymmetry to correct,
   so no phantoms are added. No TD toggle. The phantom counts as a team member
   feeding the group's best-N pool (it is NOT an opponent — contrast Triple Cup,
   where the same donor machinery fills an *opponent* slot). *(Separate, deferred:
   an IR setup mode that forbids 4-player groups so a TD running 3×3×3 can't
   accidentally create a foursome.)*
2. **Donor pool = every real player in every other group, regardless of tee-off
   order** — one fixed shuffled rotation built at setup (reuses
   `CrossFoursomeRotation`). Hole by hole, the phantom takes the **next donor's
   posted score** for that hole. Borrowing spreads across the whole field, so no
   single golfer dominates the phantom's card. Donors are never notified — their
   scores are simply read; only the threesome sees the phantom.
3. **Handicap: the donor's own individual handicap.** The borrowed ball is the
   donor's **net** under the round's IR mode — net (donor gross − donor strokes),
   gross (raw), or strokes-off (donor gross − `max(0, donor_hcp − round_low)`,
   round-wide low). No team/foursome handicap is computed; individual handicaps
   cover it. **The borrowed ball is scored entirely as the donor's hole:** its
   stroke allocation (and the net-double-bogey cap's par) use the **donor's own
   tee** stroke index / par, not the threesome's. This matters on courses whose
   men's and women's cards carry different SI tables (e.g. Tilden Park), where
   the donor and the threesome may play different tees. The net-double-bogey cap
   (if on) applies to the donor's adjusted score like any other.
4. **No self-fill, accept the leaderboard lag.** If a donor hasn't posted a hole
   yet (donors can be anywhere on the course), that hole simply has no phantom
   score until they do — the threesome shows a provisional total on its 3 real
   balls and firms up once the donor posts. Acceptable because Irish Rumble is a
   side game; the lag is the price of true fairness over a self-fill guess.
5. **TD guidance:** schedule the threesome **last** so most donors are already
   finished — minimizing how long the lag lasts.

Considered and rejected: per-ball averaging and par-relative normalization
(change strokes→averages on the board, less intuitive); restricting donors to
groups *ahead* + self-fill fallback (less fair than borrowing a real net score
once it lands).

### Implementation notes

- Reuses `scoring/phantom.py` `CrossFoursomeRotation` (donor rotation +
  per-donor `donor_handicaps`) and the existing IR phantom injection
  ([irish_rumble.py:276](../services/irish_rumble.py)).
- New: (a) a setup/ensure step that creates the phantom membership for a 3-real
  IR group with a whole-field donor rotation; (b) the IR injection must adjust
  each borrowed hole by the **per-hole donor's** handicap (via
  `donor_handicaps`), not a single phantom handicap, and by the **donor's own
  tee** SI/par (not the threesome's), so mixed-tee/mixed-gender SI tables score
  the borrowed ball correctly.
- Implemented: `ensure_irish_rumble_phantom(round_obj)` (idempotent; runs in
  `IrishRumbleSetupView`; only levels when sizes are mixed) + the donor-aware
  injection in `_build_ir_score_index`. Tests:
  `scoring/tests/test_irish_rumble_phantom.py`.
- **Shares one phantom membership with pad-to-4 games.** A threesome in a round
  that also runs Pink Ball / Sixes already gets an INTRA-foursome rotating
  phantom from `setup_round`'s pad-to-4. `ensure_irish_rumble_phantom`
  **converts** that membership to the cross-foursome borrowed-4th in place
  (algorithm + config + scratch handicap, clearing pad-to-4 bogey scores) rather
  than skipping it; an already-converted borrowed-4th is left untouched (no
  reshuffle). Pink Ball is unaffected — it scores the **3 live players only**
  (`player__is_phantom=False` throughout `services/red_ball.py`); the phantom is
  purely an IR construct.
- Mobile: the Pink Ball screen shows **no phantom row** (Pink Ball = 3 players),
  except when Irish Rumble is also active — then it renders the shared
  `BorrowedFourthBanner` (donor-by-hole status) so the scorer sees the IR
  borrowed-4th. `BorrowedFourthBanner` (in `widgets/borrowed_fourth.dart`) is
  shared by the generic score-entry and Pink Ball screens.
- Backend exposure: each `irish_rumble_summary` overall row carries
  `foursome_id` + a `phantom` block (`build_phantom_info` donor-by-hole status)
  for a leveled threesome. New `GET /api/rounds/<id>/irish-rumble/`
  (`IrishRumbleResultView`) returns the summary for score-entry to read.
- Mobile surfaces (all four): shared widgets in
  `mobile/lib/widgets/borrowed_fourth.dart` (`BorrowedFourthNote`,
  `DonorByHoleStrip`, reusing `NassauPhantomInfo` for the donor block). The IR
  leaderboard (`_IrishRumbleView`) relabels "+ Phantom" → "+ Borrowed 4th",
  shows the explainer, and a collapsible donor-by-hole strip per leveled group;
  the IR setup screen shows a threesome-leveling notice when sizes are mixed;
  score entry shows a borrowed-ball banner + donor strip
  (`_BorrowedFourthBanner`, fetched via `getIrishRumbleResult`).

## Files

- Engine: [`services/irish_rumble.py`](../services/irish_rumble.py)
  (`calculate_irish_rumble`, `irish_rumble_summary`, `_build_ir_score_index`).
- Config: `games.IrishRumbleConfig` (segments, handicap_mode, net_percent,
  entry_fee, payouts, excluded_player_ids).
- Per-segment results: `games.IrishRumbleSegmentResult`.
- Setup UI: `mobile/lib/screens/irish_rumble_setup_screen.dart`.
