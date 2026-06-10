# Quick-Start Wizard for new users — kickoff brief

**Goal:** after a brand-new user signs up (phone OTP), walk them through the
*minimum* needed to start their first round, instead of dropping them into the
app with an empty account and no obvious next step.

This is a planning/handoff doc — implementation is a fresh session's job.

## The current "start a round" flow (what a wizard must cover)

Entry point: **`mobile/lib/screens/casual_round_screen.dart`** (the casual game
picker + round setup). To start a casual round a user needs, in order:

1. **A course (+ tee)** — `Round.course` is account-owned; new accounts have none.
2. **Players** — 2–4 golfers from the account roster (the user + ≥1 other).
3. **A game** — chosen from the catalog (`mobile/lib/game_catalog.dart`).
4. **Game setup** — per-game screen (handicap mode, stake/“play for fun”, teams).
5. **Start** → round/score-entry.

### Where brand-new users get stuck
- **No course.** Already handled with an empty-state: casual_round_screen shows
  “Find your course to get started” → `CatalogAddScreen` (catalog-first search,
  falls back to GolfCourseAPI import), then auto-selects the new course.
- **No other golfers.** The roster has only the signup user. Inline “Add a
  golfer” → `PlayerFormScreen` (pops the saved `PlayerProfile`, auto-selects).
- These un-blockers exist but are *discovered*, not *guided* — the wizard should
  sequence them so the user can’t miss a step.

## Pieces to REUSE (don’t rebuild)
- **Course:** `CatalogAddScreen` (“Find your course”) — search catalog +
  `addCatalogCourse`; returns a `CourseInfo`.
- **Golfers:** `PlayerFormScreen` — add a login-less golfer (name + handicap,
  phone optional); pops `PlayerProfile`.
- **Games:** `game_catalog.dart` `GameMeta` (sizes, `supportsSize(n)`,
  exactPlayers, the “Who’s playing?” size filter).
- **Per-game setup screens** (e.g. `skins_setup_screen.dart`, `nassau_setup_
  screen.dart`, `low_net_setup_screen.dart`) — already gate Start on a
  stake/“play for fun” via the shared `StakeField` widget.
- **Round creation** logic already in casual_round_screen (course+tee+players →
  create round → route to the game’s setup).

## Proposed wizard shape (for discussion)
A linear stepper for first-run, reusing the screens above as steps:

1. **Welcome** — one screen: “Track your golf bets. Let’s set up your first
   round.” (skippable).
2. **Add a course** — embed/launch `CatalogAddScreen`.
3. **Add golfers** — “Who are you playing with?” → add 1–3 via `PlayerFormScreen`
   (the user themselves is already a Player). Enforce ≥2 total.
4. **Pick a game** — show a *short* curated list for beginners (e.g. Skins,
   Nassau, Stroke Play) rather than the full catalog; “more games” expands.
5. **Quick setup** — the game’s own setup screen (handicap default Net 100%,
   stake or “play for fun”).
6. **Start** → score entry.

### Key design decision (resolve first)
**Reuse vs. parallel flow.** Prefer wrapping the *existing* casual_round_screen
pieces in a guided stepper over building a parallel round-creation path —
otherwise round-creation logic forks and drifts. Likely cleanest: a first-run
“guided mode” flag that drives casual_round_screen step-by-step, or a thin
`OnboardingWizard` that calls the same building blocks.

### Trigger / re-entry
- Show automatically after `ProfileSetupScreen` for a brand-new account (the
  `is_new_account` path already exists in the auth flow).
- Also reachable later from the drawer (“Start your first round” / help) so it’s
  not one-shot.
- Don’t block the app — “Skip” always available; never trap the user.

## Open questions for the new session
- Auto-launch after signup, or a dismissible “Get started” card on the home/
  rounds screen? (Card is lower-risk, less modal.)
- Which 2–3 games to feature for beginners?
- Does the wizard need to handle the **empty rounds list** state too (a user who
  skipped it), or is that a separate empty-state?
- Pure-mobile (no backend changes expected — all the endpoints exist).

## How to start the new session
> “Read docs/onboarding-wizard.md. Let’s build the quick-start wizard for new
> users — start by proposing the stepper structure and which existing screens we
> reuse, then we’ll implement.”
