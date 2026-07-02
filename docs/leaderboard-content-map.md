# Leaderboard / scorecard content map

Status: **analysis only — no code changes** (per decision on 2026-07-01).
Purpose: map where the same round data is shown, so we can decide how to
de-duplicate. The felt problem: "a lot of the same information across different
screens in different formats."

## The three surfaces (all reachable from the score-entry header)

1. **Score entry** — one screen per game (`nassau_screen`, `skins_screen`,
   `points_531_screen`, `wolf_screen`, `rabbit_screen`, `pink_ball_screen`,
   `quota_nassau_screen`, and the generic `score_entry_screen` for
   Skins/Vegas/Fourball/Stableford/tournament rounds). Below the hole-entry
   card, each renders a **full embedded grid/standings**:
   - `nassau_screen` → "Round progress" (hole × player, strokes + won-by dots)
   - `points_531_screen` → "Round progress" (+ points row)
   - `rabbit_screen` → "Rabbit by hole" + "Segments"
   - `score_entry_screen` → "Nassau progress" / "Stroke play progress" /
     "Skins standings" / "Fourball progress" / "Round progress" (game-dependent)
2. **Leaderboard** (📊 icon, `leaderboard_screen`) — a tab per active game
   (`_GameView` switch). Notable:
   - Nassau → F9 / B9 / Overall match result + money
   - **Stroke Play (`low_net_round`) → `_LowNetView` = a per-hole gross grid**
     ("Gross per hole. Red/circle = under net par", + Full Net toggle)
   - Skins → standings + money + by-hole strip
   - Pink/Red Ball → standings + money
   - Championship / Cup / Match-play → rank·thru·total, brackets, team score
3. **Scorecard** (▦ icon, `scorecard_screen`) — the **per-hole score grid**,
   vertical (player rows) + landscape (full 18-column card), gross + net.

## Content × surface matrix (■ = shown, · = not)

| Data element                              | Score entry (embedded) | Leaderboard tab | Scorecard |
|-------------------------------------------|:----------------------:|:---------------:|:---------:|
| Per-hole gross (circle/square to-par)     | ■ (progress grid)      | ■ (Stroke Play) | ■         |
| Per-hole net                              | ■ (some)               | ■ (Full Net)    | ■         |
| Stroke dots (handicap strokes/hole)       | ■                      | ·               | ■         |
| Running total to par (gross/net)          | ■                      | ■               | ■         |
| Ranking / standings order                 | ■ (some)               | ■               | · (card order) |
| Money / payout                            | ■ (some)               | ■               | ·         |
| Game status (skins-on-line, up/down, etc.)| ■                      | ■               | ·         |
| Thru / holes played                       | ■                      | ■               | ■ (implicit) |

## The three redundancy hotspots

1. **Per-hole score grid appears in 3 places** — Scorecard, the Stroke Play
   leaderboard tab (`_LowNetView`), and the embedded in-entry progress grid.
   Three renders of the same hole-by-hole numbers in three formats.
2. **Game standings appear in 2 places** — the embedded in-entry grid
   (e.g. "Skins standings", Nassau "won by") and that game's leaderboard tab.
3. **Total-to-par** shows on entry rows, the scorecard, and the leaderboard
   (recently cleaned to Gross/Net wording, but still three locations).

## Candidate "one job per surface" model (for later)

- **Score entry** = enter scores + a **thin live-status line** ("Thru 2 · Jim &
  Dave 1UP", "2 skins on the line"), not a full embedded grid.
- **Leaderboard** = **standings & money** (rank · thru · total-to-par · payout).
  The Stroke Play tab becomes a ranked list, **not** a per-hole grid.
- **Scorecard** = the **single** hole-by-hole grid (gross/net).

Net effect: kills the triple per-hole grid and the double standings; each
surface has one clear purpose.

## Options considered (deferred)

- **A. Stroke Play leaderboard tab → standings list** (drop its per-hole grid;
  it duplicates the Scorecard). Lowest-risk, highest-clarity single change.
- **B. Slim the in-entry embedded grids → compact status line** (full detail one
  tap away on Leaderboard/Scorecard).
- **C. Keep the in-entry grids but collapsed by default** (tap to expand) —
  preserves the at-a-glance view some players like, de-emphasises it.

Trade-off to weigh: the embedded grid is handy mid-round (no tap away), so B is
the most opinionated; C is the gentlest; A is orthogonal and safe.

## Not yet inventoried

- Web **watch pages** (`watch/*.html`) render spectator versions of several of
  these — a 4th surface that likely mirrors the leaderboard tabs. Worth a look
  before committing to a model, so the consolidation carries to the watch view.
