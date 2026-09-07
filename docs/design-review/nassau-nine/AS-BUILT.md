# Nassau Nine — as built

**There is no packet for this game.** What the screen does today, and the
choices taken with no rule to follow.

Screen: `mobile/lib/screens/nassau_setup_screen.dart` — **not a screen of its
own.** Engine: `services/nassau.py`. Setup is Part 1 below; Play follows it in the same file.

---

# Setup

## 1. It is Nassau's screen in single-match mode, over a partial round

> **This is the one to read**, and it is why this game is missing things the
> others have for reasons that are not oversights.

The same screen configures three games, chosen by route flag rather than by
any toggle on the form — see `singles-match/AS-BUILT.md` for the table. Nassau
Nine is `singleMatch`: **one match over one nine**, not three bets over
eighteen.

That partial-round shape is load-bearing:

- **It has no lock-screen card, deliberately.** Every card in the set draws
  holes-remaining, and this game's remaining is not *18 minus played*. It does
  not fit the state slot, so `nassau_nine` is absent from the Live Activity
  registry rather than drawn wrong. This is the only game excluded for that
  reason.
- The round it sits in may itself be nine holes, or it may be a nine inside an
  eighteen. The screen does not distinguish, and neither does the engine.

---

## 2. The screen, top to bottom

Identical to Nassau's, with the bet block collapsed to a single match:

| Block | In Nassau Nine |
|---|---|
| Teams | Sides of 1–2 golfers |
| Handicap | Net / Gross / SO Low, percent slider under Net |
| Bets | **One**, not three — `_baseMultiple` is 1 |
| Presses | Offered, same code as Nassau's |
| Variant | `none` / `tiebreak_2nd` / `claremont` offered |
| Stake | `StakeField` |
| Advanced | *Cap each player's losses* |

---

## 3. Decisions taken with no rule to follow

| # | Decision | Why it went that way | Worth revisiting? |
|---|---|---|---|
| 1 | **Three games share one screen**, identity from the route | A game whose identity depended on which bets were left switched on would turn into a different game by accident | Settled, and load-bearing |
| 2 | **No lock-screen card** | Its holes-remaining does not fit a slot every other card shares. Drawing it wrong is worse than not drawing it | ⚠ Worth a decision: either a partial-round variant of the card, or this stays the one game with no board |
| 3 | **Claremont is offered on a nine** | Claremont's bottom bet has its own auto-press series tuned to a nine, so it is arguably more at home here than in a Singles Match | Untested in this mode |
| 4 | **The stake is the round's bet unit** | Nassau has no stake field of its own | Correct as built |
| 5 | **The title is derived, not stored** | `Nassau Nine` comes from the route flag, so the screen renames itself | Settled |

---

## 4. Shared components it already uses

- All of Nassau's setup screen
- `HandicapModeSelector`, `StakeField`, `SectionCard`
- Nassau's progress grid and hole-outcome strip under score entry

---

## 5. Still open

- **The lock-screen question** (decision 2) is the only real one here.
- **No web view, no receipt, no How to Play.**
- Whether Nassau Nine deserves a row of its own on the coverage table at all,
  or whether it and Singles Match are honestly *modes of Nassau* — three rows
  currently describe one screen, one engine and one play surface.

---

# Play

## 6. Where the game is played

**Nassau's play screen**, `/nassau`, and Nassau's progress grid under shared
score entry — the same surfaces as Nassau and Singles Match. See
`singles-match/AS-BUILT.md` §7 for what the screen draws; the differences here
are the bet count and the hole range.

## 7. What differs in this mode

| Element | In Nassau Nine |
|---|---|
| Match chips | One bet, not three |
| Summary grid | Nine holes of an eighteen-hole grid, or a nine-hole round's full grid — the screen does not distinguish |
| Presses strip | Same as Nassau's |
| Lock screen | **None**, by design — see Part 1 §3, decision 2 |

## 8. Decisions taken with no rule to follow — Play

| # | Decision | Why | Worth revisiting? |
|---|---|---|---|
| 6 | **The grid does not mark which nine the match covers** | Nassau's grid draws the round; the match's own range lives in the chips | ⚠ On an eighteen-hole round carrying a nine-hole match, half the grid is outside the bet and nothing says so |
| 7 | **No lock-screen card** | Holes-remaining does not fit the shared state slot | ⚠ Carried from Part 1 — the only game excluded from the card set |

## 9. Still open — Play

- **Marking the match's nine on the grid** (decision 6).
- Whether this and Singles Match are games or modes — three coverage rows
  currently describe one screen, one engine and one play surface.
