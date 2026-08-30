# Halved — Screen & Flow Inventory

> Reverse-engineered from the Flutter source at `mobile/lib`. Every claim is derived from routes, screens, and components as implemented (`golf_mobile` v2.5.0+18). Names match the code exactly. Where behavior is ambiguous, dead, or inconsistent, it is flagged in **§7 Open Questions** rather than guessed.

---

## 1. App overview

**Halved** is an iOS-first Flutter mobile app (package `golf_mobile`, display name "Halved") for tracking golf gambling games during a round — a group scorecard plus per-game money settlement. It talks to a Django REST backend (`ApiClient`, `lib/api/client.dart`) over HTTP, caches to a local SQLite database (`sqflite`) with an **offline queue** drained by `SyncService` when connectivity returns (`connectivity_plus`), receives FCM push (`PushService`), and handles universal links (`halved.golf/watch/<token>` → a round's read-only leaderboard) via `DeepLinkService`.

**Platform/framework:** Flutter (Dart SDK ≥3.3), Material 3, `provider` for state, forced light theme. Builds target iOS, Android, and desktop/web (sqflite FFI on desktop).

**State layer (4 providers, wired in `main.dart` `MultiProvider`):**
- `AuthProvider` — phone-OTP + legacy password auth, session token, `isLoggedIn`/`isAdmin`/`isSupport`, account deletion.
- `RoundProvider` — the main round/scorecard state: `loadRound`, `loadScorecard`, `submitHole`, and per-game load/summary methods (`loadSkins`/`skinsSummary`, `loadSixes`, `loadVegas`, `loadFourball`, `loadStableford`, `loadHonors`, `loadSpots`, …).
- `MessageProvider` — per-round chat/event feed (one round open at a time).
- `SettingsProvider` — local device prefs (`netStyleEntry`, `autoAdvanceHole`, `onboardingDone`, per-help-sheet "seen" flags).
- `SyncService` — connectivity monitor + pending-write queue drain (offline support).

**Primary user loop:** sign in by phone → land on the Tournaments/Casual home → create a round (pick course, players, tees, a **primary game** + optional **side games**) → open the **round hub** (`RoundScreen`) → enter scores hole-by-hole (`ScoreEntryScreen` or a game-specific play screen) → watch the **leaderboard**/money settle → complete the round. Rounds can be **casual** (single foursome, no tournament) or part of a **tournament** (multiple foursomes/rounds, cup formats).

**Casual game model (important for reading the setup/entry screens):** a casual round has **exactly one PRIMARY game** (owns score entry) plus **zero or more SECONDARY "side games"** (pure leaderboard overlays computed from the entered scores; some, like Spots, add a capture control in score entry). The primary is stored on the round (`Round.primaryGame`); `resolvePrimary()`/`primaryGameOf()` in `game_catalog.dart` resolve it. Handicap modes throughout are **Net (with %)**, **Gross**, and **Strokes-Off-Low**.

---

## 2. Navigation map

**Framework:** single `MaterialApp` with `onGenerateRoute: _router` (`main.dart`) — ~70 named routes, no nested `Navigator`s or tab bar. There is **no bottom tab bar**; top-level navigation is the **`AppDrawer`** (hamburger) plus in-screen buttons/FABs. A global `navigatorKey` lets `AuthProvider` redirect on 401, and `PushService`/`DeepLinkService` push from outside the tree.

**Entry point & boot:** `initialRoute: '/splash'` — and `onGenerateInitialRoutes` *forces* `/splash` even when the platform hands us a cold-launch deep link. `SplashScreen` runs an animation, then `_navigateAfterSplash` does a **version compatibility check** (`ApiClient.getVersion`; a too-old build gets a non-dismissible "Update Required" dialog → App Store) and routes to:
- `/tournaments` if `AuthProvider.isLoggedIn`, else
- `/login`.

**Auth gate:** any 401 → `AuthProvider` clears the token; `main.dart` `_onAuthChanged` fires `pushNamedAndRemoveUntil('/login')` and clears the local cache on a logged-in→logged-out transition. `onUnknownRoute` also falls back to `LoginScreen` (logged, named `/unknown`).

```
/splash  (SplashScreen) ── entry, forced ──┐
                                            │ version check
        ┌───────────────────────────────────┴─────────────┐
   not logged in                                     logged in
        │                                                   │
   /login (LoginScreen, phone OTP)                    /tournaments (TournamentListScreen) ── home
        │  ├─ /verify-otp (OtpVerifyScreen)                 │
        │  │      └─ /profile-setup (ProfileSetupScreen, new accounts only)
        │  └─ (legacy password login: see §7 — screen/route no longer present)
        │
   AppDrawer (global, from home screens & round hub):
     ├─ Casual Rounds ........ /casual-rounds (CasualRoundsListScreen)
     ├─ Tournaments .......... /tournaments  (TournamentListScreen)
     ├─ Start your first round /onboarding   (OnboardingWizard)   [conditional: ages off after wizard done or 15 days]
     ├─ My Golfers ........... PlayerListScreen (pushed) ─→ PlayerFormScreen (pushed)
     ├─ Invite Friends ....... native share sheet (shareInvite; no screen)
     ├─ Profile .............. /settings (SettingsScreen)
     ├─ Manage Courses ....... /manage-courses (ManageCoursesScreen)   [admin only]
     │     ├─ ManageCourseTeesScreen (pushed) ─→ TeePasteScreen (pushed)
     │     ├─ CoursePasteScreen (pushed)
     │     └─ /course-search (CourseSearchScreen) [admin full-DB import]
     ├─ Suggest a Game ....... /suggest-game (GameSuggestionScreen)
     ├─ About ................ AboutDialog (no screen)
     ├─ Support: Open Round .. /support-lookup (SupportLookupScreen)   [support staff only]
     └─ Sign Out ............. AuthProvider.logout → /login

   CREATE-A-ROUND paths:
     Casual: CasualRoundsListScreen ─(FAB)→ CasualRoundScreen (pushed)
                 └─ picks course + players + primary/side games → creates round → game setup route → /round
     Onboarding: OnboardingWizard → single-game first round → /round
     Tournament: TournamentListScreen ─→ NewRoundWizard (pushed)  and/or  CupRoundSetupScreen (pushed)
                 └─ RyderCupDraftScreen (pushed) ─→ RyderCupScoreboardScreen (pushed)

   ROUND HUB:  /round (RoundScreen) ── the per-round home; branches per foursome to:
     ├─ /score-entry (ScoreEntryScreen)            ── universal per-hole entry [landscape-wrapped]
     ├─ game SETUP routes (before play):
     │    /sixes-setup /points-531-setup /vegas-setup /fourball-setup /skins-setup
     │    /spots-setup /honors-setup /wolf-setup /rabbit-setup /triple-cup-setup
     │    /multi-skins-setup /nassau-setup(-18|-nine) /irish-rumble-setup /low-net-setup
     │    /stableford-setup /pink-ball-setup /match-play-setup /three-person-match-setup
     │    /setup-round-players (SetupRoundPlayersScreen)  /confirm-tees (ConfirmTeesScreen)
     ├─ game PLAY routes [each wrapped in RoundLandscapeScorecard]:
     │    /points-531 /skins /wolf /rabbit /triple-cup /multi-skins
     │    /nassau /pink-ball /match-play /quota-nassau
     ├─ /leaderboard (LeaderboardScreen) [landscape-wrapped] ─→ ShareScorecardScreen (pushed)
     ├─ /round-feed (RoundFeedScreen)  ── chat/event feed (RoundChatButton)
     └─ (completed rounds) the Enter Scores button becomes "View Scorecard" → read-only /score-entry

   TOURNAMENT views:
     /tournament-leaderboard (TournamentLeaderboardScreen)
        ├─ /tournament-low-net-setup (TournamentLowNetSetupScreen)
        └─ TournamentStablefordSetupScreen (pushed)
```

**Auth-gated:** everything except `/splash` and `/login` (and the public universal-link leaderboard) requires a session token; the drawer's Manage Courses (admin), Support: Open Round (support) are role-gated.

**Conditional routing:** first-run vs returning is decided at splash (login state). "Start your first round" drawer entry ages off. Per-foursome routing in the round hub branches heavily on `round.isCupRound` (cup rounds hide the TD per-foursome menu and game-config buttons) and on the resolved **primary game**.

**Landscape wrapper:** the per-foursome play routes + `/leaderboard` are wrapped in `RoundLandscapeScorecard` — rotating the phone to landscape reveals the full-group `ScorecardGrid`. There is no orientation lock.

---

## 3. Screen catalog

One entry per screen, in navigation order. Bullet fragments; names exactly as in code. States marked "not handled" are genuinely absent in the source.

---

### 3.1 · Auth, home & roster

### SplashScreen
- **File:** lib/screens/splash_screen.dart
- **Purpose:** Branded launch screen that animates the Halved mark/wordmark, then hands off to the auth-gated first route.
- **Layout & regions:** Full-screen `Scaffold` (`Halved.surface` bg), no app bar; centered `Column` — `SvgPicture.asset('assets/icon/halved_mark.svg')` badge (132x132, rounded-clipped) above a `Text('Halved')` wordmark (Schibsted Grotesk 40/w700). No footer/FAB.
- **Components used:** `SvgPicture` (flutter_svg); `Halved` brand tokens (theme/halved_brand.dart); `GoogleFonts.schibstedGrotesk`. No lib/widgets shared components.
- **Data:** None displayed from providers/API. Purely visual. Drives a 2200ms `AnimationController` (fade-in 0–0.27, fade-out 0.77–1.0); `onComplete` callback (passed from main.dart) runs `_navigateAfterSplash()` after the animation.
- **States:** loading = the animation itself (no spinner). No empty/error/permission/offline handling in this widget — not handled. (The version-check / force-upgrade dialog and routing live in main.dart `_navigateAfterSplash`, not here.)
- **Interactions & exits:** No tappable elements. On animation completion fires `widget.onComplete()` → main.dart `_navigateAfterSplash()`, which `pushReplacementNamed('/tournaments')` if logged in else `'/login'` (or shows a blocking "Update Required" dialog).
- **NOTE:** Doc comment says it is shown mainly on desktop while iOS uses the native LaunchImage, but `initialRoute: '/splash'` in main.dart routes every platform through it.

### LoginScreen
- **File:** lib/screens/login_screen.dart
- **Purpose:** Phone-first sign-in — user enters cell number (+ optional name for new accounts) to request an SMS one-time passcode.
- **Layout & regions:** `Scaffold` (no app bar) → `SafeArea` → centered `SingleChildScrollView` (32 padding) → `Form` `Column`: `Icon(Icons.golf_course)`, `Text('Halved')`, subtitle "Sign in with your phone number", phone `GolfTextField`, optional-name `GolfTextField`, inline error text, `GolfPrimaryButton('Send code')`, SMS-consent disclosure text.
- **Components used:** `GolfTextField`, `GolfPrimaryButton` (both lib/widgets/). No app bar/drawer/FAB.
- **Data:** Local `TextEditingController`s for phone + name; no data displayed. Watches `AuthProvider` for `loading` / `error`. Submit calls `AuthProvider.requestOtp(phone)` (returns dev debugCode). Phone validator requires ≥10 digits.
- **States:** loading = `GolfPrimaryButton.loading` bound to `auth.loading`. error = `auth.error` shown as red inline text. No empty/permission/offline-specific handling — not handled (network failure surfaces via `auth.error`).
- **Interactions & exits:** "Send code" button / name-field submit → `_sendCode()` → `auth.requestOtp`; on success `pushNamed('/verify-otp', arguments: {phone, name, debugCode})`. No other exits.
- **NOTE:** Header comment references a deactivated password path (`PasswordLoginScreen` / `/login-password`), but this screen has no link to it — password login is not reachable from here.

### OtpVerifyScreen
- **File:** lib/screens/otp_verify_screen.dart
- **Purpose:** Step 2 of phone sign-in — enter the 6-digit SMS code to authenticate (and route new accounts through profile setup).
- **Layout & regions:** `Scaffold` with `AppBar(title: 'Enter code')` → `SafeArea` → centered `SingleChildScrollView` → `Form` `Column`: prompt "We sent a 6-digit code to <phone>", optional "Dev code: …" hint, code `GolfTextField`, inline error, `GolfPrimaryButton('Verify')`, `TextButton('Resend code')`.
- **Components used:** `GolfTextField`, `GolfPrimaryButton` (lib/widgets/). Standard `AppBar`.
- **Data:** Ctor args `phone`, `name?`, `debugCode?`. Local `_codeCtrl` + `_debugCode` state. Watches `AuthProvider` (`loading`, `error`, `isLoggedIn`, `isNewAccount`). Verify calls `AuthProvider.verifyOtp(phone, code, name:)`; resend calls `AuthProvider.requestOtp(phone)` and refreshes the dev hint.
- **States:** loading = `GolfPrimaryButton.loading` / resend disabled while `auth.loading`. error = `auth.error` inline red. Code validator requires exactly 6 digits. No offline/permission handling — not handled.
- **Interactions & exits:** "Verify" / code submit → `_verify()`; on `auth.isLoggedIn` → `pushNamedAndRemoveUntil('/profile-setup')` if `isNewAccount` else `'/tournaments'`. "Resend code" → `_resend()` (re-requests OTP, shows "A new code was sent." snackbar). Back arrow pops to LoginScreen.

### ProfileSetupScreen
- **File:** lib/screens/profile_setup_screen.dart
- **Purpose:** First-run profile setup for brand-new phone accounts — confirm name/short name/handicap index/default tee and name-discoverability before entering the app.
- **Layout & regions:** `Scaffold` with `AppBar(title: 'Set up your profile', automaticallyImplyLeading:false)` + a "Skip" `TextButton` action → `SafeArea` → `SingleChildScrollView` → `Form` `Column`: welcome text, name `GolfTextField`, short-name `GolfTextField` (auto-fills initials), handicap-index `GolfTextField`, "Default tees" `SegmentedButton<String>` (Men's/Women's), "Findable by name" `SwitchListTile`, inline error, `GolfPrimaryButton('Continue')`.
- **Components used:** `GolfTextField`, `GolfPrimaryButton` (lib/widgets/); `PlayerProfile.computeInitials` (api/models.dart); `SegmentedButton`, `SwitchListTile`.
- **Data:** Seeds fields from `AuthProvider.player` (suppresses the "New Golfer"/"NG" default). Local state: `_sex`, `_discoverable`, `_saving`, `_error`. Save calls `AuthProvider.client.updatePlayer(id, name, shortName, handicapIndex, sex)` then `auth.applyPlayer`; if discoverable turned off, `client.setDiscoverableByName(false)` (best-effort, swallowed). Handicap validator: number in [-10, 54].
- **States:** loading = `GolfPrimaryButton.loading` (`_saving`). error = `_error` inline red ("Could not save. Please try again."). If `auth.player == null`, save no-ops straight to the app. No offline/permission-specific handling — not handled.
- **Interactions & exits:** "Continue"/`_save` → on success `_goToApp()`: `pushNamedAndRemoveUntil('/tournaments')` then, if `isNewAccount`, `pushNamed('/onboarding')`. "Skip" action → same `_goToApp()` (also lands on onboarding for new accounts). Segmented button and switch mutate local state only.

### OnboardingWizard
- **File:** lib/screens/onboarding_wizard.dart
- **Purpose:** Guided 4-step first-round setup for new accounts (welcome → course → golfers → pick a game), creating a casual round via the shared helper.
- **Layout & regions:** `Scaffold` with `AppBar(title: 'Set up your first round', automaticallyImplyLeading:false)` + "Skip" action → `SafeArea` `Column`: `_StepDots` progress (private), `Expanded` body (`SingleChildScrollView`, switches on `_step`), bottom nav bar (`_buildNav`: Back `OutlinedButton` + primary `FilledButton`). Steps: 0 Welcome (icon + `_miniSteps`), 1 Course (`CourseSearchField`), 2 Golfers (`CheckboxListTile` cards + "Add a golfer"), 3 Game (`ChoiceChip`s + Simple-Skins `StakeField` / other-game card).
- **Components used:** `CourseSearchField`, `StakeField`, `ErrorView`, `HalvedMark` (all lib/widgets/); `game_catalog.dart` (`GameMeta`, `GameIds`, `casualGames`, `gameMeta`, `defaultTeeIdFor`); `createCasualRound` (utils/create_casual_round.dart); `maybeOfferRoundSmsInvite` (utils/golfer_invite.dart). Private widgets: `_StepDots`.
- **Data:** Roster from `AuthProvider.client.getPlayers()` (filters `isPhantom`, auth player auto-selected). Tees from `client.getTees()`. Local state: `_course`, `_players`, `_selected` (≤4), `_game`, `_betCtrl`. Creates a round via `createCasualRound(...)`; Simple-Skins path also calls `RoundProvider.updateRoundBetUnit`, `client.postSkinsSetup(strokes_off/no carryover/no junk)`, `rp.loadSkins`; marks `SettingsProvider.markOnboardingDone()`.
- **States:** loading = `_loadingRoster` full-screen `CircularProgressIndicator`; busy = `_busy` spinner in the nav `FilledButton`. error = `_error` rendered via `ErrorView(friendlyError(...))`. Empty-ish gates: step-2 requires 2–4 golfers; tee-missing → `_teeError` snackbar. No offline/permission handling beyond error view — not handled.
- **Interactions & exits:** "Add a golfer" → pushes `PlayerFormScreen` (returns `PlayerProfile`, auto-selected) then `maybeOfferRoundSmsInvite`. Step nav Back/Next/Get started mutate `_step`. Skins path "Start Round" → `_startSimpleSkins()` → `pushReplacementNamed('/score-entry', arguments: fsId)`. Other games / "Customize the rules instead" → `_continueToSetup(game)` → `pushReplacementNamed('/round', roundId)` then `pushNamed(launch.route, launch.effectiveArgs)`. "Skip" → pops, else `pushReplacementNamed('/tournaments')`.

### TournamentListScreen
- **File:** lib/screens/tournament_list_screen.dart
- **Purpose:** Home hub listing the user's tournaments (Active/Completed) plus cross-account "Shared with you" and "Observing" tournaments, with create/manage actions.
- **Layout & regions:** `Scaffold` with `AppBar(title: 'Tournaments')` + refresh action; `AppDrawer`; body `Column`: Active/Completed `SegmentedButton<bool>` then `Expanded` list (`RefreshIndicator` + `ListView`) with `_sectionHeader`s ("Shared with you" via `SharedRoundCard`, "Observing" via `_observingTournamentCard`, "Your tournaments" via `_TournamentCard`); extended FAB "New Tournament" (admins only).
- **Components used:** `AppDrawer`, `ErrorView`, `SharedRoundCard`, `HalvedLivePill` (lib/widgets/ + theme/halved_brand.dart); `GolfTextField` (in the `_ChangeCupGameDialog`); private widgets `_TournamentCard`, `_RoundTile`, `_PendingRoundTile`, `_ActionButton`, `_ChangeCupGameDialog`. Pushes `NewRoundWizard`, `SetupRoundPlayersScreen`, `TournamentLeaderboardScreen`, `RyderCupDraftScreen`, `RyderCupScoreboardScreen`, `CupRoundSetupScreen`, `TournamentLowNetSetupScreen`, `PlayerListScreen`.
- **Data:** `client.getTournaments()` → `_tournaments`; `client.getPlayingForMe()` (filtered `isTournament`) → `_shared`; `client.getSharedRounds()` (filtered `isTournament`) → `_observing`. Watches `AuthProvider` (`player`, `isAdmin`). Mutations: `deleteTournament`, `postRyderCupChangeGame`, `postRyderCupCalculate`. `_isComplete` derives Active vs Completed.
- **States:** loading = full-screen spinner. error = `ErrorView(isNetwork:, onRetry:_load)`. empty = "No active/completed tournaments." Shared/observing fetches are best-effort (failures swallowed). Silent refresh on app resume + drawer returns. First-load auto-redirect: if no active tournaments, `pushNamed('/casual-rounds')`. No explicit permission/offline states beyond ErrorView — not handled.
- **Interactions & exits:** FAB → `NewRoundWizard` (returns bool → success snackbar). Round tile tap → `pushNamed('/round', roundId)`; pending round "Set Up" → `SetupRoundPlayersScreen`. Championship Leaderboard → `TournamentLeaderboardScreen` or (cup) `_openCupTab` → `pushNamed('/leaderboard', {roundId, initialTabKey:'__bandon_cup__'})`. Cup actions → draft/scoreboard/`CupRoundSetupScreen`/change-game dialog/recalculate. Delete → confirm dialog → `deleteTournament`. `SharedRoundCard` tap → `openSharedRound`; observing card → `openWatchedRound`. Drawer routes to casual-rounds/players/settings/logout.

### CasualRoundsListScreen
- **File:** lib/screens/casual_rounds_list_screen.dart
- **Purpose:** Lists the user's casual rounds (Active/Completed) merged with cross-account "played" and "Observing" rounds, and launches new-round creation/onboarding.
- **Layout & regions:** `Scaffold` (`Halved.surface`) with custom `AppBar` (`kCasualRoundsLabel` title, refresh action); `AppDrawer`; `bottomNavigationBar` = `_buildNewRoundBar` ghost "New Round" (Active tab only); body `Column`: `HalvedSegmented<bool>` Active/Completed toggle then `Expanded` list (`RefreshIndicator` + `ListView.builder` of `_RoundCard`), or `_buildEmptyState`.
- **Components used:** `AppDrawer`, `ErrorView` (lib/widgets/); `HalvedSegmented`, `HalvedCtaButton`, `Halved` tokens (theme/halved_brand.dart); `SvgPicture`; `gamesDisplayLabel`/`gameMeta` (game_catalog + ui_labels); `SyncService` (sync); `appRouteObserver` (utils/route_observer.dart); private `_RoundItem`, `_RoundCard`. Pushes `CasualRoundScreen`, `PlayerListScreen`.
- **Data:** `client.getCasualRounds(status:)` → `_rounds`; `client.getPlayingForMe()` (non-tournament) → `_shared`; `client.getSharedRounds()` (non-tournament) → `_observing`; `_hasAnyRound` checks the other status too. Watches `AuthProvider`. Merges into one date-sorted `_RoundItem` list; dedupes played vs observed (playing supersedes). Mutations: `deleteCasualRound`.
- **States:** loading = full-screen spinner (also shown briefly while sync drains in `_openRound`). error = `ErrorView(isNetwork:, onRetry:)`. empty = branded `_buildEmptyState` (mark badge + "No rounds…" + `HalvedCtaButton` "New Round" + first-timer onboarding link). Silent refresh on resume (`WidgetsBindingObserver`) and on return (`RouteAware.didPopNext`). Shared/observing best-effort. No explicit permission handling — not handled.
- **Interactions & exits:** Card tap → `_openRound` (`pushNamed('/round', roundId)` for completed/not-started/multi_skins; else round hub after waiting on `SyncService`), shared → `openSharedRound`, observing → `openWatchedRound`. Delete icon (creator only) → confirm dialog → `deleteCasualRound`. Bottom "New Round" / empty-state CTA → pushes `CasualRoundScreen` (MaterialPageRoute, not a named route). "First time?…" → `pushNamed('/onboarding')`. Drawer routes to tournaments (popUntil)/players/settings/logout.

### PlayerListScreen
- **File:** lib/screens/player_list_screen.dart
- **Purpose:** Browsable/searchable "My Golfers" roster with add/edit/delete and per-golfer invite.
- **Layout & regions:** `Scaffold` with `AppBar(title: 'My Golfers')` + "Invite friends" and refresh actions; extended FAB "Add Player" (admins only); body `Column`: `SearchBar` then `Expanded` list (`ListView.separated` of `ListTile`s, my card pinned top, `HalvedMark` badge for on-app golfers, invite/delete trailing icons, `Dismissible` swipe-to-delete for admins).
- **Components used:** `ErrorView`, `AppDrawer` (imported), `HalvedMark` (lib/widgets/); `shareInvite`/`shareOriginFrom` (app_drawer.dart); `inviteGolfer`/`maybeOfferGolferSmsInvite` (utils/golfer_invite.dart); pushes `PlayerFormScreen`.
- **Data:** `client.getPlayers()` → `_all`; `_filtered` by `_search` (name/email). Watches `AuthProvider` (`isAdmin`, `player.id`). Shows `p.name`, `p.displayHandicap`, email, `isOnApp` badge. Create/edit via `PlayerFormScreen`; delete via `client.deletePlayer(id)`. User can add/edit/remove golfers (admin) or view read-only (non-admin).
- **States:** loading = spinner. error = `ErrorView(isNetwork:_networkError, onRetry:_load)`. empty = "No players yet. Tap + Add Player." (admin) / "No players yet." / "No matches." (search). permission = non-admins get no FAB, read-only form, chevron instead of delete. Delete PROTECT failures show the API `detail` in an error snackbar. No offline-specific state beyond ErrorView — not handled.
- **Interactions & exits:** Row tap → `_openForm(player:)` → `PlayerFormScreen` (read-only for non-admins); on save reloads + offers SMS invite for new golfers. FAB → `_openForm()` (new). Invite icon → `inviteGolfer`. Delete icon / swipe → `_confirmDelete` → `client.deletePlayer`. App-bar invite → `shareInvite`. No named-route pushes (form is a direct MaterialPageRoute).

### PlayerFormScreen
- **File:** lib/screens/player_form_screen.dart
- **Purpose:** Add or edit a single golfer (name, short name, handicap index, tee sex, phone, email); read-only view for non-admins.
- **Layout & regions:** `Scaffold` with `AppBar` (title "Add Player"/"Edit Player"/"Player Details"); body `SingleChildScrollView` → `Opacity`+`AbsorbPointer` (read-only dim/lock) → `Form` `Column`: name `GolfTextField`, short-name `GolfTextField` (auto-initials), handicap-index `GolfTextField`, "Tee designation" `InputDecorator`+`SegmentedButton<String>` (Men/Women), phone `GolfTextField` (above email intentionally), email `GolfTextField`, inline `ErrorView`, `FilledButton.icon` Save (hidden when read-only).
- **Components used:** `GolfTextField`, `ErrorView` (lib/widgets/); `PlayerProfile.computeInitials` (api/models.dart); `SegmentedButton`.
- **Data:** Ctor args `player?` (null = create) + `readOnly`. Seeds controllers from `player`. Save calls `AuthProvider.client.updatePlayer(...)` (edit) or `createPlayer(...)` (new); pops with the saved `PlayerProfile`. Validators: name required ≥2 chars, short ≤5, handicap number in [-10,54], email format optional.
- **States:** loading = `_saving` spinner in Save button ("Saving…"). error = `_error` via `ErrorView(friendlyError(e))`. permission = `readOnly` dims + `AbsorbPointer` + hides Save. No offline/empty states — not handled.
- **Interactions & exits:** Save → `_save()` → create/update → `Navigator.pop(saved)` returning the `PlayerProfile` to the caller. Segmented button mutates `_sex`. Back arrow pops with null. No named-route exits.

### SettingsScreen
- **File:** lib/screens/settings_screen.dart
- **Purpose:** The "Profile" page — edit own name/short/index, set home course, toggle name-discoverability and per-device score-entry preferences, and delete the account.
- **Layout & regions:** `Scaffold` with `AppBar(title: 'Profile')`; body `Column`: `Expanded` `ListView` with `_sectionHeader`ed sections — "Your info" (`_infoSection`: avatar + on-app row + name/short/index `TextField`s + Save `FilledButton`), "Home course" (`ListTile` → bottom-sheet picker), "Privacy" (`SwitchListTile` "Findable by name"), "Preferences" (`SwitchListTile`s "Net Style Entry", "Auto-advance to next hole"); then a pinned bottom `Divider` + "Delete Account" `ListTile`.
- **Components used:** `CourseSearchField`, `HalvedMark` (lib/widgets/); standard `SwitchListTile`/`ListTile`/`TextField`; bottom sheet via `showModalBottomSheet`.
- **Data:** Watches `SettingsProvider` (`netStyleEntry`, `autoAdvanceHole`) + `AuthProvider.player`. `_discoverable` fetched via `client.me()`. Mutations: `client.updatePlayer` (name/short/index and homeCourse set/clear via `homeCourseId`/`clearHomeCourse`) + `auth.applyPlayer`; `client.setDiscoverableByName`; `settings.setNetStyleEntry`/`setAutoAdvanceHole`; `auth.deleteAccount()`. Shows `me.displayShort`, `isOnApp`, phone, `homeCourseName`.
- **States:** loading = `_saving` spinner in Save button; `_discoverable == null` renders switch disabled with "Checking…" (fetch failure leaves it null/disabled). Save disabled unless `_dirty`. Validation snackbars for empty name / bad index. Discoverable toggle is optimistic with snap-back + error snackbar on failure. Delete failure (e.g. last-admin guard) shows `ApiException.message`. No empty/offline-specific states beyond these — not handled.
- **Interactions & exits:** "Save" → `_saveInfo`. Home-course `ListTile` → `_pickHomeCourse` bottom sheet (`CourseSearchField` select → `updatePlayer`; "Clear home course"). Privacy/Preferences switches → provider/API mutations. "Delete Account" `ListTile` → `_confirmAndDelete` → `auth.deleteAccount()`; the main.dart auth gate then redirects to `/login`. No forward named-route pushes.
- **NOTE:** Reached via `pushNamed('/settings')` and the drawer's "Profile" entry, but the app-bar title and doc comment call it "Profile" (class/route name remain SettingsScreen/`/settings`).

---

### 3.2 · Courses & support

### ManageCoursesScreen
- **File:** lib/screens/manage_courses_screen.dart
- **Purpose:** Admin screen listing the account's imported courses, letting admins delete a course, drill into its tees, or import more.
- **Layout & regions:** `Scaffold` → `AppBar` (title "Courses"; actions: "Paste a scorecard" `IconButton` [`content_paste_go_outlined`], refresh `IconButton`) → body (loading spinner / `ErrorView` / empty-state / course list) → `FloatingActionButton.extended` "Import course" (`add_location_alt_outlined`).
- **Components used:** `ErrorView` (lib/widgets/error_view.dart) + its `friendlyError()` helper; otherwise stock Material (`Scaffold`, `AppBar`, `ListView.separated`, `ListTile`, `CircleAvatar`, `Dismissible`, `AlertDialog`, `RefreshIndicator`, `FloatingActionButton.extended`). No lib/widgets/ form widgets.
- **Data:** Lists `List<CourseInfo>` from `AuthProvider.client.getCourses()`; each tile shows `c.name`, `c.location`, tee-set count and joined `t.teeName` list. Mutations: `deleteCourse(c.id)`. Admin state read from `AuthProvider.isAdmin`. Local state: `_courses`, `_loading`, `_error`.
- **States:** Loading = centered `CircularProgressIndicator`. Error = `ErrorView(message, onRetry: _load)`. Empty = `golf_course` icon + "No courses yet." + hint to import. Permission = non-admins get a bare Scaffold "Only admins can manage courses." (re-checked in `build` so deep-links can't bypass the drawer gate). Offline = folded into error via `friendlyError`; delete failures show a red `SnackBar` (5s for `ApiException` message, e.g. course protected because it hosted rounds). No dedicated offline state.
- **Interactions & exits:** "Paste a scorecard" action → pushes `CoursePasteScreen` (MaterialPageRoute); reloads on `true`. Refresh action / pull-to-refresh → `_load()`. FAB "Import course" → `pushNamed('/course-search')`; reloads on return. Tile tap → pushes `ManageCourseTeesScreen(courseId)` (MaterialPageRoute); reloads if it returns `true`. Trailing delete `IconButton` → `_confirmDelete` dialog then `deleteCourse`. Swipe end-to-start (`Dismissible`) → same confirm + `deleteCourse`.
- **NOTE:** Delete logic is duplicated — the trailing-button path (`_delete`) and the `Dismissible.confirmDismiss` inline block each independently confirm, call `deleteCourse`, and snackbar. Not dead, but two copies of the same flow.

### ManageCourseTeesScreen
- **File:** lib/screens/manage_course_tees_screen.dart
- **Purpose:** Drill-down from ManageCoursesScreen showing one course's tee sets, with add / edit / delete / re-rate.
- **Layout & regions:** `WillPopScope` → `Scaffold` → `AppBar` (title = course name; action "Re-rate tees from a scorecard" `IconButton` [`update_outlined`], shown only when `_course != null`) → body (spinner / `ErrorView` / empty / tee list) → `FloatingActionButton.extended` "Add tee" (`add`, hidden until course loaded).
- **Components used:** `ErrorView` (lib/widgets/); stock Material (`ListView.separated`, `ListTile`, `CircleAvatar` w/ `flag_outlined`, `AlertDialog`, `WillPopScope`, `SegmentedButton` not here). No lib/widgets/ form widgets.
- **Data:** Loads one `CourseInfo` via `client.getCourse(widget.courseId)`; renders `_course.tees` (`CourseTeeSummary`) sorted by `sortPriority`, each showing `teeName`, `slope`, `courseRating`, `par`, and sex (`M's`/`W's`/`Unisex`). Edit fetches the full `TeeInfo` via `client.getTee(summary.id)` (list payload omits per-hole blob). Mutations: `deleteTee(t.id)`. Local state: `_course`, `_loading`, `_error`, `_anyDeleted`.
- **States:** Loading = spinner. Error = `ErrorView(onRetry: _load)`. Empty = centered grey "No tees configured on this course." Permission = not handled here (relies on the parent's admin gate). Offline = via `friendlyError`; delete failures → red `SnackBar` (5s for `ApiException`, e.g. tee protected by a played round).
- **Interactions & exits:** Back (`WillPopScope`) → pops returning `_anyDeleted` (true when any tee was added/edited/deleted/re-rated) so the course list refreshes its tee count. Re-rate action → pushes `CoursePasteScreen(replaceCourseId, replaceCourseName)`; on `true` sets `_anyDeleted` + reload. FAB "Add tee" → pushes `TeePasteScreen(courseId, courseName)`; on `true` reload. Tile tap → `_editTee`: fetch full tee → push `TeePasteScreen(existingTee: full)`; on `true` reload. Trailing delete → confirm `AlertDialog` then `deleteTee`.

### CourseSearchScreen
- **File:** lib/screens/course_search_screen.dart
- **Purpose:** Admin full-database tool to search GolfCourseAPI and import a course (with tees) into the local account.
- **Layout & regions:** `Scaffold` → `AppBar` (title "Import Course"; `bottom` = a search `TextField` with `search` prefix + clear suffix, autofocus) → body (spinner / `ErrorView` / no-results / empty prompt / results `ListView.separated`). Tapping a result opens `_CourseDetailSheet` (a `showModalBottomSheet` / `DraggableScrollableSheet`): drag handle → header (title + close) → optional city/state → tee-set cards list → sticky "Import to Library" / "Already in Library — Tap to Update" `FilledButton.icon`.
- **Components used:** `ErrorView` (lib/widgets/) with `isNetwork`/`onRetry`; `prettyCourseName` (lib/api/models.dart). Everything else is stock Material (`TextField`, `ListTile`, `CircleAvatar`, `Chip`, `DraggableScrollableSheet`, `Card`, `AlertDialog`, `FilledButton.icon`). No lib/widgets/ form widgets and NOT the unified `CourseSearchField`.
- **Data:** Debounced (600ms, ≥2 chars) search via `client.searchGolfApiCourses(query)` → `List<Map<String,dynamic>>` (raw API rows: `club_name`, `course_name`, `city`/`state`/`country`, `already_imported`, `id`). Detail sheet loads `client.getGolfApiCourse(courseId)` (tees + holes). Import = `client.importCourse(courseId, forceUpdate:)`. Local state: `_courses`, `_searching`, `_searchError`; sheet state `_detail`, `_loading`, `_error`.
- **States:** Loading (searching) = spinner. Error = `ErrorView` with retry re-running the query. No-results (query ≥2, empty list) = 'No courses found for "…".' Empty (no query) = large `golf_course` icon + prompt to search. Offline = `ErrorView(isNetwork: isNetworkError(...))`. Imported rows show a secondary-container check avatar + "In library" `Chip` instead of a chevron. Sheet: loading spinner, `ErrorView` with retry, "No tee data available for this course.", per-tee "⚠ n/18 holes" warning when a tee lacks 18 holes. Permission = not re-checked in this screen (reached only from the admin Manage Courses FAB / route).
- **Interactions & exits:** Search field `onChanged` → debounced `_search`; clear suffix resets. Result tap → opens `_CourseDetailSheet`. Sheet close/X → pops sheet. Import button → `_onImportTapped`: if `already_imported`, confirm Skip/Update `AlertDialog` (Update ⇒ `importCourse(forceUpdate:true)`), else direct import; success/warning/error shown as colored `SnackBar` (green/orange/red); a 409 prompts to use Update. No route pushes — screen returns to Manage Courses via system back.
- **NOTE:** `initialQuery` constructor param (pre-fills + auto-runs a search) exists but the only registered route `/course-search` in lib/main.dart builds `const CourseSearchScreen()` with no argument, so `initialQuery` is effectively unused now that the unified `CourseSearchField` removed its old fallback-push into this screen.

### CoursePasteScreen
- **File:** lib/screens/course_paste_screen.dart
- **Purpose:** Hand-import a whole course by pasting a scorecard, or re-rate an existing course's tees in place (preserving tee IDs so played rounds aren't broken).
- **Layout & regions:** `Scaffold` → `AppBar` (title "Paste Course" or "Re-rate Tees") → `SingleChildScrollView` column: in replace mode a secondary-container info `Card`, else a `GolfTextField` "Course name"; then the monospace multi-line scorecard `TextField` (12–18 lines, with an example `helperText`); "Paste from clipboard" `TextButton.icon`; optional error container; optional `_PreviewCard`; footer `Row` of "Preview" `OutlinedButton.icon` + "Create Course"/"Save Changes" `FilledButton.icon`.
- **Components used:** `GolfTextField` (lib/widgets/golf_text_field.dart) for the course-name field; `friendlyError` (lib/widgets/error_view.dart). Private `_PreviewCard`, `_CellHead`, `_Cell` (in-file). Stock Material for the paste `TextField`, buttons, `Table`. `Clipboard` from flutter/services.
- **Data:** Two modes keyed on `replaceCourseId`. Dry-run preview via `client.pasteCourse(name / replaceCourseId, paste, dryRun:true)` → `Map` with `tees` (name/slope/course_rating/par/sex) and `holes` (number/par/stroke_index/yards_by_tee). Commit via `client.pasteCourse(...)` (no dryRun). Creates a new account course or updates matching-name tees in place. Local state: `_nameCtrl`, `_pasteCtrl`, `_busy`, `_error`, `_preview`.
- **States:** Busy = spinner inside the Create/Save button; Preview/Save disabled while busy or when preconditions unmet (`canPreview` needs non-empty paste + a name unless replace; Save needs a `_preview`). Error = errorContainer box with `error_outline`; `ApiException` shows `e.message`, else `friendlyError`. Preview = `_PreviewCard` (tee table + first-3/last-3 hole lines + "N hole rows parsed"). Editing the paste or name invalidates any existing preview. Empty/loading/permission/offline = not separately handled (no initial fetch; offline surfaces as an error string).
- **Interactions & exits:** "Paste from clipboard" → `Clipboard.getData` into the paste field. "Preview" → `_preflight()` (dry-run). "Create Course"/"Save Changes" → `_commit()`; on success shows a `SnackBar` and `Navigator.pop(true)` (signals caller to reload). Reached via MaterialPageRoute from ManageCoursesScreen (create) and ManageCourseTeesScreen (re-rate); no named route.

### TeePasteScreen
- **File:** lib/screens/tee_paste_screen.dart
- **Purpose:** Add a single tee to an existing course, or edit/re-rate one existing tee (each tee carries its own par + stroke index + yards per hole).
- **Layout & regions:** `Scaffold` → `AppBar` (title "Add Tee" or "Edit Tee") → `SingleChildScrollView` column: course-name caption; `GolfTextField` "Tee name"; `Row` of `GolfTextField` "Slope" + "Course rating"; `SegmentedButton<String>` Men/Women/Unisex sex selector; monospace hole-rows `TextField` (12–20 lines, example helper); "Paste from clipboard" `TextButton.icon`; optional error container; optional `_TeePreviewCard`; footer `Row` "Preview" + "Add Tee"/"Save Changes".
- **Components used:** `GolfTextField` (lib/widgets/) for name/slope/rating; `friendlyError` (lib/widgets/error_view.dart). Private `_TeePreviewCard` (in-file). Stock Material `SegmentedButton`, `TextField`, buttons; `Clipboard`. Uses `TeeInfo` (lib/api/models.dart).
- **Data:** Optional `existingTee` (`TeeInfo`) pre-fills name/slope/rating/sex and serializes its `holes` into the paste box for tweaking. Dry-run + commit via `client.pasteTee(courseId, name, slope, courseRating, sex, paste, dryRun)`; server keys on `tee_name` so it inserts or updates. Preview `Map` has `tee` + `holes` (number/par/stroke_index/yards). Local state: `_nameCtrl`, `_slopeCtrl`, `_ratingCtrl`, `_pasteCtrl`, `_sex`, `_busy`, `_error`, `_preview`.
- **States:** Busy = spinner in the Add/Save button. Preview enabled only when `_canPreview` (name + valid int slope + valid double rating + non-empty paste); Save enabled only with a `_preview`. Error = errorContainer box; `ApiException.message` else `friendlyError`. Preview = `_TeePreviewCard` (tee summary line + first-3/last-3 hole lines). Any field edit clears the preview. No loading/empty/permission/offline states beyond the error string.
- **Interactions & exits:** Sex `SegmentedButton` change clears preview. "Paste from clipboard" → clipboard into paste field. "Preview" → `_go(dryRun:true)`. "Add Tee"/"Save Changes" → `_go(dryRun:false)`; on success `SnackBar` + `Navigator.pop(true)`. Pushed via MaterialPageRoute from ManageCourseTeesScreen (add + edit); no named route.

### SupportLookupScreen
- **File:** lib/screens/support_lookup_screen.dart
- **Purpose:** Support-staff tool (gated on `AuthProvider.isSupport`) to open ANY round's leaderboard read-only from a watch link, watch code, or round ID for diagnosing reported issues (server-audited).
- **Layout & regions:** `Scaffold` → `AppBar` (title "Support — Open Round") → `ListView`: read-only/logging notice; input `TextField` ("Watch link / code / round ID", paste `IconButton` suffix); "Look up" `FilledButton.icon`; optional error text; on success a result `Card` (account name, course + date, status/foursome-count/round #, optional tournament name, optional games) with an "Open leaderboard (read-only)" `FilledButton.icon`.
- **Components used:** `prettyCourseName` (lib/api/models.dart). All stock Material (`TextField`, `FilledButton.icon`, `Card`); `Clipboard`. No lib/widgets/ widgets (no `ErrorView`, no `GolfTextField`).
- **Data:** `client.supportLookupRound(query)` → `Map` (`account_name`, `course_name`, `date`, `status`, `num_foursomes`, `round_id`, `is_tournament`, `tournament_name`, `active_games`). Local state: `_ctrl`, `_loading`, `_error`, `_result`.
- **States:** Loading = spinner inside the Look up button (button disabled). Error = red text; `ApiException.message`, else generic "Lookup failed — check the link or id." Empty = no result card until a successful lookup (initial state is just the input). Permission = not re-checked in-screen (drawer/route gated on `isSupport`). Offline = folded into the generic catch. Empty-clipboard paste → informational `SnackBar`.
- **Interactions & exits:** Paste suffix `IconButton` → clipboard into field. Field submit or "Look up" → `_lookup()`. "Open leaderboard (read-only)" → `pushNamed('/leaderboard', arguments: round_id)`.

### GameSuggestionScreen
- **File:** lib/screens/game_suggestion_screen.dart
- **Purpose:** Free-form "Suggest a Game" form submitting a new-game request (players, rounds, per-hole scoring, betting, notes, contact email) to the server for review.
- **Layout & regions:** `Scaffold` → `AppBar` (title "Suggest a Game") → `ListView`: heading + explanatory subtext; `GolfTextField` "Game name"; `Row` of "Number of players" + "Number of rounds"; multiline `GolfTextField`s "How each hole is scored", "How the betting works", "Anything else"; "Your email (required, for follow-up)" field with inline validation; optional error container; "Send Suggestion" `FilledButton.icon`.
- **Components used:** `GolfTextField` (lib/widgets/golf_text_field.dart) for every field; `friendlyError` (lib/widgets/error_view.dart). Stock Material otherwise.
- **Data:** Submits via `client.submitGameSuggestion(gameName, numPlayers, numRounds, holeScoring, betting, notes, contactEmail)`. Email is pre-filled from `AuthProvider.player?.email`. No data displayed/loaded; pure create form. Local state: the 7 controllers, `_saving`, `_error`.
- **States:** Saving = spinner in the button; label switches to "Sending…". Send disabled unless `_hasContent` (≥1 of name/scoring/betting/notes) AND `_emailValid` (regex). Email field shows inline "Enter a valid email address" error text when non-empty and invalid. Error = errorContainer box via `friendlyError`. Success = "Thank you!" `AlertDialog` (mentions info@halved.golf) then `Navigator.pop()`. No loading/empty/permission/offline states beyond the error box.
- **Interactions & exits:** Field edits `setState` to re-evaluate the Send gate. "Send Suggestion" → `_submit()` → success dialog → pop the form. Reached via named route `/suggest-game` (lib/main.dart).

---

### 3.3 · Round creation & the round hub


Derived entirely from the Dart source under `lib/screens/` (plus `lib/main.dart` router and `lib/api/client.dart`). Names are used exactly as in code.

---

### CasualRoundScreen
- **File:** lib/screens/casual_round_screen.dart
- **Purpose:** Three-step flow to create a single-foursome (or Multi-Group Skins) casual round — pick course + game(s), select players, assign tees — then create the round and route to its play surface.
- **Layout & regions:** `Scaffold` (bg `Halved.surface`) with a plain `AppBar` whose title flips by step ("New Round" → "Players" → "Tees"); body is a `SingleChildScrollView`; `bottomNavigationBar` = `_buildNav()` (a Back `OutlinedButton` + a `HalvedCtaButton` reading "Next" / "Next" / "Configure Round"). Step 0 body top-to-bottom: "Select Course" head → `CourseSearchField` → "Games" head → "Who's playing?" `HalvedSegmented<String>` size filter (2/3/4/Across groups) → primary game chip `Wrap` → optional partial-round note → optional "Side games" chip `Wrap` → `_buildAdvanced()` `ExpansionTile` (holes/starting-hole steppers + Full 18 / Front 9 / Back 9 preset `ChoiceChip`s). Step 1: per-game `_gamePlayerCountHint` `InlineMessage`s → "Select Players" → `UnifiedPlayerSearch` → a roster `ListView.builder` of `Card` rows (checkbox, name, `HalvedMark` badge / invite icon / locked "You" `Chip`, index/blocked subtitle). Step 2: `_buildTeeStep()` → "Set tees" → `TeeAssignmentList`.
- **Components used:** `CourseSearchField`, `HalvedSegmented<String>`, `GameSelectableChip` (via `_buildPrimaryChip`/`_buildSideChip`), `HalvedCtaButton`, `UnifiedPlayerSearch`, `TeeAssignmentList`, `HalvedMark`, `InlineMessage`, `ErrorView`, `Halved.chipScope`; pushes `PlayerFormScreen`.
- **Data:** Loads via `AuthProvider.client` `getCourses()`, `getTees()`, `getPlayers()` (`Future.wait`; phantoms filtered out; auth player auto-selected). Local state: `_selectedCourse`, `_primaryGame`, `_sideGames`, `_playerTees` (playerId→teeId), `_playerGroups`, `_numHoles`, `_startingHole`. Game classification driven by `game_catalog.dart` (`casualGames`, `gameMeta`, `sideGamesFor`, `allowsSideGames`, etc.). Creation delegates to `createCasualRound(...)` (lib/utils/create_casual_round.dart) which returns a launch descriptor (round + optional route). Course selection may clone from the catalog via `CourseSearchField`.
- **States:** Loading → centered `CircularProgressIndicator` (nav bar hidden). Error → `ErrorView` with `friendlyError`/`isNetworkError`/`onRetry: _loadData` (nav bar hidden). Creating → `_creating` flag disables nav + shows "Configuring…" spinner on the CTA; create errors set `_error` and fall back to the error view. Empty roster search → "No golfers match your search." Validation is via `SnackBar` (no course/game, <2 players, overstuffed group >4, per-game exact/min/max player counts, unassigned tees). No explicit offline/permission handling beyond network-error styling.
- **Interactions & exits:** Size `HalvedSegmented` → re-filters games + prunes invalid primary/side. Primary/side chips → `_setPrimary`/toggle. "Add Golfer" / `UnifiedPlayerSearch` create-guest → pushes `PlayerFormScreen` (returns `PlayerProfile`), then `maybeOfferRoundSmsInvite`. Per-row invite icon → `inviteGolfer`. Back → decrement step; Next (step0→1, step1→2 with `_applyTeeSuggestions`). "Configure Round" → `_createRound` → `pushReplacementNamed('/round', arguments: launch.round.id)` then optionally `pushNamed(launch.route!, launch.effectiveArgs)` on top (returnToHub-style). Pushed directly via `MaterialPageRoute` from `casual_rounds_list_screen.dart` (not in the named router).

---

### NewRoundWizard
- **File:** lib/screens/new_round_wizard.dart
- **Purpose:** Multi-step wizard to create a tournament (or add a round to an existing one) with rounds, players, drag-assigned groups, per-player tees, and side-game/championship config; a shorter branch creates a Cup (team) tournament skeleton.
- **Layout & regions:** `PopScope(canPop:false)` → `Scaffold`; `AppBar` with `BackButton(onPressed:_back)`, a title showing step count ("New Round  (N of M)" / "New Cup Tournament (N of M)" / "Game Setup" / "Tournament Created"), and a `LinearProgressIndicator` `bottom`. Body dispatched by `_stepBody()`. `bottomNavigationBar` = `_BottomBar` (Back + Next / "Create Round" / "Save Tournament" / "Done"). Step count is computed: cup = 5 steps, non-cup = 6. Step widgets: `_Step0Tournament`, `_Step1Details`, `_Step2Players`, `_Step3GroupsAndTees`, `_Step4Games`, `_Step5Review`, `_Step6GameSetup`; cup-only `_Step2CupDesign` and `_Step3CupRoundGames`. A shared `_pinnedStep(...)` helper gives each step a pinned title/subtitle header over a scrollable body.
- **Components used:** `GolfTextField`, `GameSelectableChip`, `HandicapModeSelector`, `InlineMessage`, `NetDoubleBogeyCard` (`net_double_bogey_card.dart`), `PayoutConfigField`, `CourseSearchField`, `SegmentedButton`, `DropdownButtonFormField`, `ReorderableListView` (in `_Step3GroupsAndTees`), `ErrorView`; pushes `PlayerFormScreen`, `RyderCupDraftScreen` (import), and reuses `IrishRumbleSetupScreen`/`LowNetSetupScreen` + `PinkBallSetupScreen` imports. Group-badge `_groupColors` palette.
- **Data:** `_loadReferenceData()` → `getTournaments()`, `getTees()`, `getPlayers()`; courses derived from tees. Extensive local draft state: `_createNewTournament`/`_existingTournament`, `_nameCtrl`, `_numRounds` + `_additionalRounds` (`_RoundDraft`), `_tournamentActiveGames`, cup fields (`_cupNameCtrl`, `_cupTeamCount`, `_cupTeamColours`, `_roundCupGames`/`_roundCupPoints`/`_roundCupGroupCounts`), `_selectedCourseId`/`_date`/`_handicapMode`/`_netPercent`/`_netMaxDoubleBogey`, `_activeGames`, Stroke Play / Match Play buy-in fields, `_selectedIds`, `_orderedPlayerIds`/`_playerTees`/`_groupSizesOverride`. Group balancing via `utils/grouping.dart` `groupSizes(n)`. Championship set is mutually-exclusive (`kChampionshipGames`, `GameIds.championshipStrokePlay/Stableford/teamCup`). Creation: cup path → `createTournament` + per-round `createRound` stubs + `postTeamTournamentSetup` (placeholder teams/colours). Non-cup path → `createTournament` (+ `postTournamentLowNetSetup` / `postTournamentStablefordSetup` when buy-ins entered), stub `createRound`s for rounds 2..N, `createRound` for round 1, `setupRound(autoSetupGames:true)` with optional explicit `group_number`, then `postMatchPlaySetup` per foursome when Match Play/Singles Nassau configured.
- **States:** Loading → `CircularProgressIndicator` (bottom bar hidden). Error → `ErrorView(onRetry:_loadReferenceData)`. `_canAdvance()` gates Next per step (name required; multi-day requires a championship; ≥2 players; every player has a tee; each cup round has ≥1 game; ≥1 game exists before create). Creating → `_creating` shows a spinner in `_BottomBar`; `_createError` rendered inside `_Step5Review`. Post-creation step shows `_Step6GameSetup` + a "Done" button. No offline/permission-specific handling.
- **Interactions & exits:** Segmented New/Existing; rounds stepper; championship chips (mutually exclusive; Team Cup silently adds hidden Stroke Play); `CourseSearchField` per round (Round 1 selection defaults unset extra days); date pickers; `HandicapModeSelector`; player select/all/clear + Add-by-phone (`addHalvedGolferByPhone`) / Add golfer (`PlayerFormScreen` → `maybeOfferRoundSmsInvite`); `ReorderableListView` drag to re-group + `TeePicker` per player + group-size override; side-game toggles + buy-in `PayoutConfigField`. Create → cup: builds skeleton then lands on `_Step6GameSetup`; non-cup: either lands on `_Step6GameSetup` (when a game needs per-foursome config) or `Navigator.pop(true)`. "Done" → `Navigator.pop(true)`. Pushed directly via `MaterialPageRoute` from `tournament_list_screen.dart`.
- **NOTE:** `ryder_cup_draft_screen.dart` is imported; the round-detail widgets (`_Step2Players` … `_Step6GameSetup`, `_Step2CupDesign`, `_Step3CupRoundGames`) live in the lower ~2100 lines of the same file (documented here from their construction sites in `_stepBody`).

---

### CupRoundSetupScreen
- **File:** lib/screens/cup_round_setup_screen.dart
- **Purpose:** Phase 3 of the Cup lifecycle — build a cup round's foursomes one at a time (game type, players by team, tees, tee time, singles matchups), enforcing team-composition rules, then commit via `setupRound` + `postRyderCupRoundSetup` + `setTeeTimes`.
- **Layout & regions:** `Scaffold`; `AppBar` with `BackButton(onPressed:_prevStep)`, title "Round N · <course>", and a `LinearProgressIndicator` driven by the `_BuildStep` enum position. Body switches on `_BuildStep { gameType, players, tees, teeTime, matchups, review }`: gameType → `_RoundFormatToggle` (custom vs "One Day Ryder Cup"/triple_cup) over `_GameTypePicker` (or `_TripleCupFormatNote`); players → `_PlayerPicker`; tees → `_TeePicker`; teeTime → `_TeeTimePicker`; matchups → `_MatchupBuilder`; review → `_ReviewPage`. `bottomNavigationBar` = `_buildBottomBar()` (Back + "Next" / "Add Group" (on teeTime) / "Start Round" (on review)).
- **Components used:** `_RoundFormatToggle`, `_GameTypePicker`, `_TripleCupFormatNote`, `_PlayerPicker`, `_TeePicker`, `_TeeTimePicker`, `_MatchupBuilder`, `_ReviewPage` (all private in-file), `TeePicker` (from `tee_assignment.dart`), `ErrorView`, `LinearProgressIndicator`, platform `showTimePicker`.
- **Data:** `_load()` → `getTeamTournament(tournamentId)` (→ `TeamTournamentSummary`, `CupTeam`/`CupPlayer`) + `getTees()` filtered to `courseId`. Builds a `List<_FoursomeDraft>` (gameType, ordered playerIds, playerTees, teeTime, pointValue, singlesMatchups). Game options from `_kCupGames` (nassau/quota_nassau/irish_rumble/singles_nassau/singles_18), filtered by `widget.availableGames`; point values from `widget.gamePointValues`. Composition rules in `_playersValid` (Irish Rumble = 4 same-team; Four Ball/Quota = 2/3/4 with solo-side phantom; Singles = 2/3/4 split). Submit builds a flat player list, matches drafts to created foursomes by index, posts game types + team ids + `singles_matchups`, then tee times.
- **States:** Loading → `CircularProgressIndicator`. Error → `ErrorView(isNetwork:_networkError, onRetry:_load)`; a dedicated guard error when no players are drafted to teams ("use Cup Draft & Teams …"). `_canProceed` gates Next per step; review requires `_allPlayersAssigned` (≥1 foursome). Submitting → spinner on "Start Round"; `_submitError` shown via `friendlyError` in `_ReviewPage`. Players sitting out (uneven singles) are allowed and listed in review. No offline/permission handling beyond network styling.
- **Interactions & exits:** Round-format toggle (locked once a foursome committed); game pick; player toggles + Irish-Rumble team picker; per-player `TeePicker`; tee-time picker; matchup A/B swaps; review actions — remove foursome, edit/clear tee time, "Add another". "Start Round" → `setupRound` + `postRyderCupRoundSetup(roundFormat:_roundFormat, foursomes:...)` + `setTeeTimes`, then `Navigator.pop(true)`. Back walks `_prevStep` (from gameType with foursomes present → jumps to review; else pops). Pushed directly via `MaterialPageRoute` from `tournament_list_screen.dart`.

---

### SetupRoundPlayersScreen
- **File:** lib/screens/setup_round_players_screen.dart
- **Purpose:** Lightweight 3-step setup for an already-created stub round (status `pending`, no foursomes yet) — choose games, players, then drag-assign groups + tees and call `setupRound`. Used for days 2..N of a multi-day tournament.
- **Layout & regions:** `PopScope(canPop:false)` → `Scaffold`; `AppBar` (title "Round N — <course>", `LinearProgressIndicator` over 3 steps); body `_stepBody()` (0 games / 1 players / 2 groups+tees); `bottomNavigationBar` = `_BottomBar` (Back + Next / "Set Up Round"). Step 0: "Select Games" + `FilterChip` `Wrap` (from `tournamentRoundGames`) + an info box when none selected. Step 1: "Select Players" header with selected/group count, `GolfTextField` search + All/None, inline Add Golfer / Halved Golfer search buttons, `CheckboxListTile` roster (avatar, name, `HalvedMark`/invite icon, index), error banner if <2. Step 2: "Groups & Tees" header, group-color `Chip`s, bulk "All men/All women" `TeePicker`s, a `ReorderableListView` of drag rows (drag handle, name, per-player `TeePicker`, group badge), phantom-fill note, save-error box.
- **Components used:** `GolfTextField`, `HalvedMark`, `TeePicker` (from `tee_assignment.dart`), `FilterChip`, `CheckboxListTile`, `ReorderableListView`, `ErrorView`, `_BottomBar` (in-file); pushes `PlayerFormScreen`; `inviteGolfer`/`addHalvedGolferByPhone`/`maybeOfferRoundSmsInvite`; `utils/grouping.dart` `groupSizes`/`groupOf`/`isGroupBoundary`.
- **Data:** `_loadData()` → `getRound(roundId)`, `getTees()`, `getPlayers()` (phantoms filtered). Local: `_selectedGames`, `_selectedIds`, `_orderedIds`, `_playerTees`. Save → `setupRound(players:[{player_id,tee_id}], randomise:false, autoSetupGames:_selectedGames.isNotEmpty, activeGames:_selectedGames)`.
- **States:** Loading → `CircularProgressIndicator`. Load error → `ErrorView(onRetry:_loadData)`. Step gating: step 0 always advances, step 1 requires ≥2 players (`_canAdvanceStep1`, error banner shown), create requires every ordered player has a tee (`_canCreate`). Saving → spinner on "Set Up Round"; `_saveError` shown in an error box via `friendlyError`. No offline/permission handling.
- **Interactions & exits:** Game `FilterChip`s toggle `_selectedGames`; search/All/None; Add Golfer → `PlayerFormScreen` + SMS-invite offer; Halved Golfer search → `addHalvedGolferByPhone`; invite icon → `inviteGolfer`; reorder drag; bulk + per-player `TeePicker`. "Set Up Round" → `setupRound` then `Navigator.pop(true)`. Back walks steps then pops. Registered in the named router as `/setup-round-players` (main.dart).

---

### ConfirmTeesScreen
- **File:** lib/screens/confirm_tees_screen.dart
- **Purpose:** Reassign each player's tee for one foursome before any hole is scored (fix a placeholder default chosen at setup); server refuses once scoring starts.
- **Layout & regions:** `Scaffold`; `AppBar` title "Edit Tee Boxes"; body a `ListView` (explanatory caption + `TeeAssignmentList`); `bottomNavigationBar` a full-width "Save Tees" `FilledButton`.
- **Components used:** `TeeAssignmentList` (from `tee_assignment.dart`), `ErrorView`, `FilledButton`.
- **Data:** `_load()` resolves the foursome from `RoundProvider.round.foursomes` (no re-fetch) and fetches `getFoursomeCourseTees(foursomeId)` (scorer-accessible, sourced from the round's course). `_picks` (playerId→teeId) seeded from each `Membership.tee`. Save → only-changed rows to `patchFoursomeTees(foursomeId, tees:[{player_id,tee_id}])`, then re-`loadRound` so recomputed course/playing handicaps refresh.
- **States:** Loading → `CircularProgressIndicator` (bottom bar hidden). Error → `ErrorView(isNetwork, onRetry:_load)` (bottom bar hidden); throws if foursome not on the loaded round. Saving → `_saving` spinner on the button. No-changes → `SnackBar('No changes.')` + `pop(false)`. Success → `SnackBar('Updated N player(s).')` + `pop(true)`. Save errors set `_error` (shown in the body). No offline/permission handling beyond network styling.
- **Interactions & exits:** `TeeAssignmentList.onChanged` mutates `_picks`; subtitle shows "Course Hcp X · Playing Y". Save Tees → mutation + pop. Registered as `/confirm-tees` (main.dart), wrapped in `RoundLandscapeScorecard`.

---

### RoundScreen — THE ROUND HUB
- **File:** lib/screens/round_screen.dart
- **Purpose:** The launch/management hub for a round — shows round info, per-foursome cards with Enter Scores / config / side-game / tee-box actions, TD (tournament director) tools, Multi-Group Skins management, and Complete Round / Final Results, plus leaderboard and chat entry.
- **Layout & regions:** `Scaffold`; `AppBar` — leading is an `Icons.close` "Exit round" (casual) or default back; title = casual game name (`_casualTitle`) or "Round N"; actions = `RoundChatButton` + a `Icons.bar_chart` Leaderboard button (`pushNamed('/leaderboard')`). Persistent `bottomNavigationBar`: `_CompleteRoundButton` (in-progress) / "Final Results" `FilledButton` (complete) / empty. Body = `RefreshIndicator(onRefresh:_reloadRound)` wrapping a `ListView`: `_RoundInfoCard` → (optional) Multi-Group Skins management `Card` → (optional) "Game Setup" section with `_GameSetupCard` → "Foursomes" header → one `_FoursomeCard` per foursome.
- **Components used:** `RoundChatButton`, `GameChip`, `ErrorView`, `_RoundInfoCard`, `_GameSetupCard`, `_CompleteRoundButton`, `_FoursomeCard`, `_GameSelectionSheet` (all in-file); `PopupMenuButton`, `showModalBottomSheet`, `AlertDialog`; helpers `hubHandicapLabel`, `primaryHandicapFor` (utils/primary_handicap.dart), `effectiveMatchHandicap` (utils/match_handicap.dart), `resolvePrimary`/`sideGamesFor`/`gameMeta` (game_catalog.dart), `linkRoundToPoolFlow` (utils/skins_pool_link.dart), `resolveTripleCupTeamColor`.
- **Data:** Loads via `RoundProvider.loadRound(roundId)` (watched); `AuthProvider.player` for "my group". Per-foursome primary-game handicap loaded async into `_fsHcap` via `primaryHandicapFor` (casual only; `_maybeLoadHcap` guarded by `_hcapLoadStarted`, reset by `_reloadRound`). Displays `round.course`, date, status, `betUnit`, active-game `GameChip`s, foursome rosters with tee + `hubHandicapLabel` (CH / CH·PH plays-to). `canManage` = `round.canManage` (TD = own-account admin; cross-account scorer = false). Mutations: `addSideGame`, `patchFoursomeActiveGames`, `setFoursomeName`, `setFoursomeShotgun`, `completeRound` (via provider), and the dead-code roster methods below.
- **States:** Loading → `CircularProgressIndicator`. Error → `ErrorView(onRetry: loadRound)`. Null round → empty. In-progress vs complete drives the bottom button and per-card affordances. `_CompleteRoundButton` distinguishes fully-scored (prominent filled "Complete Round") vs early-finish (outlined "Complete Anyway" with unscored-holes warning dialog). Pull-to-refresh re-fetches + re-arms handicap load. No explicit offline/permission states (permission handled via `canManage` gating).

- **Per-foursome TD actions menu (`PopupMenuButton<String>`):** rendered on `_FoursomeCard` and gated `if (canManage && !isComplete && !isCupRound)` — i.e. hidden on cup rounds, complete rounds, and for non-managers. `onSelected` handles only three actions: `configure_games` → `_showGameSheet` (`_GameSelectionSheet` bottom sheet → `patchFoursomeActiveGames`); `rename_group` → `_renameGroup` (`AlertDialog` text field → `setFoursomeName`); `set_start` → `_setStartingHole` (`AlertDialog` with a 1..18/inherit `DropdownButtonFormField` + tee-slot field → `setFoursomeShotgun`). The `set_start` item only appears when `allFoursomes.length > 1`. An in-code comment (lines ~1623-1635) explicitly states the roster-change actions were removed from this menu because they leave stale state (game chips, payouts, brackets, phantom accounting don't recompute) and the TD's only safe path on a roster change is to delete + recreate the round.

- **`_showRemovePlayerSheet` / `_showMovePlayerSheet` / `_showSwapPositionSheet` — DEAD CODE (defined-but-unwired):** These three `_FoursomeCard` methods are fully implemented (lines 1015, 1130, 1290) and call `client.removeFoursomePlayer` (1104), `client.moveRoundPlayer` (1264), and `client.swapFoursomePosition` (1368) respectively, with confirm dialogs and bottom sheets. I grepped every reference in the file: **each name appears only on its own definition line — there is no invocation site.** No `PopupMenuItem`, button, or `onSelected` case calls any of them. The TD `PopupMenuButton` only wires `configure_games`, `rename_group`, `set_start`. So the "no-show remove", "move/rebalance player", and "swap tee positions" tools are present in the source but unreachable from the UI — consistent with the comment above. **NOTE:** dead code — the backend endpoints exist and the methods compile, but nothing invokes them.

- **Buttons on `_FoursomeCard` (bottom, shown when `canEdit || isComplete`):**
  - **Enter Scores** (primary `FilledButton.icon`): label/icon adapt — "View Scorecard" (complete → `/score-entry` read-only), "Set Up Bracket →" (`needsBracketSetup`), "Start Match" (sixes active, not started), else "Enter Scores". `onEnterScores` loads the scorecard then computes a large route ladder: cup rounds → `/quota-nassau` / `/nassau` / `/score-entry`; else per-game setup routes when unconfigured (`/three-person-match-setup`, `/match-play-setup`, `/pink-ball`, `/sixes-setup`, `/points-531-setup`, `/nassau-setup`, `/nassau-setup-18`, `/nassau-nine-setup`, `/vegas-setup`, `/fourball-setup`, `/skins-setup`, `/wolf-setup`|`/wolf`, `/rabbit-setup`|`/rabbit`, `/triple-cup-setup`) else `/score-entry`. Primary-vs-side gating uses `resolvePrimary(round.primaryGame, fsGames)` for nassau/match_18/skins. Match-play-setup gets richer args (`allMatchPlayIds`, `peerIds`). Returns re-`loadRound`.
  - **Edit Tee Boxes** (`OutlinedButton`): shown `canEdit && !isComplete && !foursome.hasAnyScore` → `pushNamed('/confirm-tees', foursome.id)` (ConfirmTeesScreen).
  - **Edit Configuration / Set up Configuration** (`OutlinedButton`): shown `canManage && !isComplete && !isCupRound && !hasAnyScore` via `_editConfigTarget(merged, foursome, primaryGame)` targeting the PRIMARY game's setup screen (returnToHub). Label is "Set up Configuration" until `configuredGames` contains the primary, then "Edit Configuration".
  - **Side-game setup buttons** via `_sideGamePerFoursomeTargets` (Skins/Nassau/Singles Match as side, Spots, Honors) — each an `OutlinedButton` "Set up X"/"Edit X" → its setup route (foursome id, returnToHub).
  - **Round-level side games** (Stroke Play / Stableford) via `_roundLevelEditTargets`, shown as bottom buttons only when `allFoursomes.length == 1` (round id args).
  - **Add side game** (`OutlinedButton`, casual only): `_showAddSideGameSheet` → picks an eligible `sideGamesFor(primary,size)` game → `client.addSideGame(roundId,pick)` → opens its `_sideGameSetupRoute` setup.
  - **Link to a Skins pool** (`OutlinedButton`): shown `!isCupRound && canManage && groupNumber == 1 && !activeGames.contains('multi_skins')` → `linkRoundToPoolFlow(context, roundId)`.
  - **View Scorecard FAB / completed action:** there is no floating `FloatingActionButton`; on a complete round the Enter Scores button becomes "View Scorecard" (`table_chart_outlined`) → read-only `/score-entry`, and the persistent bottom bar shows "Final Results" → `/leaderboard`.
  - **Leaderboard:** `AppBar` bar-chart action → `pushNamed('/leaderboard', round.id)`.
  - **Round feed / chat:** `RoundChatButton(roundId, title: course.name)` in the `AppBar` actions (routes to the round feed/chat).

- **Multi-Group Skins management `Card`:** shown `hasMultiSkins && canManage` — a "Multi-Group Skins" `ListTile` → `/multi-skins`, plus (when not complete) an "Edit configuration" `OutlinedButton` → `/multi-skins-setup` (returnToHub) → re-`_reloadRound`.

- **"Game Setup" section (`_GameSetupCard`):** shown `hasSetupGames && !isComplete && canManage && !round.isCupRound`, only for multi-foursome rounds — buttons for "Configure Irish Rumble", "Edit Stroke Play", "Edit Stableford", "Configure Pink Ball", and a "Mini Singles Brackets" list ("Set Up <group>" per unconfigured foursome, auto-dispatching threesome→`/three-person-match-setup` vs `/match-play-setup`).

- **Cup-round differences (`isCupRound` gating throughout):** TD `PopupMenuButton` hidden (`!isCupRound`); "Game Setup" card hidden (`!round.isCupRound`); "Edit Configuration", side-game buttons, "Add side game", "Link to a Skins pool" all hidden on cup rounds. `_RoundInfoCard` hides the `$/unit` chip when `isCupRound`. Game chips always show for cup foursomes (`isCupRound ? effectiveGames.isNotEmpty : hasOverride...`). `onEnterScores` short-circuits cup rounds to `/quota-nassau` / `/nassau` / `/score-entry` (skipping all setup routing, since cup rounds are configured in CupRoundSetupScreen). Player rows tint names with `cupTeamColour`. Bracket-setup gate (`needsBracketSetup`) is disabled for cup foursomes.

- **Interactions & exits (summary):** AppBar → `/leaderboard`, round chat; bottom bar → Complete Round (confirm dialog → `completeRound` → `/leaderboard`) or Final Results (`/leaderboard`); per-card → the route ladder above, `/confirm-tees`, per-game setup routes, `_showAddSideGameSheet`, `linkRoundToPoolFlow`, `/multi-skins`(+setup); TD menu → configure-games sheet / rename dialog / starting-hole dialog. Registered as `/round` in main.dart (pushed by many callers, e.g. CasualRoundScreen's `pushReplacementNamed`). **NOTE:** per-foursome game *play* routes (e.g. `/score-entry`, `/skins`, `/nassau`) are wrapped in `RoundLandscapeScorecard` in the router; the setup routes generally are not.

---

#### Router context (lib/main.dart `_router`)
- `CasualRoundScreen`, `NewRoundWizard`, `CupRoundSetupScreen` are **not** in the named router — they are pushed directly via `MaterialPageRoute` (from `casual_rounds_list_screen.dart` and `tournament_list_screen.dart`).
- `RoundScreen` → `/round`; `SetupRoundPlayersScreen` → `/setup-round-players`; `ConfirmTeesScreen` → `/confirm-tees` (wrapped in `RoundLandscapeScorecard`).
- Per-foursome game/scorecard routes (`/score-entry`, `/points-531`, `/skins`, `/wolf`, `/rabbit`, `/match-play`, etc.) are wrapped in `RoundLandscapeScorecard(foursomeId:…, child:…)`; the corresponding `-setup` routes accept either a plain `int` foursomeId or a `{'id':…, 'returnToHub':…}` map.

---

### 3.4 · Score entry, feed, sharing & leaderboards


Derived entirely from the Dart source under `mobile/lib/screens/`. Class/widget names are exactly as in code (private helper widgets keep their leading underscore).

---

### ScoreEntryScreen
- **File:** lib/screens/score_entry_screen.dart
- **Purpose:** The universal per-hole score-entry screen for every casual game combination (replaces the old per-game play screens — nassau/skins/sixes/points_531), rendering the active hole card, the score picker, junk/spots capture, and per-game status strips.
- **Layout & regions (top→bottom):**
  - **AppBar** (`automaticallyImplyLeading:false`): leading `Icons.close` (tooltip flips "Close" → "Exit to rounds" once a casual single-foursome round has any score — then `popUntil('/casual-rounds')`); centred title from `_appBarTitle` (game names + handicap-mode suffix, e.g. "Skins (Net 90%)"); actions = pending-sync `Badge` + `Icons.cloud_upload_outlined` (tap to `sync.recheck()`), `RoundChatButton`, `Icons.leaderboard_outlined` (→ `/leaderboard`), and a `more_vert` `PopupMenuButton` (Refresh scores / Finish round / "What do these buttons do?" help).
  - **Body** (`_buildBody`): optional `_TeamBanner` (Nassau primary) → `_PressesStrip` (Nassau top+bottom presses) → scrollable `RefreshIndicator`+`SingleChildScrollView` containing: `_irBallsBanner` (Irish Rumble "N balls count") → the **`_HoleScoreCard`** (hole header + per-player rows + inline picker) → `_StablefordStrip` (Stableford primary only) → **`_GameStatusSection`** (per-game status cards).
  - **bottomNavigationBar** (`_buildBottomBar`): `_MatchStatusBar` (Nassau) / `_MatchPlayStatusBar` or `_CupSinglesStatusBar` (bracket) → a row of `Previous`/`Hole N` outlined+filled nav buttons via `_buildPrimaryActionButton`.
- **Components used:** `_HoleScoreCard`, `_PlayerRow`, `InlineScorePicker`, `NetScoreButton`, `scoreCellWithDots`/`ScoreMark` (widgets/score_mark.dart), `_JunkDots`, `SpotsDots` (via `SpotsCaptureMixin`, widgets/spots_capture.dart), `_PhantomPlayerRow`, `BorrowedFourthRow`, `_TeamBanner`, `_PressesStrip`, `_StablefordStrip`, `_GameStatusSection` and its children — `_NassauProgressGrid`/`_GridPlayerRow`, `_SkinsStandingsCard`, `_MultiSkinsStandingsCard`, `_SixesMatchGrid`/`_SixesSegmentCard`, `_TripleCupMatchGrid`/`_TripleCupMatchCard`, `_P531SummaryGrid`/`_P531PlayerGridRows`, `_VegasStatusCard`, `_FourballStatusCard`/`_FourballProgressGrid`, `_StrokePlayProgressGrid`, `_StablefordProgressGrid`, `_MatchPlayStatusCard`/`_MatchRow`, `_ThreePersonMatchStatusCard`, `_CupSinglesProgressGrid`/`_CupSinglesStatusCard`, `_IrishRumbleScorecardGrid`; status widgets `_MatchStatusBar`/`_MatchPlayStatusBar`/`_CupSinglesStatusBar`; `_NassauHoleOutcome`/`_SkinsHoleOutcome`/`_SkinsCarryChip`; helpers `_SetTeamsPrompt`/`_ExtraTeamPickerSheet`, `_ScoreEntryLegendSheet` (the "?" legend), `RoundChatButton`, `TeamSplitter4`, `HalvedMark`, `_StatusChip`, `_PlaceBadge`.
- **Data:** Reads a `Scorecard` + per-game summaries from `RoundProvider` (`loadScorecard`, and `loadNassau`/`loadSkins`/`loadSpots`/`loadMultiSkins`/`loadSixes`/`loadTripleCup`/`loadPoints531`/`loadVegas`/`loadFourball`/`loadStableford`/`loadLowNetConfig`/`loadMatchPlay`/`loadThreePersonMatch`, gated by `_loadGameSummaries` on the union of round- and foursome-level `active_games` / `configured_games`). Mutations: `RoundProvider.submitHole` (per-hole gross), `ApiClient.postSkinsJunk`, spots tally via the mixin (`ApiClient` spots tally), `RoundProvider.callNassauPress`, `ApiClient.withdrawPlayer`/`reinstatePlayer`, `RoundProvider.completeRound`. User creates/edits: gross scores per player per hole (pending in `_pending`), skins junk counts (`_pendingJunk`), spots counts, Nassau presses, mid-round withdrawals, and Sixes extra-segment team assignments.
- **States:**
  - *Loading:* `CircularProgressIndicator` while `loadingScorecard && scorecard==null`; per-game status card shows a small spinner while its summary loads.
  - *Error:* `InlineMessage(kind: error)` + Retry button (reloads scorecard + summaries) when `rp.error != null && sc==null`.
  - *Empty:* no dedicated empty state — a fresh round jumps to the first unplayed hole (`_jumpToFirstUnplayed`) and shows blank score boxes.
  - *Offline / sync:* explicitly reflected — the AppBar shows a pending-count `Badge` with a spinner when `SyncService.state == syncing` (tap to `recheck`); scores go through the offline queue (`submitHole` enqueues, `waitUntilIdle()` gates summary reloads and Complete Round); a direct `SyncService` listener (`_syncWatcher`) reloads summaries on the pending→idle transition.
  - *Permission:* no in-screen permission gate here (scorer access is enforced server-side via `foursome_for_scorer`); score entry is disabled per-row when the round `status == 'complete'` (rows read-only, withdrawal long-press disabled).
- **Interactions & exits:**
  - Tap an empty/hot player row → `InlineScorePicker` appears inline; picking a value → `_selectScore` (stores pending; auto-save+advance when the hole completes if `SettingsProvider.autoAdvanceHole`).
  - Tap an already-scored player → `onEditTap` makes them the hot row (`_editHotPid`) with the inline picker + Clear chip (no separate edit sheet).
  - Junk `_JunkDots` ⊕/⊖ → `_adjustJunk` (0–20, submitted via `postSkinsJunk`) — **only when Skins is the primary and `allowJunk`**.
  - Spots `SpotsDots` ⊖N⊕ → `adjustSpots` (debounced tally POST; signed, negatives allowed) — rendered whenever `spotsActive` (the `capturesInScoreEntry` carve-out for a side game).
  - **Long-press a player row → `_showWithdrawSheet`** (mid-round withdrawal): if already withdrawn, a reinstate sheet (`reinstatePlayer`); otherwise a modal with a "Last hole completed" stepper, a "Group abandoned hole N+1" `SwitchListTile`, and (Sixes only) "Void the affected matches" vs "Partner plays solo" radios → `withdrawPlayer(afterHole, killNextHole, sixesAction)` → `loadRound` + reload summaries. Row then shows a **WD** badge and an "Out" marker (no score box) on holes the player is out for.
  - Bottom-left `Previous / Hole N` → `_retreat`; bottom-right primary button (`_buildPrimaryActionButton`): "Hole N+1" (`_saveAndAdvance`, disabled until all scored) / "Save scores" (`_saveCurrentHole`, on the last hole in play order with pending edits) / "Complete Round" (`_completeRound` — soft-gate confirm dialog `confirmCompleteRound`, warns on blank holes, multi-group copy) / "View Leaderboard" when complete → `/leaderboard`.
  - Hole-number strips in the status grids → `_selectHole` (guarded by `_canSelectHole`; jumping ahead of an unplayed hole is refused with a SnackBar — entry stays in play order).
  - Nassau "Call Press" in `_MatchStatusBar` → `_callPress`; Sixes extra-segment auto-opens `_ExtraTeamPickerSheet` / `_SetTeamsPrompt`; Triple Cup foursomes tee-off prompt (`_maybePromptTripleCupTeeOff`).
  - Match-play / three-person-match summaries poll every 3s via `_matchPlayTimer`.
- **NOTE:** Primary-vs-side-game distinction governs rendering: Skins standings, Multi-Skins standings, Stroke Play grid, and Stableford strip render in entry **only when that game is `resolvePrimary(round.primaryGame, games)`**; as side games they are leaderboard-tab-only. Junk and the stroke-dot handicap likewise resolve from the primary. Nassau's in-card UI (banner/presses/outcome/progress grid) is primary-only, but Nassau team **colouring** (`teamColorNassau`) still applies when Nassau is a side game. `_handicapParams` resolves `(mode, %)` from the primary game's summary.
- **NOTE:** 3-real-player foursomes auto-dispatch to Three-Person Match (not a bracket) — both the poll timer and `_GameStatusSection`/`_buildBottomBar` guard against `/match-play/` 404s and against a sibling foursome's `matchPlayData` (`foursome_id` mismatch) bleeding in.

---

### RoundFeedScreen
- **File:** lib/screens/round_feed_screen.dart
- **Purpose:** The per-round message feed — a chronological mix of human chat bubbles and server-generated event cards (birdie, skin, lead change, final scores…), with a compose box that queues offline.
- **Layout & regions:** AppBar (title = `widget.title ?? 'Round chat'`, refresh action) → `_OfflineBanner` → `Expanded` feed (`ListView.builder`) → `_Composer` (multiline `TextField`, maxLength 1000, filled send `IconButton`).
- **Components used:** `_OfflineBanner`, `_ChatBubble`, `_EventCard` (+ its `_scoreReportCard` ranked "Final scores" table), `_Composer`, `ErrorView`.
- **Data:** `MessageProvider` (`open(roundId)` starts polling, `close()` on dispose, `messages`, `unread`, `markAllRead`, `myPlayerId`, `refresh`, `send`). Each item is a `ChatMessage` (`isEvent`, `authorId`/`authorName`, `body`, `createdAt`, `pending`, `data['type']`). Event icons chosen by `_iconFor(type)`. The user creates chat messages via `send(text)`.
- **States:**
  - *Loading:* centered `CircularProgressIndicator` while `loading && messages.isEmpty`.
  - *Error:* `ErrorView(message, onRetry: refresh)` when `error != null && messages.isEmpty`.
  - *Empty:* pull-to-refresh `ListView` with `Icons.sms_outlined` + "No messages yet. Say hello…" prompt.
  - *Offline / sync:* `_OfflineBanner` watches `SyncService` — shows "You're offline — N message(s) will send when you reconnect." (`Icons.cloud_off`) or "Sending N queued message(s)…" (`Icons.sync`) using `sync.pendingMessageCount`; queued/pending bubbles show a `Icons.schedule` clock (`message.pending`). Composing while offline enqueues via `MessageProvider.send` (SyncService).
  - *Permission:* not handled in-screen.
- **Interactions & exits:** AppBar refresh → `mp.refresh()`; pull-to-refresh → `refresh`; send button / `_send` → `MessageProvider.send`, clears field, auto-scrolls; auto-marks-read + auto-scrolls on new messages while open. No push navigation — this is a leaf screen.

---

### ShareScorecardScreen
- **File:** lib/screens/share_scorecard_screen.dart
- **Purpose:** Preview a foursome's portrait scorecard as an image and share/text it as a PNG via the native share sheet.
- **Layout & regions:** `GolfAppBar` (title "Share Scorecard", Share `Icons.ios_share` action, spinner while `_sharing`) → body = a `FittedBox`-scaled `RepaintBoundary` wrapping `ShareableScorecard` → `bottomNavigationBar` "Share / Text scorecard" `FilledButton.icon`.
- **Components used:** `ShareableScorecard` (widgets/shareable_scorecard.dart), `GolfAppBar`, `RepaintBoundary`.
- **Data:** `RoundProvider.scorecard` (`holes`, `totals`) + `round.course.name`/`date`/`activeGames`; loads via `loadScorecard(foursomeId)` if not already the active foursome. `_roundLabel` joins `gameMeta(g)?.displayName`; `_dateLabel` formats the date. Nothing is created/edited — read-only capture.
- **States:**
  - *Loading:* centered `CircularProgressIndicator` until `scorecard != null && activeFoursomeId == foursomeId`.
  - *Error:* capture/share failure → SnackBar "Could not share scorecard: …".
  - *Empty / permission / offline:* not handled (relies on the already-loaded scorecard).
- **Interactions & exits:** Share action or bottom button → `_share` renders the `RepaintBoundary` to a 3.0-pixel-ratio PNG in the system temp dir and calls `Share.shareXFiles` (with an `sharePositionOrigin` rect for iPad). No route push.
- **NOTE:** Pushed from `LeaderboardScreen`'s overflow "Share scorecard" via `MaterialPageRoute` (targets `_landscapeFoursomeId`), not a named route.

---

### LeaderboardScreen
- **File:** lib/screens/leaderboard_screen.dart
- **Purpose:** The multi-tab per-round leaderboard — one tab per active game plus tournament/utility tabs — with expandable rows, a landscape full-field scorecard gesture, and spectator-link sharing.
- **Layout & regions:** `RoundLandscapeScorecard` wrapper (rotate-to-landscape → full-group `ScorecardGrid` for `_landscapeFoursomeId`) → `Scaffold` with `GolfAppBar` (title "Leaderboard"; actions `RoundChatButton` + `_buildOverflowMenu`; `bottom` = scrollable `TabBar` from `_gameTabs`) → optional "Final Results · course · date" banner → `TabBarView` bodies → `bottomNavigationBar` "Done" `FilledButton` when the round is final.
- **Tab types (built by `_initTabs`, left→right):**
  1. **`__bandon_cup__`** (cup rounds / cup-nassau) → `_BandonCupTabView` (+ `_BandonCupScoreboard`/`_CupWinnerBanner`/`_BandonCupLiveCard`).
  2. **`__championship__`** (tournament rounds) → `ChampionshipTabView` (imported from tournament_leaderboard_screen.dart).
  3. The round's own **side games** (from `active_games`, minus `low_net_round` and cup-suppressed singles keys) dispatched by `_GameView`'s switch to per-game cards: `stableford`→`_StablefordView`(+`_StablefordPointsGrid`); `pink_ball`→`_RedBallView`; `skins`→`_SkinsGroupCard` (+`_JunkHoleStrip`, `_MsScorecard`); `spots`→`_SpotsGroupCard`(+`_SpotsHoleStrip`); `honors`→`_HonorsGroupCard`(+`_HonorsHoleStrip`); `triple_cup`→`_TripleCupGroupCard`(+`_TripleCupHoleDetail`) with a preceding `__triple_cup_overview__`→`_TripleCupOverviewView`; `multi_skins`→`_MultiSkinsView`(+`_MsScorecard`); `nassau`/`nassau_nine`/`match_18`→`_NassauGroupCard`; `quota_nassau`→`_QuotaNassauGroupCard`; `sixes`→`_SixesGroupCard`; `points_531`→`_Points531GroupCard`(+`_Points531HoleGrid`/`_PointsCell`); `vegas`→`_VegasGroupCard`(+`_VegasHoleGrid`); `fourball`→`_FourballGroupCard`; `wolf`→`_WolfGroupCard`; `rabbit`→`_RabbitGroupCard`; `singles_nassau`/`cup_singles`→`_CupSinglesGroupCard`; `singles_18`→`_Singles18GroupCard`; `cup_singles_18`→`_CupSingles18GroupCard`; `three_person_match`→`_ThreePersonMatchGroupCard` (+`_TpmTiebreakSection`/`_TpmPhase2Section`); `match_play`→`_MatchPlayGroupCard`; `irish_rumble`→`_CupIrishRumbleView` or `_IrishRumbleView`; unknown→`_RawJsonView`. Group cards are laid out by **`_ByGroupView`** (one card per `by_group` entry; injects `_single_group` to hide the "Group N" header in single-foursome rounds).
  4. **`__my_foursome__`** (multi-group rounds where the viewer plays) → `_MyFoursomeTabView`.
  5. **`settlement`** → `_SettlementView` (cross-game "who owes whom" transfers).
  6. **`low_net_round`** (Stroke Play, always rightmost, excluded for Triple Cup) → `_LowNetView`.
- **Row expand behavior:** `_LowNetView` renders a ranked net-to-par table (rank · name+CH · gross · Net/S-Off · payout) with a Gross/Net/Strokes-off `HalvedSegmented` selector (re-ranks from pre-computed `data['modes']`, default via `_defaultMode`); **tapping a player row toggles an inline hole-by-hole `StrokePlayStrip`** (accordion via `_expandedPids`, multiple can be open). Group cards (Fourball, TPM, matches, cup singles) similarly expand per-hole detail.
- **Components used:** `_GameView` (dispatcher), `_ByGroupView`, `_LowNetView`, `StrokePlayStrip` (widgets/stroke_play_strip.dart), `_SettlementView`, `_MsScorecard`, `ScorecardGrid` (via `RoundLandscapeScorecard`), `ShareScorecardScreen`, `RoundChatButton`, `GolfAppBar`, `ChampionshipTabView`, `MatchPlayDetailView`, plus every group/live-row card listed above (`_NassauLiveRows`, `_QuotaNassauLiveRows`, `_IRLiveRows`, `_TripleCupLiveRows`/`_TripleCupSubMatchRow`, `_SinglesLiveRows`, `_CupSinglesLiveRows`, `_CupWinnerBanner`, etc.).
- **Data:** `RoundProvider.loadLeaderboard(roundId)` → a `Leaderboard` (`games` map of `LeaderboardGame`, `activeGames`, `tournamentId`, `tournamentActiveGames`, `isCupRound`, `cupName`, `status`, `course`, `roundDate`, `accountId`/`accountName`, `watchToken`). Player-row order comes from `rp.round.foursomes[].realPlayers`. `AuthProvider` supplies the viewer's `player.id` (My Foursome gating) and `isSupport`/`isAdmin`. Mutation: `RoundProvider.reopenRound` (final rounds).
- **States:**
  - *Loading:* centered `CircularProgressIndicator` (`loadingLeaderboard`); tab switches refresh silently (no spinner flash).
  - *Error:* `InlineMessage(error)` + Retry when `error != null && leaderboard == null`.
  - *Empty:* "No games active." (no tabs) and per-tab "No data yet." / "No scores yet." / "No settlement yet.".
  - *Permission / support:* support cross-account view shows an amber "Support · read-only" banner and hides chat/overflow (refresh stays inline).
  - *Offline / sync:* not directly surfaced here (the leaderboard is a server read); auto-refreshes on `didPopNext` and app resume.
- **Interactions & exits:**
  - Overflow `_buildOverflowMenu`, in order: "Invite a watcher" → `inviteWatcher` (the ONLY invite path — it texts the watch link, which opens in-app for a Halved golfer and on the web page for everyone else); "Refresh" → `loadLeaderboard`; help sheet; "Reopen round" → `_confirmReopen` → `reopenRound` then pop; **"Share scorecard"** → pushes `ShareScorecardScreen(foursomeId: _landscapeFoursomeId)`; **"Copy round link"** (last) → `_copyRoundLink` (builds `<host>/watch/<token>/`, copies to clipboard + SnackBar) — for pasting into another round to link a side game, not for inviting people.
  - `RoundChatButton` → round feed; tab switch → silent `_refresh`; per-row taps → inline expand (Low Net strip, group-card detail); "Done" (final) → `popUntil(isFirst)`; rotate phone → landscape `ScorecardGrid`.
- **NOTE:** Internal keys `__bandon_cup__` / `_BandonCup*` class names are legacy (pre-"Halved"/trademark-scrub) and intentionally left non-user-visible; the tab label falls back to `cupName ?? 'Cup'`.

---

### TournamentLeaderboardScreen
- **File:** lib/screens/tournament_leaderboard_screen.dart
- **Purpose:** The tournament-level (cross-round) championship leaderboard — a tab per active tournament game (Stroke Play / Stableford championship, Mini Singles Bracket).
- **Layout & regions:** `Scaffold` → `AppBar` (title = tournament name; actions "Invite a watcher", Refresh, and a staff-only `Icons.settings_outlined` `PopupMenuButton` to Configure Stroke Play / Stableford; `bottom` = scrollable `TabBar` from `_tabs` labelled via `_labels`) → `TabBarView` bodies.
- **Components used:** `_GameView` (local dispatcher), `_LowNetChampView` (+ `_InfoChip`), `_StablefordChampView`, `_MatchPlayChampView` (+ `_BracketCard`/`_MatchRow`/`_PayoutBlock`/`_StatusChip`), `ChampionshipTabView` (exported for embedding in LeaderboardScreen), `strokePlayHoleStrip`/`StrokePlayStrip`, `ErrorView`, `InlineMessage`.
- **Data:** `ApiClient.getTournamentLeaderboard(tournamentId)` → `{active_games, games{...}}`; tabs = active games that have a `games` entry (deduped). `_LowNetChampView` shows cumulative net standings (rank · name(hcp) · Thru · per-round Net columns · total Net · Prize) with per-round scorecards; `_StablefordChampView` shows cumulative points + payout + points-table chips; `_MatchPlayChampView` groups brackets by round → Semis (holes 1–9) / Final & 3rd (holes 10–18) + payouts. `AuthProvider.isAdmin` gates the Configure menu. Setup mutations happen on `TournamentLowNetSetupScreen` / `TournamentStablefordSetupScreen`.
- **States:**
  - *Loading:* centered `CircularProgressIndicator` (non-silent load).
  - *Error:* `ErrorView(onRetry: _load)`; silent refreshes keep last-good standings on transient failure.
  - *Empty:* "No championship games configured. / Select Stroke Play or Mini Singles Bracket…"; per-tab "No scores yet." / "No Mini Singles Brackets found.".
  - *Permission:* Configure menu is admin-only (`isStaff`).
  - *Offline / sync:* not surfaced (server read); auto-refreshes silently on `didPopNext` / app resume / tab switch.
- **Interactions & exits:** "Invite a watcher" → `inviteWatcher(tournamentId:)`; Refresh → `_load`; Configure → `_configure` pushes the low-net / stableford setup screen then reloads; `_LowNetChampView` / `_StablefordChampView` rows expand inline per-round scorecards (`_expanded` set). No spectator-link/share action here (that lives on the per-round `LeaderboardScreen`).

---

### 3.5 · Game setup (part 1)


### SixesSetupScreen
- **File:** lib/screens/sixes_setup_screen.dart
- **Purpose:** Configures Sixes — 2v2 best-ball across three 6-hole segments (rotating partners) — requiring exactly 4 real players.
- **Layout & regions:** GolfAppBar ("Sixes Setup" / "Edit Sixes"); scrolling body: `_HolePlayerCard` (hole header — Hole N + Par/yds/SI — with a `TeamSplitter4` drag-reorder of players, top 2 → Team A, bottom 2 → Team B), `_ScoringFormatPicker` (Classic vs High-Low radios), `HandicapModeSelector`, `_HandicapAllocationPicker` (only in strokes_off mode), `StakeField` + `MaxLiabilityNote` (multiple 5), `_MatchPreview` card; footer `GolfPrimaryButton` in a SafeArea.
- **Components used:** GolfAppBar, `_HolePlayerCard`, TeamSplitter4, `_ScoringFormatPicker`, HandicapModeSelector, `_HandicapAllocationPicker`, SectionCard, StakeField, MaxLiabilityNote, `_MatchPreview`, GolfPrimaryButton.
- **Data:** Knobs — handicap mode (`_handicapMode` net/gross/strokes_off) + net % (`_netPercent`), scoring format (`_scoringFormat` classic/high_low), handicap allocation (`_handicapAllocation` per_segment/full_round, strokes_off only), inline bet unit (`_betCtrl`). Loads via `RoundProvider.loadSixes` / `loadScorecard`; edit-mode prefill from `rp.sixesSummary`. Saves via `RoundProvider.setupSixes(foursomeId, segmentData, handicapMode, netPercent, scoringFormat, handicapAllocation)` (→ ApiClient `postSixesSetup`); bet persisted first via `rp.updateRoundBetUnit`. Builds 3 segments up front (Match 1 = user-dragged P1+P2 vs P3+P4; Matches 2 & 3 randomized so P1 partners everyone once), submitted as play-order thirds (shotgun-aware).
- **States:** `_checkingSetup` / `loadingSixes` → spinner (title switches Edit/Setup); scorecard loading → inner spinner; `_HolePlayerCard` shows a small spinner until 4 players load; a normal (non-returnToHub) already-started match redirects to `/score-entry`; `<4` players shows a SnackBar on Start and disables the button (also gated on `!_stakeOk`). No explicit error view (uses SnackBar with a Retry action on save failure).
- **Interactions & exits:** Start button → `setupSixes` POST then `rp.loadSixes`; if `returnToHub` reloads the round and `pop()`s to the hub (label "Save Configuration"), else `pushReplacementNamed('/score-entry')` (label "Start Match"). Drag rows reorder teams; radios/selector/stepper set config; StakeField sets the round stake.
- **NOTE:** Trailing dangling doc comment (lines ~792-795, "Small card with a single dollar-amount field…") describes a bet-unit card class that is not present — dead/orphaned comment. The old `_initials(name)` helper was removed (noted in-file).

### Points531SetupScreen
- **File:** lib/screens/points_531_setup_screen.dart
- **Purpose:** Configures Points 5-3-1 — a per-player (no-teams) points game — requiring exactly 3 real (non-phantom) players.
- **Layout & regions:** GolfAppBar ("Points 5-3-1 Setup" / "Edit Points 5-3-1"); scrolling body: `_RosterBanner` (3-player status), `HandicapModeSelector`, `_buildPayoutCard` ("How the money settles" — vs Average / Above you / Just leader SegmentedButton + Advanced ExpansionTile with a loss-cap switch + field), `StakeField` ("Value per point"), a "How scoring works" rules card; footer FilledButton (Start Game / Save Configuration) inside the body Column.
- **Components used:** GolfAppBar, `_RosterBanner`, HandicapModeSelector, SegmentedButton, ExpansionTile, SwitchListTile, StakeField, ErrorView, FilledButton.
- **Data:** Knobs — handicap mode (`_mode`) + net % (`_netPercent`), per-point settlement mode (`_perPointMode` average/all/first), optional per-player loss cap (`_capEnabled`/`_capCtrl`; default off, suggested 36× stake), per-point value (`_betCtrl`). Loads via ApiClient `getPoints531Summary`; edit-mode adopts saved mode/net%/perPointMode/lossCap. Saves via ApiClient `postPoints531Setup(foursomeId, handicapMode, netPercent, payoutStyle:'per_point', perPointMode, lossCap)` (always per_point — no pool for points); bet persisted first via `rp.updateRoundBetUnit`, then `rp.loadPoints531`.
- **States:** `_loading` → spinner; `_error` → ErrorView (friendlyError/isNetworkError, onRetry `_load`); configured & non-returnToHub → redirects to `/score-entry`; roster-invalid → `_RosterBanner` shows error styling ("needs exactly 3 real players") and Start is disabled (`!_rosterValid`); Start also gated on `!_stakeOk`.
- **Interactions & exits:** Start → `postPoints531Setup` then `loadPoints531`; returnToHub reloads round + `pop()`, else `pushReplacementNamed('/score-entry')`. SegmentedButton picks settlement; Advanced tile toggles/edits the cap; StakeField sets per-point value.

### VegasSetupScreen
- **File:** lib/screens/vegas_setup_screen.dart
- **Purpose:** Configures Las Vegas — fixed 2v2 teams whose scores form a two-digit "number" — requiring exactly 4 players.
- **Layout & regions:** AppBar ("Las Vegas — Setup" / "Edit Vegas"); ListView body: "Teams" SectionCard (`TeamSplitter4` drag split, [0,1]=team1 [2,3]=team2), `HandicapModeSelector`, "Birdies" SectionCard (Flip vs Multiply SegmentedButton + explanation), Carryover SwitchListTile, "Net double-bogey max" SwitchListTile, `StakeField` ("Stake ($ per point, per player)"), "Cap each player's loss" SwitchListTile + conditional `GolfTextField` (max loss); footer FilledButton (Start Las Vegas / Save Configuration).
- **Components used:** AppBar, SectionCard, TeamSplitter4, HandicapModeSelector, SegmentedButton, SwitchListTile, StakeField, GolfTextField, ErrorView, FilledButton.
- **Data:** Knobs — handicap mode (`_mode`) + net % (`_netPercent`), net max double bogey (`_netMaxDbl`), birdie mode (`_birdieMode` flip/multiplier), carryover (`_carryover`), loss cap (`_capEnabled`/`_capCtrl`), team ordering (`_ordered`), stake (`_betCtrl`). Loads via ApiClient `getVegasSummary`; edit-mode restores mode/net%/netMaxDbl/birdieMode/carryover/teams/stake. Saves via ApiClient `postVegasSetup(foursomeId, team1PlayerIds, team2PlayerIds, handicapMode, netPercent, netMaxDoubleBogey, birdieMode, carryover, lossCap)`; bet persisted first via `rp.updateRoundBetUnit`.
- **States:** `_loading` → spinner; `_error` → ErrorView (onRetry `_load`); already-started (in_progress/complete) & non-returnToHub → redirect to `/score-entry`; roster ≠ 4 → body shows centered "Las Vegas needs exactly four players (two teams of two)."; Start disabled unless `_rosterValid && _stakeOk`.
- **Interactions & exits:** Start → `postVegasSetup`; returnToHub reloads round + `pop()`, else `pushReplacementNamed('/score-entry')`. Drag sets teams; SegmentedButton/switches set options; StakeField + cap set money.

### FourballSetupScreen
- **File:** lib/screens/fourball_setup_screen.dart
- **Purpose:** Configures Fourball — a single 18-hole 2v2 best-ball match-play game — requiring exactly 4 players (two fixed teams of two).
- **Layout & regions:** AppBar ("Fourball — Setup" / "Edit Fourball"); ListView body: "Teams" SectionCard (`TeamSplitter4` drag split + explanation), `HandicapModeSelector`, "The Match" SectionCard (rules text + `StakeField` "Match stake ($ per player)"); footer FilledButton (Start Fourball / Save Configuration).
- **Components used:** AppBar, SectionCard, TeamSplitter4, HandicapModeSelector, StakeField, ErrorView, FilledButton.
- **Data:** Knobs — handicap mode (`_mode`) + net % (`_netPercent`), team ordering (`_ordered`), match bet (`_betCtrl`). Loads via ApiClient `getFourballSummary`; edit-mode restores mode/net%/betAmount/teams. Saves via ApiClient `postFourballSetup(foursomeId, team1PlayerIds, team2PlayerIds, handicapMode, netPercent, betAmount)`; also persists via `rp.updateRoundBetUnit` when the parsed value differs.
- **States:** `_loading` → spinner; `_error` → ErrorView (onRetry `_load`); already-started (in_progress/complete/halved) & non-returnToHub → redirect to `/score-entry`; roster ≠ 4 → body shows centered "Fourball needs exactly four players (two teams of two)."; Start disabled unless `_rosterValid && _stakeOk`.
- **Interactions & exits:** Start → `postFourballSetup`; returnToHub reloads round + `pop()`, else `pushReplacementNamed('/score-entry')` (no dedicated play screen; results show on the leaderboard). Drag sets teams; HandicapModeSelector + StakeField set the rest.

### SkinsSetupScreen
- **File:** lib/screens/skins_setup_screen.dart
- **Purpose:** Configures Skins — an individual per-hole contest — for 2–4 real players; can be primary or a side game.
- **Layout & regions:** GolfAppBar ("Skins Setup" / "Edit Skins"); scrolling body: `_RosterBanner` (2–4 status), `_participantCard` ("Who's in the bet" subset checkboxes, only for 3–4 players), `HandicapModeSelector`, "Game options" card (Carryover switch + Junk skins switch — junk hidden when a side game), "How the money settles" card (Pool vs Per skin SegmentedButton; per-skin reveals vs Average/Above you/Just leader + Advanced loss-cap), `StakeField` ("Ante per player" / "Value per skin"), "How scoring works" rules card; footer `GolfPrimaryButton` (Start Game / Save Configuration).
- **Components used:** GolfAppBar, `_RosterBanner`, `_participantCard`, CheckboxListTile, HandicapModeSelector, SwitchListTile, SegmentedButton, ExpansionTile, StakeField, ErrorView, GolfPrimaryButton.
- **Data:** Knobs — handicap mode (`_mode`) + net % (`_netPercent`), carryover (`_carryover`), allow junk (`_allowJunk`, forced false when side game), payout style (`_payoutStyle` pool/per_point), per-point mode (`_perPointMode` average/all/first), loss cap (`_capEnabled`/`_capCtrl`, per-point only), participant subset (`_participantIds`, null = everyone), value (`_betCtrl` = pool ante or per-skin rate). Loads via ApiClient `getSkinsSummary`. Saves via ApiClient `postSkinsSetup(foursomeId, handicapMode, netPercent, carryover, allowJunk, payoutStyle, perPointMode, perPointRate, lossCap, participantPlayerIds)`; pool mode also writes the round stake via `rp.updateRoundBetUnit`, then `rp.loadSkins`. Side-game detection via `resolvePrimary(round.primaryGame, activeGames) != 'skins'`.
- **States:** `_loading` → spinner; `_error` → ErrorView (onRetry `_load`); configured & non-returnToHub → redirect to `/score-entry`; roster invalid → `_RosterBanner` error text ("needs at least 2 players" / "supports at most 4"); subset < 2 → "Pick at least 2 players." + `_participantsValid` false; Start gated on `_rosterValid && _moneyOk && _participantsValid`.
- **Interactions & exits:** Start → `postSkinsSetup` then `loadSkins`; returnToHub reloads round + `pop()`, else `pushReplacementNamed('/score-entry')`. Checkboxes set the bet subset; switches/SegmentedButtons set options; StakeField sets ante/rate.

### SpotsSetupScreen
- **File:** lib/screens/spots_setup_screen.dart
- **Purpose:** Configures Spots — a hand-tallied capture add-on (one-putt, sandy, barky, …) settled on its own pot — for 2–4 real players; side-game-only (never a primary).
- **Layout & regions:** GolfAppBar ("Spots Setup" / "Edit Spots"); scrolling body: "How the money settles" card (Pool vs Per spot SegmentedButton; per-spot reveals vs Average/Above you/Just leader + Advanced loss-cap), `StakeField` ("Ante per player" / "Value per spot"), "How Spots works" rules card; footer `GolfPrimaryButton` (Start Spots / Save Configuration).
- **Components used:** GolfAppBar, SegmentedButton, ExpansionTile, SwitchListTile, StakeField, ErrorView, GolfPrimaryButton.
- **Data:** Knobs — payout style (`_payoutStyle` pool/per_point, default per_point), per-point mode (`_perPointMode` average/all/first, default all = "pay around"), loss cap (`_capEnabled`/`_capCtrl`, per-point only), spot value (`_betCtrl`). Loads via ApiClient `getSpotsSummary`; edit-mode restores payoutStyle/perPointMode/lossCap/betUnit. Saves via ApiClient `postSpotsSetup(foursomeId, betUnit, payoutStyle, perPointMode, lossCap)` then `rp.loadSpots`. No handicap knob (spots are captured, not derived).
- **States:** `_loading` → spinner; `_error` → ErrorView (onRetry `_load`); configured & non-returnToHub → redirect to `/score-entry`; Start gated on `_rosterValid && _stakeOk`. `_rosterValid` (2–4) is checked in `_start` but there is no on-screen roster banner/warning here.
- **Interactions & exits:** Start → `postSpotsSetup` then `loadSpots`; returnToHub reloads round + `pop()`, else `pushReplacementNamed('/score-entry')` (capture happens on the score-entry screen; no dedicated play screen). SegmentedButtons set settlement; Advanced toggles cap; StakeField sets spot value.

### HonorsSetupScreen
- **File:** lib/screens/honors_setup_screen.dart
- **Purpose:** Configures Honors — a derived carry-token points overlay (hold "the honor" by winning a hole outright, score 1 pt/held hole) — for 2–4 real players; side-game-only (defaults `returnToHub: true`).
- **Layout & regions:** GolfAppBar ("Honors Setup" / "Edit Honors"); scrolling body: `_RosterBanner` (2–4 status), `HandicapModeSelector`, `_participantCard` ("Who's playing Honors" subset checkboxes, only 3–4 players), `_buildPayoutCard` ("How the money settles" — vs Average/Above you/Just leader SegmentedButton + Advanced loss-cap), `StakeField` ("Value per point"), "How Honors works" rules card; footer FilledButton (Start Game / Save Configuration).
- **Components used:** GolfAppBar, `_RosterBanner`, HandicapModeSelector, `_participantCard`, CheckboxListTile, SegmentedButton, ExpansionTile, SwitchListTile, StakeField, ErrorView, FilledButton.
- **Data:** Knobs — handicap mode (`_mode`) + net % (`_netPercent`), per-point settlement mode (`_perPointMode` average/all/first), loss cap (`_capEnabled`/`_capCtrl`, off by default), participant subset (`_participantIds`, null = everyone), per-point value (`_betCtrl`). Loads via ApiClient `getHonorsSummary`; edit-mode restores mode/net%/perPointMode/lossCap/participants. Saves via ApiClient `postHonorsSetup(foursomeId, handicapMode, netPercent, payoutStyle:'per_point', perPointMode, lossCap, participantPlayerIds)`; bet persisted first via `rp.updateRoundBetUnit`, then `rp.loadHonors`.
- **States:** `_loading` → spinner; `_error` → ErrorView (onRetry `_load`); configured & non-returnToHub → redirect to `/score-entry`; roster invalid → `_RosterBanner` error ("Honors needs 2 to 4 real players."); subset < 2 → "Pick at least 2 players." + `_participantsValid` false; Start gated on `_rosterValid && _participantsValid && _stakeOk`.
- **Interactions & exits:** Start → `postHonorsSetup` then `loadHonors`; returnToHub (the normal path) reloads round + `pop()`, else `pushReplacementNamed('/score-entry')` (no dedicated play/entry screen — shows only as a leaderboard tab). Checkboxes set participants; SegmentedButton sets settlement; Advanced toggles cap.
- **NOTE:** The backend `pool` payout style is not surfaced here (only the three per-point modes) — `payoutStyle` is hard-coded `'per_point'`.

### WolfSetupScreen
- **File:** lib/screens/wolf_setup_screen.dart
- **Purpose:** Configures Wolf — rotating-Wolf hole game (partner / Lone / Blind) — for exactly 3 or 4 real players.
- **Layout & regions:** GolfAppBar ("Wolf Setup" / "Edit Wolf"); scrolling body: `_RosterBanner` (3-or-4 status), "Wolf rotation" `_SectionCard` (`_RotationList` drag-reorder seat order), `HandicapModeSelector`, "Point values" `_SectionCard` (`_Stepper`s: Lone Wolf, Blind Wolf, and — 4-player only — Team win), "Options" `_SectionCard` (Wolf loses ties; 4-player: non-Wolf clean-win bonus; 4-player & full-18: last-place-Wolf-on-17&18 and must-go-Lone/Blind-by-16), `StakeField`, "Cap losses" `_SectionCard` (switch + max-loss field), "How Wolf works" rules card; footer FilledButton (Start Game / Save Configuration).
- **Components used:** GolfAppBar, `_RosterBanner`, `_SectionCard`, `_RotationList` (ReorderableListView), HandicapModeSelector, `_Stepper`, SwitchListTile, StakeField, TextField, ErrorView, FilledButton.
- **Data:** Knobs — handicap mode (`_mode`) + net % (`_netPercent`), rotation order (`_order`), lone/blind/team points (`_lonePoints`/`_blindPoints`/`_teamPoints` steppers), `_wolfLosesTies`, `_nonWolfBonus`, `_lastPlace1718`, `_requireLoneOrBlind`, loss cap (`_capEnabled`/`_capCtrl`), stake (`_betCtrl`). Loads via ApiClient `getWolfSummary` (non-empty `wolfOrder` = configured tell). Saves via ApiClient `postWolfSetup(foursomeId, handicapMode, netPercent, wolfOrder, loneWolfPoints, blindWolfPoints, teamWinPoints, wolfLosesTies, nonWolfBonus, lastPlaceWolf1718, requireLoneOrBlind, lossCap)`; result set via `rp.setWolfSummary`; bet persisted first via `rp.updateRoundBetUnit`. Partial (<18-hole) rounds hide and force off the 17/18 and by-16 rules.
- **States:** `_loading` → spinner; `_error` → ErrorView (onRetry `_load`); already-configured & non-returnToHub → redirect to `/wolf` (has a dedicated play screen); roster invalid → `_RosterBanner` error ("Wolf needs 3 or 4 real players."); Start gated on `_rosterValid && _stakeOk`.
- **Interactions & exits:** Start → `postWolfSetup`; returnToHub reloads round + `pop()`, else `pushReplacementNamed('/wolf')`. Drag reorders the Wolf rotation; steppers set point values; switches set options; StakeField + cap set money.

### RabbitSetupScreen
- **File:** lib/screens/rabbit_setup_screen.dart
- **Purpose:** Configures Rabbit — catch/hold-the-rabbit hole game — for exactly 3 real players.
- **Layout & regions:** GolfAppBar ("Rabbit Setup" / "Edit Rabbit"); scrolling body: `_RosterBanner` (3-player status), `HandicapModeSelector`, "Rabbit mode" `_Card` (Accumulate vs Stop RadioListTiles), "Match format" `_Card` (segment-split RadioListTiles from `_segmentOptions` — even splits only for the round's hole count), `StakeField` ("Stake per match"), "How Rabbit works" rules card; footer FilledButton (Start Game / Save Configuration).
- **Components used:** GolfAppBar, `_RosterBanner`, HandicapModeSelector, `_Card`, RadioListTile, StakeField, ErrorView, FilledButton.
- **Data:** Knobs — handicap mode (`_mode`) + net % (`_netPercent`), accumulate vs stop (`_accumulate`), number of segments (`_segments`, default 3), stake (`_betCtrl`). Loads via ApiClient `getRabbitSummary` (non-empty `segments` = configured tell); reconciles saved `_segments` against valid splits for the hole count. Saves via ApiClient `postRabbitSetup(foursomeId, handicapMode, netPercent, accumulate, numSegments)`; result set via `rp.setRabbitSummary`; bet persisted first via `rp.updateRoundBetUnit`.
- **States:** `_loading` → spinner; `_error` → ErrorView (onRetry `_load`); already-configured & non-returnToHub → redirect to `/rabbit` (has a dedicated play screen); roster ≠ 3 → `_RosterBanner` error ("Rabbit needs exactly 3 real players."); Start gated on `_rosterValid && _stakeOk`.
- **Interactions & exits:** Start → `postRabbitSetup`; returnToHub reloads round + `pop()`, else `pushReplacementNamed('/rabbit')`. Radios set rabbit mode + segment format; StakeField sets the pot.

---

#### Cross-screen observations
- **Handicap modes** are uniform across all nine: Net (with an adjustable %), Gross, and Strokes-Off-Low, via the shared `HandicapModeSelector` (except Spots, which has no handicap because it is captured, not derived). The casual default everywhere is `strokes_off`.
- **returnToHub pattern** is identical: when true (round creation / hub "Edit Configuration"), the screen stays on the form even if configured, saves, reloads the round, and `pop()`s back to the `/round` hub with a "Save Configuration" button label; when false it `pushReplacementNamed`s to the play/entry screen with a per-game "Start …" label. Honors uniquely defaults `returnToHub` to `true` (side-game-only).
- **Stake gate** is consistent: `StakeField` reports `_stakeOk` true once a positive stake is entered or "play for fun" is chosen, and every Start button is disabled until then; a previously-set round `betUnit > 0` pre-fills the field.
- **Play-screen vs generic entry:** Sixes, Points 5-3-1, Vegas, Fourball, Skins, Spots, Honors route to `/score-entry`; Wolf → `/wolf` and Rabbit → `/rabbit` have dedicated play screens.
- **Side-game-only:** Spots and Honors are never a primary; Skins can be either and hides its junk toggle (forcing `allow_junk:false`) when it is a side game.

---

### 3.6 · Game setup (part 2)


Derived entirely from Dart source under `mobile/lib/screens/` (routes confirmed in `mobile/lib/main.dart`).

---

### TripleCupSetupScreen
- **File:** lib/screens/triple_cup_setup_screen.dart
- **Purpose:** Configures the One-Round Triple Cup (three 6-hole segments — Fourball, Foursomes alt-shot, Singles); 2–4 real players, ≥1 per team (2v1 only allowed in cup rounds, rejected client-side for casual).
- **Layout & regions:** AppBar (`One-Round Triple Cup — Setup` / `Edit Triple Cup`); scrolling body top-to-bottom: Teams `SectionCard` (TeamSplitter4 for 4 players, else per-player Blue/Orange `SegmentedButton` + colored team chips), HandicapModeSelector, Segment order `SectionCard` (Foursomes-first switch), Foursomes (alt-shot) handicap `SectionCard` (Low%/High% fields), optional 2v1 phantom-donor note `SectionCard`, StakeField + MaxLiabilityNote, "How it works" rules `SectionCard`; persistent bottom `FilledButton` (Start Match / Save Configuration) in a SafeArea footer.
- **Components used:** SectionCard, TeamSplitter4, HandicapModeSelector, StakeField, MaxLiabilityNote, GolfTextField (`_pctField` for alt-shot Low/High %), InlineMessage, SegmentedButton, SwitchListTile, ErrorView, private `_ColoredTeamChip` (uses `kTripleCupTeam1Color`/`kTripleCupTeam2Color`).
- **Data:** Knobs — team assignment/order (`_teamMap`, `_team1Order`/`_team2Order`; order drives 2v2 singles pairing), handicap mode (default `strokes_off`) + net %, alt-shot low/high % (default 50/50), `_foursomesFirst` segment-order swap, round-level bet unit. Loads via `client.getTripleCupSummary(foursomeId)`; saves via `rp.setupTripleCup(...)` and `rp.updateRoundBetUnit`. User edits teams, handicap, segment order, alt-shot allowance, stake.
- **States:** loading (CircularProgressIndicator); error (ErrorView with retry); roster warnings via InlineMessage ("Need at least 2 real players.", casual-2v1 not allowed, "Each team must have at least 1 player."); Start disabled until `_rosterValid && _stakeOk`; empty roster not explicitly handled beyond roster-valid gate.
- **Interactions & exits:** Start button → optional bet-unit update + `setupTripleCup` POST; if `returnToHub` → reload round + `Navigator.pop()` (back to hub); else `pushReplacementNamed('/score-entry', foursomeId)`. On load an already-started game (non-returnToHub) auto-`pushReplacementNamed('/score-entry')`. Team toggles/splitter, handicap selector, segment switch, alt-shot % fields, stake field all mutate state.

---

### MultiSkinsSetupScreen
- **File:** lib/screens/multi_skins_setup_screen.dart
- **Purpose:** Configures Multi-Group (round-level) Skins — a Halved-members-only pool crossing every foursome in the round; needs ≥2 participants.
- **Layout & regions:** GolfAppBar (`Multi-Group Skins Setup` / `Edit Multi-Group Skins`); ListView body: intro text, HandicapModeSelector, Divider, entry-fee row (Row: label + `TextField`) with live pool total + "Play for fun — no stakes" CheckboxListTile, Divider, Participants flat CheckboxListTile list (round members; login-less shown disabled with "Not on Halved" subtitle), optional "Add golfers" section (external on-app golfers); persistent Start button (SafeArea footer, outside ListView) + `!_canStart` InlineMessage.
- **Components used:** GolfAppBar, HandicapModeSelector, CheckboxListTile, TextField, InlineMessage, ErrorView, FilledButton.
- **Data:** Knobs — handicap mode (default `net`; SO-Low intentionally not used cross-group) + net %, entry fee per player (`_betCtrl`, default $10), participant set (`_participants`, defaults to all eligible on-app members). Loads via `client.getMultiSkinsSummary(roundId)` + `client.getPlayers()` (best-effort, for on-app eligibility + external golfers); saves via `client.postMultiSkinsSetup(...)`. Roster is Halved-only (`_onAppIds`); login-less golfers never auto-checked and cannot join.
- **States:** loading (bare Scaffold + spinner); error (Scaffold + ErrorView retry); player-roster fetch failure degrades silently (nothing eligible, external section hidden); Start disabled unless `_participantCount >= 2 && (_betUnit>0 || _noStakes)` with warning ("Pick at least 2 participants." / "Enter an entry fee, or tick 'Play for fun'.").
- **Interactions & exits:** Start → `postMultiSkinsSetup` then `rp.loadRound` + `rp.loadMultiSkins`; if `returnToHub` → reload round + `Navigator.pop()`; else `pushReplacementNamed('/multi-skins', roundId)`. Failure shows SnackBar. Handicap selector, entry-fee field (clears no-stakes when >0), no-stakes checkbox (forces fee to 0), participant/external checkboxes mutate state.

---

### NassauSetupScreen
- **File:** lib/screens/nassau_setup_screen.dart
- **Purpose:** Configures the Nassau family — fixed-team 9-9-18 best-ball match for 1v1/2v2; 2–4 real players, ≥1 per team (Singles Match strictly 1v1). Serves 3 routes via flags: `/nassau-setup` (full F9/B9/Overall), `/nassau-setup-18` (`overallOnly:true` → "Singles Match", one 18-hole bet), `/nassau-nine-setup` (`singleMatch:true` → "Nassau Nine", one match over played holes, keeps teams + presses). `_gameType` = `nassau` / `match_18` / `nassau_nine`.
- **Layout & regions:** AppBar (title from `_gameTitle` slug: `Nassau` / `Singles Match` / `Nassau Nine`, prefixed `Edit ` when editing); scrolling body: Teams `SectionCard` (shown for side games, Singles Match with >2 players, or team Nassau with ≥3 — participant Out/Blue/Orange rows for subset/Singles picking, TeamSplitter4 for 4-player teams, else Blue/Orange toggles; match-type SegmentedButton for side games; team summary chips + roster-invalid text), HandicapModeSelector, StakeField, Advanced `ExpansionTile` (Nassau only, non-match18): press stakes chips (None/Manual/Auto/Both — Manual/Both hidden for side games), press-unit GolfTextField, game-variant chips (Standard / 2nd Ball Tiebreak / Claremont — last two need 2v2), loss-cap switch + field (only when escalating), MaxLiabilityNote (when non-escalating), "How Nassau works" rules `SectionCard`; persistent Start Match / Save Configuration footer.
- **Components used:** SectionCard, HandicapModeSelector, StakeField, MaxLiabilityNote, TeamSplitter4, GolfTextField, SegmentedButton, ChoiceChip (`_pressChip`/`_variantChip`), ExpansionTile, SwitchListTile, ErrorView; helpers from `utils/nassau_team_style.dart` (`nassauTeamColor`/`nassauTeamDot`) and `resolvePrimary` from `game_catalog.dart`.
- **Data:** Knobs — team map (`_teamMap`; Out = removed), handicap mode (default `strokes_off`) + net %, press mode (`none`/`manual`/`auto`/`both`), press unit ($), variant (`none`/`tiebreak_2nd`/`claremont`), bet legs `_playFront`/`_playBack`/`_playOverall` (+ `_singleMatch`), optional loss cap, round-level bet unit. Loads via `client.getNassauSummary(foursomeId, gameType:)`; saves via `rp.setupNassau(...)` (+ `rp.updateRoundBetUnit`). `_isSideGame` (when `resolvePrimary` ≠ `_gameType`) restricts presses to auto-only, allows leaving players Out, defaults to overall-only.
- **States:** loading (spinner); error (ErrorView retry); roster-invalid text ("Each team must have at least 1 player."); Start disabled unless `_rosterValid && _stakeOk`; variants auto-disabled/reset when not 2v2.
- **Interactions & exits:** On load an in_progress/complete game (non-returnToHub) → `pushReplacementNamed('/score-entry')`. Start → optional bet-unit update + `setupNassau`; if `returnToHub` → reload round + `Navigator.pop()`; else `pushReplacementNamed('/score-entry', foursomeId)`. Team/participant toggles, splitter, match-type toggle, handicap selector, stake, press chips, press-unit, variant chips, cap switch/field mutate state.

---

### IrishRumbleSetupScreen
- **File:** lib/screens/irish_rumble_setup_screen.dart (first of two classes in this file)
- **Purpose:** Configures the round-level Irish Rumble tournament game (per-group best-N-nets across segments); handicap + variant + entry fee/payouts. Route `/irish-rumble-setup` (no returnToHub flag).
- **Layout & regions:** 2-step wizard. AppBar title `Irish Rumble · Game` (step 0) / `Irish Rumble · Money` (step 1). Step 0 (`_gameBody`): optional threesome-leveling notice, `_VariantPicker` (Classic / Arizona Shuffle / Shuffle par-based / Custom per-hole radios), `_SegmentPreview` (collapsed balls-per-hole runs), `_CustomBallsEditor` (18 tappable per-hole cells, custom only), net-double-bogey hint, HandicapModeSelector or `_LockedHandicapChip` (tournament), NetDoubleBogeyCard. Step 1 (`_moneyBody`): Entry Fee `SectionCard` (GolfTextField + "no stakes" checkbox), Payouts `SectionCard` (PayoutConfigField with per-player split subtitles), error banner. Footer `_nav`: Back (step 1) / Next (step 0) / Save Setup / Save Changes.
- **Components used:** HandicapModeSelector, PayoutConfigField (+ `suggestPayouts`), GolfTextField, SectionCard, NetDoubleBogeyCard, `_VariantPicker`, `_SegmentPreview`, `_CustomBallsEditor`, `_SegmentRow`, `_LockedHandicapChip`, `_ErrorBanner`, ErrorView.
- **Data:** Knobs — handicap mode (default `net`) + net %, variant (default `classic`) + `_customBalls` (18×, default 2), entry fee per player (default 5) + `_noStakes`, payout places 1–4 (group totals). Loads via `client.getIrishRumbleConfig(roundId)` (reads `group_sizes`, `hole_pars`, `variant`, `custom_balls`, `num_players`, `is_tournament_round`, etc.); saves via `client.postIrishRumbleSetup(...)`; net-double-bogey via `RoundProvider.updateRoundNetMaxDoubleBogey`. `_ballsPerHole` mirrors backend `_balls_per_hole`.
- **States:** loading (spinner); error (ErrorView retry, or `_ErrorBanner` inline on step 1); pool-imbalance blocks Save (error message payouts vs pool); Save disabled unless `_poolBalanced && _stakeChosen`; tournament rounds lock handicap (read-only chip). No explicit empty state.
- **Interactions & exits:** Next → step 1; Back → step 0; Save → `postIrishRumbleSetup` then `Navigator.pop(true)` (no returnToHub path — always pops with result). Variant radios, custom-ball cells (cycle 1→2→3→4), handicap selector, net-dbl-bogey card, entry fee, no-stakes, payout fields/suggest mutate state.
- **NOTE:** No `returnToHub` support (unlike the casual screens); always `pop(true)`.

---

### LowNetSetupScreen (Stroke Play / Low Net)
- **File:** lib/screens/irish_rumble_setup_screen.dart (SECOND class in the same file; route `/low-net-setup`)
- **Purpose:** Configures casual/tournament Stroke Play (a.k.a. Low Net) — individual net-score competition with entry fee + paid places; supports a casual subset side bet and tournament prize exclusions.
- **Layout & regions:** Single-step. AppBar (`Stroke Play — Setup` / `Edit Stroke Play`); scrolling body: HandicapModeSelector or `_LockedHandicapChip` (tournament), "Who's in the bet" `_participantCard` (casual, ≥3 players — subset checkboxes), NetDoubleBogeyCard (round-level), Entry Fee `SectionCard` (GolfTextField + "no stakes" checkbox), Payouts `SectionCard` (PayoutConfigField), Prize Exclusions `_buildExclusionsSection` (tournament only — championship-placer suggestions + toggle list), inline error banner; persistent Save button footer (Save Setup / Save Configuration).
- **Components used:** HandicapModeSelector, `_LockedHandicapChip`, PayoutConfigField (+ `suggestPayouts`), GolfTextField, SectionCard, NetDoubleBogeyCard, CheckboxListTile, `_ErrorBanner`, ErrorView.
- **Data:** Knobs — handicap mode (default `net`) + net %, participant subset (`_participantIds`, null = all), entry fee (default 5) + `_noStakes`, payout places 1–4, excluded player IDs (tournament), round-level net-max-double-bogey. Loads via `client.getLowNetConfig(roundId)` (reads `payouts`, `excluded_player_ids`, `championship_placers`, `participant_player_ids`, `is_tournament_round`, handicap fields — casual prefers config's own `net_percent`/`handicap_mode`, tournament prefers round-level); saves via `client.postLowNetSetup(...)`.
- **States:** loading (spinner); error (ErrorView retry / inline banner); pool-imbalance blocks Save; subset must be ≥2 (`_participantsValid`); Save disabled unless `_poolBalanced && _stakeChosen && _participantsValid`; exclusions show "No championship placers found…" when empty.
- **Interactions & exits:** Save → `postLowNetSetup`; if `returnToHub` → reload round + `Navigator.pop()`; else `Navigator.pop(true)`. Handicap selector, participant checkboxes, net-dbl-bogey card, entry fee, no-stakes, payout fields/suggest, exclusion toggles/"Exclude all placers" mutate state.

---

### StablefordSetupScreen
- **File:** lib/screens/stableford_setup_screen.dart
- **Purpose:** Configures casual Stableford — an editable 6-bucket points table with pool or per-point payout; supports subset side bet. Route `/stableford-setup`.
- **Layout & regions:** Single scrolling ListView (NOT a 2-step wizard in code — the brief's "2-step" refers to its conceptual handicap→payout grouping; UI is one page). AppBar (`Stableford Setup` / `Edit Stableford`); body sections: HandicapModeSelector (`allowStrokesOff:false`), "Who's in the bet" `_participantCard` (≥3 players), Points table card (3 preset ActionChips: Standard / Modified (pro) / Reward birdies + 6 editable signed integer bucket fields), "How the money settles" card (Pool vs Per-point SegmentedButton; per-point mode SegmentedButton vs Average / Above you / Just first + Advanced loss-cap ExpansionTile), Stake card (Ante per player OR Value per point + "no stakes" checkbox; pool shows pot total + PayoutConfigField); persistent Save footer (Start Game / Save Configuration).
- **Components used:** HandicapModeSelector, PayoutConfigField (+ `suggestPayouts`), SegmentedButton, ActionChip, CheckboxListTile, ExpansionTile, SwitchListTile, TextField (bucket + stake + cap, with `FilteringTextInputFormatter`), ErrorView; private `_card`/`_cardHeader` helpers.
- **Data:** Knobs — handicap mode (`net`/`gross` only, default `net`) + net %, 6-bucket points table (`_points`, default Standard 5/4/3/2/1/0, negatives allowed), payout style (`pool`/`per_point`), per-point mode (`average`/`all`/`first`), optional per-player loss cap (per-point), entry fee/ante (default 5) or per-point rate (default 1), payout places, participant subset. Loads via `client.getStablefordConfig(roundId)`; saves via `client.postStablefordSetup(...)`. `_editing` set when saved payouts exist.
- **States:** loading (spinner); error (ErrorView retry); subset must be ≥2; Save disabled unless `_stakeChosen && _participantsValid`. No explicit empty/pool-balance gate (pool auto-defaults to winner-take-all on fresh round).
- **Interactions & exits:** Save → `postStablefordSetup`; if `returnToHub` → reload round + `Navigator.pop()`; else jump straight to scoring `pushReplacementNamed('/score-entry', firstFoursome.id)` (fallback `pop(true)` if no foursome). Preset chips apply tables, bucket/stake/cap fields, style/mode toggles, no-stakes, participant checkboxes, payout suggest mutate state.
- **NOTE:** Brief describes a "2-step wizard"; the current source renders a single scrolling page (all sections at once), unlike IrishRumble's real `_step` wizard.

---

### PinkBallSetupScreen
- **File:** lib/screens/pink_ball_setup_screen.dart
- **Purpose:** Staff-only round-level config for Pink Ball (team ball-rotation game) — ball colour label + entry fee/payouts; per-group hole rotation is set later on the scoring screen. Route `/pink-ball-setup`.
- **Layout & regions:** AppBar `Pink Ball Setup`; ListView body: Game Settings `Card` (Ball Color GolfTextField + entry-fee GolfTextField + pool explainer), Payouts `Card` (PayoutConfigField with per-player split subtitles + "pool depends on players" info when unset), info `Card` ("each group sets their own ball rotation…"), error container; `bottomNavigationBar` Save button (Save Setup / Save Changes).
- **Components used:** GolfTextField, PayoutConfigField (+ `suggestPayouts`), Card, FilledButton (no HandicapModeSelector — no handicap knob on this screen).
- **Data:** Knobs — ball colour (`_colorCtrl`, default "Pink"), entry fee per player, payout places 1–4 (group totals). Loads via `client.getPinkBallSetup(roundId)` (reads `payouts`, `entry_fee`, `ball_color`, `num_players`, `foursomes` for group sizes); saves via `client.postPinkBallSetup(...)`.
- **States:** loading (spinner, hides footer); error shown as inline error container (`_error` is a String); pool-imbalance blocks Save; Save disabled unless `_poolBalanced`; "Pool depends on number of players" info when `_numPlayers==0` and a fee is entered.
- **Interactions & exits:** Save → `postPinkBallSetup` then `rp.loadRound(roundId)` + `Navigator.pop(true)` (result signals wizard Step 6 to flip the configured icon). No returnToHub / score-entry jump. Colour field, entry-fee field, payout fields/suggest mutate state.
- **NOTE:** No handicap mode selector and no `returnToHub` flag; `_error` typed as `String?` (unlike the `Object?`/ErrorView pattern elsewhere).

---

### MatchPlaySetupScreen
- **File:** lib/screens/match_play_setup_screen.dart
- **Purpose:** Configures a foursome's match-play bracket (semis → final/consolation) before play — seedings, handicap, entry fee, payouts; 3 or 4 players. Route `/match-play-setup` (args may be int or Map with `allMatchPlayIds`/`peerIds`).
- **Layout & regions:** AppBar `Match Play — Setup`; scrolling body of `SectionCard`s: Bracket Seedings (ReorderableListView with explicit drag handles + seed badges + Auto-seed button + live matchup preview), HandicapModeSelector, Entry Fee (GolfTextField + "no stakes" checkbox + pool line + "Copy to all match plays" OutlinedButton), Payouts (PayoutConfigField + "Copy payouts to peers" OutlinedButton), How it works rules; `bottomNavigationBar` Save Configuration button.
- **Components used:** SectionCard, HandicapModeSelector, PayoutConfigField (+ `suggestPayouts`), GolfTextField, ReorderableListView + ReorderableDragStartListener, OutlinedButton (copy actions), CheckboxListTile, ErrorView; private `_SeedPlayer` model, `_seedBadge`.
- **Data:** Knobs — seed order (`_seedPlayers`, drag/auto-seed by handicap), handicap mode (default `strokes_off`) + net %, entry fee + `_noStakes`, payout places (default 3, 1–4). Loads via `client.getMatchPlay(foursomeId)` (404 = no bracket yet → seed from foursome roster in handicap order); saves via `client.postMatchPlaySetup(...)`. Copy actions POST the fee/payouts to `allMatchPlayIds`/`peerIds`.
- **States:** loading (spinner); error (ErrorView retry); 404 handled as expected "no bracket yet"; Save disabled unless `_stakeChosen`; copy buttons show inline spinners + SnackBar success/failure; seedings placeholder text when empty.
- **Interactions & exits:** On load an in_progress/complete bracket (non-returnToHub) → `pushReplacementNamed('/match-play', foursomeId)`. Save → `postMatchPlaySetup` (seed order + handicap + money) then reload round (returnToHub) and `Navigator.pop()` either way (never jumps to score entry). Drag reorder, Auto-seed, handicap selector, fee/payout fields, suggest, copy-to-all / copy-to-peers mutate state or fire copy POSTs.

---

### ThreePersonMatchSetupScreen
- **File:** lib/screens/three_person_match_setup_screen.dart
- **Purpose:** Configures the Three-Person Match tournament game (9 holes of Points 5-3-1, standings by cumulative points after hole 9); exactly 3 real players. Route `/three-person-match-setup`.
- **Layout & regions:** AppBar `Three-Person Match — Setup`; scrolling body: `_RosterCard` (roster-validity banner + player list), HandicapModeSelector, Entry Fee `SectionCard` (GolfTextField + pool line), Payouts `SectionCard` (PayoutConfigField, max 3 places), "How it works" rules `SectionCard`; `bottomNavigationBar` with optional error InlineMessage + Start Match button.
- **Components used:** SectionCard, HandicapModeSelector, PayoutConfigField (+ `suggestPayouts`, `maxPayouts:3`), GolfTextField, InlineMessage, ErrorView; private `_RosterCard`.
- **Data:** Knobs — handicap mode (default `strokes_off`) + net %, entry fee, payout places 1–3 ("1st"/"2nd"/"3rd"). Loads via `client.getThreePersonMatch(foursomeId)`; saves via `rp.setupThreePersonMatch(...)`.
- **States:** loading (spinner); error (ErrorView when `_summary==null`, else inline InlineMessage); roster warning via `_RosterCard` (needs exactly 3); Start disabled unless `_rosterValid` (exactly 3 players); 404 on load = not-yet-configured (shows defaults).
- **Interactions & exits:** On load a non-pending game (non-returnToHub) → `pushReplacementNamed('/score-entry', foursomeId)`. Start Match → `setupThreePersonMatch` then reload round + `Navigator.pop(returnToHub ? null : true)` (back to caller — round screen / wizard Step 6 / tournament list; never jumps to score entry). Handicap selector, entry fee, payout fields/suggest mutate state.
- **NOTE:** `_pool` getter is `_entryFee * (_rosterValid ? 3 : 3)` — the ternary is dead (both branches 3); effectively always ×3.

---

#### Cross-screen notes
- **Shared widgets** recur across these screens: `HandicapModeSelector`, `PayoutConfigField` (+ the `suggestPayouts` helper), `StakeField`, `MaxLiabilityNote`, `SectionCard`, `TeamSplitter4`, `GolfTextField`, `InlineMessage`, `ErrorView`, `NetDoubleBogeyCard`.
- **`returnToHub` pattern** (Triple Cup, Multi-Skins, Nassau, Low Net, Stableford, Match Play, Three-Person Match): opened from round creation / "Edit Configuration" — stays on the form when already configured and pops back to the `/round` hub on save instead of launching scoring. Irish Rumble and Pink Ball do NOT expose this flag (`/irish-rumble-setup`, `/pink-ball-setup` construct without it).
- **Route→flag mapping** (main.dart): `_routeId` / `_routeReturnToHub` unpack int-or-Map args; NassauSetupScreen is the only screen reached by three routes via `overallOnly`/`singleMatch` flags.
- **Save-button label logic** generally: `Save Configuration` when `_editing || returnToHub`, else `Start Match` / `Start Game` / `Start Multi-Group Skins`; Irish Rumble/Pink Ball use `Save Setup`/`Save Changes`; Match Play always `Save Configuration`.

---

### 3.7 · Game play & standings


All routes below are registered in `lib/main.dart` and wrapped in `RoundLandscapeScorecard` — rotating the phone to landscape swaps the screen for the full-group `ScorecardGrid` (widgets/scorecard_grid.dart) while the portrait screen stays mounted via `Offstage`.

---

### Points531Screen
- **File:** lib/screens/points_531_screen.dart
- **Purpose:** Score-entry + live-standings screen for the Points 5-3-1 casual game (3 real players rank per hole, awarding 5/3/1 with tie-splitting, sum 9 per fully-scored hole).
- **Layout & regions:** GolfAppBar ("Points 5-3-1", ✕ leading, sync badge, RoundChatButton, Leaderboard icon) → scrollable body: active-hole `Card` (`_P531HoleScoreCard`: grey hole header "Hole N" + per-tee "Par X | Y yds. | SI: Z", then one `_P531PlayerRow` per player with running "N pts" pill + per-hole "+X" award pill + stroke-dot score box; hot-spot row wrapped in a pine bounding box containing the `InlineScorePicker`) → 18-hole `_P531SummaryGrid` ("Round progress": Hole/Par header rows + per-player gross row with stroke dots + a "pts" row per player, horizontally scrolling, auto-scrolls current hole to slot 7) → bottom nav Row (← Hole N-1 | Hole N+1 →, "Done" on hole 18).
- **Components used:** GolfAppBar, InlineScorePicker, `scoreCellWithDots` (net_score_button.dart), SpotsDots (via SpotsCaptureMixin, spots_capture.dart), RoundChatButton, InlineMessage; local `_P531HoleScoreCard` / `_P531PlayerRow` / `_P531SummaryGrid` / `_PlayerGridRows`.
- **Data:** Displays running points, per-hole 5-3-1 awards, handicap "gets N" chip, stroke dots; from `RoundProvider.loadScorecard` + `loadPoints531` / `points531Summary` (`Points531Summary`), `loadSpots`/`spotsSummary` when `spots` active. Handicap strokes derived via `match_handicap.dart` (`effectiveMatchHandicap`, `strokesOnHole`) supporting net/net-%/gross/strokes_off. User enters gross scores (inline picker) + spots ⊖N⊕ counts.
- **States:** loading → centered `CircularProgressIndicator`; error+no scorecard → `InlineMessage` + Retry; summary loading → small spinner in place of grid; empty scorecard → `SizedBox.shrink`; offline/sync → app-bar sync badge (pending count, tap-to-sync, spinner while syncing), edits stored in `_pending` and reloaded when the sync queue drains.
- **Interactions & exits:** Inline picker sets/edits gross (`submitHole`); tap a scored row to edit in place (`_editHotPid`); Auto-advance (SettingsProvider.autoAdvanceHole) saves + advances when the hole completes; ← / → hole nav; tap a summary-grid cell to jump holes; "Done" → `confirmCompleteRound` → `completeRound` → replace with `/leaderboard`; ✕ leading pops, or on a single-foursome casual round once any score exists becomes "Exit to rounds" (popUntil `/casual-rounds`); Leaderboard icon → `/leaderboard`.

---

### SkinsScreen
- **File:** lib/screens/skins_screen.dart
- **Purpose:** Score-entry + live-standings for the Skins casual game (1 skin/hole to best net, optional carryover, optional manual junk skins, pool settlement).
- **Layout & regions:** GolfAppBar ("Skins", ✕ leading, sync badge, RoundChatButton, Leaderboard icon) → active-hole `Card` (`_SkinsHoleScoreCard`: grey hole header with a "?" help button top-right opening `_SkinsLegendSheet`; per-player `_SkinsPlayerRow` with "gets N" chip, trophy when hole-winner, stroke-dot score box, and a `_JunkDots` "+ junk" / "− N junk +" stepper when `allow_junk`; hot-spot row followed by `InlineScorePicker`; a `_HoleOutcomeStrip` below rows: winner / "Carry →" / "Tied — skin voided") → `_SkinsSummaryGrid` ("Skins Scoring": hole-number header + per-player `_GridCell`s showing skin value / "→" carry / "✗" dead + junk dots + running total, plus a pool/skin-value legend line) → bottom nav (← | → / Done).
- **Components used:** GolfAppBar, InlineScorePicker, `scoreCellWithDots`, RoundChatButton; local `_SkinsHoleScoreCard`, `_SkinsPlayerRow`, `_JunkDots`, `_HoleOutcomeStrip`, `_SkinsSummaryGrid`, `_GridCell`, `_SkinsLegendSheet`. (No SpotsCaptureMixin — Skins excludes Spots.)
- **Data:** Displays per-hole skin outcome, carry, junk, cumulative skins, pool $ / skin value; from `RoundProvider.loadScorecard` + `loadSkins` / `skinsSummary` (`SkinsSummary`/`SkinsHole`/`SkinsPlayerTotal`). Junk POSTed via `AuthProvider.client.postSkinsJunk`. User enters gross scores + per-player-per-hole junk counts (clamped 0–20 locally).
- **States:** loading → spinner; error+no scorecard → red text + Retry; summary loading → small spinner; offline/sync → sync badge + `_pending`/`_pendingJunk` maps, reload on drain (junk save is best-effort, non-fatal on failure).
- **Interactions & exits:** Inline picker + tap-to-edit scored row; junk ± steppers (`_adjustJunk`, saved on hole save via `_saveJunkIfNeeded`); Auto-advance; hole nav + summary-grid cell tap; "Done" → confirm → `completeRound` → `/leaderboard`; ✕ leading (`maybePop`) — no casual "Exit to rounds" variant here; Leaderboard icon.

---

### WolfScreen
- **File:** lib/screens/wolf_screen.dart
- **Purpose:** Play screen for Wolf — per hole the Wolf (rotating, tees last) picks a partner, goes Lone Wolf, or Blind Wolf; points scored by winning side.
- **Layout & regions:** GolfAppBar ("Wolf", ✕/Exit leading, sync badge, RoundChatButton, Leaderboard icon, ⋯ overflow: Set Wolf rotation / End round / help) → `_HoleHeader` (Hole N, Par·yds·SI, "?" → `_showWolfLegend`) → `_WolfBar` (slim always-visible bar: paw icon + Wolf name + "Choose play ›" when pending, else decision chip + "Change"; taps open `_WolfDecisionSheet`) → `_HoleScoreCard` (tertiary "Tap to set the Wolf's play…" strip until decided, then Wolf/partner + Opponents team-colour legend dots; per-player `_PlayerRow` with team stripe/tint, paw on Wolf, "partner" chip, "gets N" chip, stroke dots; hot/editing row wrapped in a team-coloured box with `InlineScorePicker`) → `_WolfOutcomeLine` once decided+scored (Halved/Wolf wins/Wolf loses + pot + per-player ± points) → `_WolfGrid` (18-hole points grid: Hole row, "Wolf" holder row, per-player per-hole ± points + standings line) → bottom nav (play-order aware ← / →, Done).
- **Components used:** GolfAppBar, InlineScorePicker, RoundChatButton, InlineMessage, `showScoreEntryHelp` (icon_help_sheet.dart), SpotsDots (SpotsCaptureMixin), GameColors (game_colors.dart); play-order helpers `roundPlayOrder`/`nextInOrder`/`prevInOrder` (utils/play_order.dart); local `_HoleHeader`, `_WolfBar`, `_WolfDecisionSheet`, `_WolfOutcomeLine`, `_HoleScoreCard`, `_PlayerRow`, `_WolfGrid`, `_RotationSheet`.
- **Data:** Wolf identity, reverse-honors tee order, decision, per-hole points/pot, running totals — all from `RoundProvider.loadWolf` / `wolfSummary` / `setWolfSummary` (`WolfSummary`/`WolfHole`/`WolfTeeSlot`). Decisions POSTed via `client.postWolfDecision`; rotation via `client.postWolfOrder`. Handicap via `match_handicap.dart`. Spots when active. User enters gross scores + per-hole Wolf decision (partner id / lone / blind) + optional rotation reorder + spots.
- **States:** loading → spinner; error+no scorecard → InlineMessage + Retry; decision pending → inline picker suppressed (`effHot = -1`), rows dimmed (opacity 0.45) until Wolf acts; Blind Wolf locked once any score entered; last-solo-required turn locks partner (`partnerLocked`); offline/sync → sync badge + `_pending`, reload on drain.
- **Interactions & exits:** `_WolfBar`/decide-strip opens `_WolfDecisionSheet` (tee-order rows with stroke dots + "last: N", Take-as-partner buttons [4-player only], Lone/Blind buttons, Reset) → persists to `_selectedHole`; `_RotationSheet` reorderable list with locked played positions; inline score entry (`_saveHole` immediate for past-hole edits, `_saveAndAdvance` otherwise); Auto-advance; grid cell tap jumps holes; End round / hole-18 → `confirmCompleteRound(unscoredHoles:)` → `completeRound` → `/leaderboard`; ✕/Exit leading (casual-single "Exit to rounds"); Leaderboard icon.

---

### RabbitScreen
- **File:** lib/screens/rabbit_screen.dart
- **Purpose:** Play screen for Rabbit — pure score entry plus a live read-out of who holds the rabbit (won by an outright hole win; set loose on a loss), with per-segment carry/payout.
- **Layout & regions:** GolfAppBar ("Rabbit", ✕/Exit leading, sync badge, RoundChatButton, Leaderboard icon, ⋯ overflow: End round / help) → `_RabbitBanner` (holder + "(+lead)" when accumulate, or "Rabbit is loose", + "Segment X of N") → `_HoleHeader` (Hole N, Par·yds·SI, "?" → `_showRabbitLegend`) → `_HoleScoreCard` (per-player `_PlayerRow`: runner icon + tinted left edge on the current holder, "gets N" chip, stroke dots; hot/editing row wrapped in pine box with `InlineScorePicker`) → `_OutcomeLine` once scored (grab / extend / held / beaten / freed / no-change) → `_SegmentStrip` (per 6/9/18 segment holder + payout / "in play", only when numSegments>1) → `_RabbitGrid` ("Rabbit by hole": per-player gross rows with stroke dots + a "Rabbit" holder row + per-player money line + segment-value note) → bottom nav (play-order aware, Done).
- **Components used:** GolfAppBar, InlineScorePicker, `scoreCellWithDots`, RoundChatButton, InlineMessage, `showScoreEntryHelp`, SpotsDots (SpotsCaptureMixin), play_order helpers; local `_RabbitBanner`, `_HoleHeader`, `_HoleScoreCard`, `_PlayerRow`, `_OutcomeLine`, `_SegmentStrip`, `_RabbitGrid`.
- **Data:** Rabbit holder/lead/segment (walked backward in play order from the selected hole within its segment), per-hole event, segment holders/payouts, per-player money; from `RoundProvider.loadRabbit` / `rabbitSummary` (`RabbitSummary`/`RabbitHole`/segments). Handicap via `match_handicap.dart`. Spots when active. User enters gross scores + spots.
- **States:** loading → spinner; error+no scorecard → InlineMessage + Retry; loose vs held banner styling; offline/sync → sync badge + `_pending`, reload on drain.
- **Interactions & exits:** Inline score entry (`_saveHole` immediate for past-hole edits, else `_saveAndAdvance`); Auto-advance; tap scored row to edit; grid cell tap jumps holes; End round / last hole → `confirmCompleteRound(unscoredHoles:)` → `completeRound` → `/leaderboard`; ✕/Exit leading (casual-single "Exit to rounds"); Leaderboard icon. No per-hole decision (carry logic is server-derived).

---

### TripleCupScreen
- **File:** lib/screens/triple_cup_screen.dart
- **Purpose:** Read-only live cup standings + per-match detail for the One-Round Triple Cup (Fourball / Foursomes / Singles match segments); score entry happens on the universal `/score-entry` screen.
- **Layout & regions:** GolfAppBar ("One-Round Triple Cup", Refresh icon, RoundChatButton, `_HandicapBadge` NET%/GROSS/SO) → `ListView`: `_OverallScoreCard` (Blue vs Orange point pills "of N possible" + W/W/H tally) → one `_MatchCard` per match (segment badge, "Holes a–b", Blue/Orange rosters, `statusDisplay` centre coloured by leader, played-hole grid of T1/T2 net cells, "Result: …") → `_MoneyCard` (unit + per-player running $) → FAB "Enter scores".
- **Components used:** GolfAppBar, RoundChatButton, ErrorView (widgets/error_view.dart), GameColors, `kTripleCupTeam1Color`/`kTripleCupTeam2Color`; local `_HandicapBadge`, `_OverallScoreCard`, `_MatchCard`, `_MoneyCard`. No score-entry widgets (InlineScorePicker etc.) — this is a standings view.
- **Data:** Displays cup points, per-match rosters/status/hole outcomes, money; from `RoundProvider.loadTripleCup` / `tripleCupSummary` (`TripleCupSummary`/`TripleCupMatch`/`TripleCupHole`/money). No local score entry.
- **States:** loading (no summary) → spinner; no summary → `ErrorView("No Triple Cup game set up yet.")` + Retry; pull-to-refresh / Refresh icon reloads; no explicit offline/sync UI (read-only view).
- **Interactions & exits:** FAB → `/score-entry` (loads scorecard first, refreshes on return); standard back arrow (this is reached from the leaderboard, not a score screen); Refresh; RoundChatButton.
- **NOTE:** `_OverallScoreCard._scorePill` labels are called with 'Blue'/'Orange' but the `label == 'Team 1' || label == 'Blue'` check keeps a dead 'Team 1' branch (harmless).

---

### MultiSkinsScreen
- **File:** lib/screens/multi_skins_screen.dart
- **Purpose:** Read-only standings for the round-level / cross-round Multi-Group Skins pool; players enter scores on their own foursome's screen — this only displays the federated pool.
- **Layout & regions:** GolfAppBar ("Multi-Group Skins", Refresh icon, RoundChatButton, Settings icon → `/multi-skins-setup`) → `ListView`: `_MoneyCard` (pool $, players × bet, total skins, status label, mode/net%) → `_PlayerLeaderboard` (flat `ListTile` standings: name, "Not linked yet" subtitle for unlinked members, Thru / Skins / Payout columns) → `_HolesGrid` (`_NineRow` Front + Back: winner short-name or "—" dead per hole + legend).
- **Components used:** GolfAppBar, RoundChatButton, ErrorView; local `_MoneyCard`, `_PlayerLeaderboard`, `_HolesGrid`, `_NineRow`. Keyed by `roundId` (not `foursomeId`). Note: the per-group skin-winner scorecard `_MsScorecard` referenced in project docs is NOT in this file (lives elsewhere / prior revision).
- **Data:** Pool $, per-player skins won + thru + payout, per-hole winner/dead; from `RoundProvider.loadMultiSkins(roundId)` / `multiSkinsSummary` (`MultiSkinsSummary`/`MultiSkinsHole`/`MultiSkinsPlayerTotal`, incl. cross-round `linkedRounds`/`hostRoundId`). No score entry.
- **States:** loading (no summary) → spinner; no summary → `ErrorView("No data")` + Retry; pull-to-refresh / Refresh icon reloads; unlinked roster member → `foursomeId == 0` → "Not linked yet"; no offline/sync UI.
- **Interactions & exits:** Settings icon → `/multi-skins-setup`; Refresh / pull-to-refresh; standard back; RoundChatButton.
- **NOTE:** `_MsScorecard` (project docs) is not present here; this screen is display-only.

---

### NassauScreen
- **File:** lib/screens/nassau_screen.dart
- **Purpose:** Score-entry + live match view for a Nassau (2v2 team match: front / back / overall bets + presses; supports cross-foursome phantom donor and Claremont bottom bet).
- **Layout & regions:** GolfAppBar (title "Nassau — {mode}", ✕ leading, sync badge, RoundChatButton, Leaderboard icon) → `_TeamBanner` (Blue vs Orange dots + names) → `_PressesStrip` (active/completed top + bottom presses for the current nine) → active-hole `Card` (`_NassauHoleScoreCard`: grey hole header + per-tee Par/yds/SI; `_HoleOutcomeBanner` once scored [team wins / Halved]; per-player `_NassauPlayerRow` with team-colour name, "gets N" chip, stroke dots, hot-spot wrapped in team-coloured box + `InlineScorePicker`; phantom shown as read-only `_PhantomDonorRow` "Waiting for {donor}…" / "Score from {donor}") → `_NassauSummaryGrid` ("Round progress": Hole/Par rows, per-player gross rows with stroke dots, a "Top"/"Won by" winner row [+ bottom row for Claremont]) → `_PhantomInfoStrip` (HC + per-donor rotation) → bottom bar: `_MatchStatusBar` (F9/B9/Overall chips + Call Press) + phantom-waiting banner + hole nav (← | → / Done).
- **Components used:** GolfAppBar, InlineScorePicker, `scoreCellWithDots`, RoundChatButton, SpotsDots (SpotsCaptureMixin); `nassau_team_style.dart` (`nassauTeamColor`, `nassauTeamDot`, `nassauWonByLabel`); `match_handicap.dart`; local `_TeamBanner`, `_PressesStrip`, `_MatchStatusBar`, `_NassauHoleScoreCard`, `_HoleOutcomeBanner`, `_PhantomDonorRow`, `_NassauPlayerRow`, `_NassauSummaryGrid`, `_NassauGridPlayerRow`, `_PhantomInfoStrip` (some past line 1591 not fully paged but structurally referenced).
- **Data:** Team rosters, per-hole winner, F9/B9/Overall margins/status, presses (top + Claremont bottom), phantom donor rotation; from `RoundProvider.loadNassau` / `nassauSummary` (`NassauSummary`/`NassauHoleData`/`NassauPhantomInfo`). Presses POSTed via `callNassauPress`. Spots when active. User enters gross scores + calls presses + spots.
- **States:** loading → spinner; error+no scorecard → red text + Retry; summary loading → small spinner; phantom waiting → error-container banner + 8-second poll timer (`_phantomPollTimer`) refreshing scorecard+summary; offline/sync → sync badge + `_pending`, plus a direct SyncService listener that reloads the Nassau summary the moment pending→idle (so F9/B9/press chips update without navigating).
- **Interactions & exits:** Inline score entry + tap-to-edit (`_editHotPid`); Auto-advance; Call Press (`_pressStartHole`); grid cell tap jumps holes; hole nav; "Done" → `confirmCompleteRound` → `completeRound` → `/leaderboard`; ✕ leading (`maybePop`) — no casual "Exit" variant here; Leaderboard icon.

---

### PinkBallScreen
- **File:** lib/screens/pink_ball_screen.dart
- **Purpose:** Score-entry screen for tournament rounds including the Pink Ball game (a rotating ball carrier per hole; ball can be "lost"); also surfaces co-active Match Play and Three-Person-Match cards.
- **Layout & regions:** GolfAppBar ("Group N", ✕/Exit leading, RoundChatButton, Leaderboard icon, "Set ball rotation" list-number icon) → `ListView`: `_CarrierBanner` (Hole N + Par/yards/SI chips + "{carrier} plays the {colour} Ball" + optional Irish-Rumble balls-count) → `_BallLostCard` (toggle "Lost the {colour} Ball on this hole", or locked "lost on hole X" state) → player-rows `Card` (`_PlayerScoreRow` per real player: name + "CH n" chip + "{colour} Ball" carrier badge, `NetScoreButton`/hot outline box with stroke dots; hot/editing row wrapped in pine box + `InlineScorePicker`; optional `BorrowedFourthRow` when Irish Rumble borrows a 4th) → `_PinkBallMatchPlayCard` (mini singles bracket, when match_play co-active) → `_ThreePersonMatchPhase2Card` (back-9 match, holes ≥10) → bottom nav (← Hole | Finish/→).
- **Components used:** GolfAppBar, InlineScorePicker, NetScoreButton + `scoreCellWithDots`, RoundChatButton, BorrowedFourthRow (widgets/borrowed_fourth.dart); local `_CarrierBanner`, `_InfoChip`, `_PlayerScoreRow`, `_OrderSetupSheet`, `_BallLostCard`, `_PinkBallMatchPlayCard`, `_MPStatusChip`, `_ThreePersonMatchPhase2Card`, `_MPMatchRow`. (No SpotsCaptureMixin — tournament-only game, intentionally not wired for Spots.)
- **Data:** Ball colour + 18-hole carrier order (from `client.getPinkBallSetup`, fallback `foursome.pinkBallOrder`), ball-lost hole, Irish-Rumble segment balls-to-count (`client.getIrishRumbleConfig`), match-play bracket (`RoundProvider.loadMatchPlay`/`matchPlayData`), three-person-match phase 2 (`loadThreePersonMatch`/`threePersonMatchSummary`), scorecard scores; rotation POSTed via `client.postPinkBallOrder`. User enters gross scores + ball-lost toggle + confirms/reorders the ball rotation.
- **States:** loading / config not loaded → full-screen spinner; forced non-dismissible `_OrderSetupSheet` before any hole is scored (locks positions once holes played); match-play/TPM refreshed via a 3s / 5s polling timer + a sync-drain watcher; ball-lost locked once lost on a prior hole; no explicit error view (config load failure falls back silently). Not offline-badged (no sync badge in app bar) though `submitHole` still queues offline.
- **Interactions & exits:** Inline score entry (`_save`, auto-advance via SettingsProvider); tap scored box to edit; ball-lost toggle; "Set ball rotation" opens `_OrderSetupSheet` (reorderable, locked prefix); prev/next hole; hole 18 → "Finish" (snackbar "All 18 holes saved!", no forced completeRound); ✕/Exit leading (casual-single "Exit to rounds"); Leaderboard icon; match-play card taps → `/match-play-setup`.
- **NOTE:** Unlike the casual game screens, "Finish" here does NOT call `completeRound` — it just shows a snackbar (Pink Ball is a tournament-round entry screen; the round is completed elsewhere).

---

### MatchPlayScreen
- **File:** lib/screens/match_play_screen.dart
- **Purpose:** Read-only live bracket view for a foursome's match-play contest (F9 semis → B9 final + 3rd place); scores are entered elsewhere (Pink Ball / universal score entry).
- **Layout & regions:** plain `AppBar` ("Match Play", ✕/Exit leading, RoundChatButton) → `MatchPlayDetailView` (shared, also embedded in the leaderboard): `_StatusBanner` (winner / "Waiting for scores" / hidden while live) → handicap-mode line → "Front 9 — Semis" section (`_MatchCard` ×2) → "Back 9 — Final & 3rd Place" section (`_MatchCard` ×2, dimmed with pending note until semis resolve) → `_MoneyCard` (entry fee, prize pool, payouts). Each `_MatchCard`: label badge + `_StatusChip`, `_PlayerSwatch` names, live summary ("Paul 2 Up thru 7" / "wins 3&2" / sudden-death), `_HoleStrip` (coloured hole boxes + SD extension row), `_MatchScoreDetail` (Hole/Par/SI + per-player gross with stroke dots).
- **Components used:** RoundChatButton, ErrorView, GameColors (`_kP1Color`/`_kP2Color`), `friendlyError`/`isNetworkError` (api/client.dart); local `MatchPlayDetailView` (public, shared with leaderboard), `_StatusBanner`, `_MatchCard`, `_MatchScoreDetail`, `_HoleStrip`, `_MoneyCard`, `_LabelBadge`, `_StatusChip`, `_PlayerSwatch`. Uses a plain `AppBar`, not `GolfAppBar`.
- **Data:** Bracket state as a raw `Map<String,dynamic>` from `client.getMatchPlay(foursomeId)` (matches by round, holes, winner, tie_break, scorecard, money); no local score entry. `hasAnyScore` read from the foursome flag (no `_pending`/scorecard here).
- **States:** loading → spinner; error → `ErrorView(friendlyError, isNetwork:)` + Retry; pull-to-refresh / re-`_load`; pending matches dimmed (opacity 0.55) with note; no offline/sync badge (read-only fetch).
- **Interactions & exits:** Pull-to-refresh; ✕/Exit leading (casual-single "Exit to rounds", else `maybePop`); RoundChatButton. No score mutation on this screen.

---

### QuotaNassauScreen
- **File:** lib/screens/quota_nassau_screen.dart
- **Purpose:** Score-entry screen for Four Ball Quota (Nassau) — GROSS Stableford only (no net), players in two pairs, each team's combined Stableford points chased against a per-segment quota.
- **Layout & regions:** plain `AppBar` ("Four Ball Quota", centered, ✕ leading, sync badge, RoundChatButton, Leaderboard icon) → `_QNTeamBanner` (team1 vs team2 names in team colours, left/right ordered) → active-hole `Card` (`_QNHoleScoreCard`: grey hole header + per-tee Par/yds/SI; per-player `_QNPlayerRow`: team badge (T1/T2), name + "Quota F9/B9/18" sublabel, `_QNPtsBadge` gross-Stableford pts, `NetScoreButton` gross score box; auto-shown `InlineScorePicker` under the hot-spot player, strokes=0 since gross-only) → `_QNSummaryGrid` ("Round progress": Hole/Par rows, per-team player gross rows + a combined "T1 stpl"/"T2 stpl" row, footer `_QNFooterBlock` per team with F9/B9/All stpl vs quota + running net) → `_QNPhantomInfoStrip` (cross-foursome phantom HC + per-donor rotation) → bottom bar hole nav (← | → / Done).
- **Components used:** InlineScorePicker, NetScoreButton, RoundChatButton, SpotsDots (SpotsCaptureMixin); local `_gsf` (gross-Stableford), `_qnTeamColor`, `_QNTeamBanner`, `_QNHoleScoreCard`, `_QNPlayerRow`, `_QNPtsBadge`, `_QNSummaryGrid`, `_QNFooterBlock`, `_QNPhantomInfoStrip`. Plain `AppBar` (not GolfAppBar). No `match_handicap.dart` (gross-only).
- **Data:** Team pairings + per-player 18-hole quota + team colours + phantom donor rotation from `RoundProvider.loadQuotaNassau` / `quotaNassauSummary` (`QuotaNassauSummary`/`QuotaNassauMatchSummary`, phantom `NassauPhantomInfo`); gross scores from scorecard; Stableford pts + net computed client-side (`_gsf`, `_playerNetToPar`). Spots when active. User enters gross scores + spots.
- **States:** loading (no foursome/scorecard) → spinner; no dedicated error view; hot-spot auto-advances between players (`_hotPlayerOverride` for editing a scored player); cross-foursome phantom blocks "Save & Advance" until the donor scores (`_allScored` checks `donorForHole().hasScore`); offline/sync → sync badge + `_pending`, reload on drain.
- **Interactions & exits:** Inline gross picker auto-advances player→player then hole; tap a scored player to re-open their picker (`_tapScoredPlayer`); Auto-advance saves + advances hole when complete; grid cell tap jumps holes; hole nav; "Done" → `confirmCompleteRound` → `completeRound` → `/leaderboard`; ✕ leading (`maybePop`) — no casual "Exit" variant; Leaderboard icon.
- **NOTE:** `_QNPhantomInfoStrip` renders `'Course HC: \$hc (avg of team)'` with an escaped `\$hc` — the HC value is shown literally as "$hc" rather than interpolated (a string-escape bug). Also `_teamLabel` is defined on the State class but the row logic uses the card's own `_teamLabel`.

---

#### Cross-screen shared patterns
- **Common casual score-entry screens** (Points531 / Skins / Wolf / Rabbit / Nassau / QuotaNassau): `_pending` map (hole→playerId→gross) + `_selectedHole`, `_jumpToFirstUnplayed` on load, hot-spot inline `InlineScorePicker`, tap-to-edit scored rows, Auto-advance via `SettingsProvider.autoAdvanceHole`, `submitHole` (offline-queued through `SyncService`), sync-drain reload of the game summary, and "Done" → `confirmCompleteRound` (utils/round_complete.dart) → `RoundProvider.completeRound` → `pushReplacementNamed('/leaderboard')`.
- **Spots capture** (`SpotsCaptureMixin`, widgets/spots_capture.dart → `SpotsDots`) is mixed into Points531, Skins(no), Wolf, Rabbit, Nassau, QuotaNassau — wired where the primary game can host the Spots side game. (Skins excludes Spots; Skins uses junk instead.)
- **Read-only standings screens** (TripleCup, MultiSkins, MatchPlay): no `_pending`/inline picker; load a summary, Refresh / pull-to-refresh, `ErrorView` on failure, standard back arrow; scores entered on other screens.
- **Landscape:** every route is wrapped by `RoundLandscapeScorecard` in main.dart → rotate to landscape shows the shared `ScorecardGrid`.

---

### 3.8 · Tournament & Cup

### TournamentLowNetSetupScreen
- **File:** lib/screens/tournament_low_net_setup_screen.dart
- **Purpose:** Configure the tournament-level Low Net / Stroke Play Championship (cumulative net strokes across all rounds) — handicap mode, entry fee, and per-place payout amounts.
- **Layout & regions:** AppBar title "Stroke Play Championship — Setup"; scrolling body (SingleChildScrollView) top-to-bottom: About SectionCard ("Stroke Play Championship" blurb, double-bogey cap note) → HandicapModeSelector → "Entry Fee" SectionCard (per-player $ + # Players row, plus a prize-pool estimate chip/hint) → "Payouts" SectionCard (places-paid ToggleButtons stepper 1–8, per-place _PayoutRow inputs, Total payout divider row, tie-split note) → optional error banner; bottomNavigationBar SafeArea full-width "Save Setup" FilledButton (spinner while saving).
- **Components used:** SectionCard, HandicapModeSelector, GolfTextField, ErrorView, FilledButton, ToggleButtons, LayoutBuilder; local `_PayoutRow` (place ordinal + `$` GolfTextField).
- **Data:** Loads via `ApiClient.getTournamentLowNetSetup(tournamentId)` → `LowNetChampionshipSetup`-style cfg (handicapMode, netPercent, entryFee, payouts list of `{amount}`). Saves a `LowNetChampionshipSetup(handicapMode, netPercent, entryFee, payouts:[{place, amount}])` via `ApiClient.postTournamentLowNetSetup(tournamentId, setup)`. Client from `context.read<AuthProvider>().client`. User edits: handicap mode/net %, entry fee, local-only # players (pool estimate, not saved), number of paid places, and each place's dollar amount.
- **States:** loading → centered CircularProgressIndicator; error (and not saving) → ErrorView with friendlyError/isNetworkError + onRetry `_load`; also an inline error container in the body when `_error != null && !_saving`; saving → button spinner, save button disabled; empty payouts → "Select the number of paid places above." hint. No explicit permission state.
- **Interactions & exits:** HandicapModeSelector mode/percent → local state; entry fee + # players fields → live pool estimate; places ToggleButtons → `_setPayoutPlaces` (tap same to deselect to 0); payout inputs → live Total; "Save Setup" → `_save` → POST then `Navigator.pop(true)` on success; ErrorView retry → reload.

### TournamentStablefordSetupScreen
- **File:** lib/screens/tournament_stableford_setup_screen.dart
- **Purpose:** Configure the tournament Stableford Championship (total Stableford points across every round) — handicap, the editable 6-bucket points table, and pool payout.
- **Layout & regions:** AppBar title "Stableford Championship"; Column of Expanded body (ListView) + SafeArea footer "Save" FilledButton. Body top-to-bottom: intro text → HandicapModeSelector (allowStrokesOff:false) → "Points table" title + hint + preset ActionChips (Standard / Modified (pro) / Reward birdies) + one signed-number TextField per bucket (albatross/eagle/birdie/par/bogey/double) → "Payout (pool)" title → entry-fee TextField (digits only) → pool line ("Pool: $X (N players)") → PayoutConfigField.
- **Components used:** HandicapModeSelector, PayoutConfigField, ErrorView, FilledButton, ActionChip, TextField (with FilteringTextInputFormatter); `suggestPayouts` helper (from payout_config_field.dart).
- **Data:** Loads via `ApiClient.getTournamentStablefordSetup(tournamentId)` → map (`num_players`, `handicap_mode`, `net_percent`, `entry_fee`, `pts_<bucket>`, `payouts:[{amount}]`). Saves via `ApiClient.postTournamentStablefordSetup(tournamentId, handicapMode, netPercent, entryFee, payouts:[{place, amount}], pointsTable:{bucket:int})`. `num_players` is server-provided (read-only, drives pool = fee × players). User edits: handicap mode/net %, points per bucket (negatives allowed), entry fee, number of payouts + amounts.
- **States:** loading → CircularProgressIndicator; error (and not saving) → ErrorView with onRetry `_load`; saving → button spinner + disabled. No empty/permission state beyond defaults.
- **Interactions & exits:** preset ActionChips → `_applyPreset` fills the table; bucket fields / entry fee → live pool recompute; PayoutConfigField onSuggest → `_suggest` (calls `suggestPayouts(pool, numPayouts)`); onNumPayoutsChanged / onPayoutChanged → state; "Save" → `_save` → POST then `Navigator.pop(true)`; ErrorView retry → reload.

### RyderCupDraftScreen
- **File:** lib/screens/ryder_cup_draft_screen.dart
- **Purpose:** Staff cup setup and roster draft — create a Cup (name, team count, team names) OR manage team rosters (add/remove players, rename teams) and lock the draft; SETUP-TIME ONLY (rosters become immutable once locked).
- **Layout & regions:** AppBar (title = cup name or "Cup Setup"; actions when a cup exists: leaderboard IconButton → RyderCupScoreboardScreen, refresh IconButton). Body switches: (a) not-set-up → `_SetupForm` (scrolling: "Create a new Cup" heading, Cup name field, players-per-team field, number-of-teams ChoiceChips [2/3/4], one team-name field per team, "Create Cup" FilledButton); (b) cup exists → `_DraftBoard` — a top lock/status banner (green "Draft locked — rosters are final" with lock icon, or primary "Draft open — drag players to teams" with a "Lock Draft" tonal button) over an Expanded ListView of `_TeamCard`s.
- **Components used:** ErrorView, GolfTextField, ChoiceChip, FilledButton/FilledButton.icon/FilledButton.tonal, Card, ListTile, CircleAvatar; local `_SetupForm`, `_DraftBoard`, `_TeamCard`, `_PlayerPickerDialog` (multi-select search dialog), `_RenameTeamDialog`. Pulls in RyderCupScoreboardScreen for the toolbar action.
- **Data:** Loads via `ApiClient.getTeamTournament(tournamentId)` → `TeamTournamentSummary` (cupName, teams: `CupTeam` {teamId, name, colour, players:[CupPlayer], totalPoints}, draftComplete). 404 (`ApiException.statusCode==404`) → not-set-up form. Player picker loads `ApiClient.getPlayers()` → `List<PlayerProfile>` (phantoms filtered out via `!p.isPhantom`), excluding already-drafted ids. Mutations: `postTeamTournamentSetup(tournamentId, cupName, playersPerTeam, teams:[{team_number, name}])`; `postAddTeamPlayer(tournamentId, teamId, playerId)` (looped per chosen player, stop-on-first-error); `deleteTeamPlayer(tournamentId, teamId, playerId)`; `patchTeamName(tournamentId, teamId, newName)`; `postDraftComplete(tournamentId)` (lock). Client from `AuthProvider`.
- **States:** loading → CircularProgressIndicator; error (non-404) → ErrorView with onRetry `_load`; not-set-up (404) → setup form; locked → banner turns green, per-player remove IconButtons and each team's "Add player" button are hidden (`isLocked` gates them). Errors surfaced via SnackBars. No dedicated permission state.
- **Interactions & exits:** Create Cup → `_submitSetup` (validates non-empty cup + team names) → POST then `_load()` (stays on screen, now shows draft board); number-of-teams ChoiceChip → adds/keeps team-name controllers; per-team "Add player" → `_addPlayers` → `_PlayerPickerDialog` (search + multi-select checkboxes, live count badge) → sequential add POSTs → reload + SnackBar; per-player remove icon → `_removePlayer` confirm AlertDialog → deleteTeamPlayer → reload; team rename edit icon → `_renameTeam` → `_RenameTeamDialog` → patchTeamName → reload; "Lock Draft" → `_lockDraft` confirm AlertDialog ("This will lock all rosters. Players cannot be moved after this.") → `postDraftComplete` → reload (board becomes read-only); AppBar leaderboard action → push RyderCupScoreboardScreen; refresh → `_load`.
- **NOTE:** The banner text says "drag players to teams," but there is no drag-and-drop — players are added via the "Add player" picker dialog and removed via the per-row remove icon. Add/remove/rename/lock are all disabled after lock; this is the only roster-editing surface (setup-time only).

### RyderCupScoreboardScreen
- **File:** lib/screens/ryder_cup_scoreboard_screen.dart
- **Purpose:** Read-only live cup standings — overall team totals plus an expandable per-round breakdown with match-level segment results.
- **Layout & regions:** AppBar (title = cup name or "Cup Scoreboard"; refresh IconButton action). Body = RefreshIndicator over a ListView: `_StandingsCard` (Overall Standings — teams sorted by totalPoints, position, name, points, LinearProgressIndicator bar) → one `_RoundCard` per round (collapsed header: R# badge, course, date, per-team points Chips, expand chevron; expanded: `_MatchRow` list) → empty-state text when no rounds.
- **Components used:** ErrorView, Card, LinearProgressIndicator, CircleAvatar, Chip, InkWell; local `_StandingsCard`, `_RoundCard` (stateful expand/collapse), `_MatchRow`, `_SegmentChip`.
- **Data:** Loads via `ApiClient.getTeamTournament(tournamentId)` → `TeamTournamentSummary` (teams:[CupTeam], rounds:[CupRound]). CupRound → roundNumber, course, date, teamPoints (list of `{team_name, points}`), matches:[CupMatch]. CupMatch → gameType, displayLabel, team1/team2, segments:[CupSegmentResult] (segmentLabel, result: null/'halved'/'team1'/'team2'). Read-only; no user-created data.
- **States:** loading → CircularProgressIndicator; error → ErrorView with onRetry `_load`; empty rounds → italic "No rounds configured yet. Set up a round's Cup Play config to see points here."; a round with no matches → "No match data yet." No permission state.
- **Interactions & exits:** refresh IconButton and pull-to-refresh → `_load`; tap a `_RoundCard` header → toggles expand/collapse; ErrorView retry → reload. No navigation exits (terminal read-only screen).

### RyderCupRoundSetupScreen
- **File:** lib/screens/ryder_cup_round_setup_screen.dart
- **Purpose:** (Intended) let staff configure the Cup game for a single round — set points-per-segment + multiplier + notes and assign a game type and team1/team2 to each foursome.
- **Layout & regions:** (as written) AppBar (title "R# · Cup Game Setup" or "Cup Round Setup"; Save FilledButton action / saving spinner). Body SingleChildScrollView: "Points Config" (points-per-segment + multiplier GolfTextFields row, Triple-Cup note, optional Notes field) → "Foursome Game Setup" section → one `_FoursomeConfigCard` per foursome (label + real-player names, game-type DropdownButtonFormField from `_gameChoices`, and — when ≥2 teams — Team 1 / Team 2 dropdowns).
- **Components used:** ErrorView, GolfTextField, Card, DropdownButtonFormField, FilledButton; local `_FoursomeConfigCard`.
- **Data:** (as written) Loads via `Future.wait([ApiClient.getRound(roundId), ApiClient.getTeamTournament(tournamentId), ApiClient.getRyderCupRound(roundId)])` → `Round`, `TeamTournamentSummary`, cup-config map (pre-populates nassau_point_value / point_multiplier / notes). Saves via `ApiClient.postRyderCupRoundSetup(roundId, nassauPointValue, pointMultiplier, notes, foursomes:[{foursome_id, game_type, team1_id?, team2_id?}])`. Reads `round.foursomes` (Foursome.id, label, realPlayers) and `cup.teams` (CupTeam.teamId/name).
- **States:** (as written) loading → CircularProgressIndicator; error → ErrorView with onRetry `_load`; saving → AppBar spinner, Save hidden; validation SnackBars ("Please set a game type for every group.").
- **Interactions & exits:** (as written) game-type / team dropdowns → per-foursome state maps; Save → `_save` (validates every group has a game type) → POST → success SnackBar "Round configured ✓" then `Navigator.pop(true)`; ErrorView retry → reload.
- **NOTE — DEAD / UNREACHABLE CODE.** A grep of the entire lib/ for `RyderCupRoundSetupScreen` returns matches ONLY inside its own file (ryder_cup_round_setup_screen.dart lines 20, 24, 31, 32, 35, 36 — the class declaration, constructor, and `State<RyderCupRoundSetupScreen>` references). It is never imported, pushed via `Navigator`/`MaterialPageRoute`, nor registered as a named route in main.dart. There is no reachable entry point, so this screen cannot be displayed in the running app. Its ApiClient methods (`getRyderCupRound`, `postRyderCupRoundSetup`) may still be defined, but the screen that would drive them is orphaned. Everything documented above is derived from the source but describes behavior that never executes at runtime.

---

## 4. Shared component library


Every reusable widget in `mobile/lib/widgets/`. "Used by" reflects a grep of `lib/screens/` for the class name (screen files, not screen *class* names, since one file == one screen).

---

### AppDrawer
- **File:** lib/widgets/app_drawer.dart
- **Purpose:** Shared navigation drawer (brand lockup + signed-in identity header + nav entries) used by the two top-level list screens.
- **Key props:** `String? playerName`; `VoidCallback onTournamentsTap`, `onCasualRoundsTap`, `onPlayersTap`, `onSettingsTap`, `onLogout`. Entries for admin ("Manage Courses"), support ("Support: Open Round"), and a self-aging "Start your first round" nudge appear conditionally.
- **Used by:** casual_rounds_list_screen, tournament_list_screen, manage_courses_screen.
- **Also in file:** top-level helpers `shareOriginFrom(context)`, `shareInvite(auth, messenger, …)`, `showAppAboutDialog(context)` and the private `_AboutDialog` (app/server version).

### BorrowedFourthNote / DonorByHoleStrip / BorrowedFourthRow
- **File:** lib/widgets/borrowed_fourth.dart
- **Purpose:** Irish-Rumble "borrowed 4th" phantom UI — a one-line explainer note, a per-hole donor-chip strip, and a read-only score-entry row for a leveled threesome's borrowed ball.
- **Key props:** `BorrowedFourthNote({int? pending})`; `DonorByHoleStrip({required NassauPhantomInfo info, int? currentHole})`; `BorrowedFourthRow({required int roundId, foursomeId, currentHole})` (stateful — fetches Irish Rumble result and refreshes on hole change). Also top-level helpers `borrowedFourthFromJson(raw)` and `pendingDonorHoles(info)`.
- **Used by:** BorrowedFourthNote → leaderboard_screen; BorrowedFourthRow → score_entry_screen, pink_ball_screen. DonorByHoleStrip is defined here but not referenced by a screen (available/currently unused).

### CourseSearchField
- **File:** lib/widgets/course_search_field.dart
- **Purpose:** One-box course picker — type a name, pick from a single merged list (your courses / shared catalog / GolfCourseAPI); collapses to a mint "Playing today" card once chosen, with home-course "Play here" suggestion and recents.
- **Key props:** `CourseInfo? selected`; `ValueChanged<CourseInfo> onSelected`; `String selectedLabel` (default 'Playing today'); `bool suggestHome` (default true).
- **Used by:** casual_round_screen, new_round_wizard, onboarding_wizard, settings_screen.

### ErrorView
- **File:** lib/widgets/error_view.dart
- **Purpose:** Full-screen error state — icon, message, optional retry button.
- **Key props:** `String message`; `VoidCallback? onRetry`; `bool isNetwork` (wifi-off vs warning icon). Factory `ErrorView.fromError(error, {onRetry})` picks icon/message from the exception type. Also top-level `friendlyError()`, `isNetworkError()`, `isAuthError()`.
- **Used by:** widely used — ~40 screens (casual_round_screen, round_screen, leaderboard_screen, match_play_screen, all setup screens, tournament_* screens, etc.).

### GameChip / GameSelectableChip
- **File:** lib/widgets/game_chip.dart
- **Purpose:** Canonical game-name pills — read-only (`GameChip`) and selectable picker chip (`GameSelectableChip`, pine-fill/white-bold/no-checkmark when selected).
- **Key props:** `GameChip({String? gameId, String? label, bool dense, bool filled})` (one of gameId/label required — gameId resolves via `gameDisplayName`). `GameSelectableChip({String? gameId, String? label, required bool selected, required ValueChanged<bool> onSelected})`.
- **Used by:** GameChip → new_round_wizard, round_screen; GameSelectableChip → casual_round_screen, new_round_wizard.

### GolfAppBar
- **File:** lib/widgets/golf_app_bar.dart
- **Purpose:** Standard app-bar wrapper (implements `PreferredSizeWidget`) — FittedBox scale-down title, centered by default, 0–2 trailing actions.
- **Key props:** `String title`; `List<Widget>? actions`; `bool centerTitle` (default true); `PreferredSizeWidget? bottom`; `Widget? leading`; `bool automaticallyImplyLeading`.
- **Used by:** honors_setup, leaderboard, multi_skins (screen+setup), nassau, pink_ball, points_531 (screen+setup), rabbit (screen+setup), share_scorecard, sixes_setup, skins (screen+setup), spots_setup, triple_cup, wolf (screen+setup).

### GolfPrimaryButton
- **File:** lib/widgets/golf_primary_button.dart
- **Purpose:** Single source of truth for the full-width dark-green-pill primary action ("Sign In", "Start Game", "Complete Round"); FilledButton under the hood.
- **Key props:** `String label`; `VoidCallback? onPressed`; `bool loading` (swaps spinner, auto-disables); `IconData? icon`; `double height` (default 52).
- **Used by:** login_screen, otp_verify_screen, profile_setup_screen, sixes_setup, skins_setup, spots_setup.

### GolfTextField
- **File:** lib/widgets/golf_text_field.dart
- **Purpose:** Single consistent text-field wrapper (always a `TextFormField`) — canonical OutlineInputBorder + padding, first-class label/hint/helper/prefix/suffix params, plus full `decoration`/`decorationBuilder` escape hatches.
- **Key props:** `controller`/`initialValue`, `enabled`, `readOnly`, `obscureText`; `keyboardType`, `inputFormatters`, `onChanged`, `onFieldSubmitted`, `validator`; decoration shortcuts `label`, `hint`, `helper`, `errorText`, `prefixIcon`, `prefixText`, `suffix`, `suffixText`, `dense` (default true).
- **Used by:** widely used — ~20 form/setup screens (login, otp_verify, profile_setup, player_form, all setup screens, course_paste, tee_paste, new_round_wizard, etc.).

### HalvedMark
- **File:** lib/widgets/halved_mark.dart
- **Purpose:** The Halved brand mark (SVG `assets/icon/halved_mark.svg`) as a small rounded badge — flags an "On Halved" (signed-up) golfer, and doubles as a halved-hole marker with a custom tooltip.
- **Key props:** `double size` (default 20); `String tooltip` (default 'On Halved').
- **Used by:** casual_round_screen, onboarding_wizard, player_list_screen, score_entry_screen, settings_screen, setup_round_players_screen.

### HandicapModeSelector
- **File:** lib/widgets/handicap_mode_selector.dart
- **Purpose:** Shared Net / Gross / SO-Low handicap picker (SegmentedButton) with a 50–130% Net-% slider and mode blurbs. Stateless — parent owns (mode, netPercent).
- **Key props:** `String mode` ('net'|'gross'|'strokes_off'); `int netPercent`; `ValueChanged<String> onModeChanged`; `ValueChanged<int> onPercentChanged`; `bool wrapInCard` (default true); `String? soNote`; `bool allowStrokesOff` (default true — false hides SO Low, e.g. Stableford).
- **Used by:** widely used — 18 setup screens (fourball, honors, irish_rumble, match_play, multi_skins, nassau, points_531, rabbit, sixes, skins, stableford, three_person_match, tournament_low_net, tournament_stableford, triple_cup, vegas, wolf setups + new_round_wizard).

### IconHelpEntry / showIconHelpSheet + helpers
- **File:** lib/widgets/icon_help_sheet.dart
- **Purpose:** Bottom sheet explaining a screen's app-bar action icons; usable as a "?" action or a one-time auto-opened onboarding nudge (per-device "seen" flag via SettingsProvider).
- **Key props:** `IconHelpEntry({IconData icon, String title, String body})`; `showIconHelpSheet(context, {required String title, required List<IconHelpEntry> entries})`. Prebuilt entrypoints: `showScoreEntryHelp` / `maybeShowScoreEntryHelp`, `showLeaderboardHelp` / `maybeShowLeaderboardHelp`.
- **Used by:** invoked (as functions, not a widget class) from score_entry_screen and leaderboard_screen.

### InlineMessage
- **File:** lib/widgets/inline_message.dart
- **Purpose:** Compact icon-prefixed inline message (validation warnings, hints, success) with a unified tinted surface. NOT for full-screen errors (that's ErrorView).
- **Key props:** `String text`; `InlineMessageKind kind` (error | warn | info | success — drives color + default icon); `IconData? icon` override.
- **Used by:** casual_round_screen, leaderboard_screen, multi_skins_setup, new_round_wizard, points_531_screen, rabbit_screen, score_entry_screen, three_person_match_setup, tournament_leaderboard, triple_cup_setup, wolf_screen.

### InlineScorePicker
- **File:** lib/widgets/inline_score_picker.dart
- **Purpose:** The horizontal per-hole score picker on every game's score-entry screen — a centred box showing net birdie/par/bogey/double in full with net-eagle/triple peeking, auto-centred on the net-par gap, edge-fade scroll hints. Built on NetScoreButton.
- **Key props:** `int par`; `int strokes`; `int? currentScore`; `void Function(int) onScoreSelected` (−1 clears); `Color? boxBorderColor` (active team colour); `Color? boxFillColor`.
- **Used by:** score_entry_screen, nassau_screen, pink_ball_screen, points_531_screen, quota_nassau_screen, rabbit_screen, skins_screen, wolf_screen.

### MaxLiabilityNote
- **File:** lib/widgets/max_liability_note.dart
- **Purpose:** Read-only "Most you can lose: $N" line for bounded games (Sixes, Triple Cup, press-less Nassau) — a fixed multiple of the stake. Renders nothing until a positive stake exists.
- **Key props:** `double bet`; `int multiple`; `String detail` (e.g. '3 segments').
- **Used by:** nassau_setup_screen, sixes_setup_screen, triple_cup_setup_screen.

### NetDoubleBogeyCard
- **File:** lib/widgets/net_double_bogey_card.dart
- **Purpose:** Round-level SwitchListTile card for the USGA net-double-bogey cap. Hides itself unless mode == 'net' and netPercent == 100.
- **Key props:** `bool value`; `ValueChanged<bool> onChanged`; `String handicapMode`; `int netPercent`.
- **Used by:** irish_rumble_setup_screen, new_round_wizard.

### NetScoreButton (+ scoreCellWithDots)
- **File:** lib/widgets/net_score_button.dart
- **Purpose:** Tappable score button in golf-scorecard notation — under-par = red digit in circle (double circle for eagle+), par = plain, over = square (double square for double-bogey+); baseline is NET (par+strokes) when the Net-Style-Entry setting is on else GROSS. Companion `scoreCellWithDots(box, strokes, color)` stacks handicap stroke dots above a cell.
- **Key props:** `int score, par, strokes`; `bool selected`; `double width, height`; `VoidCallback? onTap`; `bool forceNetBaseline`.
- **Used by:** score_entry_screen, pink_ball_screen, quota_nassau_screen (and internally by InlineScorePicker, borrowed_fourth, stroke_play_strip via `scoreCellWithDots`).

### PayoutConfigField (+ suggestPayouts)
- **File:** lib/widgets/payout_config_field.dart
- **Purpose:** Shared "paid places + amounts" payout config — 1..N places stepper, integer-dollar amount fields, balance row ("Payouts balance ✓" / "Remaining"), and Auto-suggest. Pure helper `suggestPayouts(pool, numPayouts)` distributes with fixed splits, last place absorbs remainder.
- **Key props:** `int pool`; `int numPayouts`; `List<TextEditingController> payoutCtrls` (exactly 4); `void Function(int) onNumPayoutsChanged`; `void Function() onPayoutChanged`, `onSuggest`; `int maxPayouts` (default 4); `String? Function(int) placeSubtitle`.
- **Used by:** irish_rumble_setup, match_play_setup, new_round_wizard, pink_ball_setup, stableford_setup, three_person_match_setup, tournament_stableford_setup.

### RoundChatButton
- **File:** lib/widgets/round_chat_button.dart
- **Purpose:** App-bar chat icon with an unread-count badge; polls the messages endpoint every 25s and opens RoundFeedScreen.
- **Key props:** `int roundId`; `String? title` (feed screen title).
- **Used by:** leaderboard, round_screen, match_play, multi_skins, nassau, pink_ball, points_531, quota_nassau, rabbit, score_entry, skins, triple_cup, wolf screens.

### RoundLandscapeScorecard
- **File:** lib/widgets/round_landscape_scorecard.dart
- **Purpose:** Wraps a round-context screen so rotating to landscape overlays the full-group ScorecardGrid; keeps `child` mounted via Offstage to preserve state. `foursomeId == null` → rotation is a no-op.
- **Key props:** `int? foursomeId`; `Widget child`.
- **Used by:** applied in main.dart route wrapping; referenced directly in leaderboard_screen. (Wraps score-entry + all per-foursome game routes.)

### scoreMark (helper, not a class)
- **File:** lib/widgets/score_mark.dart
- **Purpose:** Shared score-digit renderer with circle/square scorecard notation, used by the score grid and leaderboard so a score reads identically everywhere. `diff` = score − par (null = plain).
- **Key props:** `scoreMark({required String text, required int? diff, required TextStyle baseStyle, required ThemeData theme})`.
- **Used by:** consumed within stroke_play_strip and leaderboard code (via import); a low-level shared helper.

### ScorecardGrid
- **File:** lib/widgets/scorecard_grid.dart
- **Purpose:** The full 18-hole, all-players stacked read-only scorecard (handicap dots + STBL + net/OUT/IN/TOT). Mirrors score_entry_screen's stroke/handicap/ordering logic.
- **Key props:** `int foursomeId`; `bool showClose` (X pops when pushed as its own route; false for the rotate-to-landscape overlay).
- **Used by:** score_entry_screen (multi-skins per-group card) and round_landscape_scorecard (the rotate overlay). Not pushed directly from other screens.

### SectionCard
- **File:** lib/widgets/section_card.dart
- **Purpose:** Outlined card with a bold brand-primary section title — canonical container grouping form controls on setup screens (collapsed 30+ hand-rolled helpers).
- **Key props:** `String title`; `Widget child`; `Widget? trailing`; `EdgeInsetsGeometry padding` (default all 14).
- **Used by:** fourball_setup, irish_rumble_setup, match_play_setup, nassau_setup, sixes_setup, three_person_match_setup, tournament_low_net_setup, triple_cup_setup, vegas_setup.

### ShareableScorecard
- **File:** lib/widgets/shareable_scorecard.dart
- **Purpose:** Portrait, phone-width two-nines-stacked scorecard designed to capture cleanly to a shareable image (gross rows + net Out/In/Tot summary + "Halved" footer). Stateless — takes already-loaded data.
- **Key props:** `String courseName, dateLabel, roundLabel`; `List<ScorecardHole> holes`; `List<PlayerTotals> totals`.
- **Used by:** share_scorecard_screen.
- **Note:** carries its own hardcoded palette (see tokens.md) — this is a capture surface, not themed.

### SharedRoundCard
- **File:** lib/widgets/shared_round_card.dart
- **Purpose:** List card for a round shared with me (a tournament / multi-group-skins game a friend/TD added me to); shows course, group label, date, games, and a Live pill or chevron.
- **Key props:** `ScoringRound round`; `VoidCallback onTap`.
- **Used by:** tournament_list_screen.

### SpotsDots (+ SpotsCaptureMixin)
- **File:** lib/widgets/spots_capture.dart
- **Purpose:** Shared Spots capture — the inline `⊖ N spots ⊕` control (always shows minus; spots can go negative) plus `SpotsCaptureMixin` which owns the optimistic per-hole tally + debounced tally POST.
- **Key props:** `SpotsDots({int count, VoidCallback onAdd, onRemove})`. Mixin API: `spotsActive(rp)`, `spotsCount(pid, hole, s)`, `adjustSpots(...)`, `disposeSpots()`.
- **Used by:** score_entry_screen, nassau_screen, points_531_screen, quota_nassau_screen, rabbit_screen, wolf_screen.

### StakeField
- **File:** lib/widgets/stake_field.dart
- **Purpose:** Round-level stake input paired with a "Play for fun — no stakes" opt-in; reports via `onChanged(bool)` whether a stake decision has been made (positive stake OR box ticked), keeping the two consistent. Built on GolfTextField.
- **Key props:** `TextEditingController controller`; `ValueChanged<bool> onChanged`; `String label` (default 'Stake'); `String? helpText`.
- **Used by:** fourball_setup, honors_setup, nassau_setup, onboarding_wizard, points_531_setup, rabbit_setup, sixes_setup, skins_setup, spots_setup, triple_cup_setup, vegas_setup, wolf_setup.

### TeamSplitter4
- **File:** lib/widgets/team_splitter_4.dart
- **Purpose:** Reorderable 4-player team picker — rows 0–1 = Team A, 2–3 = Team B; drag to assemble teams (order within team matters for Sixes rotation). Requires exactly 4 players.
- **Key props:** `List<Membership> players`; `ValueChanged<List<Membership>> onChanged`; `String teamALabel/teamBLabel` (default Blue/Orange); `Color teamAColor/teamBColor` (default blue-700 / orange-800); `bool reorderable`.
- **Used by:** fourball_setup, nassau_setup, sixes_setup, triple_cup_setup, vegas_setup, score_entry_screen.

### TeeAssignmentList (+ TeePicker, teesForPlayer)
- **File:** lib/widgets/tee_assignment.dart
- **Purpose:** Tee-assignment UI — golfers grouped by sex, each group with a "Set all" bulk picker plus per-player overrides. `TeePicker` is the prominent dropdown (loud red "⚠ Pick tee" chip while unassigned). Helper `teesForPlayer(all, p)` filters+sorts a player's playable tees.
- **Key props:** `TeeAssignmentList({List<PlayerProfile> players, List<TeeInfo> tees, Map<int,int> picks, void Function(int,int) onChanged, String Function(PlayerProfile)? subtitle})`. `TeePicker({List<TeeInfo> tees, int? value, ValueChanged<int> onChanged, String hint, bool warn, bool isExpanded})`.
- **Used by:** TeeAssignmentList → casual_round_screen, confirm_tees_screen; TeePicker → cup_round_setup_screen, setup_round_players_screen.

### UnifiedPlayerSearch
- **File:** lib/widgets/unified_player_search.dart
- **Purpose:** One search box for adding a golfer via a fallback ladder — your roster → find on Halved (name or phone lookup) → create a guest — with a "N of M added" progress row and seat chips.
- **Key props:** `List<PlayerProfile> roster`; `Set<int> selectedIds`; `void Function(int, bool) onToggle`; `void Function(PlayerProfile) onGolferAdded`; `VoidCallback onCreateGuest`; `int? requiredCount`; `String gameLabel`.
- **Used by:** casual_round_screen.

---

### Other reusable pieces (outside lib/widgets)

- **`Halved` brand components** — lib/theme/halved_brand.dart also ships shared widgets beyond raw tokens: `HalvedCtaButton` (the one bright-mint CTA per screen), `HalvedLivePill` (soft-mint "Live" pill — used e.g. in SharedRoundCard), `HalvedSegmented<T>` (pine-filled segmented pill), and `Halved.chipScope(context)` (a ThemeData override for pine-selected chips).
- **`GameColors`** — lib/game_colors.dart: one source of truth for team (blue/orange) and semantic (win/loss/neutral green/red/grey) colours plus `scoreFill(diff)` for score-vs-par cell fills. Used across leaderboard + score-entry surfaces.
- **golf_colors.dart** — lib/utils/golf_colors.dart: `underParColor`, `scoreColor(score, par)`, `toParColor(toPar)` — the under-par-is-red score convention, consumed by NetScoreButton, scoreMark, stroke_play_strip.
- **game_catalog.dart** — lib/game_catalog.dart: `GameIds`, `GameMeta`, and label/eligibility helpers (`gameDisplayName`, `gamesDisplayLabel`, `primaryGameOf`, `resolvePrimary`, `sideGamesFor`, `canBeSideGame`, `allowsSideGames`, …) that drive GameChip/GameSelectableChip and the pickers.
- **strokePlayHoleStrip** — lib/widgets/stroke_play_strip.dart: a top-level *function* (not a class) rendering the per-player expand-on-tap Stroke Play hole strip; shared between the casual leaderboard and the tournament (championship) leaderboard.
- **Nassau/cup team-colour constants** — lib/utils/nassau_team_style.dart (`kNassauTeam1Color`/`kNassauTeam2Color`) and lib/api/models.dart (`kTripleCupTeam1Color`/`kTripleCupTeam2Color`, plus a named-colour switch `…colorFor('red'/'blue'/…)`) — duplicated team/cup palettes reused by several game screens (see tokens.md § hardcoded values).

---

## 5. Design tokens & styling


Two token systems coexist in the codebase:

1. **`Halved`** (lib/theme/halved_brand.dart) — the current brand system (sage/pine/mint). This is what `main.dart`'s global `_halvedTheme` is built from, so it governs the whole app today.
2. **`GolfTokens`** (lib/theme/tokens.dart) — the earlier "May 2026 design audit" primitives (Material-green seed `#2E7D32`). Still referenced by a few widgets (notably `unified_player_search.dart`) but NOT wired into the global theme; effectively a legacy/secondary palette.

---

### Palette

### Halved brand palette — lib/theme/halved_brand.dart (lines 24–42)

| Token | Hex | Role |
|---|---|---|
| `Halved.deepPine` | `#0B1F1A` | Primary text · dark tile |
| `Halved.pine` | `#0F6E56` | Primary · structure (selected chips/segments, CTAs' background is mint though) |
| `Halved.mint` | `#1D9E75` | Accent / secondary |
| `Halved.brightMint` | `#3BD89A` | CTA · live state · the hole (the ONE bright accent per screen) |
| `Halved.surface` | `#EEF3EE` | Light sage app background (scaffold) |
| `Halved.card` | `#FFFFFF` | Card / sheet / dialog fill |
| `Halved.cardBorder` | `#D3DED6` | Card / chip border, dividers |
| `Halved.muted` | `#5C6B62` | Secondary text |
| `Halved.cream` | `#F3F1EA` | Text/mark on dark |
| `Halved.ink` | `#06120E` | Deepest shadow |
| `Halved.win` | `#3BD89A` | Semantic win (= brightMint) |
| `Halved.owe` | `#F0916E` | Semantic "owe money" |
| `Halved.warning` | `#B24225` | Warning / error (mapped to `colorScheme.error`) |
| `Halved.disabledFill` | `#D3DAD5` | Disabled button fill |
| `Halved.disabledText` | `#93A099` | Disabled button label |

Rules encoded in the file's header: app runs on the light sage surface, pine is structure, bright-mint is reserved for the one CTA / live / hole per screen; selected chips/segments are PINE fill, never mint.

### GolfTokens palette (legacy, non-global) — lib/theme/tokens.dart (lines 22–42)

| Token | Hex | Role |
|---|---|---|
| `GolfTokens.brandGreen` | `#2E7D32` | M3 seed (legacy primary) |
| `GolfTokens.brandGreenSoft` | `#C8E6C1` | FAB fill / selected-chip bg (legacy) |
| `GolfTokens.surfaceTint` | `#F4F6ED` | Page background tint (legacy) |
| `GolfTokens.teamRed` | `#8E2E2E` | Team identity (calmer than alert red) |
| `GolfTokens.teamBlue` | `#1B4F8E` | Team identity |
| `GolfTokens.error` | `#B33A2E` | Error / destructive only |
| `GolfTokens.ink` | `#1A1A1A` | Primary text |
| `GolfTokens.inkMute` | `#6B6B6B` | Secondary / meta text |
| `GolfTokens.lineSoft` | `#E6E3DA` | Soft dividers / card borders |

### Game-specific colours — lib/game_colors.dart (`GameColors`)

Rule: green/red/grey = *meaning* (win/loss/neutral), never a team; teams use blue/orange (colour-blind-safe, avoids the money/win collision).

| Token | Value | Role |
|---|---|---|
| `GameColors.team1` | `Colors.blue.shade700` (~`#1976D2`) | Team 1 / Wolf-side |
| `GameColors.team2` | `Colors.orange.shade800` (~`#EF6C00`) | Team 2 / Opponents |
| `GameColors.team1Bg` | `Colors.blue.shade50` | Pale team-1 chip/cell fill |
| `GameColors.team2Bg` | `Colors.orange.shade50` | Pale team-2 chip/cell fill |
| `GameColors.win` | `Colors.green.shade700` | win / up / +money |
| `GameColors.loss` | `Colors.red.shade700` | loss / down / −money |
| `GameColors.neutral` | `Colors.grey.shade600` | halved / push / pending |
| `GameColors.winBg` | `Colors.green.shade100` | |
| `GameColors.lossBg` | `Colors.red.shade100` | |

`GameColors.scoreFill(diff, {parFill})` — graduated score-vs-par cell fill: `diff ≤ −2` → green.400 (eagle+), `−1` → green.100 (birdie), `0` → `parFill`, `+1` → red.100 (bogey), `≥ +2` → red.400 (double+).

### Under-par score convention — lib/utils/golf_colors.dart

- `underParColor` = `Colors.red.shade700` (~`#D32F2F`) — under-par digit colour.
- `scoreColor(score, par)` / `toParColor(toPar)` — return `underParColor` when under par, else `null` (default text colour). Applied ONLY to score-vs-par displays (not money/status/validation, where red = bad).

---

### Typography

Confirmed from code (lib/theme/halved_brand.dart lines 50–71 and lib/main.dart lines 114–129):

- **Headings — Schibsted Grotesk** via `google_fonts` (`GoogleFonts.schibstedGrotesk`), weight w600 (w700 for empty-state titles / drawer wordmark).
- **Body & labels — Spline Sans** via `GoogleFonts.splineSansTextTheme()`.

`Halved` type helpers (halved_brand.dart): `appBarTitle()` 20/w600, `sectionHead()` 22/w600, `emptyTitle()` 26/w700 (all Schibsted Grotesk, deepPine); `body({color,weight})` 15/w400, `label({color,weight})` 12.5/w600 +0.4 letter-spacing/muted, `button({color})` 16/w700 (all Spline Sans).

**Global text-theme mapping (main.dart `_halvedTheme`):** starts from `GoogleFonts.splineSansTextTheme()`, then overrides `display{Large,Medium,Small}`, `headline{…}`, and `title{Large,Medium,Small}` with Schibsted Grotesk (w600) via a local `grotesk()` helper. `body*` and `label*` stay Spline Sans. `.apply(bodyColor: deepPine, displayColor: deepPine)`. Net: display/headline/title = Schibsted Grotesk; body/label = Spline Sans. `appBarTheme.titleTextStyle` is also Schibsted Grotesk 20/w600.

---

### Spacing / radii / border widths

### Halved radii — halved_brand.dart (lines 45–48)
- `Halved.rCta = 16` (CTA buttons)
- `Halved.rCard = 18` (cards)
- `Halved.rChip = 12` (chips)
- `Halved.rPill = 999` (pills / segmented tracks)

### GolfTokens spacing (4-pt grid) + radii — tokens.dart (lines 45–56)
- Spacing: `s4=4`, `s8=8`, `s12=12`, `s16=16`, `s24=24`, `s32=32`.
- Radii: `rSm=8`, `rMd=12`, `rLg=16`, `rPill=999`.

### Border widths (observed, not centralized as named tokens)
- Card border `1.5` (main.dart cardTheme + course_search_field selected card).
- Standard 1-px borders/dividers elsewhere; CTA button height `54` (HalvedCtaButton), primary button height `52` (GolfPrimaryButton). Note there is no single spacing scale for the Halved system — Halved spacing is ad-hoc `SizedBox`/`EdgeInsets`; only `GolfTokens` defines a formal 4-pt scale.

---

### Theme wiring — lib/main.dart `_halvedTheme(Brightness)` (lines 80–200)

- **themeMode is forced light:** `MaterialApp(theme: _halvedTheme(light), darkTheme: _halvedTheme(dark), themeMode: ThemeMode.light)` (lines 360–366). The dark branch (lines 83–89) is a bare seeded stub — "Dark mode is currently unused" per the comment.
- **colorScheme:** `ColorScheme.fromSeed(seedColor: Halved.pine)` then `.copyWith(...)` overriding: `primary=pine`, `onPrimary=white`, `secondary=mint`, `tertiary=brightMint`, `onTertiary=deepPine`, `surface=card` (white), `onSurface=deepPine`, `onSurfaceVariant=muted`, `outline=#B7C3BB`, `outlineVariant=cardBorder`, a ladder of `surfaceContainer*` greens (`#F4F7F4`→`#E1EAE2`), and `error=Halved.warning`.
- **scaffoldBackgroundColor:** `Halved.surface` (sage).
- **dividerTheme:** `cardBorder`.
- **appBarTheme:** bg `surface`, fg `deepPine`, `surfaceTintColor: transparent`, elevation 0 / scrolledUnderElevation 0, `centerTitle: true`, icon `deepPine`, title Schibsted Grotesk 20/w600.
- **cardTheme:** fill `card`, elevation 0, transparent surface tint, `RoundedRectangleBorder(radius rCard=18, side cardBorder width 1.5)`.
- **chipTheme:** bg `card`, selectedColor `pine`, side `cardBorder`, `showCheckmark: false`, shape radius `rChip=12`; `labelStyle` deep-pine/w500, `secondaryLabelStyle` white/w600 (selected chip). (A plain, non-stateful TextStyle is used deliberately.)
- **outlinedButtonTheme:** fg `pine`, side `pine` width 1.5.
- **segmentedButtonTheme:** selected → `primary`/`onPrimary`, else `surface`/`onSurface`.
- **floatingActionButtonTheme:** `backgroundColor: brightMint`, `foregroundColor: deepPine` (FAB = bright-mint CTA).

Additionally `Halved.chipScope(context)` (halved_brand.dart) is a local ThemeData override some screens wrap around Material FilterChips to force pine-selected / rounded-rect chip rendering without forking the widget.

---

### Hardcoded values that bypass tokens

Colours literal `Color(0xFF…)` used outside the theme files (grep of lib/), by file:

- **lib/screens/score_entry_screen.dart (~21 literals)** — the biggest offender. Repeated (×3) named-colour switch mapping a stored team-colour string to a swatch: `red #B71C1C`, `blue #0D47A1`, `green #1B5E20`, `yellow #F57F17`, `orange #E65100`, `purple #4A148C`, default `#455A64`. Used for user-configurable cup/team colours.
- **lib/screens/new_round_wizard.dart (~11)** — cup team-colour picker palette: `#1565C0`, `#2E7D32`, `#B71C1C`, `#E65100`, `#6A1B9A`, and a named `(label, Color)` list (`#B71C1C`/`#0D47A1`/`#1B5E20`/`#E65100`/`#F57F17`/`#4A148C`).
- **lib/api/models.dart (~10)** — cup team constants `kTripleCupTeam1Color = #1976D2` (blue), `kTripleCupTeam2Color = #EF6C00` (orange), plus the same named-colour swatch switch (adds `black #212121`, `white #424242`).
- **lib/utils/nassau_team_style.dart (2)** — `kNassauTeam1Color = #1976D2`, `kNassauTeam2Color = #EF6C00` (comments note they equal GameColors.team1/team2 — duplicated by value).
- **lib/widgets/shareable_scorecard.dart (7)** — the paper-scorecard capture inks, deliberately self-contained (not themed) so the exported image is stable: `_pine #1E5C3F`, `_muted #6B7280`, `_line #D8DED9`, `_headerBg #E7EEE9`, `_parBg #F3F6F4`, `_subBg #F1F5F2`, `_under #C62828`.
- **lib/screens/leaderboard_screen.dart (7)**, **lib/screens/setup_round_players_screen.dart (5)**, **lib/screens/tournament_low_net_setup_screen.dart (3)**, **lib/screens/quota_nassau_screen.dart (2)** — scattered one-offs (mostly team/cup swatches and status inks).
- **lib/widgets/team_splitter_4.dart (2)** — default `teamAColor = #1976D2` (blue-700), `teamBColor = #EF6C00` (orange-800); comment notes these mirror the GameColors team standard.
- **lib/widgets/inline_message.dart (4)** — warn tone `fg #B76E00 / bg #FFF4E0` and success tone `fg #1B5E20 / bg #E6F4E7` are literals (M3 has no dedicated warn/amber slot under the green seed).
- **lib/main.dart (5)** — the `surfaceContainer*` ladder + `outline #B7C3BB` inside the colorScheme copyWith (theme-internal, not a bypass, but hardcoded).

**Recurring theme:** the team/cup colour swatches (red/blue/green/yellow/orange/purple/black/white → hex) are duplicated across score_entry_screen, models.dart, and new_round_wizard rather than centralized — a clear consolidation candidate. The shareable-scorecard inks are an intentional exception (image-capture surface).

---

## 6. Flows

### Flow 1 — Phone sign-in → first round (new user)
1. **SplashScreen** (`/splash`) — animation + version check.
2. **LoginScreen** (`/login`) — enter phone → `AuthProvider.requestOtp`.
3. **OtpVerifyScreen** (`/verify-otp`) — enter 6-digit code → `AuthProvider.verifyOtp`.
   - *Branch:* existing account → straight to `/tournaments`. New account (`isNewAccount`) → `/profile-setup`.
4. **ProfileSetupScreen** (`/profile-setup`) — name/handicap → `AuthProvider.applyPlayer` → home.
5. **TournamentListScreen** (`/tournaments`) — home. Drawer nudge **"Start your first round"** → **OnboardingWizard** (`/onboarding`) → picks course + players + one game → creates round → **RoundScreen** (`/round`).

### Flow 2 — Create a casual round & enter scores
1. Drawer → **Casual Rounds** (`/casual-rounds`) → FAB **New Round** → **CasualRoundScreen**.
2. Pick course (`CourseSearchField`, empty-account inline "Find your course"), add players (inline **PlayerFormScreen** for new golfers), pick **primary game** (single-select) + **side games** (multi-select, shown when the primary `allowsSideGames`), set tees/handicap/stake.
3. Create → routes to the primary game's **setup screen** (e.g. `/skins-setup`) → save (POST) → **RoundScreen** (`/round`) hub.
4. Hub → **Enter Scores** → **ScoreEntryScreen** (`/score-entry`) or a game play screen → enter each hole (`InlineScorePicker` / `NetScoreButton`), capture junk/spots where applicable → `RoundProvider.submitHole` (queued offline, synced by `SyncService`).
5. Hub → **Leaderboard** (`/leaderboard`) → per-game tabs + money. Rotate to landscape anywhere → full-group `ScorecardGrid`.
6. When all holes scored → **Complete Round** (universal unblocker accounts for withdrawn players/killed holes).

### Flow 3 — Add & configure a side game at the tee (in-round)
1. In **RoundScreen** hub, per foursome (non-cup, pre-score) → **Add side game** → bottom sheet of eligible overlays (`sideGamesFor(primary,size)`).
2. Selecting one → its setup route (e.g. `/spots-setup`, `/honors-setup`) with `returnToHub:true` → save → back to hub.
3. Side game appears as a **leaderboard tab**; capture add-ons (Spots) also render a control in score entry.

### Flow 4 — Run a tournament / cup
1. **TournamentListScreen** → **NewRoundWizard** (multi-foursome round) or **CupRoundSetupScreen** (cup format).
2. Cup: **RyderCupDraftScreen** — draft players onto teams (add/remove) → **Lock Draft** (`postDraftComplete`; rosters frozen — *no further roster edits*) → **RyderCupScoreboardScreen** / round play.
3. Per-foursome scoring from the hub; **TournamentLeaderboardScreen** aggregates. Championship games configured via **TournamentLowNetSetupScreen** / **TournamentStablefordSetupScreen**.
4. **Roster change mid-tournament:** for regular (non-cup) tournament rounds the hub exposes TD tools (see §3 RoundScreen — remove no-show / move player / swap tee positions). For **cup rounds these are hidden**; the only path is delete + recreate the round. *(See §7 — the no-show tools' wiring status.)*

### Flow 5 — Watch a shared round (spectator / friend)
1. Universal link `halved.golf/watch/<token>` (or a round flagged **"Observing"** inline on the Casual/Tournament lists) → `DeepLinkService`/`openWatchedRound`.
2. Opens the **read-only LeaderboardScreen** (or `TournamentLeaderboardScreen`) — never the score-entry `/round`. Host shares the link via the leaderboard's **Invite a watcher** (or **Copy round link**).

### Flow 6 — Delete account (App Store 5.1.1)
Drawer → **Profile** → **SettingsScreen** (`/settings`) → **Delete Account** → confirm → `AuthProvider.deleteAccount` → token cleared → auth gate → `/login`.

---

## 7. Open questions

- **No-show / rearrange-foursomes-on-the-fly tools — built, deliberately unwired, and cup-gated (design decision needed).** `RoundScreen` defines `_showRemovePlayerSheet` (TD "no-show" removal), `_showMovePlayerSheet` (rebalance a player between groups), and `_showSwapPositionSheet` (swap two groups' tee positions), all fully implemented and backed by real client calls (`removeFoursomePlayer`, `moveRoundPlayer`, `swapFoursomePosition`). **None of the three is invoked by any button or menu item** — they are orphaned. An in-code comment (round_screen.dart ~1623-1635) says they were *intentionally pulled* from the TD menu because a roster change leaves stale state (game chips, payouts, brackets, phantom accounting don't recompute), so the TD's only sanctioned path today is **delete + recreate the round**. Separately, the whole per-foursome TD menu is gated `!isCupRound`, so even re-wired these would not appear on **Ryder Cup / cup rounds**. **This is the app's single most important open design question:** treating it (per direction) as an intended feature, the work is (a) re-wire the three sheets into the TD menu, (b) make roster changes recompute dependent state so they're safe, and (c) decide whether cup rounds get an on-the-tee no-show/rearrange path (today cup roster edits are setup-time only, frozen at "Lock Draft"). ← raised by the product owner.
- **`RyderCupRoundSetupScreen` is dead code.** Defined in `ryder_cup_round_setup_screen.dart` but never imported, routed, or pushed anywhere in `lib/`. (Would have configured per-round cup game settings + per-foursome team/game assignment.)
- **Legacy password login is gone but still referenced.** CLAUDE.md documents `PasswordLoginScreen` at `/login-password`; **no such file or route exists** in the code, yet `LoginScreen` still references the path. The legacy username/password path appears to have been removed — verify reviewers/legacy accounts still have a way in.
- **No "Scoring" drawer entry.** CLAUDE.md describes a delegated-scoring "Scoring" drawer item → `scoring_rounds_screen.dart`; neither the drawer entry nor that screen file exists in the current code (as with the retired `shared_rounds_screen.dart`).
- **Label vs. code drift (trademark scrub).** `TournamentLowNetSetupScreen` is titled "Stroke Play Championship" in the UI but its class/API are Low Net; Triple Cup screens say "One-Round Triple Cup"; internal `__bandon_cup__` tab key and `RyderCup*`/`triple_cup` slugs remain in code. Expected (per the rename), but the design brief should carry the **user-visible** strings, not the internal slugs.
- **Three Nassau setup routes, one screen.** `/nassau-setup`, `/nassau-setup-18` (`overallOnly`), and `/nassau-nine-setup` (`singleMatch`) all resolve to `NassauSetupScreen` with different flags — three distinct configurations of one screen.
- **`RyderCupDraftScreen` banner says "drag players to teams" but there is no drag-and-drop** — adds go through a multi-select picker dialog.
- **Duplicated delete flow in `ManageCoursesScreen`** (`_delete` button + inline `Dismissible.confirmDismiss` are two copies) and a **dead `CourseSearchScreen.initialQuery`** param (the only route builds it with no argument).
- **Dark mode is defined but forced off** (`themeMode: ThemeMode.light`); the dark `ThemeData` exists only so the app compiles if enabled. Design should treat the app as light-only for now.
- **Sparse use of the shared component library.** Several screens use plain Material `AppBar`/widgets rather than `GolfAppBar`/`SectionCard`/`GolfPrimaryButton`; the shared kit is not applied uniformly (see §4).
