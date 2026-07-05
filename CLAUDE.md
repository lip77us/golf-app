This is a golf app that will support tracking golf gambling games for golfers during the round.

I plan to eventually support tournaments that might have multiple foursomes, multiple games being played at the same time and potentially multiple rounds across multiple days where the user can pick the best N of the M rounds.

I will start by implementing some single foursome games where there is no greater tournament and it concludes after the single 18 hole round.  This is called a casual round and is not really part of a specific tournament.

I have decided to put in three modes to operate on single foursome games.  You could go net (with a percentage of net), or gross, Strokes off best golfer.   We can play all three depending on the situation.  I want to define for each game, if all three are possible.  Sometimes, only net or only strokes off makes sense, depending on the game.

---

## Architecture overview

**Stack:** Django REST Framework backend + Flutter/Dart mobile app.

**Key directories:**
- `backend/core/` — shared enums (GameType, MatchStatus, HandicapMode), Player model
- `backend/games/` — per-game models (SkinsGame, SkinsHoleResult, SkinsPlayerHoleResult, Points531Game, etc.), migrations
- `backend/services/` — business logic (skins.py, points_531.py, sixes.py …)
- `backend/api/` — serializers.py, views.py, urls.py
- `mobile/lib/api/` — models.dart, client.dart
- `mobile/lib/providers/` — round_provider.dart (main state), auth_provider.dart
- `mobile/lib/screens/` — one screen file per game

**Coding pattern:** Every new game follows the Points 5-3-1 pattern exactly (use that as the template for future games).

---

## Implemented casual games

### Six's (`sixes`)
- 2v2 best-ball across three 6-hole segments, requires exactly 4 players.
- Setup screen: `/sixes-setup` → `SixesSetupScreen`; play screen: `/sixes` → `SixesScreen`

### Points 5-3-1 (`points_531`)
- Per-player points game, requires exactly 3 players.
- Setup screen: `/points-531-setup` → `Points531SetupScreen`; play screen: `/points-531` → `Points531Screen`

### Casual game model: one primary + leaderboard-only side games — implemented (Phase 1)
Casual rounds no longer use a flat multi-select with `excludes` mutual-exclusion.
A casual round now has **exactly one PRIMARY game** (owns the score-entry screen)
plus **zero or more SECONDARY "side games"** — pure leaderboard overlays computed
from the entered scores, with **no effect on score entry** (they appear only as
leaderboard tabs). Mirrors how tournaments separate a primary accumulator from
per-round side games. Originally the primary was **derived** from the flat
`active_games` set (mobile-only). That broke for two-overlay sets like
{`low_net_round`, `skins`} — Stroke-Play-primary + Skins-side and its inverse
produce the SAME set, so `primaryGameOf` guessed (wrongly) via priority. The
primary is now **STORED** — see "Casual primary game stored" below — so the
user's explicit pick is authoritative; `primaryGameOf` remains the fallback for
legacy/tournament rounds (null `primary_game`).
- **Classification** lives in `game_catalog.dart` `GameMeta`: `canBeSideGame`
  (true: `skins`, `stableford`, `low_net_round` [Stroke Play]) and `allowsSideGames` (false:
  `sixes`, `vegas`, `nassau`, `triple_cup`, `multi_skins`). Helpers:
  `primaryGameOf(active)` (the entry-owning game, or the highest-priority
  side-eligible game for an overlay-only round), `sideGamesFor(primary, size,
  multiGroup)`, `canBeSideGame()`, `allowsSideGames()`. The old
  `excludes`/`applyGameToggle`/`gamesCompatible` are KEPT for the tournament
  picker (unchanged); the primary/side model is casual-only.
- **Picker** (`casual_round_screen.dart`): `String? _primaryGame` single-select
  + `Set<String> _sideGames` multi-select (rendered only when the primary
  `allowsSideGames`); `_activeGames` is now a computed getter
  (`{primary, ...sides}`). Side games prune on primary/size change.
- **Routing off the primary**: `create_casual_round.dart` `casualGameRoute`
  routes off `primaryGameOf(...)` (no longer gated on a single game);
  `round_screen.dart` `onEnterScores` gates the side-game (`skins`) branch to
  primary-only so a configured primary + unconfigured side game goes straight to
  `/score-entry` (was hijacked to `/skins-setup`). `_editConfigTarget` targets
  the primary; new `_sideGamePerFoursomeTargets` adds a "Set up Skins" button
  for side-game Skins (Stableford/Stroke Play already have hub buttons via
  `_roundLevelEditTargets`).
- **Entry suppression** (`score_entry_screen.dart`): `_GameStatusSection` gained
  a `primaryGame` param; the Skins / Multi-Skins / Stroke-Play / Stableford
  sections + the Stableford strip + the junk stepper now render only when that
  game **is** the primary. `_handicapParams` (entry) and
  `scorecard_screen.dart` `_handicapParams` resolve the stroke-dot handicap from
  the **primary** game (side games keep their own mode server-side).
- **Skins-as-side ⇒ no junk** (`skins_setup_screen.dart`): junk toggle hidden +
  `allow_junk:false` forced when Skins is a side game (junk is a score-entry
  modifier). `_isSideGame` = `primaryGameOf(round.active_games) != 'skins'`.
- **Side games inherit the primary's handicap, net-only for Stableford/Stroke
  Play.** A side game has no own handicap selector — `utils/primary_handicap.dart`
  `primaryHandicapFor()` resolves the primary's (mode, net%) and
  `widgets/inherited_handicap_note.dart` renders the read-only note. Stableford
  (`stableford_setup_screen.dart`) and **Stroke Play / Low Net**
  (`LowNetSetupScreen` in `irish_rumble_setup_screen.dart`) only do net/gross, so
  a **strokes-off primary degrades to net** there (`_isSideGame` getter +
  `inherited` fetch in `_load`, `InheritedHandicapNote` in the body). Skins-as-side
  inherits all three modes verbatim.
- **Validated combo:** Fourball + Skins + Stableford (+ Stroke Play / Low Net as
  a further side game). **Deferred to Phase 2:** cross-group Multi-Skins linkage
  (feed a single foursome's scores into another group's pool); broaden side games
  to the other allowed primaries. `match_18` allows side games by default
  (flippable). Onboarding wizard already picks a single game (= primary);
  tournament wizard untouched.

### Fourball (`fourball`) — implemented
- A single 18-hole **2v2 best-ball match play** game; requires exactly 4 players
  (two fixed teams of two). The better of each team's two balls counts per hole;
  the match is decided by holes up/down with dormie/early close-out ("3&2"), like
  Match Play. Handicap: Net / Gross / Strokes-Off-Low, each with an adjustable %
  for Net & SO. Settlement: a single **match bet** (winning team +bet per player,
  losing team −bet, halve = push). Mutually exclusive with all other casual games.
- Closely derivative: the match-play up/down logic mirrors `match_play.py` /
  Triple Cup's `_score_fourball_or_singles`; the 2v2 fixed-team setup mirrors Vegas.
- **Backend:** `GameType.FOURBALL`; `games.models` `FourballGame`/`FourballTeam`/
  `FourballHoleResult` (migration `games/0045`, + `tournament/0041` refreshes the
  `game_type` enum choices); `services/fourball.py` (`setup_fourball`,
  `calculate_fourball`, `fourball_summary` — SO uses full-round SI allocation via
  `scoring.handicap._strokes_on_hole`, no per-segment spreading); serializer
  `FourballSetupSerializer`; views `FourballSetupView`/`FourballResultView`; routes
  `foursomes/<id>/fourball/` + `…/setup/`; recalc dispatch + leaderboard block in
  `api/views.py`; `fourball_game` added to `FoursomeSerializer.get_configured_games`.
  Tests: `scoring/tests/test_fourball.py` (engine — best ball, margin, close-out,
  halve, settlement, 3 handicap modes) + `api/test_fourball.py` (endpoints).
- **Mobile:** catalog entry (`GameIds.fourball`, exactPlayers 4); Dart
  `FourballSummary`/`FourballTeamInfo`/`FourballHole`/`FourballMoneyEntry`;
  `client.getFourballSummary`/`postFourballSetup`; `RoundProvider.loadFourball` +
  `fourballSummary`; setup screen `/fourball-setup` → `FourballSetupScreen`
  (TeamSplitter4 + HandicapModeSelector + StakeField); leaderboard
  `_FourballGroupCard`. Scores entered via the generic score-entry screen (no
  dedicated play screen, same as Vegas); results show on the leaderboard card.
  Routing wired in `create_casual_round.dart`, `round_screen.dart`,
  `casual_rounds_list_screen.dart`, `main.dart`, and `score_entry_screen.dart`
  (summary load + handicap-mode resolution).
- **Deferred:** web watch-page renderer; per-hole match strip in score entry;
  `seed_demo` round; mid-round withdrawal settlement (the universal unblocker
  already lets a fourball round complete).

### Skins (`skins`) — **fully implemented, not yet tested in production**
- 2–4 players; 1 skin per hole to best score; optional carryover on ties; optional junk skins (manual integer count per player per hole); pool-based settlement (bet_unit × n_players, split proportional to total_skins).
- Handicap: Net / Gross / Strokes-Off-Low (all three supported).
- Mutually exclusive with all other casual games.

**Backend files changed/created:**
- `backend/core/models.py` — added `SKINS = 'skins'` to GameType enum
- `backend/games/models.py` — added `SkinsGame`, `SkinsHoleResult`, `SkinsPlayerHoleResult`
- `backend/games/migrations/0004_skins.py` — migration for the three new tables
- `backend/services/skins.py` — `setup_skins()`, `calculate_skins()`, `skins_summary()`
- `backend/api/serializers.py` — `SkinsSetupSerializer`, `SkinsJunkSerializer`, `SkinsJunkEntrySerializer`
- `backend/api/views.py` — `SkinsSetupView` (POST), `SkinsResultView` (GET), `SkinsJunkView` (POST); also fixed `_build_leaderboard()` to use `skins_summary(fs)` directly (not wrapped in `{'totals': ...}`)
- `backend/api/urls.py` — three new routes under `foursomes/<pk>/skins/`

**Mobile files changed/created:**
- `mobile/lib/api/models.dart` — `SkinsSummary`, `SkinsPlayerTotal`, `SkinsHole`, `SkinsJunkEntry`
- `mobile/lib/api/client.dart` — `getSkinsSummary()`, `postSkinsSetup()`, `postSkinsJunk()`
- `mobile/lib/providers/round_provider.dart` — `skinsSummary`, `loadingSkins`, `loadSkins()`
- `mobile/lib/screens/skins_setup_screen.dart` — new (setup knobs: handicap mode, carryover, junk, bet unit)
- `mobile/lib/screens/skins_screen.dart` — new (score entry + junk stepper + hole outcome strip + 18-hole grid)
- `mobile/lib/screens/leaderboard_screen.dart` — updated `_SkinsGroupCard` to use new summary shape (`players`, `money` keys)
- `mobile/lib/screens/casual_round_screen.dart` — enabled Skins chip, added to mutex group, added 2–4 player gate + inline warning, added `/skins-setup` routing branch
- `mobile/lib/screens/round_screen.dart` — added `skins` branch in `onEnterScores` routing
- `mobile/lib/main.dart` — added imports + `/skins-setup` and `/skins` route registrations

**API shape (skins summary):**
```json
{
  "status": "in_progress",
  "handicap_mode": "net",
  "net_percent": 100,
  "carryover": true,
  "allow_junk": false,
  "players": [
    {"player_id": 1, "name": "Paul", "short_name": "Paul",
     "skins_won": 3, "junk_skins": 1, "total_skins": 4, "payout": 12.00}
  ],
  "holes": [
    {"hole": 1, "winner_id": 1, "winner_short": "Paul",
     "skins_value": 1, "is_carry": false,
     "junk": [{"player_id": 1, "short_name": "Paul", "count": 1}]}
  ],
  "money": {"bet_unit": 1.00, "pool": 4.00, "total_skins": 4}
}
```

**Endpoints:**
- `GET  /api/foursomes/<id>/skins/`        → skins summary
- `POST /api/foursomes/<id>/skins/setup/`  → configure + start (body: handicap_mode, net_percent, carryover, allow_junk)
- `POST /api/foursomes/<id>/skins/junk/`   → upsert junk counts (body: hole_number, junk_entries: [{player_id, junk_count}])

---

## Phone-first login (SMS OTP) — implemented (identity layer only)

Implements the phone-first identity from `docs/freemium-design.md` §12 as an
**additive** path. Account-name + username + password login still works
unchanged (legacy accounts + App Store reviewer rely on it).

**Model:** a verified phone maps to one `User` → one `Account` (account name is
now just a display label). Added to `accounts.User`: `phone` (E.164, globally
`unique`, `null=True` so legacy password-only users coexist) and
`phone_verified_at`. New `accounts.PhoneOTP` stores **hashed** codes
(SECRET_KEY-peppered) with a 10-min TTL + 5-attempt cap; `issue()` /
`check_code()` classmethods. (`check_code`, not `check` — `Model.check` is
reserved by Django's system checks.) Migration
`accounts/0005_user_phone_user_phone_verified_at_phoneotp.py`.

**Services:** `accounts/phone.py` (`normalize()` → E.164, US-default, no
dependency — swap in `phonenumbers` later for i18n), `accounts/sms.py`
(`send_sms()` dispatching on the `SMS_BACKEND` setting), `accounts/otp.py`
(`request_code()` w/ ≤5/hr rate-limit, `verify_code()` → existing-phone login
or unknown-phone self-signup creating Account+admin User+linked Player).

**SMS delivery is pluggable.** `SMS_BACKEND=console` (default) just logs the
code; the request endpoint also returns it as `debug_code` when `DEBUG`. Going
live on real SMS = set `SMS_BACKEND=twilio` + `TWILIO_ACCOUNT_SID/AUTH_TOKEN/
FROM` env vars (and US 10DLC) — no code change. (Twilio backend in `sms.py` is a
stub that posts via the `twilio` package if installed.)

**Endpoints** (both `AllowAny`, in `api/views.py` + `api/urls.py`):
- `POST /api/auth/otp/request/` → `{phone}` → `{sent, debug_code?}`
- `POST /api/auth/otp/verify/`  → `{phone, code, name?}` → same body as
  `LoginView` plus `is_new_account`. `name` seeds a new account/player.
`DeleteAccountView` now also clears `User.phone` so the number is freed.

**Mobile:** `LoginScreen` (login_screen.dart, route `/login`) is now the phone
screen → `OtpVerifyScreen` (`/verify-otp`) → `ProfileSetupScreen`
(`/profile-setup`, new accounts only). Legacy form moved verbatim to
`PasswordLoginScreen` (`/login-password`), linked as "Sign in with a username
instead". API: `ApiClient.requestOtp/verifyOtp`; `AuthProvider.requestOtp/
verifyOtp/isNewAccount/applyPlayer`; `AuthResult.isNewAccount`.

**Demo:** `seed_demo` sets verified phones on the 4 login users
(`+1310555010{1-4}`, reviewer = ...0101) so phone login is testable locally.
Reviewers still use password login in prod (console SMS can't reach Apple).

**NOT in scope** (deferred per §12): billing/IAP, metered free tier,
claimable-pending-player merge, device-initiated Messages invites.

### Live SMS via Twilio Verify — implemented (off by default)
OTP delivery is now pluggable via the `OTP_BACKEND` setting:
- `local` (default) — our `PhoneOTP` table (hashed codes, TTL, attempts) +
  `SMS_BACKEND` delivery (console in dev). Returns `debug_code` under DEBUG.
  Production stays here until the env var is flipped, so nothing changes yet.
- `twilio_verify` — **Twilio Verify** generates/sends/checks the code
  (`accounts/twilio_verify.py`: `start_verification` / `check_verification`).
  `accounts/otp.py` branches on `_use_twilio_verify()`; account-creation logic is
  shared. Chosen over Programmable SMS because login is one code per user/device
  (very low volume) and Verify owns code storage + most carrier compliance.

Going live (env on Railway): `OTP_BACKEND=twilio_verify`, `TWILIO_ACCOUNT_SID`,
`TWILIO_AUTH_TOKEN`, `TWILIO_VERIFY_SERVICE_SID`. `twilio` is in
`requirements.txt`. Rollback = set `OTP_BACKEND=local`. Test tool:
`python manage.py send_test_otp <phone> [--code <code>]` (never creates an
account). Full from-scratch provisioning + toll-free/10DLC steps:
`docs/twilio-verify-setup.md`. The long pole is carrier registration (multi-day
approval) — start it early.

---

## Friends — Phase 1 ("My Golfers" roster + invite link) — implemented

First step toward "play with friends who also use the app," scoped deliberately
small because one-account-per-user isolates every tenant (a round's players /
scores all live in one account; `PlayerListView` is filtered to
`request.user.account`).

**Key reuse:** the existing per-account `Player` roster already does most of it.
Every phone signup is `is_account_admin=True`, so the user can already add
**login-less** golfers (name + handicap, phone optional) via the roster and reuse
them across rounds. Phase 1 just reframes + extends it:
- **"My Golfers"** relabel: drawer entry + `PlayerListScreen` title (was
  "Players"). Same screen/routes/`getPlayers()`.
- **Inline "Add a golfer"** during round setup (`setup_round_players_screen.dart`,
  `casual_round_screen.dart`): pushes `PlayerFormScreen`, which now **pops the
  saved `PlayerProfile`** (was `true`) so the new golfer is added to the list and
  auto-selected. The one existing caller (`player_list_screen.dart`) was updated
  to `push<PlayerProfile>` + null-check.

**Invite / download link (viral, user-initiated → TCPA/Apple safe):**
- `accounts.User.invite_code` (unique, lazy-minted via `ensure_invite_code()`,
  same base32-8 scheme as `Round.watch_token`). Migration `accounts/0006`.
- `GET /api/invite/` (`InviteView`) → `{code, url, share_text}`; `url` built from
  `request.build_absolute_uri` (correct in dev + prod).
- Public landing page `GET /i/<code>/` (`api/invite_views.py`, AllowAny, plain
  HTML like `watch_views.py`) → "<First> invited you to Halved" + a download
  button to `APP_DOWNLOAD_URL` (settings, env-overridable placeholder until the
  App Store listing is live). Route in `my_golf_app/urls.py`.
- Mobile: **`share_plus`** dep; `ApiClient.getInvite()`; `shareInvite()` helper +
  "Invite Friends" drawer entry (`app_drawer.dart`) and a My Golfers app-bar
  button → native share sheet (user texts it from their own phone).

Tests: `accounts/test_invite.py` (code minted once + stable; `/api/invite/` shape
+ auth-required; landing 200 for real code, 404 otherwise).

**Deferred to Phase 2** (the parts that must solve the `PROTECT` / account-scoping
wall): claim-on-signup (link a friend's new login to a login-less player you
created — player can't move accounts, so it'd link in place) and cross-account
shared-round visibility + live multi-phone scoring.

### Friends Phase 2a — "Shared with me" (read-only cross-account history) — implemented
First cross-account slice. After a user verifies their phone, they can see
(read-only) casual rounds in OTHER accounts where a player carrying their phone
number played — i.e. games a friend added them to. **Phone-matched, no permanent
link / no schema change** (the OneToOne→FK "claim" refactor is deferred to the
write-scoring slice where it's actually needed).
- Backend: `SharedRoundsView` (`GET /api/rounds/shared-with-me/?status=`,
  `api/views.py`) — finds players in other accounts whose free-text `Player.phone`
  normalizes (`accounts.phone.normalize`) to `request.user.phone`, returns their
  casual rounds (lightweight summary: course, date, status, games, `group_label`
  = creator/account name, `your_name`). Detail view **reuses the existing
  `LeaderboardView`** (already fetchable by round id). Route in `api/urls.py`.
  Tests: `api/test_shared_rounds.py` (formatted-phone match, own-account
  excluded, wrong/no phone → empty).
- Mobile: `SharedRoundSummary` model; `client.getSharedRounds()`;
  `shared_rounds_screen.dart` (list → existing `LeaderboardScreen`); "Shared with
  me" drawer entry; `/shared-rounds` route.
- Demo: `seed_demo` creates a separate **'Saturday Crew'** account with a
  completed skins round whose login-less guest 'Paul Avery' carries the
  reviewer's phone (formatted `(310) 555-0101`), so the round surfaces in the
  reviewer's "Shared with me" out of the box (`_seed_shared_round`; cleared on
  `--reset`).
- Out of scope (later): permanent claim (OneToOne→FK), live multi-phone scoring,
  tournament rounds, recycled-number safeguards, tightening LeaderboardView's
  open-by-id read.

#### Observed rounds folded into the main lists (standalone "Shared with me" retired)
The separate "Shared with me" drawer screen was removed; the rounds/tournaments
you were invited to WATCH now appear inline on the **Casual Rounds** and
**Tournaments** lists, flagged **"Observing"** (eye icon, `secondary` color) so
it's clear you're watching, not playing. They sort/age by the same Active vs
Completed tab rule as your own rounds — an observed round moves to Completed when
it finishes (still subject to the server's `SHARED_WATCH_RETENTION_DAYS`=7 aging
for completed watcher follows; live ones never age off).
- Both lists already merged cross-account PLAYER rounds via `getPlayingForMe`
  (`PlayingRoundsView`); this adds the WATCHER rounds via `getSharedRounds`
  (`SharedRoundsView`), split by `isTournament` per screen.
- `utils/shared_round.dart` `openWatchedRound(context, SharedRoundSummary)` —
  joins best-effort then opens the **read-only leaderboard** (`/leaderboard` or
  `TournamentLeaderboardScreen`), NOT the score-entry `/round` (that's
  `openSharedRound`, for players/scorers). This watch-vs-play split is the whole
  point of the flag.
- Casual: `_RoundItem.isObserving` drives the flag in `_RoundCard`
  (`casual_rounds_list_screen.dart`). Tournaments: an "Observing" section +
  `_observingTournamentCard` (`tournament_list_screen.dart`).
- Removed: `shared_rounds_screen.dart`, its `/shared-rounds` route + import
  (`main.dart`), and the "Shared with me" drawer entry (`app_drawer.dart`).
  Backend `SharedRoundsView` / `getSharedRounds()` are unchanged (just consumed
  from the list screens now).

### Connected golfers roster — implemented
"My Golfers" now shows which golfers have signed up ("On Halved"), unifying
golfers=friends (a golfer is just a friend who hasn't signed up yet). Phone-
matched, no schema change — the connection is emergent (invite a golfer → they
sign up with that number → badge appears; same match as Phase 2a).
- Backend: `PlayerSerializer.is_on_app` (SerializerMethodField); `PlayerListView`
  computes an `on_app_phones` set (one `User.objects.filter(phone__in=...)` over
  the normalized golfer phones) and passes it via context. Test:
  `api/test_players_on_app.py`. Single-player uses (login/me) default `is_on_app`
  False (no context).
- Mobile: `PlayerProfile.isOnApp`; the **Halved mark** badge (`HalvedMark`
  widget, `flutter_svg` rendering `assets/icon/halved_mark.svg`) flags signed-up
  golfers in **My Golfers, casual round setup, and tournament setup** pickers; a
  per-golfer **Invite** button (personalized share) appears on the rest;
  `shareInvite(..., inviteeName:)` builds a named message.
- Final logo: `mobile/assets/icon/halved_mark.svg` (H + flagstick in a mint cup)
  is bundled and used for the connected badge. **Still pending for the next App
  Store upload:** swap the app icon (re-run `flutter_launcher_icons` from a
  1024px PNG of this mark) and the splash/drawer text wordmarks → `Image`/`Svg`.
- Demo: `seed_demo` mirrors each login user's phone onto its `Player.phone`, so
  the 4 login golfers show "On Halved" and the 8 others show as invitable.
- Prerequisite for delegated cross-account scoring (below).

#### Handicap index: locally-editable + propagate-on-self-edit
The handicap model is **push, not read-time override** (replaced the old
"authoritative index" that locked a friend's copy):
- Every account keeps its OWN editable copy of a golfer's index — a friend can
  ALWAYS change their copy. `Player.effective_handicap_index()` just returns the
  local `handicap_index` (scoring uses the local value, snapshotted into
  `FoursomeMembership` at setup as before).
- When a golfer edits their OWN profile index, it PROPAGATES to friends'
  login-less copies (matched by normalized phone), overwriting them; the friend
  may re-edit, and the next self-edit overwrites again. `PlayerDetailView.patch`
  calls `propagate_canonical_index(player)` when the edited player is a canonical
  profile (`Player.user` set) and `handicap_index` changed. A friend editing a
  copy (no linked user) stays local.
- The obsolete `effective_handicap_index` / `handicap_is_authoritative` fields
  were REMOVED end-to-end: gone from `PlayerSerializer` (incl. a stray dead
  `extra_kwargs` block that lived inside the old `get_*` method), and from the
  mobile `PlayerProfile` (`effectiveHandicapIndex`/`handicapIsAuthoritative`
  fields + the `_handicapLocked` read-only logic in `player_form_screen`).
  `PlayerProfile.displayHandicap` now just returns the local `handicapIndex`.
  `_on_app_context` no longer computes the authoritative map. (Removing the API
  fields is safe for the shipped 2.1.0 client — its `fromJson` defaults the
  missing keys to `''`/`false`, which degrade to exactly the new behavior.)
  The model method `Player.effective_handicap_index()` stays (returns local;
  used by `course_handicap`).
- Tests: `api/test_handicap_propagation.py` (local copy used for display +
  course handicap; friend edit stays local; owner edit propagates + overwrites a
  friend's local change; only phone-matches touched). Replaced the old
  `test_handicap_authoritative.py`.

### Friends Phase 2b — delegated cross-account scoring (BACKEND done) — implemented
A TD designates an on-app golfer in a foursome as its **scorer**; that user (in
their OWN account) enters scores for the whole foursome and reads the whole-field
leaderboard. **Phone-matched** (no token/claim), assignable any time (even
day-of, not enforced at setup).
- Model: `FoursomeMembership.is_scorer` (migration `tournament/0034`).
- Auth (`accounts/scoring_access.py`): `foursome_for_scorer` (own-account OR
  phone-matched `is_scorer` member — WRITE/score), `round_for_scorer` (open the
  round), `round_for_reader`/`tournament_for_reader` (leaderboard read =
  own-account OR any phone-matched participant — **also preserves "Shared with
  me"**). All raise 404 like `account_get_or_404` and are behaviour-preserving
  for own-account users.
- Applied by swapping `account_get_or_404(Foursome, request.user.account, pk=pk)`
  → `foursome_for_scorer(request.user, pk)` across the ~29 per-foursome score +
  game views, and tightening the **previously-open** `ScoreSubmitView`,
  `ScorecardView`, `LeaderboardView`, `TournamentLeaderboardView` to the
  scorer/reader resolvers (security hardening). Round-level TD-management views
  stay own-account; `MultiSkinsResultView`/`RoundDetailView.get` use the
  scorer/reader resolvers.
- Endpoints: `POST /api/foursomes/<pk>/scorer/` `{player_id, is_scorer?}` (TD,
  own-account, ≥1 scorer allowed); `GET /api/rounds/scoring-for-me/` (rounds I'm
  designated to score, with `your_foursome_id`). `FoursomeMembershipSerializer`
  exposes `is_scorer`.
- Tests: `api/test_delegated_scoring.py` (designate, scorer reach+read, non-scorer
  404, own-account preserved, participant-can-read-not-score). Full `api`+`scoring`
  suite green (85). Demo: `seed_demo` makes the reviewer the scorer of the
  in-progress 'Saturday Crew' round (appears under "scoring-for-me").
- Mobile (PR B): TD designates via a **"Set scorer"** item in the round screen's
  per-foursome TD menu (`round_screen.dart` `_setScorer` bottom sheet;
  `Membership.isScorer`, `client.setFoursomeScorer`). Scorer side: a **"Scoring"**
  drawer entry → `scoring_rounds_screen.dart` (`client.getScoringForMe`,
  `ScoringRound` model) → tap opens `/round` (RoundScreen loads via
  `round_for_scorer`) to enter the foursome's scores + see the whole leaderboard.
  Caveat: the per-foursome TD menu is hidden on cup rounds, so cup-round scorer
  designation is a follow-up.

Tests: `accounts/test_otp.py` (normalization, request→verify happy paths,
self-signup, wrong/expired/too-many-attempts, rate-limit, phone uniqueness, and
legacy password login still works).

### One-tap SMS invite for a just-added golfer — implemented (mobile only)
When you inline-add a login-less golfer **with a phone number** during round
setup, the app offers to open Messages with the recipient AND a seeded invite
body pre-filled (one tap to send, from the user's own phone → TCPA / App Store
safe). The text names the golfer + the round and carries the user's personal
invite link (`/i/<code>/`); when the invitee installs Halved and verifies that
number, the round surfaces in **their** Casual Rounds via the existing phone
match (no backend change — chosen over a true per-round invite token/landing).
- Dep: `url_launcher: ^6.3.1`; iOS `Info.plist` declares `sms`/`tel` in
  `LSApplicationQueriesSchemes`.
- `utils/golfer_invite.dart`: `maybeOfferRoundSmsInvite()` (the post-add prompt;
  no-ops when the golfer has no phone or is already on Halved),
  `sendGolferSmsInvite()` (fetches `getInvite().url`, builds the named/round-aware
  body, launches `sms:<digits>?body=<%20-encoded>`), `_launchSmsInvite()`. The
  body is built by hand (NOT `Uri(queryParameters:)`, which encodes spaces as
  `+` that iOS Messages renders literally) — `Uri.encodeComponent` → `%20`.
- The existing per-golfer **"Invite"** button (`inviteGolfer`) now opens Messages
  pre-addressed when the golfer has a phone; the native share sheet stays the
  fallback for the no-phone "Invite anyway" path.
- Wired into ALL inline add-golfer flows: `casual_round_screen.dart`
  (`_selectedCourse?.name`), `onboarding_wizard.dart` (the "Set up your first
  round" flow — `_course?.name`), `setup_round_players_screen.dart`
  (`_round?.course.name`), `new_round_wizard.dart` (`_selectedCourse?.name`).
  (Each "add golfer" entry point needs its own call — there's no single shared
  hook.)
- `player_form_screen.dart`: phone field moved ABOVE email (phone is the
  cross-account link — auto-connect, "On Halved", round sharing, texted invite).
- iOS quirk to watch: the SMS **body** pre-fill uses the standard `?body=` form;
  if a given iOS version ignores it, switch `?body=` → `&body=` in
  `_launchSmsInvite`. Can't be tested in the simulator (no Messages app).
- Deferred: a true round deep-link (per-round invite token + landing page showing
  the actual round + post-signup deep-link into it).

---

## Shared course catalog + copy-on-add — implemented

Solves the one-account-per-user course problem: previously every account
re-imported the same real-world course (re-hitting GolfCourseAPI, N duplicate
`Course` rows, no sharing). Now a **global deduped catalog** (keyed by
`golf_api_id`) is the canonical source, and accounts **copy-on-add** from it.

**Why copy, not reference:** tee priority is a LOCAL preference
(`Tee.sort_priority`), and the app's tenant isolation assumes account-owned
courses (`for_account()` = `.filter(account=acct)`; `Round.course` /
`FoursomeMembership.tee` are `PROTECT` within-account). So each account gets its
own `Course`/`Tee` clone — local edits stay local, scoping/scoring untouched.

**Backend:**
- `core/models.py`: `CatalogCourse` (`golf_api_id` unique, name + location, no
  `account`) + `CatalogTee` (mirrors `Tee`; `default_sort_priority` seeds the
  clone). `Course` gained `city/state/country/latitude/longitude`. Migration
  `core/0006`.
- `services/catalog.py`: `upsert_catalog_course()` (build/refresh catalog from
  an adapted API course) + `clone_catalog_to_account()` (idempotent copy-on-add).
- `CourseImportView` now **upserts the catalog then clones** into the caller's
  account; `CoursePasteView` (custom courses) stays account-private — never
  cataloged. `services/golf_api_client.py` `_adapt_course_detail` now keeps
  lat/lng.
- Endpoints (`IsAccountMember`): `GET /api/catalog/courses/?q=` (search
  name/city, `already_in_account` flag) and `POST /api/catalog/courses/<id>/add/`
  (clone, no API call). `CatalogCourseSerializer`; `CourseSerializer` gained
  location. Tests: `api/test_catalog.py` (import populates catalog+copy; 2nd
  account adds w/o API call; **local tee-priority isolation invariant**; search
  owned-flag).
- `seed_demo` seeds 3 shared-catalog courses (`golf_api_id` `seed-*`) so the
  "Find your course" flow is demoable without a GolfCourseAPI key; `_teardown`
  clears them on `--reset`.
- `seed_catalog_from_courses` backfills the catalog from existing account
  `Course` rows using their CURRENT data (preserves local mods; no API call).
  Keyed by `golf_api_id`, else synthetic `local-<pk>` with `--include-custom`.
  Flags: `--account <name>`, `--overwrite`. Helper `catalog_from_course()` in
  `services/catalog.py`.

**Mobile:** `CourseInfo` gained `city/state` (+`location` getter); new
`CatalogCourse` model; `client.searchCatalog()` / `addCatalogCourse()`. New
`catalog_add_screen.dart` ("Find your course"): **catalog-first search** with a
"search the full database" fallback to the existing `CourseSearchScreen`
(GolfCourseAPI import, which now also feeds the catalog); tapping a result
clones + pops the `CourseInfo`. `manage_courses_screen` shows city/state.

**Empty-account un-blocker (key UX):** `casual_round_screen.dart` shows a
"Find your course to get started" empty-state when the account has no courses,
and an "Add a course" button by the picker; both push `CatalogAddScreen`, then
refresh courses+tees and **auto-select** the new course. No arbitrary
pre-seeding (geography deferred) — the inline add is the guaranteed un-blocker.

**Deferred:** pre-seeding / seed-from-inviter, "courses near me" (needs user
location), catalog auto-refresh of copies, the same inline-add affordance in the
tournament round path (`setup_round_players_screen.dart`), catalog admin UI
(Django admin suffices).

### Unified one-box course search — implemented
Collapsed the previous visible two/three-level flow (own courses → catalog →
"search the full database" button) into a SINGLE search box. The user types a
course name and picks from one merged, deduped list; adding is transparent.
Enabled by the GolfCourseAPI Pro plan ($10/mo, 10k queries/day) — the per-call
cost that justified the old gating is no longer a constraint.
- Backend: `CourseFindView` (`GET /api/courses/find/?q=`, `api/views.py`) merges
  three sources into one list — the account's own courses (instant select), the
  shared catalog (clone-on-add), and a live `search_courses()` GolfCourseAPI
  call (imported with tees on selection). Dedup by `golf_api_id` then
  `(name, city)`, preferring the cheapest add path (account > catalog > api).
  Each row carries `source` + the id to add it (`course_id` / `catalog_id` /
  `golf_api_id`). **The GolfCourseAPI call is best-effort** — wrapped in
  try/except so a slow/down upstream still returns local results (picker never
  breaks). No staff gate on search (any authenticated user). Tests:
  `api/test_catalog.py::CourseFindMergeTests` (merge+dedup by source, API-failure
  degrades to local, short-query empty).
- Mobile: `CourseHit` model + `client.findCourses()` / `importApiCourse()`.
  `widgets/course_search_field.dart` rewritten to call `findCourses` and branch
  on tap (account → select cached CourseInfo; catalog → `addCatalogCourse`;
  api → `importApiCourse`, immediate import, no tee-preview sheet per the
  "just type and find it" decision). Removed the "Search the full course
  database" button + the `CourseSearchScreen` fallback push. Flows everywhere
  `CourseSearchField` is used (casual round, onboarding, new-round wizard).
- Untouched: the standalone `CourseSearchScreen` (route `/course-search`,
  reached from Manage Courses) stays as the admin full-DB import tool. Note:
  `CourseImportView` (the selection-time import) still requires
  `is_staff or is_account_admin` — fine because every phone signup is an account
  admin; relax it if non-admin members ever need to import.

### Import quality gate — implemented
Rejects courses with broken hole data BEFORE they enter the shared catalog (and
poison every account that later copies from them). Motivated by a real defect: a
GolfCourseAPI course came in with **all 18 stroke indexes = 18**, which silently
breaks net scoring (every hole allocates handicap strokes identically).
- **Root cause:** `services/golf_api_client.py` `_adapt_hole` used
  `int(raw.get('handicap') or 18)` — a missing per-hole handicap collapsed to SI
  18 for every hole. Fixed: `_adapt_hole` no longer FABRICATES; missing
  handicap/par become a **0 sentinel** (via new `_opt_int`) that the gate
  reports explicitly, instead of a plausible-looking default that corrupts
  scoring. (Par got the same treatment — was silently defaulting to 4.)
- **Gate:** `services/course_quality.py` `assert_course_quality(api_course)`
  (operates on the ADAPTED dict — the shape `fetch_course()` returns /
  `upsert_catalog_course()` consumes). Hard-rejects a tee that CLAIMS per-hole
  data but gets it wrong — **stroke index must be a permutation of 1..18** (each
  once: catches all-18, duplicates, gaps, out-of-range), par 3-6 per hole,
  plausible total par, contiguous hole numbers. A **0-hole tee is a soft warning,
  not an error** (slope/rating-only tees stay usable for gross games — no
  regression). Raises `CourseQualityError(problems=[...])` on hard defects;
  returns soft warnings otherwise. `validate_tee_holes(holes)` is the per-tee
  unit.
- **Wiring:** `CourseImportView` (the single API→catalog entry point — only
  caller of `upsert_catalog_course`; the unified-search "api" branch routes
  through it too) runs the gate after the name check and **before any DB write**,
  returning **422** `{detail, problems:[...]}` on failure. The view's
  `@transaction.atomic` guarantees nothing leaks into the catalog or account.
- **Parity:** the manual paste path (`services/course_paste.py`) already had the
  equivalent SI-permutation check — this brings the API path up to it. (Two
  implementations; DRY-ing into one shared check is a cheap future cleanup.)
- Tests: `api/test_course_quality.py` (validator units, adapter-sentinel,
  view 422 + asserts zero rows written, good import still 201). 
- **Decision:** reject (not gross-only import) a course with no SI data — the
  user can paste a corrected card. A "gross-only" import toggle is deferred.
- **Not gated:** the `seed_catalog_from_courses` backfill (migrates existing
  local data) — revisit if needed.

### Copy-on-write tees (round-history freeze) — implemented
Makes an account `Tee` IMMUTABLE once a round references it, so a completed
round's scorecard stays frozen against the exact hole data (par + stroke index)
it was played on. **Why this was needed:** every scoring service reads par/SI
LIVE from `membership.tee.holes` (points_531, skins, nassau, sixes, …), and the
re-rate / re-import paths mutated tees IN PLACE — so a course correction silently
rewrote the net scores + handicap allocations of every past round on that tee.
([api/views.py] even had a comment claiming pk-preservation protected history;
it preserved the FK, not the geometry.) This is the prerequisite that makes
catalog→account propagation safe.
- **Model:** `Tee.superseded_by` (self-FK, `SET_NULL`, `related_name='supersedes'`;
  **null == current revision**) + `Tee.is_current` property. Migration
  `core/0007`. No data migration — existing rows default to null (current).
  Chosen over a separate `is_current` boolean to keep a single source of truth +
  free lineage ("old rounds point to a previous rev").
- **The choke point:** `services/tee_revisions.py` `update_tee_geometry(tee,
  attrs)` — if the new holes differ AND the tee is referenced by any
  `FoursomeMembership`, it RETIRES the old row (sets `superseded_by`) and creates
  a NEW current revision (carrying local `sort_priority` unless overridden);
  old rounds keep pointing at the old immutable row, new rounds pick up the
  re-rate. Unreferenced or holes-unchanged → updates IN PLACE (no revision
  churn for courses nobody has played).
- **Write sites rewired through it:** `services/course_paste.py`
  (`apply_single_tee`, `apply_parse` — match CURRENT tees only) and
  `services/catalog.py` `clone_catalog_to_account(replace_tees=True)`. The
  catalog refresh now supersedes-by-`(name, sex)` instead of
  `course.tees.all().delete()` — which **fixes the `ProtectedError`** a re-import
  of a played course used to raise, and preserves local `sort_priority`.
- **Select sites filtered to current** (`superseded_by__isnull=True`):
  `TeeListView`, the tee-box editor GET (`FoursomeTeesView`), `CourseSerializer.tees`
  (now a method field; Manage Courses), and `CourseFindView` `tee_count`.
  **Left unfiltered on purpose:** `TeeDetailView` (by-id — old rounds fetch their
  retired tee) and `MembershipSerializer.tee` (embeds the played tee + holes, so
  the score screen renders an old round from the frozen revision). All
  `getTees()` consumers are setup screens, so they correctly see current only.
- Tests: `api/test_tee_revisions.py` (in-place vs supersede, frozen membership
  holes, unchanged-holes no-churn, serializer excludes retired, catalog re-import
  supersedes + preserves local priority). Full `api`+`scoring` suites green (257).
- **Next (Part B of the original plan — propagation):** `CatalogCourse.data_version`
  + `Course.catalog_synced_version` + a lazy sync that supersedes account tees
  from the catalog. Now SAFE to build on top of this. (Not the import-quality
  "B" above — that's already done; this is the propagation slice.)

---

## App Store readiness

### In-app account deletion (Guideline 5.1.1(v)) — implemented
Logged-in users can delete their own account from **Settings → Delete Account**.

Decision (chosen over full Player delete / Account-tenant delete): delete the
`User` + auth token, then **unlink and anonymize** the linked `Player`
(name → "Former Player", short_name → "FP", email/phone cleared) while keeping
the Player row and its golf history. Rationale: `HoleScore` and
`FoursomeMembership` reference `Player` with `on_delete=PROTECT`, and that
history is shared with other golfers in the account — a hard delete would
either fail or corrupt other players' scorecards. The `Account` (tenant) is
left intact even if it becomes memberless (deleting it cascades into
PROTECT-locked scores).

Guard: a sole admin of an account that still has other members is blocked
("promote another admin first"); a solo user can always delete.

- Backend: `DeleteAccountView` (`DELETE /api/auth/delete-account/`) in `api/views.py`, route in `api/urls.py`.
- Mobile: `ApiClient.deleteMyAccount()`, `AuthProvider.deleteAccount()`, Delete Account tile in `settings_screen.dart`. The auth gate in `main.dart` redirects to `/login` when the token clears.

Privacy policy should state: deleting your account removes your login and
personal info; anonymized game records may be retained.

### App name (working) — "Halved"
Working name as of this round of App Store prep, chosen after vetting several
candidates for trademark / App Store / domain conflicts:
- Rejected: **AllSquare** (registered "All Square®" golf social app),
  **GolfAction** (direct competitor golfactionapp.com), **Dormie** (existing
  Dormie golf app + multiple golf trademarks). **AutoPress** and **Honors**
  were "yellow lights" (proximity to Press Golf / existing "Honors" golf
  apparel brand). **Halved** came back clean (match-play term for a tied hole;
  no golf app or brand collision).
- Rename DONE across the app: in-app title + About dialog → "Halved"
  ([main.dart], [app_drawer.dart]); iOS `CFBundleDisplayName`/`CFBundleName`
  → "Halved"; drawer + splash logo replaced with a temporary **text wordmark**;
  app icon regenerated via `flutter_launcher_icons` from
  `mobile/assets/icon/halved_icon.png` (a green "Halved" text placeholder).
  Cup-name hint examples and the leaderboard cup fallback ("Bandon Cup" → "Cup")
  were neutralized. Internal-only `__bandon_cup__` key + `_BandonCup*` class
  names were intentionally left (not user-visible).
- TODO before launch: USPTO search in the software/golf class; pick a domain
  (`halved.app` / `halvedgolf.com`); decide support email.
- Trademark cleanup #2 — **"Ryder Cup"** (PGA-owned mark) scrubbed from all
  user-visible strings: catalog displayName + Triple Cup screens → "One-Round
  Triple Cup"; championship label "Cup Play (Ryder Cup style)" → "Cup Play";
  cup-format labels → "One-Day Triple Cup"; default cup-name field → "Team Cup";
  scoreboard hint → "Cup Play config"; backend `GameType.TRIPLE_CUP` label →
  "One-Round Triple Cup". Internal slugs (`triple_cup`, `team_cup`), the
  `/ryder-cup/` API routes, `RyderCup*` class/file names, and code
  comments/docstrings were intentionally left (not user-visible).
- App Store listing copy drafted in `docs/app-store-listing.md` (name, subtitle,
  keywords, promo text, description, what's-new). Support page in
  `docs/support.html` → host as `support.html` in the `halved-legal` repo
  (→ https://lip77us.github.io/halved-legal/support.html) for the App Store
  Connect Support URL field.
- LOGO UPGRADE (delivery 2): replace `assets/icon/halved_icon.png` with the
  final cut-golf-ball mark and re-run `dart run flutter_launcher_icons`; swap
  the temporary `Text('Halved')` wordmarks in app_drawer + splash_screen for an
  `Image.asset` of the real lockup.

### Privacy policy (Guideline 5.1.1 / App Privacy) — PUBLISHED
Live at **https://lip77us.github.io/halved-legal/privacy.html** (GitHub Pages,
repo `lip77us/halved-legal`, file `privacy.html`). Publisher = Paul Lipkin,
contact `paul@lipkin.us`, effective date May 30, 2026. App Store listing name
is **"Halved Golf"** (standalone "Halved" was taken; in-app/home-screen name
stays "Halved"). Source of truth for the
text is `docs/privacy-policy.html` in this repo — edit there, then copy into the
`halved-legal` repo to update. Goes in App Store Connect → App Information →
Privacy Policy URL.

(original draft notes:)
### Privacy policy (Guideline 5.1.1 / App Privacy) — drafted
`docs/privacy-policy.html` — self-contained HTML page ready for GitHub Pages,
publisher = Paul Lipkin (individual). Reflects the real data inventory (no
location/camera/tracking/ads; data stored on the Railway backend; course
lookups to GolfCourseAPI send no PII) and an account-deletion section matching
the implemented feature. Remaining placeholders before publishing:
`[EFFECTIVE DATE]` and `[CONTACT EMAIL]`. Once hosted, the URL goes in App
Store Connect → App Privacy, and ideally an in-app "Privacy Policy" link.

### Demo account for App Store review — `seed_demo`
`core/management/commands/seed_demo.py` builds a deterministic **DemoClub**
tenant for reviewer login + screenshots, and doubles as an end-to-end
smoke/regression test (drives the real model + service layer; exercises round
setup and the Skins / Points 5-3-1 / Nassau / Sixes calculators).

- `python manage.py seed_demo` — build (errors if DemoClub exists).
- `python manage.py seed_demo --reset` — tear down + rebuild deterministically.
- Creates: 12-player roster (4 logins: `reviewer` admin, `reviewer_delete`
  non-admin for deletion testing, `dmiller`, `slopez`), 1 course/tee, 5 casual
  rounds (completed Skins/Points/Nassau + in-progress Sixes/Skins) and 2
  tournaments (1 completed w/ 2 foursomes, 1 in-progress). Default password
  `HalvedDemo2026` (override with `--password`).
- **Run it against the Railway prod backend** before submitting — the
  reviewer's app talks to prod, not local.
- NOTE: the older `seed_test_data` command is **stale** (predates a schema
  refactor: it treats `Round.course` as a Tee and uses a non-existent
  `Tee.course_name`). `seed_demo` follows the current schema — use it as the
  reference for programmatic data creation.

## Stableford — casual implemented (tournament championship still deferred)
Casual Stableford is **live** end-to-end. The defining feature is an **editable
6-bucket points table** per round; with the standard table (5/4/3/2/1/0) it
ranks identically to low-net-with-a-double-bogey-cap — custom tables (e.g.
Modified `8/5/2/0/-1/-3`) are where it diverges.

**Backend:**
- `games.StablefordGame` (OneToOne round): `handicap_mode` (net|gross only — no
  Strokes-Off), `net_percent`, 6 `pts_*` buckets (albatross/eagle/birdie/par/
  bogey/double, SmallInteger, **negatives allowed**, default 5/4/3/2/1/0),
  `payout_style` (`pool`|`per_point`), `per_point_rate`, `per_point_mode`
  (`all`|`first`), plus Low-Net-style `entry_fee`/`payouts`/`excluded_player_ids`.
  `points_for_diff()`. Migrations `games/0033`,`0034`,`0035`.
- `services/stableford.py`: standings computed **config-aware from gross + the
  game's own handicap** (mirrors Low Net; does NOT trust stored `net_score`),
  ranked by points desc. Pool payout = Low-Net prize-rank/tie-split/excluded;
  per-point = `rate × (n·pts − total)` (`all`) or winner-collects-the-margins
  (`first`) — both zero-sum. `stableford_summary()` → standings + table + pool +
  style; each standing carries a per-hole `holes:{hole:pts}` map.
- Endpoints: `GET/POST /rounds/<id>/stableford/setup/`
  (`StablefordSetupSerializer`), `GET /rounds/<id>/stableford/`
  (`StablefordResultView`). Leaderboard block spreads the rich summary.
- Note: `HoleScore.stableford_points` is intentionally left **standard** (the
  generic scorecard field); the Stableford GAME recomputes config-aware in the
  service. Tests: `api/test_stableford.py` (8: setup/defaults, standard ranking,
  modified table, pool payout, excluded, per-point all+first, watch render).

**Mobile:**
- `stableford_setup_screen.dart` — 2-step wizard: (1) handicap (shared
  `HandicapModeSelector`, `allowStrokesOff:false`) + points table (3 presets:
  Standard / Modified / Reward birdies, editable) → (2) payout (Pool via
  `PayoutConfigField`+`PayoutPresetsRow`, or Per-point with an Everyone-above /
  Just-first toggle). Routes `/stableford-setup` (after round create, like Low
  Net); catalog entry re-enabled (`casual:true, enabled:true`).
- Three surfaces: `_StablefordView` (leaderboard — points + payout + table/style
  chips), `watch/stableford.html` (+ `_render_casual_stableford` tab), and a
  `_StablefordStrip` in `score_entry_screen` (per-hole points, authoritative via
  `RoundProvider.loadStableford` → `getStablefordResult`, refreshed after save).
- `client`: `getStablefordConfig`/`postStablefordSetup`/`getStablefordResult`.

### Stableford Championship (tournament, cross-round) — implemented
Total Stableford points accumulated across **every round** of a tournament
(all rounds count; N-of-M deferred, matching Low Net Championship). Pool-paid.
- Backend: `games.StablefordChampionshipConfig` (OneToOne tournament; Net%/Gross,
  6-bucket table, entry_fee/payouts/excluded; migration `games/0036`).
  `services/stableford_championship.py` aggregates per-round points via the
  refactored `stableford._build_stableford_totals(round, mode, net_pct,
  points_fn)` (so every round is scored on the tournament's own table), ranks by
  total points desc, pool prize-rank/tie-split like Low Net. Endpoints
  `GET/POST /tournaments/<id>/stableford/setup/` (+`num_players`) and
  `GET /tournaments/<id>/stableford/`; `TournamentLeaderboardView` spreads it
  under `stableford_championship`. Watch: `_render_stableford_championship` tab +
  `watch/stableford_championship.html`. Tests `api/test_stableford_championship.py`.
- Mobile: `championshipStableford` re-enabled in `kChampionshipGames` (shows in
  the tournament championship picker; activated with the standard table by
  default). `tournament_leaderboard_screen` → `_StablefordChampView` tab +
  "Configure Stableford" → `tournament_stableford_setup_screen.dart` (handicap +
  table presets/editor + pool payout). `client.get/postTournamentStablefordSetup`.

## Nassau — implemented
Enabled in `game_catalog.dart` (casual, 2–4 players; excludes Sixes/Points).
Full stack present: `nassau_setup_screen.dart` + `nassau_screen.dart`,
`/nassau-setup` + `/nassau` routes in `main.dart`, and backend
`NassauResultView` / `NassauSetupView` / `NassauPressView`. (This supersedes
the earlier "not yet implemented" note; the "Implemented casual games" list
above predates Nassau and Triple Cup / Match Play / Multi-Skins.)
## Mid-round withdrawal ("player can't continue") — implemented (Phase 1 + Sixes)
Lets a group keep scoring and complete the round when a player can't finish
(e.g. injury). The player and their posted scores are KEPT (unlike
`FoursomeRemovePlayerView`, which refuses once any score exists). Full kickoff
brief + decisions in `docs/mid-round-withdrawal.md`.

**Data model:** `FoursomeMembership.withdrew_after_hole` (SmallInteger, null =
played all 18; N = completed 1..N, out N+1..18) and `withdrew_killed_next_hole`
(group abandoned hole N+1). `SixesSegment.is_void` (voided segment = 0 pts,
excluded). Migrations `tournament/0036`, `games/0038`.

**Universal unblocker:** `RoundCompleteView._all_foursomes_done` now compares
each foursome's scored holes against an `_expected_holes(fs)` set that drops
killed holes and holes no remaining player is active for. Mobile `_allScored`
(used by `_allHolesScored` / `_firstMissingHole`) excludes withdrawn players and
killed holes, so the advance gate + Complete Round unblock automatically.

**API (`api/views.py`, auth = `foursome_for_scorer`):**
- `POST /api/foursomes/<id>/withdraw-player/` `{player_id, after_hole,
  kill_next_hole?, sixes_segment_action?: 'void'|'solo'}` → sets the WD fields,
  applies Sixes void/solo (`apply_withdrawal_to_sixes`), recalculates.
- `POST /api/foursomes/<id>/reinstate-player/` `{player_id}` → undo.

**Skins (segmented pool):** `services/skins.py` `_skins_withdrawal_plan()`
partitions the round into constant-roster segments; `calculate_skins` scopes the
carry pot per segment (carries die at every boundary) and `skins_summary`
settles each segment as its own pool funded only by the players IN it — a
withdrawn player stops contributing when they leave: `seg_pot = holes ×
roster_size × bet_unit / 18`, split within the segment by skins won (regular +
junk). So a skin on a 3-player hole is worth less than on a 4-player hole.
Killed holes + post-game-over holes evaporate. No-WD round = single 18-hole
segment with the full roster = unchanged. Summary gains
`withdrawals`, per-hole `is_killed`, and `money.pool_at_risk`. (Per-skin payout
styles — pay-the-winner / pay-those-above — aren't in Skins yet; when added they
settle each segment as a closed game instead of fractioning, noted in the plan
helper.)

**Sixes:** `apply_withdrawal_to_sixes()` marks the affected + remaining segments
`is_void` (void) or leaves them active (solo). Best-ball uses the lone ball
automatically; High-Low uses the lone net as both high and low
(`_high_low_nets_for_team` keys off a per-hole expected-roster check). Voided
segments label "Voided" and are excluded from money + the win/halve tally.

**Mobile (`score_entry_screen.dart`):** `Membership.withdrewAfterHole` /
`withdrewKilledNextHole`; `MembershipSerializer` exposes both. Long-press a
player row → withdraw sheet (last-hole stepper + "group abandoned hole N+1"
toggle + Sixes void/solo radios) or reinstate. `_PlayerRow` shows a **WD** badge
and an "Out" marker (no score box) on holes the player is out for.
`client.withdrawPlayer()` / `reinstatePlayer()`.

**Tests:** `scoring/tests/test_skins.py` (segmented pool split, lone-survivor
pool reduction, WD round completes), `scoring/tests/test_sixes.py` (void
excludes segments, solo best-ball lone ball, solo high-low lone net),
`api/test_withdrawal.py` (endpoint sets fields/killed hole, round completes with
WD + killed hole, control stays open, reinstate).

**Deferred:** Nassau / Points 5-3-1 / Match Play settlement (universal unblocker
already lets those rounds complete; per-game money for them is a follow-up).

## Spots (`spots`) — implemented (capture add-on, side-game-only)

A standalone gambling **add-on**: user-defined per-hole achievements (one-putt,
sandy, barky, hit-the-flag, …) the app can't detect, **tallied by hand** in
score entry like junk. **Always a side game, never a primary** (`GameMeta
.sideGameOnly`); 2–4 players; **separate payout** (never folded into the main
game). **Excludes Skins** in any role — junk is the Skins way to do per-hole
extras. Full design doc: `docs/spots.md`.

**The architectural carve-out it introduced:** side games were assumed to be
pure leaderboard overlays with no score-entry effect. Spots is the first
**capture add-on** — `GameMeta.capturesInScoreEntry`. Its capture control
renders in score entry even though it isn't the primary. (Snake — `docs/snake.md`
— will reuse the same slot.)

**Backend:**
- `core.GameType.SPOTS`; `games.SpotsGame` (`bet_unit`, `payout_style`) +
  `SpotsPlayerHoleResult` (per-player-per-hole `count`, a **signed**
  SmallInteger — negatives allowed). Migrations `games/0046`,`0047`, +
  `tournament/0042` (enum refresh).
- `services/spots.py`: `setup_spots`, `tally_spots` (upsert; `count=0` deletes),
  `spots_summary`. **No recalc step** — the counts ARE the data. Settlement:
  - **pay_around** (default): each spot pays the achiever `bet_unit` from every
    other active player on that hole — zero-sum within the hole roster; a
    **negative** spot reverses it (that player pays everyone). Honors mid-round
    withdrawal (only active-on-hole players pay).
  - **pool**: everyone antes `bet_unit` (pot = max loss). If anyone is positive,
    the pot splits among positives ∝ positive spots (negatives/zeros get
    nothing); else the **least-negative** player(s) take it, split on a tie.
- Endpoints `GET/POST /api/foursomes/<id>/spots/{,setup/,tally/}`
  (`foursome_for_scorer`); `SpotsSetup`/`SpotsTally` serializers; leaderboard
  block; `configured_games` entry.
- Tests: `scoring/tests/test_spots.py` (pay-around/pool zero-sum, negatives,
  the three pool cases, withdrawal, zero-deletes) + `api/test_spots.py`.

**Mobile:**
- Catalog: `GameIds.spots`; flags `canBeSideGame`, `capturesInScoreEntry`,
  `sideGameOnly`; `excludes: {skins}`. `sideGamesFor` honors the exclusion; the
  casual picker prunes a conflicting side game on toggle; `sideGameOnly` is
  filtered out of every primary list (picker + onboarding) and `primaryGameOf`.
- Capture: an **inline `⊖ N spots ⊕`** under each player name (`_SpotsDots`,
  modeled on `_JunkDots` but always shows the minus — negatives), threaded
  `_HoleScoreCard` → `_PlayerRow`. Debounced optimistic tally POST.
- `spots_setup_screen.dart` (`/spots-setup`, returnToHub) — stake + pay-around
  /pool; reached from the round hub's "Edit Spots" button.
- Leaderboard `_SpotsGroupCard`: per-player spots + payout, plus a wrapping
  **"spots by hole"** chip strip (hole # + short name + green/red ± count).
- `SpotsSummary` model; `client.get/postSpotsSetup/postSpotsTally`;
  `RoundProvider.spotsSummary` + `loadSpots`/`setSpotsSummary`.

**Deferred (v2, per `docs/spots.md`):** named spot types (Sandy/Barky/Greenie)
with a per-type breakdown — v1 is a generic signed count. Broadening which
primaries allow side games (Nassau/Sixes/Vegas own their structure → can't host
Spots yet) is the separate Phase-2 item.

#### Spots capture wired into every casual entry screen
The `SpotsDots` ⊖N⊕ control (via `SpotsCaptureMixin` in `widgets/spots_capture.dart`)
now renders in ALL casual score-entry surfaces, not just the universal
`score_entry_screen` + Wolf + Rabbit. Added to the dedicated-screen games whose
primary can host Spots: **Nassau** (`nassau_screen.dart`), **Points 5-3-1**
(`points_531_screen.dart`), **Quota Nassau** (`quota_nassau_screen.dart`).
**Sixes** needed no change — it plays through the universal `score_entry_screen`
(no dedicated play screen; `/sixes-setup` → `/score-entry`), which already had
Spots. Pattern per screen: `with SpotsCaptureMixin`, load in initState when
`activeGames` contains `spots`, `disposeSpots()` in dispose, and thread
`spotsActive`/`spotsCountFor`/`onSpotsAdd`/`onSpotsRemove` from the State →
hole-card widget → player-row widget, rendering `SpotsDots` under the player name.
**Deliberately NOT wired:** Pink Ball + Irish Rumble (tournament-only games — for
a foursome side game inside a tournament, start a separate casual round instead).
This closes the gap where Spots was addable to a Nassau round but had no capture UI.

## Scorecard reconciliation — standalone screen retired, rotate-to-landscape (mobile-only)

Collapsed three overlapping surfaces (portrait scorecard, landscape scorecard,
the leaderboard "Stroke Play" tab) into three distinct jobs with **no duplicated
grid**. The standalone `ScorecardScreen` + `/scorecard` route + all ~10
"Full scorecard" `table_chart` toolbar icons were **deleted**. No backend change.
- **Rotate the phone to landscape anywhere in a round → the full-group stacked
  card.** The app has no orientation lock (iOS `Info.plist` allows landscape; no
  `SystemChrome` lock), so `widgets/round_landscape_scorecard.dart`
  (`RoundLandscapeScorecard`, a `MediaQuery.orientation` gate) is the single place
  that gives landscape meaning. It wraps each per-foursome route in `main.dart`
  (score-entry + skins/points_531/wolf/nassau/rabbit/quota_nassau/pink_ball/
  triple_cup/match_play) **plus the leaderboard**. The wrapped screen stays
  mounted via `Offstage` (state preserved across rotate-out/in). `foursomeId`
  null ⇒ rotation is a no-op (e.g. multi-group leaderboard where the target group
  is ambiguous — the leaderboard resolves the sole/viewer's foursome, else null).
- **The grid itself:** `widgets/scorecard_grid.dart` (`ScorecardGrid`) — the
  landscape stacked grid (all players × 18 holes, handicap **dots** + **STBL** +
  net/OUT/IN/TOT), extracted verbatim from the old screen's landscape view along
  with ALL its stroke/handicap/ordering logic (`_handicapParams`,
  `_effectiveHcapFor`, `_tripleCupStrokes`, sixes-SO, team ordering) — still
  mirrors `score_entry_screen.dart`. Read-only (entry lives on the game screens).
  `showClose` param: X-button pops only when PUSHED as its own route
  (multi-skins per-group card); the rotate gate passes `showClose:false` +
  `automaticallyImplyLeading:false` so it never pops the screen underneath.
- **The "Stroke Play" tab is now a ranked net-to-par TABLE, not a grid**
  (`_LowNetView` rewrite, `leaderboard_screen.dart`): rank · name+CH · gross ·
  net · +/- · $payout, one row per player, **tap a row to expand that player's
  own 18-hole strip inline** (accordion, `_expandedPid`; par + gross coloured by
  net-vs-par via the kept `_scoreCell`, front/back subtotals + totals). Scales to
  a big tournament field where a stacked grid wouldn't. Fed by the existing
  backend `low_net_round` block — which the server already emits for every
  individual-ball round **except** `triple_cup`/`scramble` (alt-shot), so
  Sixes/Vegas/Fourball participants get the tab too (their individual scores,
  even though that isn't the bet). Future scramble/shamble just join that
  exclusion set. `_standingsRow` + the old stacked-grid body were removed.
- The round hub's completed-round **"View Scorecard"** FAB
  (`round_screen.dart`, still `table_chart_outlined`) was intentionally LEFT — it
  routes to read-only `/score-entry` (now rotate-gated), not the deleted route.
  Multi-Skins keeps its own skin-winner scorecard (`_MsScorecard`, unrelated).

## Casual primary game stored (`Round.primary_game`) — implemented

The casual round's PRIMARY game is now **persisted**, replacing the ambiguous
"derive from `active_games`" approach. Bug it fixes: picking Stroke Play as the
primary + Skins as a side game produced the unordered set {`low_net_round`,
`skins`}; `primaryGameOf` then re-derived **Skins** as primary (priority list put
skins first), so the create wizard dropped the user into **Skins** config (not
Stroke Play), the hub's "Edit Configuration" targeted Skins (generic label, no
"Edit Skins" side button), and stroke-dots/junk followed the wrong game. Two
overlay games can't be disambiguated from a flat set — so we store the pick.
- **Backend:** `Round.primary_game` (CharField, `null=True`; null = derive, for
  tournament/legacy rounds). Migration `tournament/0044`. `RoundCreateSerializer`
  accepts `primary_game`; `RoundCreateView` persists `d.get('primary_game') or
  None`; `RoundSerializer` exposes it (read).
- **Mobile:** `Round.primaryGame` (from `primary_game`); `ApiClient.createRound`
  sends it; `createCasualRound(primaryGame:)` + `casualGameRoute(…, primaryGame:)`
  route off the explicit pick; the casual picker passes `_primaryGame`, onboarding
  passes its single game.
- **Resolution helper:** `resolvePrimary(storedPrimary, active)` in
  `game_catalog.dart` — returns `storedPrimary` when present AND still in `active`,
  else `primaryGameOf(active)` (unchanged fallback). Applied at EVERY former
  `primaryGameOf(...)` call site that has a round in hand (~13):
  `primary_handicap.dart`, `create_casual_round.dart`, `score_entry_screen.dart`
  (×4: handicap params, junk gate, Stableford strip, `_GameStatusSection`),
  `scorecard_grid.dart`, `round_screen.dart` (onEnterScores routing +
  `_editConfigTarget`/`_sideGamePerFoursomeTargets`, which gained a `primaryGame`
  param threaded from a new `_FoursomeCard.primaryGame` field),
  `skins_setup_screen.dart` / `stableford_setup_screen.dart` /
  `irish_rumble_setup_screen.dart` (`_isSideGame`). Legacy/tournament rounds
  (null `primary_game`) fall back to the derived value → no behavior change.
- Both directions now honored: Stroke Play primary + Skins side AND Skins primary
  + Stroke Play side each configure/route/score the game the user actually chose.

## Nassau press fixes + hub plays-to PH — implemented

Three testing-found fixes:
- **Claremont bottom auto-press skip (`services/nassau.py`).** The bottom bet is
  2 points/hole (best ball + 2nd ball), so its margin moves up to ±2/hole and an
  odd margin could LEAP OVER the exact ±4/±8 threshold (e.g. −3 → −5 skips −4) —
  the `in AUTO_BOT_THRESHOLDS` exact match never fired. Now triggers on
  REACHING/CROSSING a 4-point band (`abs(margin) >= 4`, `band = sign*((abs//4)*4)`,
  tracked in `bot_*_thresholds_fired`). Top presses were fine (±1/hole hits every
  integer). Regression test in `scoring/tests/test_nassau.py`.
- **Press labels on the Nassau LEADERBOARD** (`leaderboard_screen.dart`
  `_pressRows`): "Auto press 3–9" → **"Auto Press holes 3–9"** (capital P +
  "holes"). The compact **play-screen** chips (`nassau_screen.dart` /
  `score_entry_screen.dart` `_PressesStrip`) intentionally KEEP the short
  "F9 Press 1" form — the long label is leaderboard-only.
- **Hub Playing Handicap is now the PLAYS-TO number** (`round_screen.dart`
  `hubHandicapLabel`). Was the stored WHS playing handicap (course + mixed-par,
  100% allowance) — which for a same-par full-net round equals CH, so nothing
  extra showed. Now it's the EFFECTIVE handicap after the primary game's
  allowance: "CH 20 · PH 18" for Nassau at 90%. The hub loads each foursome's
  primary-game `(mode, net%)` async via `primaryHandicapFor` (extended to cover
  nassau/sixes/vegas/triple_cup/low_net_round/quota_nassau) — **casual rounds
  only**, bounded to a few calls; the effective handicap uses
  `effectiveMatchHandicap(mode, net%, playingHandicap, groupLow)`. Until loaded
  (or on non-casual/unconfigured games) it falls back to the WHS playing handicap
  → shows "CH x" alone. So the PH difference appears only once the primary game's
  handicap is configured with an allowance <100% / strokes-off (or mixed par).

### Follow-up: editing Stroke Play net % now reflects on the hub
Two bugs blocked the plays-to PH from responding to a Stroke Play net-% edit:
- **Load** (`irish_rumble_setup_screen.dart` `_LowNetSetupScreenState._load`): read
  `cfg['round_net_percent'] ?? cfg['net_percent']` — but `round_net_percent`
  (=`Round.net_percent`, a fixed 100% for casual) is always present, so it hid the
  config's saved `net_percent` and the slider always showed 100%. Now gated on
  `is_tournament_round`: tournament rounds use the round-level value; casual rounds
  prefer the game config's own `net_percent`/`handicap_mode`. (The POST already
  persisted `net_percent` correctly — save was never the problem.)
- **Hub cache** (`round_screen.dart`): the per-foursome handicap load used a
  one-time `_hcapLoadStarted` guard, so it never re-fetched after an edit. New
  `_reloadRound()` resets the guard before `loadRound`; wired to both
  `onGamesChanged` (config-edit return) and pull-to-refresh, so the plays-to PH
  updates once the new % is saved.
