# Halved 2.5.1 (build 19) — Release notes

Version in `mobile/pubspec.yaml` → `2.5.1+19` (build must exceed the last
TestFlight upload; 2.5.0 was build 18).
Backend is deployed and backward-compatible — no `CLIENT_MIN_VERSION` bump.

---

## What's New (user-facing / App Store "What's New" copy)

- **Triple Nassau** — a new game: three simultaneous 1‑v‑1 Nassaus in one
  foursome (you vs each of the other three). One setup, per‑pair handicaps, a
  dedicated play screen with each match's status, presses, and a per‑player
  settlement on the leaderboard.
- **Sixes team draws** — a slot‑machine that picks your partners. Draw the
  Segment 1 teams at setup ("Randomly assign teams"), the Segment 2 pairing
  reveals automatically at the turn, and you can draw the teams for an extra
  match too. Or keep dragging to set them by hand.
- **Cleaner Rounds list** — each round is a tidy card showing the game, live
  progress ("Through 12"), your gross, and the money you won or lost. A new
  filter separates rounds you played from rounds you're only watching.
- **Rabbit improvements** — extra "rabbits" when a leg finishes early, fairer
  handicap allocation across extra legs, and a hole nobody wins now reads
  "Halved."
- **Stroke Play display modes** — see the leaderboard as Gross, Net, or
  Strokes‑off.
- **Cup matches by team colour** — One‑Round Triple Cup match cards are now
  tinted by the leading team.
- **Course fixes** — courses with letter‑and‑number IDs now add correctly, and
  a failed add tells you why instead of a generic error.

## Fixes

- Fixed an 11px layout overflow on the "Set all tees" header (iPhone 13 mini).
- Course picker no longer pre‑selects the suggested course.
- The database can once again be built from zero (migration state fix).

---

## Changes since 2.5.0 (developer summary)

**New games / features**
- Triple Nassau — backend (round‑robin of three 1‑v‑1 Nassaus), mobile setup,
  dedicated play screen, leaderboard card with presses + round progress.
- Sixes segment draw — front‑end slot‑machine reveal: Segment 1 at setup,
  Segment 2 auto at the turn, and the extra match; drag‑or‑spin, name capping,
  "spin to pick partners" idle prompt.
- Rounds list redesign — 3‑row card (course/date/delete · game+state ·
  players+result), live/complete state, watched‑round filter. Backend adds each
  completed round's gross + net settlement; `settlement.player_round_net`.

**Improvements**
- Rabbit — extra rabbits (Sixes‑style early lock, accumulate‑only), full‑round
  handicap allocation on extra legs, "Halved" label for an unwon leg.
- Stroke Play — Gross / Net / Strokes‑off display modes.
- Triple Cup — colour matches by the leading team.

**Fixes**
- Course add / Manage Courses search accept alphanumeric GolfCourseAPI ids;
  surface the server's rejection reason on a failed add.
- Set‑tees "Set all" header overflow (13 mini).
- Migration state fixed so a database builds from zero.
