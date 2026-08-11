# Handoff: Cup flow redesign

## Overview

The Triple Cup tournament flow in Halved, resequenced ahead of the September 2026 Cup event.
This is an **edit of an existing 28-step flow**, not a new feature. Seven steps replace the
wizard's front half, five screens collapse into one group builder, and the play surfaces
get a lighter pass.

Read in this order:

1. `HANDOFF.md` — the spec. Diff-shaped: every entry names what ships today, what it becomes,
   and which file to look at. Phases are ordered by deadline.
2. `after/cup-create-flow-map.html` — the diagnosis all of it comes from, plus the divergence
   table for the other three tournament families.
3. The screen files themselves.

## About the design files

Everything in `after/`, `before/` and `foundations/` is a **design reference written in HTML** —
a prototype of intended look and behaviour, not production code to lift. The app is
**Flutter/Dart** (`lib/theme/halved_brand.dart` holds the live palette); the job is to recreate
these screens in that codebase using its existing widgets, theme and patterns.

Each HTML file opens standalone in a browser. Most carry a **notes column beside the phone
frame** explaining the intent, the shipped behaviour it replaces, and any open question. Read the
notes — they carry decisions the pixels don't. The phone frame itself (390 × 812, iPhone 13 mini)
is presentation scaffolding, not a component.

A "← Contents" link in the corner of some files points at the design system index and will 404
in this bundle. Ignore it.

## Fidelity

**High-fidelity.** Final colours, type, spacing and copy. Layout, hierarchy and exact strings
should carry over as drawn. Where a screen shows interaction (tapping a golfer into a group seat,
switching sides on the draft), the behaviour is drawn deliberately and described in the notes
column — implement the behaviour, not just the still.

Two things are deliberately *not* final:
- **Net skins and the Nassau press** on the group-bets tab. Not specified — do not build them.
- **Pairings** (two-man tournaments). Named by the wizard, no screen exists. See "Not drawn yet"
  in `HANDOFF.md`. Do not invent it.

The group-bet **attach path** — previously the open mechanism — is now drawn at
`after/group-bet-attach.html`. It reuses the **multi-group skins** attach control.

## What's in this bundle

```
HANDOFF.md              the spec — phased, diff-shaped
README.md               this file
after/                  the redesign, 17 screens
before/                 the shipped build, captures 01–28 recreated as HTML,
                        plus set-tees-standalone.html (the standalone Set Tees screen)
foundations/            colours, typography, spacing & radii
```

Numbers in `HANDOFF.md` (`13`, `24`…) always mean the file of that number in `before/`.

### after/ — screen index

| File | Step | Purpose | Replaces |
|---|---|---|---|
| `cup-wizard-step1.html` | 1 | Type & format. Type is the scoring unit — side, golfer, pair or group — and the format sets it. The rest of the step list is derived from the answer. | `13`, `14` |
| `cup-event-details.html` | 2 | Name, home course, and one round per date. Dates create rounds. | `13`, `15` |
| `cup-design-teams.html` | 3 | Team count, names, badges and colours in one place. | `17` |
| `cup-handicap.html` | 4 | Mode only (Net / Gross / SO Low), allowance per segment. | `16` |
| `cup-games-by-round.html` | 5 | Format and points per segment, per round. No group-count field. | `19`, `28` |
| `cup-side-game.html` | — | Field-wide games only. Struck with a stated reason when the format is exclusive. | `18` |
| `cup-review.html` | 6 | Review & save. Names what remains; absorbs the created screen. | `20`, `21` |
| `ryder-cup-draft.html` | 7 | Draft board. Lock disabled until every side is legal. | `22` |
| `draft-add-players.html` | 7 | Add players to a side. Side switcher, side size set here, group count derived from it. | `23` |
| `group-builder.html` | — | One card per group: golfers, tees, tee time, start format, group bets. | `24`, `25`, `26`, standalone Set Tees |
| `round-groups.html` | — | Groups for this round; unassigned golfers by name; Start Round states its blocker. | `27` |
| `cup-round-hub.html` | play | Team chips, aligned tee/CH columns, score entry scoped by role. | `05` |
| `cup-leaderboard.html` | play | Competition selector split from view tabs; segment results as cells. | `04` |
| `cup-hub.html` | play | Live score on the tournament card; one primary action plus a grouped disclosure. | `01` |
| `group-bet-attach.html` | play | Attach a game to the foursome. One Attach to option — this group, several groups, or the tournament. Never two. | — |
| `leaderboard-group-bets.html` | play | Skins, Nassau, rabbit settled from gross already entered. A tab at group scope. | — |
| `cup-create-flow-map.html` | — | Diagnosis and divergence table. Reference, not a screen to build. | — |

## Interactions & behaviour

Per-screen behaviour lives in each file's notes column and in `HANDOFF.md`. The rules that cut
across screens:

- **The step list is derived, never hardcoded.** Type decides whether draft, teams and match
  selection exist at all, so the progress indicator ("3 of 7") must be computed from the chosen
  type. Kill the hardcoded "4 of 4".
- **Group count is never asked.** It falls out of side size (set on the draft) and roster size.
- **Nothing is disabled without saying why.** Lock Draft, Start Round and Next each state their
  blocker in place rather than sitting greyed and silent.
- **Tee time defaults to previous group + 10 minutes.** The clock dial is doing work for a value
  that is nearly always predictable.
- **Never render an enum raw** — `triple_cup` must not reach the screen.
- **Role scopes score entry.** A TD can enter scores for any group; a player sees only his own.
  Open question, flagged for product: whether a TD editing another group's card is attributed.

## State

The wizard's model, in the order it fills:

| State | Set on | Consumed by |
|---|---|---|
| `type` / `format` (scoring unit) | Step 1 | Step list derivation, leaderboard shape, group-bet availability |
| `name`, `homeCourse`, `rounds[]` (one per date) | Step 2 | Everything downstream; course inherits per round with override |
| `teams[]` (count, name ≤ 16 chars, colour, badge) | Step 3 | Draft, leaderboard, round hub |
| `handicapMode`, per-segment allowance | Step 4 | Scoring |
| per-round, per-segment `format` + `points` | Step 5 | Leaderboard, round hub |
| `tournamentSideGame` | Side game step | Suppressed entirely when the format is exclusive |
| `sideSize`, rosters | Step 7 draft | **Group count derives from these** |
| groups (golfers, tees, tee time, start format, bets) | Group builder | Round start |

Rules the state must enforce: team colours lock once taken; badge collisions warn but do not
block; the drafted-golfer count runs against roster size and shows who holds each golfer;
Lock Draft requires every side legal.

## Design tokens

Live values from `lib/theme/halved_brand.dart`. Rendered specimens in `foundations/`.

**Brand** — deepPine `#0B1F1A` (primary text, dark tile) · pine `#0F6E56` (structure, selected
state) · mint `#1D9E75` (accent) · brightMint `#3BD89A` (CTA, live, "the hole" — one per screen)
· surface `#EEF3EE` · card `#FFFFFF` · cardBorder `#D3DED6` · muted `#5C6B62` (secondary text)
· cream `#F3F1EA` · ink `#06120E`

**Semantic** — win `#3BD89A` · owe `#F0916E` · warning `#B24225` · disabledFill `#D3DAD5`
· disabledText `#93A099`

**Team palette** — six named colours, stored by name and resolved through one palette:
Red · Blue · Green · Orange · Yellow · Purple. No custom hex.

**Team / game** — team1 `#1976D2` · team2 `#EF6C00` (colour-blind-safe pair) · win green.700
`#388E3C` · loss red.700 `#D32F2F` · neutral grey.600 `#757575`. Green/red/grey mean
win/loss/neutral and never identify a team.

**Type** — headings Schibsted Grotesk, body and labels Spline Sans, both via google_fonts.
Empty-state title 26/700 · section head 22/600 · app-bar title 20/600 (Grotesk);
button label 16/700 · body 15/400 · label-meta 12.5/600 uppercase +0.4px (Spline).
Money and scores use tabular figures.

**Radii** — chip 12 · CTA 16 · card 18 · pill 999.
**Spacing** — 4-pt grid: 4, 8, 12, 16, 24, 32.
**Borders** — cards and selected controls 1.5 px in cardBorder.
**Buttons** — primary height 52; bright-mint CTA height 54.

Selected chips and segments are **pine, never mint**.

## Assets

None. No images or icon files — every glyph in the mocks is a text character or CSS shape. Fonts
load from Google Fonts in the HTML; the app already has both families via `google_fonts`.

## Do not touch

Shipping as-is, no changes requested: `02` Lock draft · `06` TD menu · `07` Remove no-show ·
`08` Swap tee position · `09` Championship tab · `10` Overview · `11` Details · `12` My Foursome.

`03` "Set up cup round" is **retired** — both its questions are answered in Phase 1 now.
