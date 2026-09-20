# Stableford — as built: Play

**Setup is drawn** (`handoff-individual-play/03-stableford-setup.html`), and so
is the lock-screen card. **Play is not.**

Surface: `_StablefordProgressGrid` inside shared score entry. Engine:
`services/stableford.py`.

---

## 1. The grid is authoritative, not derived — which is the whole design

> **This is the one to read**, because it is invisible and it is the reason
> this grid can be trusted.

Every cell is the **server's** points for that hole, computed against the
round's own points table, rather than the client working them out from a score.
A Stableford round can be configured — the points for an eagle, whether a
double bogey scores at all — and a grid that re-derived points on the phone
would silently disagree with the leaderboard the moment a group used anything
but the default table.

| Element | Behaviour |
|---|---|
| Rows | One per golfer, **drawn with empty cells immediately** — before any score exists |
| Cells | The authoritative points for that hole |
| Last column | The running total |
| Scrolling | Horizontal, auto-positioned so the current hole sits about seven columns from the left, and it re-scrolls when the hole changes |

It shares its shape with `_StrokePlayProgressGrid`, and the auto-scroll
behaviour is reused by the per-hole grids and strips under the score card —
so nobody ever has to scroll right to find the hole they just entered.

---

## 2. Decisions taken with no rule to follow

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **Points come from the server, always** | The points table is configurable; deriving on the client guarantees a disagreement the first time somebody changes it | Settled, and load-bearing |
| 2 | **Empty rows draw before any score** | The grid is visible from the first tee rather than appearing on hole two. A golfer sees the shape of the round waiting for them | Settled, and worth copying |
| 3 | **Auto-scroll parks the current hole ~7 columns in** | Far enough left to show what is coming, far enough right to show what just happened | ⚠ A magic number that nobody has looked at on a small phone |
| 4 | **Stableford is round-scoped, not foursome-scoped** | It loads by round id where every other casual game loads by foursome — it is a whole-field format | Settled, but it is the reason its data path looks different from its neighbours |
| 5 | **No per-hole explanation of the points table** | The grid shows `3` and never says why | ⚠ The one thing a first-time Stableford golfer asks |

---

## 3. Still open

- **What the points mean** (decision 5). A tap on a cell, or the table itself
  somewhere in play.
- **The auto-scroll offset** (decision 3) on a small screen.
- No dedicated play screen, and none obviously needed — the grid is the game.

---

# Leaderboard

View: `_StablefordView`. **Not a per-group card** — Stableford is one of only
two games on this screen where the field is the unit, so there are no `Group N`
cards and everyone ranks together. Web view: **yes**, and it is the only game
in this set with both a casual and a championship gate
(`_has_casual_stableford`, `_has_stableford_championship`). Lock screen:
**yes** (`stableford` → `_stableford`).

## What the view draws

| Block | Content |
|---|---|
| Chip row | `Gross` / `Net n%`, then the money shape: `Pool $X/player`, or `$X/pt · vs Average` (`Just first` / `Everyone above`) and `Cap $X/player` when set |
| Points table | The whole table spelled out in one line: `Alb 5 · Eag 4 · Bird 3 · Par 2 · Bog 1 · Dbl 0` |
| Points grid | `_StablefordPointsGrid` — rank, per-hole points, running total, payout |
| Gross scorecard | `HoleGridScorecard` below it |

## Decisions taken with no rule to follow — Leaderboard

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 1 | **The points table is printed on the board** | A modified table is a house rule, and a `3` means nothing without it | ⚠ Good — and the only card in the set that states its own scoring rule. Worth copying to every game with a configurable table |
| 2 | **The gross scorecard sits under the points grid** | The source comment gives the reason: a `3` could be a net birdie or a gross par, and the points grid alone cannot tell them apart | Correct, and the argument generalises |
| 3 | **One card, not per-player standing cards** | The comment records that the old shape overlapped | Settled |
| 4 | **Whole-field, no group cards** | The game is played against the field | Correct — and the reason this view is shaped unlike the other nine |

## Still open — Leaderboard

- Nothing pressing. This is the most complete board in the set, and decisions 1
  and 2 are the two worth propagating to the others.
