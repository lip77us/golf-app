# 12A — Stroke Play display modes (Gross · Net · Strokes-off)

Status: **CONFIRMED — ready to plan implementation.**
Source: design deck `Halved App.dc.html` turn 12 / 12A, plus implementation
notes from Paul's earlier (lost) attempt. Captured 2026-07-24 so the spec
survives regardless of the chat transcript.

## Scope

This lives **entirely inside the Leaderboard's "Stroke Play" tab** (the outer
tabs — e.g. Singles Match / Stroke Play — are unchanged). Within Stroke Play we
add a **2-or-3 way selector**: **Gross · Net · [Strokes-off]**.

Today the mode is fixed by `handicap_mode` and labelled inconsistently
(`Gross` / `Strokes Off` / `Full Net` / `Net {pct}%`) in `leaderboard_screen.dart`
(~lines 1456–1463, 1775–1777). This replaces that with a real selector.

## 1. Scorecard layout — two rows

- The full scorecard renders as **two rows**, not one wide grid:
  - Row 1: **front 9** (holes 1–9)
  - Row 2: **back 9 (holes 10–18) + Total**
- Each block has a **shaded header** with three rows: **Hole number**, **Par**,
  and **SI** (per-hole stroke index).

## 2. Which selectors appear

- **Gross** and **Net** are **always shown**.
- **Strokes-off (SO)** selector is shown whenever **any game (main OR side) uses
  SO**. It only becomes the *default* when the **main/primary game** is SO
  (see §3). A side-game-only SO still creates the selector but does not default
  to it. (Primary vs side games = the stored `Round.primary_game` model.)

## 3. Default selector (precedence — first match wins)

1. User's personal **"enter scores in Gross" setting** → default **Gross** (this
   user only).
2. Else **main game is SO** → default **SO** (everyone else).
3. Else a **side game is SO** (main game not SO) → default **Net**.
4. Else → default **Net** (catch-all).

- The default is **recomputed each time the Stroke Play tab is opened**.
- **Switching the selector re-ranks + re-renders from already-loaded data** — it
  does NOT recompute the default or refetch.

## 4. Ranking

- **Switching the selector re-ranks the standings**: Gross ranks by gross,
  Net by net, SO by strokes-off net. (Not just a symbol change.)

## 5. Stroke display ("gets N")

- The **"gets N"** figure = the player's course handicap **scaled by the main
  game's chosen handicap percentage**, e.g. CH 10 at 90% → **gets 9**.
- **Net** → absolute CH (× main-game %).
- **SO** → CH **relative to the low** handicapper (low plays off scratch), × %.

## Symbols (from turn 12)

Consistent circle/square + stroke-dot vocabulary across all three:
- Under par / par / bogey / double+ shapes stay constant.
- **Gross**: shapes vs par, no dots.
- **Net**: shapes vs *net*, stroke dots shown.
- **SO**: gross shapes, dots front-and-centre (the match-play read).
