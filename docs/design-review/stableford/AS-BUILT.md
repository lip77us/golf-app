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
