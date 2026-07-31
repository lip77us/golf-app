# Design-system card taxonomy — handoff to code

Design owns two lines in every card file. Bake them into the source once and re-sends will preserve filing.

**Line 1 — the `@dsCard` comment. Must be the FIRST line of the file, before `<!doctype html>`.**

```html
<!-- @dsCard group="<Group>" name="<Label>" subtitle="<one line>" -->
```

`group` is matched verbatim, so spacing and the literal `&` matter: `group="Buttons & chips"`, not `&amp;`. A group name that doesn't match an existing one silently creates a new group — that's what produced the stray `Patterns` and `Screens` groups in the last two batches.

**Line 2 — the back link, immediately after `<body>`.**

```html
<a href="../index-contents.html" style="position:fixed;top:12px;right:14px;z-index:99;display:inline-flex;align-items:center;gap:6px;background:#FFFFFF;border:1.5px solid #D3DED6;border-radius:999px;padding:6px 13px 6px 11px;font:500 12px/1 'Spline Sans',system-ui,sans-serif;color:#0F6E56;text-decoration:none;box-shadow:0 1px 3px rgba(11,31,26,.08)">&#8592; Contents</a>
```

`../index-contents.html` is correct for any card one directory down (`components/`, `patterns/`, `screens/`, `foundations/`). A card at the project root uses `index-contents.html`.

## Groups

Thirteen, in display order. New cards pick one of these; if none fits, ask rather than inventing a group.

- **Overview** — 1 cards
- **Foundations** — 4 cards
- **Buttons & chips** — 2 cards
- **Inputs & fields** — 4 cards
- **Scoring controls** — 3 cards
- **Money & settlement** — 4 cards
- **Layout & feedback** — 3 cards
- **People & teams** — 3 cards
- **Games** — 5 cards
- **Scorecards & leaderboards** — 8 cards
- **Rounds** — 6 cards
- **Tournaments** — 2 cards
- **Account & setup** — 5 cards

Grouping is by what a card *is*, not which folder it lives in — `patterns/sixes-matches.html` sits in Games with the Sixes setup screen; `screens/scorecard-landscape.html` sits with the scorecard patterns. Folder paths are unchanged and don't need to move.

## The map

### Overview

- `index-contents.html` — **Contents** · Every card in this system, by group — start here

### Foundations

- `components/halved-mark.html` — **HalvedMark** · Brand mark badge — 'On Halved' / halved-hole marker
- `foundations/colors.html` — **Colors** · Halved palette — sage / pine / mint + semantic + team
- `foundations/spacing-radii.html` — **Spacing & radii** · Corner radii, border weight, 4-pt spacing scale
- `foundations/typography.html` — **Typography** · Schibsted Grotesk headings · Spline Sans body · tabular figures

### Buttons & chips

- `components/buttons.html` — **Buttons** · GolfPrimaryButton · HalvedCtaButton · Outlined · loading
- `components/chips.html` — **Game chips** · GameChip (read-only) · GameSelectableChip (pine-selected)

### Inputs & fields

- `components/app-bar-text-field.html` — **GolfAppBar & GolfTextField** · Centred app bar + the canonical text field states
- `components/course-search-field.html` — **CourseSearchField** · One-box course picker → 'Playing today' card
- `components/handicap-mode-selector.html` — **HandicapModeSelector** · Net / Gross / Strokes-Off segmented + net-% slider
- `components/tee-assignment.html` — **TeeAssignment** · TeePicker + TeeAssignmentList — grouped by sex, warn until set

### Scoring controls

- `components/capture-controls.html` — **Capture controls** · SpotsDots (⊖ N ⊕) and Skins junk stepper
- `components/inline-score-picker.html` — **InlineScorePicker** · Horizontal per-hole score picker, centred on net par
- `components/score-notation.html` — **Score notation** · NetScoreButton — circle under par, square over, + handicap dots

### Money & settlement

- `components/notes.html` — **Money notes** · MaxLiabilityNote · NetDoubleBogeyCard
- `components/payout-config.html` — **PayoutConfigField** · Paid places + amounts, balance row, auto-suggest
- `components/settlement-receipt.html` — **Settlement receipt** · The signature moment — deep-pine tile, cream text, mint figures, closing quip
- `components/stake-field.html` — **StakeField** · Round stake input + 'play for fun' opt-in

### Layout & feedback

- `components/chat-button-drawer.html` — **RoundChatButton & AppDrawer** · Unread-badge chat icon + the app navigation drawer
- `components/messages.html` — **InlineMessage & ErrorView** · error / warn / info / success + full-screen error
- `components/section-card.html` — **SectionCard** · Outlined card with brand-primary section title

### People & teams

- `components/player-search.html` — **UnifiedPlayerSearch** · Add a golfer — roster → find on Halved → create guest
- `components/team-splitter.html` — **TeamSplitter4** · Reorderable 4-player team picker — Blue (top 2) vs Orange
- `screens/ryder-cup-draft.html` — **Cup draft** · RyderCupDraftScreen — team rosters + Lock Draft

### Games

- `patterns/sixes-matches.html` — **Sixes matches** · _SixesMatchGrid — three rotating 2v2 segment cards
- `screens/game-setup-skins.html` — **Game setup (Skins)** · SkinsSetupScreen — handicap, options, payout, stake
- `screens/rabbit-play.html` — **Rabbit (play)** · RabbitScreen — holder banner, score card, outcome, segments, by-hole grid
- `screens/rabbit-setup.html` — **Rabbit (setup)** · RabbitSetupScreen — mode, match format, stroke allocation, extra rabbit, stake
- `screens/sixes-setup.html` — **Sixes (setup)** · SixesSetupScreen — 2v2 across 3 segments, Classic/High-Low, allocation

### Scorecards & leaderboards

- `patterns/leaderboard-cards.html` — **Leaderboard cards** · Stroke Play net-to-par table + Skins group card
- `patterns/leaderboard-rabbit.html` — **Leaderboard — Rabbit** · _RabbitGroupCard — holder/money rows, segment breakdown, by-hole winner strip
- `patterns/leaderboard-sixes.html` — **Leaderboard — Sixes** · _SixesGroupCard — per-match score + who-beat-whom + money
- `patterns/leaderboard-stroke-play.html` — **Leaderboard — Stroke Play** · _LowNetView — Gross / Net / Strokes-off selector (SO only when the round plays it)
- `patterns/scorecard-grid.html` — **ScorecardGrid** · Full-group landscape scorecard — handicap dots, net, OUT/IN/TOT
- `patterns/shareable-scorecard.html` — **ShareableScorecard** · Portrait, image-capture scorecard (its own paper inks)
- `screens/leaderboard.html` — **Leaderboard & settlement** · LeaderboardScreen — tabs, net-to-par table, Settlement
- `screens/scorecard-landscape.html` — **Scorecard (landscape)** · RoundLandscapeScorecard — full-group 18-hole grid

### Rounds

- `patterns/shared-round-card.html` — **Round list cards** · SharedRoundCard + Observing flag + Live pill
- `screens/create-round.html` — **Create round** · CasualRoundScreen — course + primary/side game picker
- `screens/home-casual-rounds.html` — **Casual Rounds (home)** · CasualRoundsListScreen — Active/Completed list + New Round
- `screens/round-feed.html` — **Round feed** · RoundFeedScreen — chat bubbles + server event cards
- `screens/round-hub.html` — **Round hub** · RoundScreen — round info + foursome card + Complete Round
- `screens/score-entry.html` — **Score entry** · ScoreEntryScreen — hole card, inline picker, game status

### Tournaments

- `screens/tournament-leaderboard.html` — **Tournament leaderboard** · TournamentLeaderboardScreen — cross-round championship
- `screens/tournament-wizard.html` — **Tournament wizard** · NewRoundWizard — groups & tees (drag to assign)

### Account & setup

- `screens/login-otp.html` — **Phone login** · LoginScreen — phone-first sign-in + OTP step
- `screens/manage-courses.html` — **Manage courses** · ManageCoursesScreen — course list + paste/import
- `screens/my-golfers.html` — **My Golfers** · PlayerListScreen — roster, On-Halved badge, invite, add
- `screens/onboarding.html` — **Onboarding** · OnboardingWizard — pick your first game
- `screens/settings-profile.html` — **Profile / Settings** · SettingsScreen — info, home course, prefs, delete

## When a group changes

Design moves cards between groups as the system settles — Cup draft moved out of Games into People & teams, and the leaderboard cards were split out of Patterns. When that happens I'll send the file path and its new group; update the `@dsCard` line in source so the next re-send keeps it.

## Also design-owned

`index-contents.html` (the Overview → Contents card) is generated from this map — it lists every card, grouped, each entry linking to its file. Code doesn't need to maintain it; I'll regenerate it when the map changes. It has no back link of its own since it *is* the index.
