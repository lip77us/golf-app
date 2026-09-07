# Points 5-3-1 — as built: Setup

**There is no packet for this game.** This is the other half of an as-built:
what the screen does today and every choice taken in the absence of a rule.

Screen: `mobile/lib/screens/points_531_setup_screen.dart`.
Engine: `services/points_531.py`. Play is a separate document.

---

## 1. It has a play screen design has never seen

> **This is the one to read.** The coverage table's empty PLAY cell means *not
> drawn*, not *not built*.

`/points-531` is a dedicated play screen, and score entry additionally carries
a `_P531SummaryGrid` — the per-hole points, by golfer. Both exist and neither
has been designed.

The other structural fact: **this is the three-handed game.** Exactly three
real golfers, phantoms excluded entirely, which is its origin — *a casual game
you play when you're a threesome*. Setup refuses anything else.

---

## 2. The screen, top to bottom

| Block | Control | Notes |
|---|---|---|
| Handicap | `HandicapModeSelector` — Net / Gross / SO Low | Percent slider under Net only |
| How scoring works | prose | 5 / 3 / 1 for 1st / 2nd / 3rd, ties split so every hole pays exactly 9 |
| Stake | `StakeField` | With the *Play for fun* opt-in |
| How the money settles | segmented: `vs Average` · `Above you` · `Just leader` | The shared wager vocabulary — see §4 |
| Advanced (collapsed) | *Cap each player's losses* + amount | Off by default |
| Action | `Start` / `Save Configuration` | |

---

## 3. Decisions taken with no rule to follow

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **Every hole pays exactly 9 points**, ties split across tied positions | 4/4/1, 5/2/2, 3/3/3 — the alternatives all leak or invent points. Par is therefore 3 a hole, and money is `(points − 3 × holes) × stake` | Settled by arithmetic |
| 2 | **A hole scores only when all three cards are in** | A partial hole would rank two golfers and pay nine points for it | Settled |
| 3 | **`vs Average` is the default settlement**, not `Above you` | It is the gentlest of the three and the only one where a middling round costs nothing | ⚠ Same trio appears on Spots and Honors with **different defaults** — Spots defaults to `Above you`. Nobody chose that inconsistency |
| 4 | **Strokes-off-low is the default handicap** | Consistent with the other casual games | Settled |
| 5 | **The loss cap is hidden behind *Advanced*, off** | It is the answer to a question most groups never ask | ⚠ The cap is real money protection buried one tap down, on four screens |
| 6 | **The stake is the round's bet unit** | Points 5-3-1 has **no stake field of its own** — the round's unit is where the number lives, so setup must write it. Contrast Fourball, which had its own field and wrote the round's anyway (now fixed) | Correct as built |

---

## 4. Shared components it already uses

- `HandicapModeSelector`, `StakeField`, `SectionCard` — the setup furniture
- **The settlement trio** — `vs Average` / `Above you` / `Just leader`, plus
  *Cap each player's losses*. This is `services/wager.py` surfaced identically
  on **Points 5-3-1, Spots and Honors**, and it is the single largest undrawn
  pattern in the set. Design it once and three screens move.

---

## 5. Still open

- **No How to Play**, and this game has the least obvious scoring of the three
  points games — nothing outside setup explains what 9 points a hole means.
- **No web view, no lock-screen card, no receipt.**
- **The default-settlement inconsistency** (decision 3) is worth one ruling
  that lands on all three screens.
