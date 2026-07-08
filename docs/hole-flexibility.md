# Hole flexibility: partial rounds, shotgun starts, and short courses

Status: **design** (2026-07-07). Kickoff by Paul. Not yet implemented.

## Problem

The app is 18-hole-hardcoded: every scoring service iterates holes 1→18,
completion checks all 18, handicaps allocate over stroke index 1–18, and
leaderboards render OUT/IN/TOT as front-9 + back-9. Three real needs break this:

1. **Shotgun-start tournaments** — every group tees off simultaneously from a
   different hole and plays 18 in a rotated order (group on hole 7 plays
   7,8…18,1…6).
2. **Partial rounds** — a whole round of fewer than 18 holes, starting on a
   non-1 hole: back 9, or a "wine-and-9" afternoon loop that isn't always the
   back 9 (some courses' clubhouse loop starts at 10/11). Needed for BOTH casual
   rounds and tournaments.
3. **Short courses** — 9-hole courses that exist in their own right and are
   played once (many of these). The app can't even *store* one today.

## Decisions taken at kickoff

- **Design it properly**, not a Thursday-tournament hack. No rush slice.
- **One unified model** powers shotgun + partial rounds + short courses.
- **Consecutive + wraparound only** — the holes played are always a consecutive
  run (with wraparound), never an arbitrary subset. This means the play sequence
  is *derived from two numbers*; no stored hole-list is needed.
- **In scope now:** courses of **9 or 18** holes, played **once**; shotgun on 18.
- **Deferred:** odd-count courses (Bandon Preserve = 13, Shorty's = 19); looping
  a 9-hole course twice to make an 18-hole round (a tee-data problem — see below).

## The model

Two stored numbers, plus a per-group override for shotgun:

```
Round.num_holes        PositiveSmallInt, default 18   — how many holes are played
Round.starting_hole    PositiveSmallInt, default 1    — the round's default start
Foursome.starting_hole PositiveSmallInt, null=True    — per-group override for
                                                         shotgun; null = inherit
                                                         Round.starting_hole
Foursome.shotgun_slot  CharField(2), blank            — DISPLAY-ONLY tee-slot
                                                         label (e.g. "A"/"B") when
                                                         >1 group starts on the
                                                         same hole; renders as
                                                         "7A"/"7B". No effect on
                                                         play order or scoring.
```

Effective start for a group = `foursome.starting_hole ?? round.starting_hole`.

Casual rounds and tournament rounds are both Round + Foursome under the hood, so
these three fields cover every case. Casual back-9 = Round(start=10, num=9) with
its single foursome inheriting. Shotgun = Round(num=18) + each Foursome its own
`starting_hole`.

### The universe is the course, not the literal 18

The wraparound modulus is the **course's hole count**, not a hardcoded 18. This
is the single generalization that makes short courses fall out for free:

```python
universe   = course_hole_count(round.course)     # 18, or 9
play_order = [ (start - 1 + i) % universe + 1  for i in range(num_holes) ]
holes_in_play = set(play_order)
```

- 18-hole course, back 9:      `universe=18, start=10, num=9`  → 10…18
- 18-hole course, shotgun grp: `universe=18, start=7,  num=18` → 7…18,1…6
- 9-hole course, played once:  `universe=9,  start=1,  num=9`  → 1…9  (same code)

Worked shotgun example (group starts on hole 8, plays 18): play order is
`8,9,10,11,12,13,14,15,16,17,18,1,2,3,4,5,6,7`.

`course_hole_count` derives from the tee's hole rows (all tees on a course share
the same count). Validation: `starting_hole ≤ universe` and `num_holes ≤
universe` (single-loop only for now).

### The one abstraction everything routes through — `services/hole_plan.py`

- **`holes_in_play(round) -> set[int]`** — the hole *numbers* that count. Scoring
  and completion iterate this. Order is irrelevant to scoring (a birdie counts
  the same whenever played), so this is a set. **Every `range(1, 19)` in the
  scoring services and `RoundCompleteView._expected_holes` becomes
  `holes_in_play(round)`.**
- **`play_order(round, foursome) -> list[int]`** — the ordered sequence starting
  at the group's effective start (with wraparound). Used by score entry, the
  "next unscored hole" gate, per-hole strips — **and by segment games and the
  scorecard** (see below).
- **`segment(round, foursome, n_parts) -> list[list[int]]`** — split `play_order`
  into `n_parts` consecutive runs (2 for Nassau front/back + OUT/IN, 3 for Sixes
  / Triple Cup). Returns hole numbers per segment, in play order.

**Segments and OUT/IN are defined by POSITION IN PLAY ORDER, not by absolute hole
number.** For a group starting on hole 8: OUT = first nine played (8→16), IN =
last nine played (17→7); Sixes' three sixes = 8–13 / 14–1 / 2–7. When the round
starts on hole 1 (the normal case) play order = 1..18, so position == hole number
and this reduces to today's front-9/back-9 behavior exactly.

This is why per-hole games (Skins, Stableford, Stroke, Points, Wolf, …) are truly
order-independent (they read the `holes_in_play` *set*), while **segment games
(Nassau, Quota Nassau, Sixes, Triple Cup) must read `play_order` / `segment()`** —
their thirds/halves follow the sequence the group actually plays. So shotgun is a
play-order concern for the UI *and* for the segment games' backend, not UI-only.

## Handicap allocation for partial rounds

18-hole rounds (incl. shotgun) are unchanged. Partial rounds need two changes,
generalizing `scoring/handicap.py::_strokes_on_hole`:

1. **Scale the playing handicap to the holes played.** WHS: a 9-hole playing
   handicap is ~half the 18-hole figure. Recommended:
   `ph_partial = round(ph_18 * num_holes / universe)`.
2. **Allocate by SI *rank within the holes in play*,** not raw SI over 1..18:
   sort holes-in-play by stroke index; give `ph_partial // n` to every hole and
   one extra to the lowest `ph_partial % n`. For a true 9-hole course (SI 1–9)
   this equals allocating by SI directly; for a back-9 of an 18-hole course it
   correctly re-ranks the 9 SIs present.

**OPEN — needs Paul (domain expert) to confirm:** the halving + re-rank approach
vs. keeping the full 18-hole course handicap and simply playing the strokes that
land on the 9 holes. WHS-correct answer preferred; we don't store separate
9-hole course ratings, so an exact 9-hole CH from a 9-hole rating isn't available
— the scale-by-fraction approximation is the pragmatic path.

## Which games work on partial rounds

Games are per-hole and work on any hole set: **Skins, Stableford, Stroke/Low
Net, Points 5-3-1, Match Play, Wolf, Rabbit, Vegas, Fourball, Spots.** These are
offered for 9-hole rounds.

Structurally-18-hole games must be **gated off when the round has fewer than 18
holes**: **Nassau** (front/back/overall), **Quota Nassau**, **Sixes** (three
6-hole segments), **Triple Cup** (fourball/foursomes/singles). These stay fully
available for **shotgun** (still 18 holes) — but their segments are taken over
**play order**, not absolute hole number: a group starting on 8 plays its Sixes
thirds as 8–13 / 14–1 / 2–7 and its Nassau front/back as 8→16 / 17→7. The gate is
about `num_holes < 18`, NOT about a non-1 start — a shotgun is a full 18 and keeps
every game. (Refactor: each segment service currently hardcodes boundaries by
hole number; it must instead call `segment(round, foursome, n)`.)

## Short-course storage (the quality-gate change)

To store a 9-hole course, the import + paste validators must accept N-hole
courses:

- `services/course_quality.py::validate_tee_holes` — stroke index must be a
  permutation of **1..N** (N = hole count), par 3–6 per hole, contiguous hole
  numbers 1..N, plausible total par. Currently hardcoded to 1..18.
- `services/course_paste.py` — same SI-permutation relaxation.
- `services/golf_api_client.py::_adapt_course_detail` — already keeps whatever
  holes the API returns; confirm it doesn't pad/truncate to 18.
- Model validators (`HoleScore.hole_number` etc.) stay `MaxValueValidator(18)` —
  hole numbers are still 1..18 (or 1..9); nothing exceeds 18. No relaxation
  needed there.

**Deferred (tee-data slice):** playing a 9-hole course *twice* for an 18-hole
round. The clean fix is to materialize an 18-hole tee (holes 10–18 = a second
copy of 1–9 with interleaved SIs) at import/paste time, so downstream code sees
18 real holes. Out of scope here.

## Leaderboard / scorecard rendering

- **Scorecard grid** (`mobile/lib/widgets/scorecard_grid.dart`) and the Stroke-Play
  strip render **by hole NUMBER** — OUT = holes 1–9, IN = 10–18, TOT — with
  **blanks for not-yet-played holes** (REVISED 2026-07-07: this matches a physical
  scorecard and reads naturally even for a mid-course start; we do NOT re-order the
  card by play order). Done for the Stroke-Play strip (`_holeStrip` renders
  `holes_in_play` with blank+par for unplayed holes; OUT/IN/TOT appear only once
  their by-number segment is fully scored). Still TODO for the landscape grid and
  the Skins/other leaderboard cards. A 9-hole round on a 9-hole course shows one
  9-hole total (no IN split).
- **Watch pages** (`api/watch_views.py::_seg_len` returns 9/18) and Nassau labels
  — same play-order generalization for shotgun; segment games are hidden on
  sub-18 rounds anyway. In a shotgun, label segment bets by their actual holes
  (e.g. Nassau "Front (holes 8–16)") so the play-order basis is explicit and a
  player doesn't read it as holes 1–9.

### Personal course-nines summary (Front 9 / Back 9 by hole number)

**SUPERSEDED (2026-07-07):** now that the scorecard DISPLAY is by hole number
(decision 5), the by-number Front 9 / Back 9 is just the normal card — no separate
summary is needed. Kept below for history.

Separate from the play-order OUT/IN above: at the **end of an 18-hole round** the
summary also reports **Front 9 (holes 1–9) and Back 9 (holes 10–18) by hole
NUMBER**, plus total — the golfer's familiar "what I shoot on the front here"
figure. Requested by Paul: in a shotgun, OUT/IN follow play order, but a regular
still wants the by-the-card nines.

- **Display-only**, gross (and net where shown); **never affects any game or
  segment bet.** Subtotals only — "not the detail" (no re-laid-out grid).
- Well-defined for any 18-hole round on an 18-hole course (pure summation by hole
  number). Omitted for 9-hole rounds. In a NON-shotgun round it equals OUT/IN, so
  it's only *distinct* in a shotgun — show it always (harmless duplicate when
  start=1) or only when it diverges; TBD in UI, but compute it always.
- Lives wherever the completed-round total is shown (leaderboard Stroke-Play row /
  round summary). Backend can expose `front9_by_number` / `back9_by_number` on the
  per-player summary, or the client sums the stored hole numbers directly.

## Shotgun assignment (tournament setup UX)

For G groups on an 18-hole course, the **TD assigns each foursome a starting
hole by hand** (manual only — no auto-fill). Setup surfaces each group's
starting-hole field.
- **A/B slots (in scope, display-only):** when more than one group starts on the
  same hole, each gets a slot label (`Foursome.shotgun_slot`, e.g. "A"/"B") so it
  renders "7A" / "7B" — like a tee time distinguishing the two groups. It does
  NOT affect play order or scoring (both groups play 7→…→6). The TD sets it; the
  UI can suggest the next free letter when a collision is detected.
- **Deferred:** auto-assign presets (sequential, split-tee half-on-1/half-on-10).

## The "Advanced" setup tab (Paul's proposal)

Both casual round setup (`casual_round_screen.dart`) and tournament round setup
get an **Advanced** section:
- **Starting hole** (1..course hole count)
- **Holes**: 9 / 18 / other (number spinner)
- Tournament only: **Shotgun start** toggle → reveals per-group hole assignment.

Defaults (start=1, holes=18) reproduce today's behavior exactly, so the tab is
opt-in and nothing changes for existing flows.

## Progress (2026-07-07)

- ✅ **Phase 0** — fields + `services/hole_plan.py` + tests (no-op).
- ✅ **Phase 1** — 9-hole course storage (quality gate + paste accept 9/18).
- ✅ **Phase 2a** — round completion on `holes_in_play`.
- ✅ **Phase 2b** — casual Advanced tab (holes + starting hole) + play-order
  score entry. **Casual 9-hole / back-9 rounds are now creatable and playable
  end-to-end for per-hole GROSS games.**
- ✅ **Phase 2c** — partial-round handicap (scale + re-rank) via
  `scoring.handicap.make_strokes_fn`, wired through build_score_index / low_net /
  stableford / `handicap_strokes_on_hole` (submit + scorecard). Full rounds
  byte-identical (434 tests). **NET games now score correctly on a 9-hole /
  partial round.** Mobile score-entry stroke DOTS + net preview are partial-aware
  too (net@100% reads the scorecard's predicted strokes; net@custom% uses
  `partialStrokesOnHole`, mirroring the backend). Remaining gap: Wolf/Rabbit
  DEDICATED play screens still compute full-18 locally (also not play-order aware
  on partial rounds yet — a combined follow-up).
- ✅ **Phase 2e (gate half)** — segment games are hidden from the CASUAL picker on
  a partial round. `GameMeta.requiresFullRound` (Nassau, Sixes, Triple Cup, Match
  brackets / Three-Person Match) drops them from `_filteredCasualGames` when
  `_numHoles < 18`, and dropping holes below 18 prunes an already-picked segment
  primary (`_setHoles`) + its side games, with an explanatory note. A shotgun is
  still num_holes 18, so it keeps them. **Deferred:** a backend guard on
  `RoundCreateView` (the picker is the only creation path today) and play-order
  thirds for shotgun segment bets.
- ✅ **Wolf / Rabbit partial rounds** — both now play-order aware end-to-end.
  Rabbit segments split by POSITION via `hole_plan.segment` (9-hole → one 9-hole
  rabbit or three 3-hole rabbits); Wolf rotates by play-order position (first
  hole played = first rotation pick), with the last-place-Wolf twist on the last
  TWO holes played and the require-lone rule on every hole before those. Mobile:
  new shared `utils/play_order.dart` drives both dedicated play screens' nav +
  grids; Rabbit setup offers only even segment splits for the hole count.
  Full-round behavior byte-identical (Wolf 21, Rabbit 7 tests).
- ✅ **Segmented games — play-order segments (shotgun engine prep).** Nassau,
  Sixes, and Triple Cup now segment by POSITION in the group's play order
  (`hole_plan.play_order`/`segment`) instead of absolute hole number, so a
  shotgun start puts the right holes in each nine / third:
  - **Nassau** tracks play-order position for nines, decided margins, and the
    whole press system (advance, holes-remaining replay, add_manual_press).
  - **Sixes** rewrote calculate_sixes' boundary tracker + early-finish
    re-segmentation + SO-stroke overlay in position space (a segment's stored
    start/end are its actual first/last holes, possibly wrapped).
  - **Triple Cup** computes segment boundaries from play-order thirds/halves at
    setup and slices each match's play-order holes for scoring (new
    `_match_hole_list`).
  All three byte-identical for a normal round (start hole 1 → position == hole-1);
  each has new shotgun tests; full scoring suite green (241). **Not app-testable
  until Phase 4** (no shotgun setup UI yet). Known gap: Sixes mid-round
  withdrawal segment selection still keys off hole number.
- ✅ **Phase 4 (core) — tournament shotgun setup.** The TD assigns each group a
  starting hole, so the shotgun engine work above is usable end to end.
  - Backend: `FoursomeSerializer` exposes `starting_hole` + `shotgun_slot`;
    `FoursomeDetailView.patch` sets them (validated 1..course holes; null clears
    → inherit round; slot upper-cased). Tests in `api/test_partial_rounds.py`.
  - Mobile: `Foursome.startingHole`/`shotgunSlot`; `play_order` resolves the
    FOURSOME's start (falls back to the round's) so score entry + Sixes dots
    follow each group's wrapped sequence; round-hub TD menu "Set starting hole"
    (hole picker + A/B slot) on multi-group non-cup rounds; card shows "Starts 7A".
  - **Deferred:** auto-assign presets (sequential / split-tee); cup-round shotgun
    (the per-foursome TD menu is hidden on cup rounds — same limit as scorer
    designation); casual Sixes shotgun already works via the round Advanced tab.
- ⏳ **Next:** back-9 rendering leftovers (Phase 5) — watch pages + any grids that
  still assume 1-18.

## Phased plan

- **Phase 0 — foundation (no behavior change).** Add the three fields + migration;
  add `services/hole_plan.py` (`holes_in_play`, `play_order`, `course_hole_count`).
  Defaults make it a no-op. Unit tests for the wraparound math.
- **Phase 1 — short-course storage.** Relax the quality gate + paste validators to
  1..N; verify API import of a 9-hole course; store one (the Ridge 9) end to end.
- **Phase 2 — scoring + completion on the primitive.** Rewire every `range(1,19)`
  in services and `RoundCompleteView` to `holes_in_play(round)`; generalize
  handicap allocation (scale + rank-within-play); gate segment games off partial
  rounds. Full scoring suite must stay green (18-from-1 = identical results).
- **Phase 3 — play-order entry (shotgun).** Mobile score entry + per-game screens
  present holes in `play_order`; `_unscoredHoleCount`/advance use the server's
  num_holes + play order.
- **Phase 4 — setup UI (the Advanced tab).** Casual + tournament setup fields;
  tournament shotgun assignment.
- **Phase 5 — rendering.** Scorecard grid + leaderboard + watch pages generalize
  OUT/IN/TOT to the holes in play.

## Decisions resolved (2026-07-07)

1. **9-hole handicap** — **halve + re-rank (WHS-style):** scale the playing
   handicap to `round(ph_18 * num_holes / universe)` and allocate by SI rank
   among the holes in play. (This is the "Handicap allocation" section above.)
2. **Segment-game gating** — **hide** Nassau / Quota Nassau / Sixes / Triple Cup
   only for **sub-18** rounds. They stay available for shotgun (full 18); their
   thirds/halves are taken over **play order** (position), not hole number.
3. **Shotgun assignment** — **manual** (TD sets each group's starting hole).
   **A/B slot labels are IN scope** as display-only "tee-slot" designators
   (`Foursome.shotgun_slot`, renders "7A"/"7B"; no scoring effect). Auto-assign
   presets + split-tee deferred.
4. **Segment BET math follows play order** — a segment *game's* thirds/halves are
   defined by position in the play sequence: Nassau front/back and Sixes/Triple
   Cup thirds for a group starting on 8 are 8→16 / 17→7 and 8–13 / 14–1 / 2–7.
   Reduces to hole-number segments when start=1.
5. **The scorecard/leaderboard DISPLAY stays by hole NUMBER** — REVISED
   2026-07-07 after testing. The scorecard grid and Stroke-Play strip render
   holes in NUMBER order with gaps (blanks) for not-yet-played holes, and OUT/IN
   are holes 1–9 / 10–18 by number — this matches a physical scorecard and reads
   naturally even for a round started mid-course. So the play-order OUT/IN idea
   from decision 4 applies ONLY to a segment game's bet math, NOT to how the card
   is drawn. This makes the old "personal Front 9 / Back 9 summary" moot: the
   by-number card already IS that view.
   **OPEN — Fourball / match-style games:** a 2v2 match's running "thru N / n up"
   state is inherently play-order. Paul is testing whether Fourball's DISPLAY
   wants play order (match state) while the raw scorecard stays by number. TBD.
6. **Score entry is sequential in play order** (all games, 2026-07-08). The hole
   strip lets you tap BACK to any hole already reached, or the current hole, but
   NOT jump ahead to an unplayed hole — a round can't be entered out of order /
   with gaps. (score_entry_screen `_canSelectHole`/`_selectHole`.)
7. **Points displays read chronologically (play order); score/scorecard displays
   read by hole number** (2026-07-08). Refines decision 5: a hole-by-hole POINTS
   grid (Points 5-3-1; Stableford where it has one) renders in play order —
   14,15,…,18,1,2 with upcoming holes blank at the end. A raw SCORE card (Stroke
   Play strip, scorecard grid) stays by hole number. Backend emits the points
   grid's `holes_in_play` play-ordered; "thru N" (match/points) is a count.
