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
- **Every side game owns its handicap (SUPERSEDES the old inherit-the-primary
  rule).** As of the parallel-games work (`docs/parallel-games.md`) the handicap
  INHERITANCE subsystem was removed: `widgets/inherited_handicap_note.dart` is
  deleted and skins/stableford/`irish_rumble` (LowNet) setup screens now always
  show a `HandicapModeSelector` — Stableford net/gross, Skins + Stroke Play all
  three (incl. strokes-off). Each side-game config already stored its own
  handicap and its summary computes from it, so this was mobile-only.
  `utils/primary_handicap.dart` `primaryHandicapFor()` is KEPT (only for the hub
  plays-to Playing Handicap in `round_screen.dart`, not side games).
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

### Skins (`skins`) — implemented and PLAYED in production
(This heading read "not yet tested in production" for a long time after
it stopped being true — there are settled skins rounds in prod from May
and July 2026, and sixteen legacy junk rows among them.)
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

Implements the phone-first identity from `docs/freemium-design.md` §12.

> **Phone-OTP is now the SOLE sign-in path** (`d5c38ad`, 16 Jun 2026). It
> started additive, alongside account-name + username + password; that half is
> gone. `PasswordLoginScreen`, the `/login-password` route and the "Sign in
> with a username instead" link were all deleted, and `LoginView` returns
> **403** unless `PASSWORD_LOGIN_ENABLED=true` — so an older build that still
> draws the password screen fails closed with a clear message rather than
> authenticating. The App Store reviewer signs in through the phone screen via
> the demo-phone bypass below.
>
> **There is no way into the app without a phone code.** Against a local
> server that is free (`DEBUG=True` echoes `debug_code`, and the console SMS
> backend prints it); against production it needs real SMS or the bypass. The
> paragraphs below describe the phone half, which is all of it.

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

**Mobile:** `LoginScreen` (login_screen.dart, route `/login`) is the phone
screen → `OtpVerifyScreen` (`/verify-otp`) → `ProfileSetupScreen`
(`/profile-setup`, new accounts only). **That is the whole flow** — there is no
password screen and no second route. API: `ApiClient.requestOtp/verifyOtp`;
`AuthProvider.requestOtp/verifyOtp/isNewAccount/applyPlayer`;
`AuthResult.isNewAccount`.

`ApiClient.login()` and `AuthProvider.login()` survive and are unreachable from
the UI — the endpoint they call 403s. Left in place because re-enabling is an
env var rather than a rebuild; **do not wire a screen back to them without
flipping `PASSWORD_LOGIN_ENABLED` first**, or it fails closed on every tap.

**Demo:** `seed_demo` sets verified phones on the 4 login users
(`+1310555010{1-4}`, reviewer = ...0101) so phone login is testable locally —
the code prints in the runserver terminal (console SMS backend) and comes back
as `debug_code` under `DEBUG`.

**The reviewer goes through the phone screen too**, via the demo-phone bypass:
set BOTH `REVIEW_BYPASS_PHONE` (comma-separated; reviewer + reviewer_delete)
and `REVIEW_BYPASS_CODE` on Railway, and `request_code` skips real SMS for
those numbers while `verify_code` accepts that code without contacting Twilio.
Each must map to a seeded User. Empty = disabled; keep the values only in the
App Store review notes and rotate at will (`accounts/otp.py`
`_review_bypass_phones` / `_is_review_bypass`).

**Testing against a local server needs the right build.** `flutter run` with no
flags points at RAILWAY, where `DEBUG=False` — so no `debug_code` appears and
nothing reaches your console. Use
`flutter run --dart-define=USE_LOCAL=true`, and check the on-screen debug
ribbon reads `LOCAL` rather than `PROD` (`mobile/lib/config.dart`).

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
  is bundled and used for the connected badge, and is now the app icon and the
  drawer/splash mark as well — the swap this note used to list as pending for
  the next App Store upload SHIPPED in August 2026.
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
the reviewer demo-phone bypass). The password-login test asserted that the
legacy path **still works**; the behaviour inverted when `LoginView` started
403ing, so what is pinned now is that it is off by default and that
`PASSWORD_LOGIN_ENABLED` turns it back on.

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

#### A refused import is now ANNOUNCED — and names the reason

Annandale Golf Club (Pasadena), 25 Oct 2026, and the chain is worth all of it
because every link taught something.

**It started as a report with no reporter.** The golf shop emailed: *"one of
our members is having trouble downloading our course… it says it cannot
import our course because there are no tee markers."* True, and correct
behaviour — `fetch_course('3vzs9mg0')` returned the club, the city and **zero
tees**, so the gate refused it and wrote nothing. Paul then filled the tee
data in at GolfCourseAPI himself, after which the same import succeeded with
all five sets. **The upstream record was the whole problem, and it was
fixable by hand** — worth knowing, because private clubs are where that
database thins out (the Madison MS Annandale has 9 tees; the Pasadena one and
the Ajax ON one had none, and both are private).

**Then: who was the member?** Unanswerable. The gate runs before any DB write
inside `CourseImportView`'s `@transaction.atomic`, so a refusal leaves no
`Course`, no `CatalogCourse`, no audit row — and the view's own log line sits
*below* the gate, so it only ever described imports that SUCCEEDED. The only
Southern-California course in the entire production database was Paul's own
copy from that evening, and `CatalogCourse` 89 was created ten milliseconds
before it, so nobody had ever got the course in. Railway's log buffer had
nothing. A real user hit a wall, gave up, and left no trace at all.

So two fixes, and the second is the one that matters:

1. **The `detail` names the reason.** It read *"This course has invalid hole
   data and was not imported"* while `problems` — which said `Course has no
   tees.` — was **sent and never read**: `_failAdd`
   (`course_search_field.dart`) renders `ApiException.message`, i.e. `detail`
   alone. A course with NO data was reported as one with BAD data, which
   sends you hunting a defect that is not there. `detail` now leads with the
   first problem and counts the rest (`… (+2 more)`). **No client change** —
   which is exactly why the reason has to live in `detail`.
2. **`services/course_import_report.py`** logs the refusal and emails the
   operator. `COURSE_IMPORT_ALERT_EMAIL` defaults to `COURSE_REPORT_EMAIL`
   (same inbox: a course record is wrong, arriving by a different door) and
   **empty turns the email off while keeping the log.**

**The log names the user by id and account id; the EMAIL carries the phone.**
Deliberate split. A phone number is this app's cross-account identity key and
does not belong in a retained platform log that anyone with Railway access
reads; an id is enough, since whoever is reading has database access by
definition. The email is a direct message about one person to help, not a
record that sits around. `test_the_log_does_not_carry_the_phone_number` pins
it, and was **checked by making it fail** before being trusted.

**One email per course per day, never a throttled log.** A broken course is a
property of the COURSE, so the second golfer tells the operator nothing new,
while three taps from one frustrated member must not send three emails. The
log is never throttled — it is what answers *who tried*. `cache.add()` so the
first caller wins; it is Django's default LocMemCache (no `CACHES` block), so
this is per worker process rather than exact, which is the right trade: a
throttle that dropped the FIRST report would be worse than one that
occasionally repeats.

**Why the email and not just the log:** a member who cannot add his home
course is the most churn-prone moment in the app, and the only reason this
one was ever heard about is that a pro shop went looking for the developer.

**Fixture note:** the first version of these tests had `account_id` and
`user_id` equal, so a log line printing the account in both slots would have
passed. The fixture burns two `Account` rows to force them apart — the same
lesson as the Sixes anchor test, where inputs that coincide cannot pin the
distinction they exist to check.

**Still silent, deliberately out of scope:** the other early returns in that
view (no name → 400, upstream down → 502/503) announce nothing either.

**Searching needs the right spelling.** `search_courses('Annandale')` finds
it; `'Annendale'` returns **zero rows** — the upstream search does not
fuzzy-match, so a misspelling is indistinguishable from a course that is not
in the database.

**The other route for a course like this is the paste path** — Courses →
`Paste a scorecard` (`CoursePasteScreen`, the toolbar icon beside the FAB),
which stays account-private and is never cataloged. Correct for a card typed
off one club's scorecard; wrong if the fix belongs upstream, which here it
did.

Tests: `api/test_course_quality.py` (26) — `RefusalIsAnnouncedTests` (8) plus
the two naming cases on the gate itself.

#### ...and then the fix made the GOLFER's message worse

Two days later the same member tried again, upstream had a *different*
defect, and the alert worked perfectly — which is how we found out what he
was being shown. `friendlyError()` returns `ApiException.message`, i.e.
`detail` verbatim, straight into a red snackbar. So he read:

> *Orange: stroke indexes must be 1..18 with each value appearing exactly
> once (this allocates handicap strokes per hole). Got: [1, 2, 4, 5, …].
> (+2 more)*

**Accurate, and unreadable.** I had put the reason in `detail` because the
client renders nothing else — correct about the plumbing, wrong about the
reader. `detail` and `problems` serve two audiences and one field cannot be
both: **`detail` is the golfer's** (names the course, says it can't be added
and that somebody has been told), **`problems` is the operator's** and still
carries every technical line, which is what the alert and the console render.

The giveaway was in the club's own email: they wrote *"there are no tee
markers"*, which is **nothing the app ever said**. That was a member
interpreting *"invalid hole data"* — the message was so unhelpful he had to
guess, and he guessed right.

`"We've been told about it"` is only honest because `report_import_refusal`
fires immediately above it. There is a comment saying so; do not keep the
wording if that call ever moves.

Also: `course_search_screen.dart` showed that error at the **4-second
default** where `CourseSearchField._failAdd` already used 7. Now 7 on both.

#### A copy we already hold beats an upstream regression

The deeper problem was that a member was blocked from a course **we
demonstrably had**. We had imported a clean Annandale into the shared catalog
three weeks earlier; somebody then edited the women's tees upstream and broke
them, and the gate refused the whole course on the strength of the new
payload alone.

So on a gate failure `CourseImportView` now looks for a catalog row with that
`golf_api_id` and, if it **has tees**, clones that instead of refusing — 201
with a `warning` the client already renders (the full-DB screen draws it
orange for 8s). The reasoning that makes this safe rather than a loosening:
**the picker's `catalog` branch already clones that same row without running
this gate at all**, so serving it here is the same trust decision, not a new
one. A row with no tees is explicitly NOT a fallback — it would "succeed"
into a course nobody can score.

**The operator is still told, and told the truth.** `report_import_refusal`
gained `served_from_catalog`, because an email saying *"a golfer could not add
this course"* about a golfer who just added it is the kind of false line that
makes somebody stop trusting the alert. The log says `SERVED-FROM-CATALOG`
rather than `REFUSED`, and the body leads with *"he was not blocked — but the
upstream record still needs fixing"*.

It returns the ordinary **409** when the account already has the course, so
*"already exists — use Update"* keeps working instead of reading as a fresh
import that did nothing.

#### What was done to the data, not just the code

Operational, 27 Oct 2026, both verified after: `upsert_catalog_course`
refreshed **catalog 89** from 5 men's tees to all 10 (the five original rows
updated in place, `curated=False`; Green, Yellow and the three women's sets
created), and `clone_catalog_to_account(..., replace_tees=True)` brought
**course 192** (the only account copy) to the same 10 with **zero superseded
rows**, because no round had been played on it. A catalog refresh does NOT
touch account clones — that is the copy-on-add model working as intended, and
it is why the second step was needed at all.

**`CourseFindView` returns `{'courses': [...]}`, not `results`.** Cost one
wrong-looking empty answer mid-diagnosis.

#### The one still open

`CourseSearchScreen` (Manage Courses → *Search the full course database*)
ignores the catalog and always calls the API, so it is the one door that can
fail where the main picker succeeds — and it is the door that failed this
member twice. The catalog fallback above means it no longer fails *this*
way, which is why it was not also hidden from non-staff. The duplication is
still there.

Tests: `api/test_course_quality.py` (32) — `RefusalIsAnnouncedTests` (8),
`HeldCopyBeatsUpstreamTests` (5), and the three stating the `detail` /
`problems` split, including the exact stroke-index message a member was
shown.

#### The stated total vs the sum of the holes — a check we never had

Paul asked, 27 Oct 2026: *"Did you check the yardages listed for the tees
vs. the sum of the holes?"* I had not, and could not have: GolfCourseAPI's
TeeBox carries **`total_yards`** beside `par_total`, and **`_adapt_tee` read
the par and dropped the yardage.** So the app fetched the one number that
cross-checks eighteen others and threw it away.

Checking it by hand against the raw payload found **three mismatches in one
course, and all three were real errors**:

| tee | stated | holes | |
|---|---|---|---|
| Green (M) | 5003 | 5049 | **−46** |
| Orange/Blue Combo (M) | 6386 | 6328 | **+58** |
| Blue/White Combo (M) | 5796 | 5792 | **+4** |

**Green triangulated to one fix.** Its 1st and 18th read 322 and 458; the
White/Green Combo had **282** and **452** on those holes, which matched no
parent and was the loose end from the combo check. 322−282 = 40, 458−452 = 6,
and 40+6 = **46** — exactly Green's shortfall. Setting Green's two holes to
the combo's values made Green add up to its own stated total AND made the
combo resolve. One error, three symptoms, in three different places.

**The Orange/Blue Combo's stated total was the third witness.** Its men's and
women's cards differed on holes 3 and 17 — a mirror swap, where each took the
longer on one and the shorter on the other. Both blends were internally legal
and resolved cleanly, so nothing in the combo logic could tell which was
right. The men's STATED total was exactly the women's hole sum, which settled
it: the men's holes were wrong.

**Blue/White was the total itself.** Every hole sourced cleanly from a parent
and no hole had Blue and White four yards apart, so no hole edit could close
the gap without breaking the sourcing. 5796 should read 5792.

### It is OURS, not the golfer's — and that needed a second channel

Paul: *"as long as it is only a warning to us and not to the user. They never
care about the accuracy of total yards."* Right, and the mechanics agree —
yards feed the display and the combo-tee indicator while scoring reads par and
stroke index.

That is why `yardage_notes()` is a **separate function with its own return
value** rather than more entries in `assert_course_quality`'s warnings list:
**that list reaches the user**, through `result['warning']` and an orange
snackbar. Same split `detail` and `problems` needed one commit earlier, learnt
the same way — two audiences, two channels, kept apart by construction rather
than by remembering. `report_yardage_notes` logs and emails on the operator
channel and **puts nothing in the response**, which a test asserts by scanning
the whole payload for the vocabulary.

Three rules in the check, each there to stop it being ignored:
- **A missing total is flagged only when the card states others.** Plenty of
  courses carry no such field, and a note per tee on every one of those is
  noise that gets the whole check tuned out. (Annandale's women's Orange was
  the real case: the one tee of twelve without one.)
- **A tee with no per-hole yardage is skipped** — a rating-only tee is a
  legitimate shape, and there is nothing to compare.
- **It never blocks an import and never raises.** A mismatch is a HINT that a
  per-hole number is wrong, not proof.

Its own throttle key, so a refusal and a yardage note for one course do not
silence each other.

**`total_yards` is not STORED**, only checked at import. Storing it needs a
migration on `Tee` and `CatalogTee` and would let the console's course editor
run the same check later; worth doing if the editor ever wants it.

Verified against the live card: the two remaining Annandale discrepancies, and
nothing else, with `assert_course_quality` returning no user-facing warnings.

Tests: `api/test_course_quality.py` (45) — `RefusalIsAnnouncedTests` (8),
`HeldCopyBeatsUpstreamTests` (5), `YardageNotesUnitTests` (7),
`YardageIsOperatorOnlyTests` (6), and the three on the `detail` / `problems`
split.

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

## Golf Genius roster import — Slice 1+2 implemented (engine + CLI)

Bulk-import a **Golf Genius roster export** (`.xlsx` or `.csv`) into an account's
`Player` roster: match each row to an existing golfer by **normalized phone**
(falling back to **GHIN**), updating their index + GHIN (+ backfilling blank
email/phone), or create a new login-less golfer. **Account-scoped** — imports
into the acting account only (fits the one-account-per-tenant model; no
cross-account plumbing).
- **Model:** `Player.ghin` (CharField(10), blank, db_index) — the golfer's GHIN
  number; natural key for re-import + future handicap-service sync. Migration
  `core/0011`.
- **Engine:** `services/genius_import.py` — dependency-free reader (stdlib
  `zipfile`+XML for xlsx, handles both shared-string AND inline-string storage;
  no `openpyxl`). Four steps: `read_rows(filename, data)` → `parse_rows(rows)`
  (finds the header row BELOW Golf Genius's title banner by scanning for "First
  Name"+"Last Name"; normalizes; `parse_index` handles `+2.3`→−2.3 plus-handicaps
  and `NH`/`WD`/blank→None) → `build_plan(account, parsed)` (diff:
  create/update/unchanged/skipped, **no writes**) → `apply_plan(account, plan)`
  (atomic). Parsing half imports without `django.setup()` (Django only touched in
  build/apply) so it's unit-testable standalone. Skips a new golfer with no index
  (Player.handicap_index is required) but still UPDATES a matched one.
- **CLI:** `python manage.py import_genius_roster <path> --account "<name>"`
  (dry-run preview by default; `--apply` to commit; `--account-id` alt). Prints a
  bucketed diff. `core/management/commands/import_genius_roster.py`.
- **Cols consumed** (Golf Genius export, matched case-insensitively): First Name +
  Last Name → `name`, Index → `handicap_index`, GHIN Id → `ghin`, Phone Number →
  match key, Email → `email`, Gender (M/F) → `sex` (M/W). All other columns
  (DOB/city/tee/affiliation/…) ignored.
- Tests: `api/test_genius_import.py` (plus-handicap/sentinel parsing, header
  below banner, phone-match + GHIN-match update, new-without-index skip,
  create-with-plus-handicap, idempotent re-import).
- **Slice 3 landed as the TD console (web), not a mobile screen** — see the TD
  console section below. The engine is unchanged in behaviour; the additions are
  additive metadata the CLI ignores (`ParsedRow.index_raw`/`td_index`,
  `SkipItem.code`/`detail`, `UpdateItem.matched_by`/`before`/`phone_conflict`,
  `ImportPlan.created_ids`, `header_line()`, and `build_plan(...,
  index_overrides=)`). (Verified against a real 213-golfer Tilden Seniors export:
  211 phones, 188 GHINs, 176 indexes, 0 parse errors.)

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
  → "Halved"; drawer + splash render `assets/icon/halved_mark.svg` through
  `SvgPicture.asset`; app icon generated via `flutter_launcher_icons` from
  `mobile/assets/icon/halved_icon.png`, which is that same mark (it began as a
  green text placeholder and was replaced in August 2026).
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
- App Store listing copy lives in `docs/app-store-listing.md` (name, subtitle,
  keywords, promo text, description, what's-new), **newest version at the top**
  — the What's New and the promotional text are per-submission, so they are
  what you open that file for, and burying them under the description means
  they get missed.
  **The file now opens with a "Submitting <version>" table** naming which
  fields move and which do not, with that version's promo text and What's New
  directly under it. The rule had been half-kept: What's New was at the top
  and the promotional text was 180 lines down under every historical one, so
  Paul opened the file for a submission and could not find either the promo
  text or the description (13 Oct 2026). Keep the table current with the
  version being submitted — a stale one is worse than none, because it is
  read as the answer. The two URL fields are served from the website:
  **https://halved.golf/support** and **https://halved.golf/privacy**.
- The logo upgrade (delivery 2) is DONE. Re-run `dart run flutter_launcher_icons`
  after changing any source art — it regenerates iOS plus the Android adaptive
  layers. The one surviving `Text('Halved')` is the About dialog's TITLE, which
  is a dialog title and not a wordmark; leave it.

### Privacy policy (Guideline 5.1.1 / App Privacy) — PUBLISHED
Live at **https://halved.golf/privacy**, which is what App Store Connect →
App Information → Privacy Policy URL points at. Publisher = Paul Lipkin,
contact `info@halved.golf`. App Store listing name is **"Halved Golf"**
(standalone "Halved" was taken; in-app/home-screen name stays "Halved").

Source of truth is `docs/privacy-policy.html`; `website/privacy.html` is the
published page and `build-zip.sh` ships it to Cloudflare Pages, so editing the
two together is the whole update — there is no copy step into another repo.

**The GitHub Pages copy at `lip77us/halved-legal` is UNPUBLISHED** (9 Oct 2026,
`gh api -X DELETE repos/lip77us/halved-legal/pages`; the repo and its history
are untouched, `has_pages` is now false). Do not re-enable it, and do not
restore it as the listing URL.

It had been abandoned rather than mirrored, and by the time it came down the
drift was exactly what that risk predicts: it still carried **the same
effective date as the live policy, May 30, 2026, while omitting the Cloudflare
Web Analytics disclosure the live one makes.** A second published copy of a
policy does not stay a copy — it becomes a document that contradicts the real
one while claiming to be current, and it is readable by anyone with the link.

Found while chasing a Search Console duplicate report, not by anyone reading
the policy. One published copy, at halved.golf, is the rule.

Note the delete printed `404 Not Found` and had nonetheless worked — GitHub
answers 404 once the Pages config is gone. `has_pages` and the site root are
the things to check, not the command's exit.

**The data inventory behind the App Privacy answers** (checked 19 Oct 2026).
`Info.plist` declares NO camera, photo-library, microphone or tracking usage
description — the app never asks for any of them. Data lives on the Railway
backend; the account-deletion section matches the implemented feature. The
website's Cloudflare Web Analytics is cookieless and aggregate and is NOT the
app, so it does not move these answers. Re-check against `Info.plist` before
answering the questionnaire rather than copying this line forward on trust —
which is exactly what the two sentences below are: this note previously said
the app declared no location description and that course lookups carried no
PII, and both stopped being true in one commit.

**Location is now declared, and it is one data type.** `?near=me` ships
behind a `Courses near me` pill in the course picker, so the questionnaire
gains **Location → Coarse Location, App Functionality, not linked to the
user's identity, not used for tracking** — and nothing else moves. Coarse
rather than Precise is earned, not asserted: the position is cut to two
decimal places on the phone AND again on arrival, because Apple reads three
or more decimal places as Precise Location whatever accuracy iOS granted.
GolfCourseAPI now receives that coarse position on a proximity lookup, which
is why §4 of the policy no longer claims we send it no personal information.
`NSLocationWhenInUseUsageDescription` + `NSLocationDefaultAccuracyReduced`
are the only two keys, `UIBackgroundModes` is untouched, and **Android is
gated off** (`nearMeOffered`) until its manifest line and the Play
Data-safety answers land together. The whole record, including the exact
policy text, is `docs/location-permission.md`.

**Still open: nothing in the app links to the policy.** Settings has a Privacy
section, but it holds the findable-by-name switch — no screen links to
halved.golf/privacy. Apple accepts the listing URL, so this is a nicety rather
than a 5.1.1 requirement; it is the one item from the original draft notes that
was never done, and it is recorded here because deleting those notes would
otherwise have lost it.

### A tournament watch link opened to "No such tournament"

Reported from production, 11 Oct 2026: a TD sent his wife a link to a
tournament he had started. The web page was fine; opening it on a phone with
Halved installed refused her.

**Why it hid.** iOS gives a universal link to the APP, so only a phone with
Halved takes the failing path — the browser page is possession-gated on the
token and never consults `Watcher` at all. Testing the link anywhere without
the app shows nothing wrong.

**The chain.** `deep_links.dart` calls `/watch/<token>/resolve/`;
`WatchTokenResolveView` records a watcher and replies `is_tournament: true`
with the tournament id; the app opens the TOURNAMENT leaderboard, gated by
`tournament_for_reader` → `Watcher.objects.filter(tournament_id=...)`. The
resolve wrote `round=rnd, tournament=None` **whatever the link was**, so the
gate never matched. Every tournament watch link ever sent was broken; casual
links were fine, because there the app opens the round board and the round row
does satisfy it.

`Watcher` sets exactly one of round/tournament (two unique constraints, one
per target), so the fix is a SECOND row rather than both columns. Both are
written for a tournament link: the round row is what surfaces the individual
round under Observing, and the two answer different questions.

**The error string was the diagnosis.** "No such tournament." appears only in
`accounts/scoring_access.py` — it is an API refusal, not anything the watch
page can render. That is what said the link had opened the app rather than the
browser. Worth asking for the exact words before theorising about the page.

Tests: `api/test_watch_link_tournament.py` (6) — the end-to-end admission,
both rows, idempotence on a second tap, a player not being filed as a
spectator of his own round, and a casual link inventing no tournament row.

### Staging production for review — and `DEBUG` drift

The two commands, in this order (11 Oct 2026):

```bash
railway variables --set "DEBUG=False"     # redeploys; wait for it
railway ssh "/opt/venv/bin/python manage.py seed_demo --reset"
```

`--reset` because DemoClub already exists in prod — plain `seed_demo` errors.
The venv prefix is required: a bare `python manage.py` in the Railway console
has no Django. Wait for the redeploy before seeding, or the teardown and the
rebuild can straddle two containers.

**Production had drifted to `DEBUG=True`.** This file recorded it as False,
and it was True — flipped at some point and left. Found while staging for the
2.11.0 submission, not by anything failing.

**It was NOT leaking login codes**, which is the first thing to check and the
reason not to panic: `/auth/otp/request/` echoes `debug_code` only when the
LOCAL backend returns a plaintext code, and prod runs `OTP_BACKEND=
twilio_verify`, where Twilio owns the code and the server gets `None`. The
view's `if settings.DEBUG and code:` needs BOTH. So this was information
disclosure, not an authentication bypass.

What it did expose: Django's technical 404 lists the whole URL
configuration, and a 500 shows settings, SQL and the stack frame's locals.

**The check is the size of a 404**, which needs no credentials and no shell:

```bash
curl -s https://web-production-b84d4a.up.railway.app/api/ | wc -c
```

**179 bytes is correct. ~60,000 means `DEBUG=True`.** Worth running before
any submission — it is a one-line check for a setting that drifts silently
and that nothing else complains about.

**Verify the reviewer can actually sign in**, because it is the likeliest
thing to fail a review and it costs two calls:

```bash
curl -s -X POST $API/auth/otp/request/ -H 'Content-Type: application/json' \
     -d '{"phone":"3105550101"}'          # {"sent":true} and NO debug_code
curl -s -X POST $API/auth/otp/verify/  -H 'Content-Type: application/json' \
     -d '{"phone":"3105550101","code":"<REVIEW_BYPASS_CODE>"}'
```

A token back with `is_new_account: false` means the bypass resolved to the
seeded account rather than self-creating one. `REVIEW_BYPASS_PHONE` must list
the number and each must map to a seeded user.


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
`withdrawals`, per-hole `is_killed`, and `money.pool_at_risk`. 

**KNOWN GAP — `per_point` ignores all of the above.** The note here used to
say per-skin payout styles "aren't in Skins yet; when added they settle each
segment as a closed game instead of fractioning". They WERE added
(`payout_style` = `pool` | `per_point`, `per_point_mode` =
`average` | `all` | `first`) and that second half was never done, so the
warning sat here reading as hypothetical while it was live. `skins_summary`
settles per-point on **`total_skins_by_pid`** — the whole round — and then
overwrites `payout_by_pid` wholesale, discarding the segment-aware pool math
above it:

```python
net_by_pid    = _wager_settle(dict(total_skins_by_pid), cfg)
payout_by_pid = {pid: net_by_pid.get(pid, 0.0) for pid in payout_by_pid}
```

So a golfer who withdrew after the 6th is settled against skins won on holes
7–18, holes he was not in. **Pool mode is correct; only `per_point` is
wrong.** The fix is the one the old note described — settle each segment as
its own closed game and sum the nets — and it needs a withdrawal AND
per-point to collide, which is why it has not surfaced. Recorded rather than
fixed (Paul, 27 Oct 2026); do not "simplify" the segment loop away in the
meantime, because pool mode depends on it.

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

A standalone gambling **add-on**: per-hole achievements (greenie, sandy, barky,
chippy, …) the app can't detect, **tallied by hand** in
score entry like junk. **Always a side game, never a primary** (`GameMeta
.sideGameOnly`); 2–4 players; **separate payout** (never folded into the main
game). Full design doc: `docs/spots.md`.

**It RUNS alongside Skins** (`excludes` is Vegas / Triple Cup / Multi-Skins
only). This line used to say Spots "excludes Skins in any role — junk is the
Skins way to do per-hole extras", which was the v1 rule and was relaxed: a
SIDE Skins has junk forced off, so there is no overlap to protect against,
and Spots is then the only way that round can pay per-hole extras at all.
The catalog comment is the accurate one.

**Junk is restricted to Skins-as-PRIMARY, in the service** (`setup_skins`
forces `allow_junk=False` when the round stores a `primary_game` that is not
`skins`). It had been a client convention — `skins_setup_screen` hides the
control — while the endpoint took `allow_junk` at face value, so an older
build or a replayed request could have paid junk out of a side game's pot.
A **null** `primary_game` is deliberately left alone: tournament and legacy
rounds store none, there is no server-side equivalent of the client's
`primaryGameOf` fallback, and guessing would switch junk off for rounds that
legitimately have it. Tests: `JunkBelongsToThePrimaryGameTests`
(`scoring/tests/test_skins.py`, 4).

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

#### v2 is a CHECKLIST, not a taxonomy — and it covers junk too
Paul, 14 Oct 2026: *"The app tracks the user's definition of spots. It is my
intention to include a checklist for junk and spots so users have an agreement
in advance."*

That is a different feature from the one `docs/spots.md` defers, and the
difference decides the design:

* **The app is not meant to own the vocabulary.** A fixed list of named types
  (Sandy / Barkie / Greenie) would make Halved the authority on which spots
  exist. The group is. What a checklist does is record what THIS group agreed
  to play for, which is why v1's generic signed count was never a placeholder
  for a taxonomy — it is already the right storage for somebody else's list.
* **The point is the AGREEMENT, not the breakdown.** The argument on the 18th
  is never "how many spots did he have", it is "we weren't playing pollies".
  Settling it after the fact is what a checklist agreed on the first tee
  prevents, and that is a different success condition from a per-type column
  on the leaderboard.
* **It spans junk as well.** Junk is a bare integer on `SkinsPlayerHoleResult`
  and spots a signed one on `SpotsPlayerHoleResult` — two capture controls, no
  shared notion of what is being counted. A checklist is the first thing that
  would belong to both, and nothing today is shared between them.

**The glossary depends on this.** `/glossary/` says Halved "counts them rather
than naming them", which is true of v1 and stops being true the day a
checklist ships. Revisit that sentence with the feature, not after somebody
notices.

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

## Honors (`honors`) — implemented (derived overlay, side-game-only)

A **carry-token points side game**, DERIVED from the entered scores (unlike Spots,
which is captured by hand). Win a hole **outright** (strictly lowest score-to-
compare, no tie) and you take **the honor**; you keep it — and score **1 point** —
every hole until another player wins a hole outright. **A tied hole never beats
the holder** ("a tie doesn't beat you"), so the current holder keeps it; a
still-loose honor (nobody has won a hole outright yet) awards no point. A player's
points = the number of holes they held the honor. **Always a side game, never a
primary** (`GameMeta.sideGameOnly`, `canBeSideGame`); 2–4 players; Net (with %) /
Gross / Strokes-Off-Low; **separate payout** via the shared wager engine.

The carry logic mirrors **Rabbit** (`services/rabbit.py` `_outright_winner` + the
per-hole holder walk) but simplified: no lead/accumulate, no segments — the honor
transfers ONLY to an outright hole winner, and every held hole scores a point. The
money model + handicap plumbing mirror **Points 5-3-1** (`payout_style` /
`per_point_mode`, `_build_so_score_index`, `services.wager.settle`).

**Backend:**
- `core.GameType.HONORS`; `games.HonorsGame` (OneToOne foursome: `status`,
  `handicap_mode`, `net_percent`, `loss_cap`, `payout_style` (`pool`|`per_point`),
  `per_point_mode` (`average`|`all`|`first`)) + `HonorsHoleResult` (one row per
  scored hole: nullable `winner` [outright, null on tie] + `holder` [after the
  hole]). Migrations `games/0056_honors`, `tournament/0048` (enum refresh of
  `rydercupfoursomeconfig.game_type` + `rydercupmatchpoints.game_type`).
- `services/honors.py`: `setup_honors`, `calculate_honors` (walks holes in play
  order; outright winner takes the honor, tie keeps the holder; holder scores 1
  pt/hole), `honors_summary` (players with points+money via `settle`; per-hole
  holder trail with a running `cum`/`average`; `current.holder_short`).
- `api`: `HonorsSetupSerializer`; `HonorsSetupView`/`HonorsResultView`
  (`foursome_for_scorer`); routes `foursomes/<id>/honors/{,setup/}`; recalc
  dispatch (`calculate_honors`) + leaderboard block (`honors`) added alongside
  Points 5-3-1. Tests: `scoring/tests/test_honors.py` (carry/transfer/tie/loose/
  unscored-carry, the 3 settlement modes + pool zero-sum, net + strokes-off) and
  `api/test_honors.py` (setup scores existing holes, result mirror, zero-sum,
  auth).
- Settlement mapping (the user's three named options → wager engine): "pay
  against average" = `average` (VS_AVERAGE), "pay everyone above you" = `all`
  (PAY_ABOVE), "pay the leader" = `first` (PAY_WINNER); plus optional `pool`.

**Mobile:**
- Catalog: `GameIds.honors`; `GameMeta(canBeSideGame:true, sideGameOnly:true,
  2–4)` — a derived overlay (NO `capturesInScoreEntry`; nothing to tap in score
  entry). Offered wherever an individual-ball primary hosts overlays (Skins /
  Stableford / Stroke Play / Nassau / Points 5-3-1 / Fourball / Wolf / Rabbit);
  filtered out of every primary list.
- `HonorsSummary`/`HonorsPlayerTotal`/`HonorsHole` models;
  `client.get/postHonorsSetup`; `RoundProvider.honorsSummary` + `loadHonors`.
- `honors_setup_screen.dart` (`/honors-setup`, returnToHub) — `HandicapModeSelector`
  + the 3 per-point settlement modes + `StakeField` + optional loss cap; reached
  from the hub's side-game buttons (`_sideGameSetupRoute` /
  `_sideGamePerFoursomeTargets`). Leaderboard `_HonorsGroupCard`: per-player
  points + payout, current honor holder, field average, and a wrapping
  **"honor by hole"** trail (hole # + holder, hole-win holes tinted). No dedicated
  play/entry screen — scores are entered on the primary's screen; Honors shows
  only as a leaderboard tab.

**Deferred:** the `pool` payout style isn't surfaced in the setup UI (backend
supports it; the screen offers the three per-point modes the game is usually
played with); tournament-foursome Honors; a per-hole honor strip inside score
entry.

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

### Nassau event/label refinements (testing round 2)
- **Claremont bottom presses in the play-screen bubble** (`nassau_screen.dart` +
  `score_entry_screen.dart` `_PressesStrip`): the strip now combines the top and
  bottom series; bottom presses are tagged "Bot" → **"F9 Bot Press 1"** (points
  margin, e.g. "4 pts"). nassau_screen previously showed only the top series.
- **Nassau nine announced when WON, not just when complete**
  (`messaging_events.py` `_emit_nassau_results`): fires on the `decided_margin`
  (mathematically clinched before the last hole → "3&2" close-out notation), else
  on play-out. Applies to front/back/overall. Test:
  `test_front_nine_announced_when_decided_early`.
- **Leaderboard "· Final" tag** (`leaderboard_screen.dart` `_betRow`,
  `_bottomBetRow`, `_pressResultLabel`, `_bottomPressResultLabel`): a decided
  press/side shown as a plain "1 UP" / "+4 pts" / "AS" now reads "1 UP · Final"
  etc., so it's distinct from a live lead (the "N&M" close-out notation already
  implies final, so it's left untagged). The Singles-Match status banner already
  says "wins …", so it's unchanged.

## Cross-round Multi-Group Skins — federated pool (Parallel-Games Phase 2) — backend done

Lets a skins pool span **independent rounds** (different foursomes, different
games, possibly different accounts): each round plays its own primary and enters
gross once; players in the pool have those same scores fed into a shared skins
competition. Design + decisions: `docs/multi-skins-cross-round.md`. **Phase 2.1
(backend) + 2.2 (mobile core) are implemented; the tournament-foursome variant
(2.3) + list-card/host-primary polish are deferred.**

The pool stays anchored on a **host round's `MultiSkinsGame`** (the "Multi-Group
Skins" round that appears in the creator's casual list); other foursome rounds
**link in** by pasting the host round's `/watch/<token>/` spectator link. The
host plays and is auto-in the pool. Locked rules: **same course only** (matched
by `Course.golf_api_id` cross-account); **≥1 roster overlap** per linked round;
**Halved-members-only** roster (login-less golfers can't be phone-matched
cross-round); **always open-join** (link possession = consent); visibility
generous, settlement pool-local (no cross-game/-account $ netting).

- **Model:** `games.MultiSkinsLinkedRound(game, round, linked_by)` (migration
  `games/0055`) — one row per linked foursome round. Which players contribute is
  NOT stored; it's the phone-matched overlap of the roster with the round's
  players, resolved at scoring time (the link record is the standing
  cross-account read grant).
- **Engine (`services/multi_skins.py`, refactored multi-source):**
  `_identity_phone` (Player→normalized E.164 match key), `_pool_source_rounds`
  (host + linked), `_resolve_participant_memberships` (canonical roster id →
  per-round `FoursomeMembership`, matched by exact id OR phone),
  `_build_pool_score_index` / `_build_pool_so_index` (net/gross/strokes-off-low,
  pool-wide SO anchor), `_calculate_game`, `_summary_for_game` (adds each
  player's `round_id` + top-level `linked_rounds`), `recalc_pools_for_round`
  (recompute every pool a round hosts OR is linked into), `pool_overlap`,
  `valid_participant_ids` (host-round members OR on-app Halved members).
  `calculate_multi_skins(round)` / `multi_skins_summary(round)` keep their
  signatures (resolve the host game internally) — the single-round multi-group
  pool is the one-source degenerate case, unchanged.
- **Endpoints (token = host round's `watch_token`, possession-gated, not
  account-scoped):** `GET /api/skins-pool/<token>/` (resolve + roster + summary,
  optional `?round_id=` overlap preview), `POST …/join/` `{round_id}` (link MY
  round; enforces same-course + ≥1 overlap; `account_get_or_404` on the joined
  round so you can only link your own), `POST …/unlink/` `{round_id}`,
  `GET /api/skins-pool/mine/` (pools my account hosts or is linked into).
- **Wiring:** `api/views.py` `_recalculate_games` now calls
  `recalc_pools_for_round` (replacing the host-only `calculate_multi_skins`), so
  a score in a *linked* Sixes/Nassau round updates the pool even though its own
  `active_games` has no `multi_skins`; `_build_leaderboard` surfaces the pool tab
  on a linked round (`host_round_id`) for visibility-generous display; new
  `_same_course` helper (course_id, else shared `golf_api_id`).
- **Tests:** `scoring/tests/test_multi_skins.py::MultiSkinsCrossRoundTests`
  (phone-matched overlap, scores flow from a linked round, unlinked contributes
  nothing) + `api/test_skins_pool.py` (resolve/roster/overlap, cross-account join
  + scoring, no-overlap 400, wrong-course 400, foreign-round 404, unlink, mine).
  Full `api` (224) + `scoring` (283 incl. withdrawal) suites green.
- **Mobile (2.2 core):** `ApiClient.parsePoolToken` (token from a pasted
  `/watch/<token>/` link) + `resolveSkinsPool`/`joinSkinsPool`/`unlinkSkinsPool`/
  `getMySkinsPools`; models `SkinsPoolResolve`/`SkinsPoolRosterMember`/
  `MySkinsPool` and `MultiSkinsSummary.linkedRounds`/`hostRoundId`/`isCrossRound`
  + `MultiSkinsPlayerTotal.roundId`; `utils/skins_pool_link.dart`
  `linkRoundToPoolFlow` (paste → resolve → confirm overlap → join) behind a
  round-hub **"Link to a Skins pool"** button (`round_screen.dart`, casual +
  manager + group 1, hidden on a pool host round); `multi_skins_setup_screen`
  "Playing in another group" section adds connected (on-app) golfers to the
  roster. The linked round's leaderboard shows the pool tab automatically; the
  host shares the link via the leaderboard's "Copy round link" (last item in
  the overflow menu, kept there precisely for this).

## Survivor (`survivor`) — implemented (3-player horse race, primary game)

A three-man **horse race**. On an **elimination hole** the strictly worst score
is knocked out — if the two worst scores TIE, nobody goes and the elimination
repeats on the next hole. The surviving two then play a **decider** head-to-head;
strictly low wins the Survivor, a tie carries the same two forward. The moment a
Survivor settles a fresh one starts on the very next hole with all three back in,
so a full 18 yields **up to nine**. Design doc: `docs/survivor.md`.

**The last hole in play order** can host neither an elimination nor a carry, so
it settles whatever is standing: three alive → strictly low wins outright, any
tie for low is **no blood**; two alive → low wins, a tie **splits** the
eliminated player's entry (+½ / +½ / −1).

**Settlement:** every player antes `Round.bet_unit` per Survivor (pot = 3×), so a
win is **+2 / −1 / −1**. Zero-sum in every outcome. `max_liability` is
`(holes + 1) // 2` — NOT `holes // 2`: a Survivor needs two holes *except* one
that starts on the last hole, which settles there in one (nine on 18, five on a
nine-holer).

**Handicaps:** Net (with %) / Gross / Strokes-Off-Low, **full-round allocation
only** — there is deliberately no `handicap_allocation` field. A Survivor's
length isn't known until it ends, so a per-leg spread would re-create the
"strokes moved onto an already-played hole" defect fixed in `services/rabbit.py`.

**Backend:** `core.GameType.SURVIVOR`; `games.SurvivorGame` /
`SurvivorHoleResult` (migration `games/0062`, + `tournament/0051` enum refresh);
`services/survivor.py` (`setup_survivor`, `calculate_survivor`,
`survivor_summary`) — the engine walks the play order carrying `alive`, and only
FULLY-SCORED holes advance state (Rabbit's convention). Survivor *legs* are
derived at summary time, not stored, so they move when a score is edited.
`SurvivorSetupSerializer` (handicap only — everything else derives from the
scores); `SurvivorSetupView`/`SurvivorResultView` (`foursome_for_scorer`); routes
`foursomes/<id>/survivor/{,setup/}`; recalc dispatch + leaderboard block;
`survivor_game` in `get_configured_games`. Round chat announces each settled
Survivor via `_emit_survivor_results` (keyed on the leg's FIRST hole, matching
the Sixes convention, so a re-run can't double-post). Tests:
`scoring/tests/test_survivor.py` (24), `api/test_survivor.py` (11),
`SurvivorEventTests` in `scoring/tests/test_messaging_events.py` (6).

**Mobile:** catalog entry (`GameIds.survivor`, exactPlayers 3,
`hostsOverlaySideGames`); `SurvivorSummary`/`SurvivorLeg`/`SurvivorHole`/
`SurvivorHoleEntry`/`SurvivorPlayerTotal`; `client.get/postSurvivorSetup`;
`RoundProvider.loadSurvivor`/`setSurvivorSummary`; `survivor_setup_screen.dart`
(`/survivor-setup` — the thinnest setup in the app: handicap + stake, defaults to
Strokes-Off); `survivor_screen.dart` (`/survivor` — dedicated play screen built
from `rabbit_screen.dart`, with an OUT badge on an eliminated row and a by-hole
grid tinting the winner green / the knocked-out red). Leaderboard
`_SurvivorGroupCard` uses the shared `_MsScorecard` grid. **The shared grid
gained an `eliminated` per-score flag** (red cell) alongside `winner_id` (green);
every other game omits it, so they're unchanged.

**Note on the play screen's alive-state:** who is alive on an UNSCORED hole
isn't in that hole's payload, so the banner walks BACK to the last scored hole of
the same Survivor and carries the roster forward (resetting across a Survivor
boundary, stepping on if that hole settled it). Without it the group would tee
off on a decider with the banner still reading "elimination".

**Deferred:** watch-page renderer; mid-round withdrawal
settlement (three players IS the format — the universal unblocker still lets the
round complete); tournament use (casual-only for v1).

### Zombie Option — phase 3 (mobile) implemented
Phases 1 (engine/model/tests) and 2 (API) shipped earlier; the UI did not, so
`zombie_option` could only ever be posted as `false` and nothing surfaced it.
Now built from `docs/design-review/handoff-survivor-zombie/`:
- **Token:** `Halved.zombie` = `#6E4B8E` — the packet's one new colour,
  deliberately neither the win green nor the out red, because a Zombie is
  neither.
- **Setup** (`survivor_setup_screen.dart`): the toggle, **on by default** (see
  below), with the three cases that actually differ (back-in-with-Zombieville, back-in-all-three,
  no-change) and a footnote for the 18th-hole kill + no blood. **Locked once any
  hole is scored** — the option decides who is still in the Survivor, so
  flipping it mid-round would rewrite played holes.
- **Play** (`survivor_screen.dart`): the knocked-out row becomes a plum ZOMBIE
  row with a LIVE score box instead of the dimmed OUT row; the phase banner
  names him and states his stake; a resurrection outranks the normal outcome
  line and says the Survivor CARRIES ON (the number does not increment); the
  by-hole grid marks the resurrection hole plum, which can sit on the same hole
  as another player's red.
- **Leaderboard** (`leaderboard_screen.dart`): a 🧟 Zombie-on pill on the header,
  `killed` rendered as "Killed by X on 18 — pays nothing", a live Survivor
  naming its Zombie, the shared `_MsScorecard` gaining a plum `resurrected` cell
  (inert for every other game, like `eliminated`), and the three-mark legend.
- Model/client: `SurvivorSummary.zombieOption`, `SurvivorHoleEntry.isZombie` /
  `isResurrected`, `SurvivorHole.resurrectedId/Short`, `SurvivorLeg.killedById/
  Short` + `isKilled`, and `postSurvivorSetup(zombieOption:)`.

#### Zombie is the DEFAULT game (was off)
Flipped in five places, because five of them decide it: `SurvivorGame
.zombie_option` (`games/0070`, a Django-level default — the migration's SQL is
empty, and **existing rows keep whatever they stored**), `SurvivorSetupSerializer`,
the `d.get(...)` in `SurvivorSetupView`, `setup_survivor()`'s own kwarg, and
`_empty_summary()` so a not-yet-configured game reports what it will get.
Mobile: `survivor_setup_screen._zombieOption` and `client.postSurvivorSetup`.

**It does not reach the shipped app until a new build.** The client ALWAYS
sends `zombie_option` explicitly, so a 2.7.0 phone keeps posting `false` from
its own screen default — the server can't tell that from a TD deliberately
turning it off, and shouldn't try.

`models.dart`'s `fromJson` fallback is deliberately still `false`: that is the
"the server didn't tell us" case, not a default, and the summary always carries
the key.

Two test suites relied on the OLD implicit default and now say what they mean —
`SurvivorTests` (`scoring/tests/test_survivor.py`) and `SurvivorEventTests`
(`test_messaging_events.py`) pass `zombie_option=False` in setUp, because their
whole subject is the classic game: knocked out is knocked out.

## Select Players — roster filters and favorites (`handoff-select-players`)

The shipped picker is one alphabetical list of everybody you have ever played
with; by the second season that is a scroll, and the fourth man is usually one
of the same nine people. Two filters and the mark that makes the second one
possible.

**Favorites are per USER, not per account.** `core.FavoriteGolfer(owner, player,
created_at)` with a unique constraint on the pair (`core/0016`). Two members of
one account keep separate shortlists, and being favorited is never visible to
the golfer favorited — it appears on no leaderboard, receipt or share card. The
player is always inside the owner's own account, so a favorite never crosses the
tenant boundary. **Guests count**: a regular fourth who never signs up is the
case the filter exists for, so there is no on-Halved gate.

- `POST` / `DELETE /api/players/{id}/favorite/` (`PlayerFavoriteView`). **Both
  verbs are idempotent** — the picker writes optimistically and an Undo tap can
  land after a retry, so a second set (or unset) is a no-op, not a 409. Open to
  every account member, not admins only: it is a private shortlist entry, not
  roster management.
- `PlayerSerializer.is_favorite` reads `context['favorite_ids']`, which
  `_on_app_context(players, user)` fills with ONE batched query — a 128-golfer
  roster costs two lookups, not 128. The `user` argument is optional so the
  field defaults False anywhere that does not pass one.

**Mobile.** `PlayerProfile.isFavorite`; `client.setPlayerFavorite`.
- `widgets/favorite_flag.dart` — **a pin flag, not a heart or a star.** A heart
  is a social-app gesture applied to a playing partner; a star reads as a rating
  of the man and collides with course ratings elsewhere. Drawn as a
  `CustomPainter` (`PinFlagGlyph`) rather than pulled from Material, because
  Material has no pin flag and the outline / filled pair has to be the SAME
  shape — if the mark is ever changed it is one swap, in that file. 44pt target
  at the **trailing** edge, hard clear of the checkbox at the leading edge, and
  **tapping it never selects the row**. Light haptic on set, none on unset (the
  Undo toast carries that one).
- `widgets/roster_filter.dart` — `RosterFilter` + the chip row. One at a time,
  **`all` on every entry**: a filter must not survive into the next round's
  setup. **The count is part of the label** — a filter that could empty the list
  has to say so before it is tapped — and it counts the whole roster, not what a
  search has narrowed it to.
- `utils/roster_sections.dart` `rosterSections()` — pure, so the rules are
  testable and reusable. **Under `All` favorites appear TWICE**, pinned above
  and again in their alphabetical place: somebody scrolling to M for Dave Moran
  should find him under M, not discover he has been moved. Roster order in is
  order out; the screen still owns the shipped sort (selected + You floated to
  the top, then alphabetical), applied per section.
- `casual_round_screen.dart` owns the state: `_favoriteIds` seeded from the
  roster, `_undoPending` for the one case that needs an Undo. **Unsetting inside
  the Favorites filter** takes the row out from under the thumb that tapped it,
  so it gets a five-second `<Name> removed from Favorites · Undo` and the row
  keeps drawing until the toast closes. (The packet writes that line as
  `<Name> removed`, which on a screen for adding golfers to a round reads as
  though he has been taken out of it — the list is named on purpose.) Everywhere else the flag just empties and the row does
  not move. No confirmation dialog either way — this is a shortlist, not a
  deletion. **Filtering never touches the selection**: a golfer already added
  stays added and stays checked when he is filtered out of view; the seat chips
  are the record of who is in.
- **Search and filter compose.** `UnifiedPlayerSearch` gained `onQueryChanged`
  and stays the single owner of the text; the host mirrors it so the roster list
  narrows with it. (`_playerSearch` existed but was vestigial — nothing set it,
  so the list below the search box was always the full roster.) A search that
  empties a filter offers **Search all golfers**, which drops back to `All`.
- **On Halved** accounts for what it hides in one line above the list
  (`_hiddenGolfersNote`), and ends with the search fallback, because the filter
  itself hides the roster somebody would otherwise be found in.

Tests: `api/test_favorites.py` (8 — per-user not per-account, cross-account 404,
idempotence, guests, the batched query) and `mobile/test/roster_filter_test.dart`
(11 — the pinning, the compose rules, order preservation, the 44pt target).

**Not wired yet:** the design says favorites are read on every screen that picks
golfers (tournament player select, group builder) — this screen is the first
consumer. The backend and both widgets are general; the other pickers still
draw the plain list.

## Flights — Phase 1 (server only, no client build)

Two flights out of one field, each ranked and PAID on its own. Full design and
the decisions behind it: `docs/flights-plan.md`.

**Why it is not two tournaments.** A foursome belongs to one tournament, and
mixed groups (A and B golfers together) would have to run two rounds side by
side — two app sessions for four men walking together, breaking the single
scorecard and every in-group side game.

**It needed no client build.** The leaderboard renders in server order and takes
`rank` verbatim, so rows returned flight-by-flight with ranks restarting at 1
draw as contiguous blocks on the shipped app. `isLeading = rank == 1` even gives
each flight's leader the leader treatment, by accident. Until real headers ship,
the summary prefixes each row's name with its letter — `A · Paul L` — applied
ONLY in the summary, never in `*_championship_standings`, so it cannot leak into
settlement or a texted receipt. **Delete the prefix when headers land**
(`services.flights.prefixed_name`).

**The pieces.** `services/flights.py`: `assign_flights` (pure — equal-sized,
remainder to the LOWER flight), `rank_in_flights` (ranks and pays within a
flight; takes `sort_key` and `rank_key` SEPARATELY because Low Net sorts on
(net-to-par, −holes) but ranks on net-to-par alone), `set_flights` / `flight_map`.
`Tournament.flight_count` (0 = one board) plus `TournamentFlight`, one frozen row
per golfer — its own model because there is no tournament-level participant row;
the field is derived from `FoursomeMembership`. Endpoint
`GET/POST/DELETE /api/tournaments/{id}/flights/`.

**Unflighted is the same code path**, one flight holding everybody — so the
shipped behaviour is the degenerate case and cannot drift. The client half
holds the same shape: `flights` is empty and `index` is null on a one-board
event, so every unflighted board is on exactly the path it was already on.

**Settlement and the receipt needed no change**: they iterate the standings rows
and read `row['payout']`. Keep flights inside the two `*_championship_standings()`
functions and that stays true.

**"No index" is named at cut time, not stored on the golfer.**
`Player.handicap_index` is NOT NULL and should stay that way — a golfer whose
index nobody knows still needs one, or his playing handicap snapshots at scratch
and he takes no strokes all day. So `POST {"unindexed": [id, ...]}` drops those
ids out of the SIZING (bottom flight, not counted), while the entered index keeps
giving them shots. It matters at three, not at one: with a single unknown in an
even field, naming him gives the same cut as a high index.

**`LowNetChampionshipConfig.excluded_player_ids`** was added here — it was the
only config without it. A golfer can be ranked and visible while unpaid; the
prize ranking is recomputed over the eligible alone, so the man behind him moves
UP a paid place. **No client renders the `excluded` flag** (not even Stableford,
which has had it for ages), so an excluded golfer shows an empty money column
with no marking.

### Phase 2 — built, and one departure from the plan

**The stopgap is deleted.** `prefixed_name` is gone and the row's `name` is a
name again: `FlightHeader` (`widgets/flight_header.dart`) draws the band, on
both the Low Net and Stableford boards. The summaries carry a `flights` list —
one block per flight with its label, size and **purse** — and the purse is the
full table because every flight pays the same one. Summing what a flight has
actually paid would read as `$0` before anybody scores.

**A flighted board shows the INDEX the cut was made on**, not the playing
handicap and not today's index. Flights are cut on index while CH moves with
tee and course, so the two side by side invited the question; and an index that
has moved since the cut would sit in a flight it no longer justifies and read
as a bug rather than as history. `cut_index_map()` reads
`TournamentFlight.index_at_assignment`, which is exactly that record.

**The excluded marker is `NOT PAID`**, on both boards. Stableford has carried
the flag for ages and no client ever drew it, so an excluded golfer showed an
empty money column with nothing saying why.

**Where Set flights lives — a departure.** The plan put the controls in
`new_round_wizard.dart`, replacing the `NOT YET` card. That cannot work: the
wizard runs *before the tournament exists* and before pairings are set, so it
has neither an id to cut nor a field to cut — and the plan's own freeze rule is
"once the field is final". `FlightsCard` (`widgets/flights_card.dart`) sits on
both championship setup screens instead, below the payouts, because a flight's
purse IS the table above it. The wizard keeps a card, now pointing at that home
rather than claiming the feature does not exist.

**The preview is the feature.** The GET already previewed a cut without
writing; Phase 2 added the roster to it so the TD can *name the guesses* from a
list. A cut is frozen once taken, so seeing the split first is the difference
between a decision and a discovery.

**Headers are interleaved, not grouped.** The server already returns rows
flight by flight with ranks restarting at 1; re-grouping them client-side would
be a second ordering authority and the two would eventually disagree.

**Known, pre-existing:** `services/payout.split_tied_places` rounds each share to
the cent, so a three-way tie over $200 pays $66.67 each and invents a cent.
Flights make it likelier, since small flights tie more often.

---

## Release tags

Every marketing version is tagged `v<version>` (annotated), pointing at the
commit that set that version's **final build number** — the code the shipped IPA
was actually built from. The annotation records the full `version+build`, the
date, and whether it reached the **App Store** or was **TestFlight only**
(everything before `v2.5.1` was TestFlight only; 2.5.1 was the first public
release).

Backfilled from `mobile/pubspec.yaml` history on 2026-08-15 (`v1.0.0` … `v2.6.0`,
19 tags). **Going forward, tag at release time** rather than backfilling:

```
git tag -a v2.7.0 -m "2.7.0+23 — App Store release" <bump-commit>
git push origin v2.7.0
```

Useful because the version lives only in `pubspec.yaml`; without tags there is
nothing in history marking what shipped when.
`git log v2.5.1..v2.6.0 --oneline` is the "what's in this release" diff.

---

## Individual play — tournament refresh (BACKEND done, mobile pending)

Build of `docs/design-review/handoff-individual-play/` — fifteen design files
plus `SPEC.md`, which restates the packet's 55 decisions as rules, state and
edge cases and is **the document to build from**. Scope is individual-play
tournaments (`_EventType.solo`); Cup play and casual rounds are untouched
except where a screen is deliberately reused.

**The TD sets four games only** — Irish Rumble, the ball game, Mini Singles
Bracket and the day bet — plus the championship. Everything a foursome plays
among itself (skins, Nassau, rabbit, survivor, sixes) is the FOURSOME's, is
configured exactly as in a casual round, reads the tournament's score entry
rather than opening its own, and **never appears in tournament settlement**.
The one exception is **spots**, which needs capture on the hole.

### What landed (P1–P7, all backend)

**P1 — scoring settings + best-N-of-M.** `Tournament` gained
`scoring_method` / `handicap_mode` (net|gross only — strokes-off-low is a
match mechanism and is not offered field-wide) / `net_percent` /
`mini_singles_carve_pct` (`tournament/0052`). `services/round_counting.py` is
the one place best-N lives, shared by both championships: unset counts
everything; otherwise the best N count and the rest are **struck through, not
hidden**; and **a round in progress can never displace a finished one**
(four holes at level par must not knock out a finished 73) though it may FILL
a slot the finished rounds leave empty. The net double-bogey cap is a **rule,
not a setting** — `_build_ln_player_totals(..., force_cap=True)` applies it at
any allowance for individual play; casual keeps Net-100%-only.
`Tournament.is_individual_play` is the type switch.

**P2 — one money model.** `services/payout.py`. Ties split the money for the
**places they occupy** (a T2 pair shares 2nd and 3rd, $16 each not $20), no
countbacks anywhere. A place that pays a GROUP splits among its **real**
golfers — the borrowed 4th is not a person, so a levelled group takes $23.33
three ways rather than $17.50 four ways. Also `validate_payout_table`,
`check_day_bet_floor`, `pool_line`, `carve_out`. **Two real defects fixed:**
Irish Rumble and the ball game each halved a single place on a tie (leaving
the next place unclaimed), and Rumble divided a group prize by a count that
INCLUDED the borrowed 4th.

**P3 — Mini Singles Bracket, two-stage.** `MiniSinglesConfig` (`games/0065`),
`Foursome.is_champions_foursome` (`tournament/0053`),
`services/mini_singles.py`. A bracket in EVERY group on day 1; the winners
play day 2 as one foursome. **A halved match plays on** — sudden death is
gone, and with it the collision where a semi borrowed hole 10 from the final.
The back-9 matches are assigned and scored from hole 10 regardless, against a
side flagged TBD: unambiguous because a pair still level can only HALVE their
overtime holes. A halved FINAL splits 1st and 2nd; last-hole-won survives only
for the trophy and the day-2 seat (`MatchPlayMatch.trophy_player`,
`games/0064`). Day 2 is seeded by **day-1 margin then lowest index**, and the
champions' foursome is filled by SWAPPING membership rows so tees and tee
times survive. Field gate 9–16. Empty seat (short field or withdrawal): one
rule set once — promote / points / short-handed; `points` reuses
`services/three_person_match.py`, which already plays a tied points round on.

**P4 — the day bet.** `DayBetConfig` (`games/0066`), `services/day_bet.py`.
Final round only. Mini Singles finalists are **not here at all** (an absence,
no row); championship money winners are **here but italic** — shown, unable to
collect, and not charged. Places scale with the eligible field (10→3, then 2,
then 1); an ineligible row holds a POSITION but not a PAID PLACE. The DQ reads
the tournament's handicap setting. The P2 floor guard is enforced in the
reducer from both directions.

**P6 — the ball game is named, not coloured.** `ball_color` → `game_name`
(16 chars, no default, required). `games/0067` is hand-written to CARRY the
old values across (`Red` → `Red Ball`) rather than dropping them. Ranking is
by **survival**: alive first, then latest death, and ball net shown only while
the ball is alive. Tied groups now share a rank. Mobile renamed in the same
commit so the client is never posting a field the API rejects.

**P7 — tournament settlement.** `services/tournament_settlement.py` +
`GET /api/tournaments/{id}/settlement/`. Separate from
`services/settlement.py` (casual, round-scoped). The carve-out is an explicit
TRANSFER, so the championship shows the full pool in and out with part leaving
for day 2. Irish Rumble and the ball game appear once PER ROUND. Three checks
block Settle and say why: every pot balances (naming the game), every round is
closed, and collected − paid is zero.

### Endpoints added
```
GET/POST      /api/rounds/{id}/day-bet/setup/
GET           /api/rounds/{id}/day-bet/
GET/POST/DEL  /api/tournaments/{id}/mini-singles/setup/
GET           /api/tournaments/{id}/mini-singles/
POST          /api/tournaments/{id}/mini-singles/sync-day2/
GET           /api/tournaments/{id}/settlement/
```
`TournamentLeaderboardView` also gained a `scoring` chip-strip block (method,
mode, allowance, counting rule, cap note) and a `day_bet` tab.

### What landed (P5, P8–P10, mobile)

**P10 — the create flow is eight honest steps.** `New Tournament`, not
`New Round`; `Create Tournament`, not `Create Round`. The step list is derived,
so the header count is always true: seven shown for a one-round stroke-play
event, Stableford adds the points table, and the day bet only appears on the
side-game step above one round. SCORING replaces Handicap: no strokes-off
(a Cup mechanism — there is no low golfer to play off against a field), the
cap stated as a rule with a worked ceiling instead of a toggle, rounds-counted
above two rounds, flights drawn as deferred rather than omitted. Money moved
to where it is charged: PAYOUTS is the championship pot alone (with carve-out
lines when the bracket is on) and SIDE GAMES carries a fee beside each switch.
`_Step4Games` was DELETED rather than left unreachable — it held a second copy
of the money model.

**P9 — score entry.** One lost-ball control (it had a radio circle AND a
switch), labelled with its consequence. The next-hole button names who it is
waiting on instead of going grey and silent. The bracket chip renders the
engine's own line, so a back-9 match against an unresolved semi shows a real
result rather than a dash. All sudden-death language retired.

**P8 — the boards.** `widgets/synced_scroll_group.dart` makes the round
columns one horizontal strip: four visible, every row scrolling with the
header, opening on the newest round. Dropped rounds are struck through and
live ones amber. Prize is muted italic until every round closes. Day bet is a
new last tab with italic ineligible rows. The ball board shows the carrier,
hides ball net once the ball is dead, and its chip reads `ties split`.

**P5 — Irish Rumble setup** is one screen (rules first, money last, one Save)
instead of `· Game` → `· Money`. The cap note states the rule instead of
pointing at a toggle that no longer exists; in a tournament the toggle itself
is replaced by an `Always on` statement (casual keeps its switch). The
borrowed-4th block TELLS rather than asks, and the pool line names its scope,
its count and the tie rule.

**P11 — settlement** (`screens/tournament_settlement_screen.dart`, reached
from the tournament leaderboard's app bar). By golfer / by game, collects
first sorted by amount, an itemised card per golfer where each line names the
game that caused it, the carve-out explained on both sides, the per-game
balance check that blocks Settle and NAMES the game, and the sum-zero footer.

**Deferred by the packet:** flights; Mini Singles above 16 golfers; per-golfer
settle marking; a settlement text export.

---

## TD console (web) — Phase 1 + 2 implemented

A **new surface**, not a redesign: a server-rendered web console for the work a
tournament director does on a laptop the night before an event. Built from
`~/Downloads/handoff-td-console/` (HANDOFF.md + four HTML design screens).
Django app `console/`, mounted at **`/td/`** by `my_golf_app/urls.py`. Plain
Django templates + a little vanilla JS; **no front-end build step**, and it
reuses the existing session and account resolution.

### Its own hostname (`CONSOLE_HOSTS`) — off by default
The design writes the routes as `td.halved.golf/sign-in`, and those paths are
meant literally. `console/middleware.py` `ConsoleHostMiddleware` swaps
`request.urlconf` to `my_golf_app/urls_console.py` (console mounted at the ROOT,
main urlconf appended after it) for any host in the **`CONSOLE_HOSTS`** env var.
`reverse()` follows `request.urlconf`, so ONE template set links correctly on
both hosts — `/roster/import/` on the console host, `/td/roster/import/`
elsewhere. `/td/` still answers on the console host so old links don't 404.
`CONSOLE_HOSTS` is empty by default → complete no-op until it is set, and the
host must also be in `ALLOWED_HOSTS` (which auto-fills `CSRF_TRUSTED_ORIGINS`).
Turning it on is three things: DNS CNAME → the Railway service, the domain added
in Railway, and `CONSOLE_HOSTS=td.halved.golf` + `ALLOWED_HOSTS` updated.

### Phase 1 — sign in (`console/auth.py`, `console/views.py`)
- **Same identity as the app**: phone → 6-digit SMS code, through the existing
  `accounts/otp.py`. The web adds no new auth concept — only a session cookie
  where the app holds a token. `login()` is called with an explicit
  `backend='accounts.backends.AccountBackend'` (that backend is the only entry
  in `AUTHENTICATION_BACKENDS` and we never go through `authenticate()`).
- **No account is created on the web.** `otp.verify_code` self-creates an
  Account for an unknown phone, so `auth.start()` checks `phone_is_known()`
  BEFORE sending — an unrecognised number is a dead end that costs no SMS.
  `auth.finish()` also hard-fails on `is_new` as a belt-and-braces guard.
- Wrong codes **count down out loud** ("Two tries left"), 3 attempts then the
  code is spent; Resend unlocks on the first failure (before that, a 30s
  countdown). `Keep me signed in` is on by default → 30-day cookie; unchecked →
  browser session. A lapsed session **names the screen** it threw you off and
  returns you to it (`td_required('<label>')`).
- Routes `/td/sign-in/`, `/td/sign-in/code/`, `/td/sign-out/`. Verify lands on
  **Import roster**, not a dashboard.
- The portal is **open** — anyone may sign in. The WRITE is what's gated: an
  import changes a roster the whole account shares, so `_can_write` requires
  `is_account_admin`, and a non-admin gets a signed-in empty state naming what
  would fill it, not a rejection.

### Phase 2 — Golf Genius import (`console/models.py`, `plan.py`, `views.py`)
A **UI over `services/genius_import.py`**, not a second importer. The command is
dry-run by default and needs `--apply`; that shape carries over exactly — **the
preview IS the confirm**, there is no dialog, and the primary button is never
`Import` but `Apply — create 12, update 5`, counts in the label.
- **`ImportRun`** (migration `console/0001`) stores the parsed file + the TD's
  typed indexes, so the plan is a pure function of `(parsed, overrides)` and is
  **rebuilt on every render**. That is what makes inline index entry possible
  without a re-upload. Numbered **per account, on apply only** (an abandoned
  draft never burns a number). `result.log` keeps per-row before/after — the
  data a future undo would need. **There is no undo today** and the receipt
  draws no button for one.
- Apply is one transaction over the golfer writes AND the run record, with
  `select_for_update` on the run so a double-submit can't write twice.
- The preview shows what the CLI can't: **which key matched** (`PHONE`/`GHIN`
  tag — a GHIN match with a different phone is where two people become one),
  **field-level diffs** (`idx 8.4 → 7.9`, `(was blank)` on backfills), the
  **header row it found** (`Header found on row 4 · 87 data rows`), and all six
  skip reasons as sentences with the offending cell quoted (`index cell read
  "NH"`). Only `no_index` is editable inline; file errors are greyed and inert.
- **Plus handicaps display as `+2.3`** (stored `-2.3`). `plan.fmt_index` is the
  single place that undoes the storage convention.
- Field display order is **pinned** (`plan._FIELD_ORDER`) because
  `ImportRun.result` is a `jsonb` column and jsonb does NOT preserve key order —
  without it the receipt lists a change in a different order than the preview.
- Routes: `/td/roster/import/`, `.../preview/<pk>/`, `.../runs/<number>/`,
  `.../runs/<number>/csv/`.

### Gotchas this build hit (worth not re-learning)
- **`{# … #}` is single-line only.** Every multi-line one rendered as visible
  text on the page. Use `{% comment %}` blocks. (`console/templates/console/`
  is all `{% comment %}` now.)
- **`collectstatic` is now required at deploy.** `STORAGES` uses
  `CompressedManifestStaticFilesStorage`, and `{% static %}` RAISES at render
  time for anything missing from the manifest. Nothing used `{% static %}`
  before this, so it was never exercised — added to `railway.toml`'s
  `startCommand`. Tests override `STORAGES` (`console/tests.py::plain_static`).
- A `<label>` used as a drop zone needs `display:block`, or it fragments.

Tests: `console/tests.py` (27) — the two web-specific auth promises (no account
created, tries counted), the import invariants that would break silently
(preview writes nothing, plan rebuilds from typed values, `+2.3` never renders
negative, apply is atomic and cannot run twice, cross-account 404), and the
host routing in both states (console host serves at root and reverses rootless;
default config unchanged).

**Testing it locally** needs no deploy: `python manage.py migrate` then
`runserver`, and open `http://localhost:8000/td/sign-in/`. With the local
defaults (`OTP_BACKEND=local`, `SMS_BACKEND=console`) the 6-digit code is
PRINTED in the runserver terminal, not texted. Sign in as any local user that
has a phone AND `is_account_admin` — a non-admin correctly gets the empty
state instead. Note `OTP_REQUESTS_PER_HOUR = 5` per number, which is easy to
hit while poking at it; clear with
`PhoneOTP.objects.filter(phone='+1…').delete()` in a shell.

### Phase 3 — course library and editor (`console/courses.py`, `test_courses.py`)
Built as **editor + push upstream**, not the handoff's report-only design: the
account OWNS its Course/Tee clone (see "Shared course catalog + copy-on-add"),
so there is nobody to ask for permission to fix it.

- **Library** (`/courses/`) — every course the account owns, **sorted by rounds
  played, not alphabetically**, with tee count, rounds, record-last-updated and a
  confidence state. `NEVER CHECKED` is deliberately distinct from
  `VERIFIED BY YOU`: a record nobody has looked at is not the same as one
  somebody checked and found right, and the library is the only place that shows.
- **Course** (`/courses/<pk>/`) — the whole course in one grid per tee (par,
  yards, stroke index × 18), read-only, with Edit per tee.
- **Editor** (`/courses/<pk>/tees/<pk>/`) — everything is editable, but:
  - **All geometry goes through `services/tee_revisions.update_tee_geometry`.**
    Nothing writes `Tee.holes` directly. A played tee is SUPERSEDED, so a
    completed round keeps the exact par/SI it was scored against; an unplayed
    tee updates in place (no revision churn).
  - **Stroke index is enforced, not warned about** — reuses
    `services/course_quality.validate_tee_holes`, the same permutation check the
    API import gate runs.
  - **Changing par or yards asks first** (`rating_at_risk`): a re-index leaves
    the rating describing the same course, but a shape change means the rating
    describes a course that does not exist and every net score from it is
    quietly wrong. Confirm-to-save, not blocked — the record may be catching up
    with a real re-measure.
  - Only CURRENT tees are editable; a retired revision 404s.
- **`CourseCheck`** (migration `console/0002`) — one timeline for all three
  things that can happen to a record: `verified` (checked, nothing wrong —
  the one people forget, and the only thing that earns *right* over *never
  looked at*), `edited` (local correction, field-level diff), `reported` (pushed
  upstream). The library's state is simply the most recent one.
- **Send to Halved** — staff (`is_staff`) write STRAIGHT THROUGH to the shared
  catalog via `services/catalog.catalog_from_course(overwrite=True)`; everyone
  else files a tracked report. Either way the diff is emailed to
  `COURSE_REPORT_EMAIL` (default `info@halved.golf`) and shown on screen before
  it goes. A source is required — scorecard / GHIN / club — because that is what
  distinguishes a re-rating from a typo. **Note a catalog write marks those tees
  `curated=True`**, which protects them from a later GolfCourseAPI re-import; that
  is the intent, but it does stop the API correcting that course automatically.

Tests: `console/test_courses.py` (19) — the permutation rejection, the
supersede-vs-in-place split with a played round's geometry asserted frozen, the
par-change confirm gate, staff-vs-non-staff upstream, the emailed diff, and
cross-account 404s.

The grid is ruled like a scorecard: a line between every hole, a heavier one at
the turn, a sticky hole-label column, and a **derived TOT column** (par + yards)
computed from the holes rather than read off `Tee.par` — which is the stored
value it exists to let you check. The editor recomputes it live as you type.

### Phase 4 — custom tees (`console/custom_tees.py`)
A **private re-index of a tee set**: same par, yards, rating and slope, only the
stroke index differs. The case is a course that indexes off the tips, where the
4th is 478 from the back and 318 from the front and still index 1.

**A custom set is a real `Tee` row** (`Tee.custom_index_of`, self-FK, migration
`core/0015`) on the same Course. That is the whole trick: the tee picker, round
setup and every scoring service then need NO change. What the FK adds is the
marker the app labels it with, and the source row the editor draws above the
editable one. Created `origin='manual'` + `curated=True`, which is what keeps
`services/catalog.py` away from it — a catalog re-sync skips a curated tee and
never deletes anything, so a set named "White — club index" is untouchable by it.

- **Index only; the lock is the feature.** `build_holes()` copies every field
  except `stroke_index` off the source, so there is no path through the code
  that changes par or a yardage whatever the form posts. A re-index leaves the
  rating describing the same course; changing geometry would not, and that is a
  course correction, so the panel links to the editor.
- **Eighteen unique indexes, enforced.** `problems()` / `blocker()` / `strip()`.
  Save is dead until the set is whole and **carries the count** (`Save — 1
  duplicate, 1 gap`), because a disabled button that doesn't say why is a
  mystery. The 1..n strip shows the WHOLE ranking — used once plain, twice
  filled red, missing dashed — since a duplicate is only half the error and the
  missing number is the one the TD has to find.
- **`suggestion()`** offers the assignment outright when exactly one number is
  doubled and one missing, targeting the cell the TD just edited (tracked in a
  hidden `changed_hole`). A swap can't fix a duplicate — something has to BECOME
  the missing number.
- Editing a set that has been played goes through `update_tee_geometry` like
  everything else, so those cards keep the ranking they were scored on. Deleting
  is refused once a round has used it.
- `sort_priority` MATCHES the source rather than beating it: appearing beside
  the tee it forked from is wanted, silently becoming everyone's default pick
  is not.
- **`/courses/custom/`** lists every set the account owns, across all courses,
  with what it forked, how many holes moved and how many rounds use it. No
  "create" button there on purpose: a set is always a re-index OF a tee, so it
  starts from a course — the empty state says so instead of offering a dead end.
- **The API marks it** — `TeeSerializer.is_custom_index` / `custom_index_of` and
  `CourseTeeSummarySerializer.is_custom_index`. **The Flutter tee picker showing
  a "TD SET" label is the one piece of Phase 4 still outstanding**; without it
  the set works fine, just unlabelled.

Tests: `console/test_courses.py` (37 total) — the ranking refusals, the lock
(a forged `par_1`/`yards_1` post cannot move geometry), curated+manual, the
sort-priority choice, strip/blocker/suggestion units, supersede-on-edit,
delete-refused-when-played, and the serializer marker.

#### Provenance now survives a tee revision (pre-existing bug, fixed here)
`services/tee_revisions.update_tee_geometry` built its replacement row from
geometry only, so a superseded tee came back with `curated=False` and
`origin='api'` — the DEFAULTS. Editing a played tee therefore silently stripped
its curation, and the next `sync_course_from_catalog` would overwrite a
deliberate local variant (a re-rated `White-Sixes`, a combo tee): exactly what
the flag exists to prevent. Found because a custom index set stopped being one
after an edit; the curated/origin half is older and bites harder. The
replacement now carries `origin`, `curated` and `custom_index_of` — a revision
is the same tee, later, not a new one. Tests:
`TeeProvenanceSurvivesRevisionTests` in `api/test_tee_revisions.py`.

**Watch out for CSS class collisions in this app's stylesheet.** `.src` was
defined for the report's radio group (`display:flex;flex-direction:column`) and
silently turned `<tr class="src">` in the custom-tee grid into a flex column —
the DOM was correct and the table simply rendered as a vertical stack. Renamed
to `.fromtee` and the radio rule scoped to `.panel .src`.

**Deliberately NOT done:** retiring the app's course screens
(`manage_courses_screen.dart`, `manage_course_tees_screen.dart`, the paste
screens). The handoff says they come out when this ships, but that needs a
Flutter release and would leave no way to fix a course from a phone. Retire them
in a later release once the console has proven itself.

### Merging import duplicates — `merge_duplicate_golfers`
The importer matches on **normalized phone, then GHIN**. A golfer already on the
roster with NEITHER cannot be matched by any means, so the file's row correctly
becomes a NEW golfer — two rows for one person: the original holding every round
they have played, and the new one holding the phone/email/GHIN that would have
matched them. (First real import: 165 created, 13 of them duplicates of golfers
with history.)

Neither row can just be dropped. The original is **PROTECTed** — every
`FoursomeMembership` / `HoleScore` / per-game result table references `Player`
with `on_delete=PROTECT` — and deleting the new one alone loses the contact
details and lets the next import recreate it. So the fix is a one-directional
merge: **contact details move onto the record with the history; the empty
duplicate is deleted.** Phone is the cross-account identity key, so it belongs
on the row that owns the rounds.

`core/management/commands/merge_duplicate_golfers.py` — dry-run by default like
the importer, `--apply` commits, one transaction for the whole batch.
`--pairs keep:delete,...` (keep = the id with the rounds), `--rename` to take the
duplicate's spelling, `--keep-index` to leave the handicap alone (default takes
the imported value, which is the current WHS number).

**Pairs are explicit on purpose — name matching is NOT automated.** The real data
had `Wendel`/`Wendell Doman` and `Rico Young`/`Richard (Rico) Young` (exact
matching misses both) sitting alongside `Roger Bird`/`Francis Bird` — same
surname, two different people, which surname matching would have fused. A human
reads the list; the command only executes it. It refuses a reversed pair (naming
the corrected `--pairs`), a cross-account pair, and re-checks for history inside
the transaction before deleting. Tests: `api/test_merge_duplicate_golfers.py` (12).

Finding the candidates is a read-only query — the applied run's
`result->'log'->'created'` gives the exact player ids the import created, which
beats guessing; join those against account players that have history and no phone.

#### Shared-phone fix — a row claims its identity only once it lands
Found in the first real import. `build_plan` recorded `seen_phone` / `seen_ghin`
the moment a row passed the duplicate check — BEFORE knowing whether the row
would survive. So a row that claimed a number and was then skipped itself
blocked its partner, and the partner's skip named it as the winner: **Charlie
Han was skipped `no_index` but had already claimed the shared home phone, so
Diana Han was dropped as a duplicate of a row that never landed — and the
receipt said "row 89 was imported" about a row that wasn't.** Both Hans
vanished, explained by something untrue.

The claim now happens in a local `_claim()` called only on create / update /
matched-and-unchanged. A skipped row claims nothing, so `won_line` always names
a row that is actually in the roster. Tests: `SharedPhoneTests` in
`api/test_genius_import.py` (4).

**Not changed:** the rule that same-phone-in-file means same-person. The real
cases were older couples sharing a HOME phone, and the right fix is distinct
cells at the source — two golfers sharing a number in our data would be actively
wrong, since phone is the cross-account identity key (`by_phone` would resolve
to whichever Player row came first, and "On Halved" / shared rounds would
confuse them). Deliberately NOT relaxed to "different GHIN ⇒ different people".

**Operational note:** the importer can only match on phone or GHIN, so a golfer
holding neither is recreated no matter how clean the file is. Before re-importing
after a source-data fix, put the new phone on the EXISTING record of anyone with
history — otherwise they arrive as a fresh duplicate needing
`merge_duplicate_golfers`.

### Sixes: a second golfer was sent to the team picker mid-round — fixed
Reported from the course: a second user re-entering an in-progress Sixes match
got the pick-teams screen. Deterministic, not a race.

`round_screen.dart` routed Enter Scores off **`rp.sixesIsStarted(fs.id)`** — an
in-memory `Set<int>` on `RoundProvider`, written ONLY by `postSixesSetup`
succeeding or by `loadSixes()` completing. **The round hub calls neither.** So
the set is populated only for the device that ran setup in that app session;
for a second golfer — or the same golfer after a restart, since the provider is
rebuilt — it is empty, `sixesIsStarted` is false, and Enter Scores routes to
`/sixes-setup`. The hub's button also reads `Start Match` instead of
`Enter Scores` for that user.

What he saw as "a spinner" is `SixesSetupScreen.initState`: not-started → call
`loadSixes` (the spinner) → now started → `pushReplacementNamed('/score-entry')`.
So it self-heals when the load succeeds. **The tail is the hazard**: if that
load fails (offline, slow), the user is left on a team picker for a match
already being played, and saving would run `setup_sixes`, which begins
`SixesSegment.objects.filter(foursome=foursome).delete()` — rewriting who was on
which team for holes already scored.

Sixes was the ONLY game on that screen routing off provider state; every other
one reads `fs.configuredGames`, which the server derives from
`obj.sixes_segments.exists()` and is therefore true for everyone. Fixed to ask
the server first, keeping `sixesIsStarted` as an OR so the moment right after
setup still routes correctly before the hub reloads. Contract pinned by
`SixesConfiguredGamesTests` (`scoring/tests/test_sixes.py`), including that a
segment never exists without players — the serializer keys off existence, so
that equivalence is what makes "configured" honest.

#### Teams and segment bounds are locked once the match has started
`setup_sixes` began with `SixesSegment.objects.filter(foursome=...).delete()`,
so re-running it mid-round with different teams silently rewrote what every
played hole meant. Now guarded **in the service, not the view**, so every caller
is covered:

* **Refused** (`SixesLocked` -> 400) once a REAL golfer has posted a gross
  score, if the request would change team membership, which side is team 1, or
  a segment's start/end hole. A phantom padding a three-ball does not lock it —
  same rule the tee-box editor uses.
* **Allowed**: handicap mode / allowance / scoring format / allocation. A TD
  correcting "we said gross, we meant net" is legitimate.
* The allowed path now **updates in place instead of rebuilding**, because a
  delete-and-recreate would also take the `is_extra` segment and any `is_void`
  withdrawal state with it.

`team_select_method` is deliberately NOT compared — how a pair was chosen is a
note about the past, not something a hole was scored against. Tests:
`SixesTeamLockTests` (`scoring/tests/test_sixes.py`).

**Watch the decorator when inserting above a function.** `setup_sixes` carries
`@transaction.atomic`; a helper inserted immediately before `def setup_sixes`
landed BETWEEN the decorator and the function, silently moving atomicity onto
the new declaration. The tests caught it (the exception class had become a
function), but a delete-then-recreate losing its transaction is exactly the
kind of thing that would not show up until it mattered.

## Settlement receipt — receipt screen + field summary send (personal send DEFERRED)

Built from `~/Downloads/handoff-settlement-receipt/`. Settlement answers the
TD's question — do the pools balance. The receipt answers the golfer's: what do
I owe, to whom, and what for.

`services/settlement_receipt.py` (composition: `money`, `sms_segments`,
`compose_personal`, `compose_field`) had shipped alone in `6d7ad19` and was
imported by nothing but its own test. This wires it up.

- **`receipt_payload(tournament, note=)`** assembles everything the screen and
  the send need. It **reads `tournament_settlement` and recomputes no money** —
  same nets, and crucially the same `blocking` list, so the send gate IS the
  Settle gate (rule 6: provisional money must not leave the app; a texted
  receipt is treated as final by everyone who gets one).
- **`GET/POST /api/tournaments/{id}/settlement/receipt/`** —
  `TournamentReceiptView`. GET takes `?note=` and returns per-golfer receipts
  (each with the exact text that would go to him + its segment count), the
  field-summary message, the gate, and the last send. POST records that a send
  happened; it **sends nothing** and refuses while `can_settle` is false, so
  the gate is not just a greyed button.
- **`SettlementSend`** (`tournament/0059`) — mode, recipients, who, when. Kept
  per send rather than as a flag, because a resend is a real event and the
  second one is the one people ask about (rule 8).
- **Mobile:** `settlement_receipt_screen.dart` (one net number, every line that
  produced it, prizes carrying group + ways, the stamp, the exclusion note, and
  the message preview), reached from a receipt button on each golfer row in
  `tournament_settlement_screen.dart`. That screen gained a **Text the field**
  section: note field, live preview, segment count (amber over three), and a
  share-sheet send that records only on `ShareResultStatus.success` — a
  dismissed sheet is not a send, and a false stamp is worse than none.

**Composition is server-side, always.** The client renders the payload and
shares the string; it never builds one. That is rule 1 — the receipt view and
the message must not be able to disagree — and it is why the note round-trips
to the server instead of being concatenated on the phone.

### Why the personal receipt is NOT built
The handoff's own first open question is transport, and it is sharper than the
doc knew: **Halved deliberately never sends golfer-facing SMS from the server.**
The invite flow uses the native share sheet specifically so the user texts from
their OWN phone (TCPA / App Store safe); `accounts/sms.py` sends to one number
and exists for OTP, and Twilio Verify is provisioned for login codes only. So
"Send 14 receipts" is app-initiated bulk SMS to people who never opted in, and
the share sheet cannot do fourteen threads in one tap. The field summary ships
because it is ONE message the TD sends himself. Personal receipts need a
decision first: field-summary-only, in-app pull (each golfer opens his own —
which also answers the second open question), or real 10DLC transactional
messaging.

Tests: `ReceiptPayloadTests` (`scoring/tests/test_tournament_settlement.py`) and
`ReceiptEndpointTests` (`api/test_settlement_receipt.py`) — the payload reads
settlement rather than recomputing, the note reaches both payloads, the field
summary carries no itemisation, the gate matches Settle, and a send cannot be
recorded while a round is open.

### The casual-round receipt — implemented
The same document one level down, for a round with **no pot and no TD holding
money**. Four golfers settle among themselves, so the sentence that matters is
not the net but **"Ben owes you $12"**: the net stays the headline because it is
what a man checks first, but the TRANSFERS are what he acts on and what belong
in a group thread. Lines are per GAME, because that is what a casual golfer
disputes — not "why did I stake that" but "I thought I won the skin on 7".

- **`casual_receipt_payload(round, note=)`** (`services/settlement_receipt.py`,
  alongside `compose_casual_personal` / `compose_casual_field`) inverts
  `round_settlement`'s `per_game` into per-golfer lines and phrases each
  transfer from that golfer's own side (`{other, amount, owes_me}`).
- **It calls `round_settlement(round_obj, min_games=1)`.** That function used to
  hard-refuse a single-game round; `min_games` is now a PARAMETER, defaulting to
  2 so the running-tab behaviour is unchanged. The rule is right for a tab and
  wrong for a receipt: a skins-only round is the commonest casual round there
  is, and "Ben owes you $12" is exactly as true with one game as with two.
- **`GET/POST /api/rounds/{id}/receipt/`** — `RoundReceiptView`. GET 404s when
  nothing is nettable (an invented empty receipt is worse than saying so); POST
  records a send and refuses while `can_send` is false.
- **`SettlementSend` now hangs off EITHER parent** — nullable `tournament` and
  `round` FKs with a `CheckConstraint` (`settlementsend_exactly_one_parent`)
  making exactly one required. Migration `tournament/0060`.
- **Mobile:** `screens/round_receipt_screen.dart`, reached from a
  "Receipts & text the group" button on the leaderboard's `_SettlementView`
  (which gained `roundId`). Per-golfer expandable cards — for a four-ball you
  want all four open at once, not four pushes and four backs — plus the
  "Text the group" card: note field, live preview, segment count (amber over
  three), the gate, and Send/Resend. Records only on
  `ShareResultStatus.success`; a dismissed sheet is not a send.

#### The receipt nothing could open — one gate, asked at two thresholds
Shipped, tested, and **unreachable**: 0 of 38 completed casual rounds in the
local database could open a receipt. 25 had one.

The receipt calls `round_settlement(round, min_games=1)` on purpose — a
skins-only round is the commonest casual round there is. Its only entry point
was a button inside `_SettlementView`, and the Settlement TAB is built from
`round_settlement(round_obj)` at the default `min_games=2`. One game, no tab,
no button. Every unreachable round was single-game: skins, sixes,
low_net_round, points_531 — exactly the case `min_games=1` was chosen for.

Two questions, one call, asked once in `_build_leaderboard`:
- the **tab** needs 2+ games (a one-game tab just restates that game's own
  payouts);
- the **receipt** needs money to have moved.

`games['receipt'] = {'available': bool}` now carries the second answer.
`_leaderboard_active_games` skips it exactly as it skips `settlement` — it is a
capability, not a game, and an older client that tabs off `active_games` must
not render it as a junk tab. The entry point is a **leaderboard overflow item**,
not a tab button: GolfAppBar's own guidance is 0–2 direct actions, and the board
already spends both on chat and the overflow.

Deriving the tab from the receipt's own call is what stops them drifting apart
again. `test_a_one_game_round_offers_the_receipt_without_a_settlement_tab`
pins it.

#### Three more, found the same way — against the database, not fixtures
- **The personal send skipped the gate.** "Send his receipt" called `Share`
  directly while the group button respected `can_send`. The gate is about
  whether the money is FINAL, not about which button was pressed: a provisional
  receipt texted one golfer at a time is exactly as wrong as one texted to
  four. Gated on both sides now, client and server.
- **`last_send` is not one fact.** It was the most recent send of any mode,
  and `_stamp()` hard-coded "to the group" — so recording a personal send
  would have made the group card claim a group text that never happened.
  Split into `field_summary.last_send` and a per-golfer `last_send`, which
  needs `SettlementSend.player` (`tournament/0064`) because the useful question
  is "have I sent Ben his yet", not "did a send happen". A personal POST must
  name a golfer who is ON the receipt.
- **A round that settles to nothing had a receipt.** 7 of 38. Everyone square,
  or a game that ran and paid nobody, produced four "+$0 to collect" lines and
  a group text saying nothing. `casual_receipt_payload` returns None, same rule
  that already refused an invented empty one.

Also: `_field_labels` falls back to full names where a surname is shared — a
family four-ball rendered `Lipkin +$0` four times — and only for the ambiguous
ones, so one repeated surname does not lengthen every line. And `_LABELS` said
`Six's`; the app says Sixes everywhere else, and that string goes out in the SMS.

#### `'completed'` is not a round status — three gates were wedged shut
`RoundStatus` is `pending` / `in_progress` / **`complete`**. Three places
compared against the literal **`'completed'`**, which matches nothing, so each
gate blocked forever:
- `services/tournament_settlement.py` — "Every round has to be closed before
  the tournament settles" on a tournament whose rounds were ALL closed, so
  **Settle could never be pressed**, and since the receipt gate IS the Settle
  gate, the tournament receipt could never be texted either.
- `services/day_bet.py` `_tournament_closed()` — never true, so the day bet
  never resolved.
- `services/settlement_receipt.py` — the casual gate, same shape.

The tests did not catch it because **they set the same invented value**: Django
does not validate `choices` on `save()`, so `'completed'` stored happily and the
test agreed with the code. All six sites (three services, three test helpers)
now compare against `RoundStatus.COMPLETE`, so a rename breaks loudly instead of
silently wedging a gate. Found by running the payload against the real local
database rather than only against fixtures — every completed round came back
`can_send=False`, which no test would have shown.

## Share link cards — one template, watch + invite (`handoff-share-link-cards`)

Both link previews now render from `services/share_card.py`: the watch card
(redesigned) and the invite card (new).

**Rendered with Pillow, not headless Chrome.** The handoff ships an HTML/CSS
template and a Puppeteer snippet. That template is the DESIGN SPEC — Chromium
on the Railway deploy is ~300MB of buildpack plus cold-start and per-request
memory, against a renderer that already draws this in milliseconds with both
fonts bundled under `core/share_assets/fonts`. Ported the deltas instead:
the 3-stop gradient (`#07130F → #0B1F1A 46% → #0D3327`, replacing a bright pine
top that fought the wordmark), the translucent footer over the gradient rather
than its own solid colour, 52/44 padding, and the 20px Spline pill.

**The invite card is the bigger win.** `/i/<code>/card.png`, same template,
`INVITE` pill and no dot. It previously served ONE static square icon via
`INVITE_OG_IMAGE_URL` — precisely the gray-row problem the watch card was built
to solve, one link over. That setting now defaults to empty (the rendered card
wins) and survives only as an override.

### Three places the handoff could not be followed literally

- **The recipient's name cannot appear on the invite card.** The handoff's
  sub-line is `Wendal Doman · Scored on the phone…`, but `invite_code` is
  STABLE PER USER — one link shared with everybody, rendered without knowing
  who opens it. Naming a recipient needs per-recipient links, a different
  feature. The pitch takes that slot; the title still personalises, because the
  code does identify the *inviter*.
- **A finished round still says FINAL, not Live.** "The pill states the kind of
  link, not a status" only ever illustrates a live round. Taken literally it
  would undo `test_completed_round_never_claims_to_be_live` and put LIVE on a
  round from last Tuesday. Same rule applied one line down, which the handoff
  does not cover: the footer now reads **See the result** on a finished round,
  because "Watch live" makes the identical false promise and the tap behind it
  lands on a scorecard.
- **Long titles shrink rather than being truncated upstream.** The handoff says
  truncate the course name server-side. A card that breaks because someone
  typed "Corica Park — South Course" is still a broken card, so `_title_block`
  wraps to two lines, shrinks to fit, and only ellipsises as a last resort.

  **The subtlety that cost a render:** `20ch` must be measured ONCE at 60px and
  held fixed while the font shrinks. Re-measuring it in the shrinking font
  keeps the box 20 characters wide at every size, so shrinking fits no more
  text — it only makes the title small. A 53-character title went from
  ellipsised at 34px to whole at 52px.

Cache keys hash the title (`invite_views.py`); the raw one carries the
inviter's name and spaces make a key invalid under memcached.

Tests: `InviteCardTests`, `TitleWrapTests`, `FinishedRoundCopyTests`
(`api/test_share_card.py`).

## Match play Live Activity — singles + fourball, the first casual-round card

Built from `docs/design-review/handoff-live-activities/match-HANDOFF.md`.
`services/live_activity_match.py`, registered for BOTH `match_18` and
`fourball`.

**One card, two games.** Both are a single match between two sides over
eighteen holes, decided by holes won; the only difference is how many names sit
on a side. Two builders differing by a conjunction would drift apart within a
release, so there is one — `_normalise_nassau` / `_normalise_fourball` reduce
the two engines to the same small vocabulary and the composition never asks
which game it is drawing.

`match_18` and `fourball` were the games the registry's own comment said were
"not drawn". They are now.

- **The state declares the CARD, not the slug.** `activity_state` changed from
  `state['kind'] = slug` to `setdefault`, so a builder serving several games
  names the layout (`kind = 'match'`) and the Swift never has to learn that two
  slugs mean one card. Single-game builders are unaffected.
- **No Swift layout was added.** The match card IS the shared composition, so
  it draws with the existing `BoardView`; `"match"` joins `LockScreenView.known`
  and nothing else branches. Two shared views gained an empty case: `PipsView`
  renders nothing for `[]` (match has no segments, and an empty HStack still
  spent the stack's spacing), and `FooterView` hides entirely when both fields
  are empty — **a no-stake round removes the footer, not the score**, with gross
  and thru moved into the header by the server. Staleness still claims the row;
  a fault report outranks a layout rule.
- **This card never pushes.** In a two-side match inside one group the reader
  was within earshot of every putt — not a hole won, not dormie, not the
  close-out. A deliberate zero, pinned by a test asserting the module exposes no
  push builder at all.
- **The money slot is empty from the 1st to the 17th.** A single match settles
  exactly once. `$0` would read as a match played for nothing.
- **A match that closes early keeps the activity.** The number becomes the
  result (`4 & 3`), the state says `CLOSED` / `ON THE 15TH`, the money finally
  fills — and the **header keeps advancing**, because the group is still
  playing golf and the reader's gross is still moving. Both engines already
  model the close-out (`overall.decided_remaining`; `finished_on_hole`), so
  neither is re-derived here.

### The bug this found: Nassau's gross was always blank
The umbrella packet's new rule is that gross against par appears on every state
of every card. There were **three** `_gross_to_par` implementations, each
guessing at the key its summary uses for per-hole scores — and Nassau's guessed
`players`, where `nassau_summary` emits `scores`. So the shipped Nassau card
silently dropped the gross figure from its footer, for every reader, on every
hole. A helper that returns `None` on a shape mismatch fails invisibly, which
is exactly why there is now one: `live_activity_registry.gross_to_par`, checking
`scores` / `players` / `entries` in order. Confirmed against the real database
before and after; no test had asserted gross was present, which is how it
shipped.

Fourball keeps its per-hole scores under `scorecard`, so it hands the list over
rather than the summary — and the footer's gross is the **reader's own**, never
the team's better ball, because a team figure on a neutral board is a number
nobody can check against their own card.

### Not built
- **Dynamic Island extras.** Compact shows the number for every card; the
  handoff wants the leading side's surname beside it on this one. Expanded wants
  an 18-hole run strip (blue/orange per hole won, blank for halved), which needs
  data the state does not carry. Both are per-card changes to a shared island.
- **The final state is written but unexercised** — `match_final_state` composes
  `−$20 / Lost 4 & 3 / Pay Paul Kelly`, and the registry calls it, but no round
  in the local database plays either game, so it has only ever run against
  fixtures.
- The packet's open questions stand: concession, halved-stake voiding, presses
  in singles, extra holes, three-sided groups.

## Forced playing handicap — matching an externally-managed card

A round scored in Halved but MANAGED elsewhere (Golf Genius, a club sheet)
hands each golfer a **playing handicap** off that system's card. Until now the
only way to hit those numbers was to edit each golfer's index — which changes
them in every other round and every future one — and restart the round to see
whether the guess landed.

`FoursomeMembership.playing_handicap_override` (`tournament/0065`), null =
computed. Per membership, so it dies with the round and never touches the
roster.

**It is the FINAL number, and no allowance is applied on top.** The external
system already applied one; applying Halved's as well double-counts it. That is
enforced in exactly one place — `scoring.handicap.effective_hcp_for(membership,
net_percent)` — which every game now calls instead of `_effective_hcp`. Eight
call sites moved (survivor, irish_rumble, low_net_round ×2, rabbit, vegas, wolf,
and `build_score_index`). The one remaining `_effective_hcp` caller is Irish
Rumble's PHANTOM handicap, which has no membership and no external card behind
it.

- **Set through `PATCH /api/foursomes/{id}/tees/`**, which gained an optional
  `handicaps` list beside `tees`. Both lists are now independent — forcing a
  handicap is not a tee change and no longer requires a redundant tee
  assignment. `playing_handicap_override: null` clears it.
- **That endpoint is the only writer**, because it is also the one place that
  recomputes handicaps from the index — i.e. the one place an override could be
  silently undone. It is applied AFTER the tee loop and re-read in the
  recompute, so a tee change in the same request (or a later one) cannot
  replace a forced number with a freshly computed one. Both cases are pinned.
- **Clearing it rebuilds `course_handicap` from the tee.** Setting an override
  overwrites CH and PH with the forced figure so the hub cannot display one
  number while the golfer plays off another; without the rebuild, clearing left
  the stale forced figure in CH. Found by the test, not by reading.
- **Refused once any hole is scored** — the same threshold as a tee change and
  for the same reason: it re-nets every hole already played.
- **Zero is a real value.** `if override:` would silently drop scratch, so
  every check is `is not None`.

**Mobile:** `confirm_tees_screen.dart` is now **Tees & Handicaps** (hub button
renamed to match), with a `Playing hcp` field per golfer. Blank means "compute
it" and the field is never pre-filled with the computed number — showing it
there would make a computed handicap indistinguishable from a forced one that
happens to match, and every golfer would read as overridden.
`TeeAssignmentList` gained an optional `trailing` builder rather than being
forked; it is null in round setup, which keeps the plain picker there.

Tests: `scoring/tests/test_handicap_override.py` (the helper — override wins,
no allowance on top at any percentage, zero honoured, per-golfer, index never
touched, and that it actually moves the stroke dots) and
`api/test_handicap_override.py` (the endpoint, the two ways a tee change could
wipe it, the scored-hole gate, cross-account 404).

## Survivor lock screen — the headline is a word

Built from `docs/design-review/handoff-survivor-zombie-v2/` (screen 3).
`services/live_activity_survivor.py`, registered for `survivor` and **held in
`UNSHIPPED_KINDS` from the day it was written** — a card enters that set with
its builder and leaves with its build.

**Survivor is the strongest case for an activity in the app: you can be knocked
out by a shot you did not see.** Elimination is a NET comparison, so watching a
man hole out does not tell you whether it was you — it depends on strokes. That
is what separates it from match play, which pushes nothing because the reader
sees the result directly. (I had this wrong first: I argued from "single group"
that Survivor could not push either. Single group is not the test; visibility of
the RESULT is.)

Three departures from every card before it:

- **The headline is a WORD** — `ALIVE` / `OUT` / `ZOMBIE` / `BACK IN`. Every
  other game is measured in something; Survivor is measured in whether you are
  still in it. A count of survivors is a GROUP fact and lives in the state slot.
  `Number.isWord` already detected this shape, so nothing needed teaching.
- **The track is two-dimensional** — a row per golfer, a cell per hole, scoped
  to the Survivor being played (five cells is the width ceiling). `pips` is 1-D
  and cannot carry it, so `track` + `ruler` are new.
- **In a Zombie round nobody is `OUT`** while the Survivor runs — they are in
  the seat. Orange never appears; plum replaces it. A Zombie's row cannot empty
  the way a plain eliminated golfer's does, because he is still hitting shots:
  `zom` is the hole that sent him there, `zplay` every hole he plays from it.

### The shared frame grew, not Survivor's
Paul confirmed the two locked corners are going onto **every** card, so they
were built shared from the start rather than moved later:
`live_activity_registry.hole_facts()` (upper right — `HOLE 13 · PAR 4 · 412`,
**yardage from THAT golfer's tee**, so two players in one group legitimately see
different numbers) and `thru_line()` (lower right — `THRU 12 · +7`, against
GROSS par). Swift gained `who`, `ribbon`, `thru`, `track`, `ruler`, all optional
and all frame-level. The sweep onto the other four cards is wiring, not rework.

`ruler`, not `track_holes`: a one-word key keeps the top-level `ContentState`
free of a `CodingKeys` enum, where one missed case silently stops the WHOLE
state decoding.

### The gold band
`POPPING ON HOLE 13` when the reader gets a stroke on the hole in play. Gold
appears nowhere else in the system, so it cannot be read as a state.

**It is built from the game's own allocator (`_alloc_by_hole`), not from the
summary.** The summary reports strokes as part of a SCORED hole, and the hole in
play is by definition not one — the first version read the summary and could
never have fired. A watcher never gets one.

### Two bugs the real database caught
- **`HOLE 19`.** A finished round has no hole in play, and inventing one gave a
  locked corner with no par and no yardage — reading as a failed fetch. The
  packet's one exception to that corner is exactly this: `ROUND COMPLETE`.
- **A `now` cell on an eliminated golfer.** He is not standing on the next hole
  in this Survivor's sense; his row stays `gone` (or `zplay` for a Zombie).

### Not built
The **pushes**. The packet lists six push events, and a round runs up to nine
Survivors — plausibly 15–20 pushes, against the umbrella packet's "three to four
a round, anything more and the activity is doing the notification's job badly".
Design to rank them. The card and its state are complete without any of it,
which is why that was a clean seam to stop at.

The **round-complete frame** (money becomes the headline at 42px) — `_survivor`
returns `{}` for `final`, like Rabbit and Nassau.

Tests: `scoring/tests/test_live_activity_survivor.py` (22).

## Survivor leaderboard — the R5 rail

Built from `docs/design-review/handoff-survivor-zombie-v2/` (screen 2), whose
`screenshots/` are far more precise than its prose and settled three things the
text left open.

`widgets/survivor_rail.dart`, in `widgets/` because the packet says the rail
serves the leaderboard AND the play screen — building it into either would have
guaranteed two of them.

**Two stacked parts over one shared ruler.** The winner bar's LENGTH answers how
long a Survivor ran and its LABEL answers who took it; the lanes answer how long
each golfer lasted. The card gained a `HalvedSegmented` (the project's own
control, which is what the packet asked be reused) splitting **Survivors** from
**Standings** — Survivors default, because the rail carries the story and the
money is one tap away.

**Solid plum marks whoever is in the seat NOW**, not whoever opened it. The
packet flags this as a live tension and offers both; following the occupant
makes every handover visible (the opener reading draws nothing when the seat
changes hands) and matches the lock-screen track, so plum means one thing on
every surface — the packet's own rule 5.

### Four bugs, all found by looking at it rather than reading it
- **The IN PLAY bar spanned all eighteen holes.** With one Survivor the bars
  divided the full width between themselves, so a Survivor covering two holes
  drew a bar across the card — and the bar's length is the entire point of that
  row. Fixed with a trailing `Spacer` for holes no Survivor has reached.
- **`Through 18` on a round two holes old**, and, from the same root cause,
  **no hatching anywhere**: `survivor_summary` emits a row for EVERY hole in
  play, scored or not, so counting rows (or testing that a row exists) marks
  all eighteen as played. Both now require every entry to carry a gross.
- **`IN PLAY` wrapped** inside a two-hole bar.
- **Unplayed cells were a flat tint** a shade off `alive`, which at 15px tall
  reads as the same cell. They are drawn as diagonal hatching now
  (`_HatchPainter`), which is what the design does and why.

### Editing this file
`leaderboard_screen.dart` is ~10k lines and several cards share identical
blocks (`if (players.isEmpty)`, the status `Container`, `HoleGridScorecard`).
String-matching edits kept hitting the wrong card or aborting mid-script and
silently discarding earlier replacements. Anchor on line numbers within the
card's own range, replace the LATER range first so earlier indices stay valid,
and write once at the end.

## Survivor score entry — the rail, and the chip that was stating the wrong fact

Screen 1 of `docs/design-review/handoff-survivor-zombie-v2/`. Most of this
screen already matched: the phase banner, the hole header, the OUT / ZOMBIE
badges and the plum row treatment all shipped with Zombie phase 3.

Two things did not.

**`gets 3` was the wrong fact.** The player row carried a running allocation
total. The packet calls the chip a LOCKED rule and forbids exactly that: it
reads **`stroking`**, in amber, and appears **only on the holes where that
golfer actually gets a stroke**. A total belongs on the setup screen; beside a
live Survivor state it invites subtracting it a second time. The row already
had this hole's `strokes` — the total was simply the easier thing to reach for.
The chip and the red stroke dots above the score box are one fact stated twice,
and neither appears anywhere else.

**The rail was missing.** The packet says it appears on both surfaces, so
`SurvivorRail` gained a `fromSummary` constructor and the play screen renders
the SAME widget as the leaderboard. Two constructors rather than one shape,
because the callers genuinely differ — the leaderboard holds a raw
`by_group[n].summary` map and the play screen a decoded `SurvivorSummary`.
Converting at either call site would put the mapping in two places, which is
how one rail becomes two.

### Not done — a shared-component decision, not a Survivor one
The design's score picker captions (`BIRD` / `PAR` / `BOG` / `DBL` under each
option) are not built. `widgets/inline_score_picker.dart` is shared by roughly
eight score screens, so adding them restyles every game in the app. That is a
system-wide visual change and wants deciding as one, not smuggled in under
Survivor.

## The stroke band, on every card — one writer in the frame

`POPPING ON HOLE 13`: the band across the top of the lock screen when the
reader gets a stroke on the hole he is about to play. It began as Survivor's,
Sequoya picked it up, Banker wrote a third — and Sequoya's own packet had
already said why that was wrong: **the band belongs to the shared frame, not to
one game.** A golfer wants to know he is stroking on the hole in front of him
whatever is being scored, and one told in two cards and left to work it out in
the other five learns to distrust all seven. It now goes out on every card.

**One writer, in `live_activity_registry`.** `stroke_ribbon(foursome,
player_id, hole, alloc)` holds everything that is the same on every card — the
wording, the watcher rule, the empty string — and takes the allocation from the
caller, because only the game knows how it spreads strokes. Three rules carry
across, each learnt the hard way on one of the first three cards:

1. **Read the game's own ALLOCATOR, never the summary's played holes.** A
   summary reports strokes as part of a SCORED hole, and the hole in play is by
   definition not one — a band built from the scorecard could never fire.
   Survivor's first version did exactly that.
2. **Only a golfer who is playing gets one.** A watcher has no strokes; a
   phantom is not a reader.
3. **Running states only.** A finished round has no hole in play, so the band
   comes down rather than inventing a `HOLE 19`.

**Which allocation each card hands in:**

| Card | Allocation | Why |
|---|---|---|
| Nassau · Skins · match (`match_18`/`fourball`) | `full_round_strokes()` | full-round by course stroke index |
| Sixes | `services.sixes.sixes_player_hole_strokes` | a match's strokes fall on that match's own six holes |
| Rabbit | its own summary's per-hole `strokes` | see below |
| Survivor · Sequoya | unchanged, now delegating the formatting | |
| Banker | **its own writer, and its own blue** | strokes come off inside each one-on-one, so there is no field-wide allocation to report — its band has to name the matches |

**Rabbit is the one card that reads its band off the summary, and legitimately:**
`rabbit_summary` walks the FULL play order and emits `strokes` from the
allocator on every hole, scored or not — it exists precisely so the stroke dots
do not snap around as holes come in. That is an allocation, not a
gross-minus-net reading, so the hole in play carries a real number.

**`hole_in_play(foursome, played)` uses play ORDER, not `played + 1`** — the
arithmetic form (which Survivor shipped) puts a back-nine round's first band on
hole 1, a hole nobody in that round will play.

**`full_round_strokes` is named that, not `strokes_by_hole`**, because
`services/sequoya_threes.py` already exports a `strokes_by_hole` with a
different signature, and two of those in one package is how the next person
picks the wrong one.

**No gating was needed.** `ribbon` has been in the Swift `ContentState` since
Survivor and is optional, so an installed phone decodes a card carrying one
whether or not its layout draws it. `BoardView` already drew it — so **Sixes
and the match card light up on the shipped build with no client change**, while
Skins, Nassau and Rabbit gained the row in their own board views and need the
next build to show it. Nothing is broken in the meantime; the row is simply not
drawn, costing those cards not even the stack's spacing.

**Corrected along the way:** `sixes_player_hole_strokes`'s docstring claimed
"only holes a player has actually scored appear", which its own body
contradicts in a comment four lines up — the plan is prospective. That claim
would have sent the next person to a different allocator for exactly this job.

Tests: `scoring/tests/test_live_activity_ribbon.py` (20) — written per card
rather than as a loop, because each game allocates differently and the whole
risk in the sweep is a card reporting a stroke on a hole its engine does not
give one on. The reader is off **2** against a scratch group, so he strokes on
exactly two holes (SI 1 = hole 5, SI 2 = hole 14) and the first tee is SI 7 —
a card firing on hole 1 is reporting a stroke nobody gets.

## The 3-hole edit ceiling — `services/edit_window.py`

> **The first three holes are the window. The 4th score locks tee box,
> handicap index and teams for every game.** A game's own rule may lock a
> setting EARLIER; no game's rule extends past the ceiling.

Design proposed four (`~/Downloads/REPLY-2.md`, 12 Sep 2026) after the engine
check found only one of eleven games guarded a setting at all, and left the
boundary a hole ambiguous. **Paul settled both at three**, and the reason is
what pins the number rather than a feel for it: **three scored holes is exactly
one complete Sequoya match, and match 2 has not been set.** A window reaching
hole 4 would be redrawing a pairing the second match was already being played
under. Three is also enough to find the three things it exists for — the wrong
tee, the wrong teams, the wrong forced handicap — all of which announce
themselves on the first green.

**It also bounds the rewrite.** `HoleScore.handicap_strokes` and `net_score`
are stored rather than computed, so accepting a retroactive edit means
rewriting rows. Under the ceiling the maximum is three holes per golfer, never
eighteen.

The constant lives in ONE module because it is one rule for every game — a 3
written into each service is how eleven games end up with eleven rules again,
which is what the matrix was trying to stop. **The refusal COPY is shared for
the same reason** (`closed_reason(noun, because)`): the first version let each
service write its own f-string, and those had already drifted by the time the
number moved from four to three.

### Banker is the one game with a stricter rule — a window of zero

`ceiling_for(foursome)` is the only place a game may narrow the ceiling, and
Banker narrows it to **0**: every hole is a separately negotiated bet priced
against the strokes in play when it was struck, so a bet made on the 1st cannot
survive its inputs changing on the 2nd. There is no interval in which a
correction is free, because the first hole has already been bought.

`setup_banker` now raises **`BankerSetupLocked`** — named apart from
`BankerLocked`, which is a hole's BETTING window closing; two different locks,
both real, and one name for them would make every traceback ambiguous. It
guards only `_PRICED_IN` = handicap mode, allowance, first banker. The wager
band, doubles, the counter, par-3 triples, birdie bonus and loss caps govern
bets **not yet struck**, so a TD may still move them — locking those would be
strictness for its own sake. An idempotent re-post of the same values is not a
change and is not refused.

### Shipped so far: the two team/pairing games

**Sixes** moved from "locked at the first real score" to the ceiling.
Design's alternative was to lock at the SECOND MATCH — which begins at hole 7,
far past the ceiling, so that trigger could never have fired. Paul settled it
on 12 Sep: **Sixes is not an exception.** The trigger is deliberately not
built.
- Inside the ceiling a redraw rebuilds the segments AND **recalculates**, so
  the played holes are rescored under the new teams rather than reading as
  unscored until the next score lands. The recalc is in `setup_sixes`, not the
  view, for the same reason the lock is: every caller is covered and the two
  cannot disagree about when it is needed.
- **A voided segment refuses a redraw even inside the ceiling.** `is_void` is a
  withdrawal's record and the rebuild would take it with the segments;
  redefining the segments it was applied to leaves nothing to carry it onto, so
  this says no rather than losing it quietly.
- Settings (handicap mode, allowance, format, allocation) stay open all round
  and still update IN PLACE — unchanged.

**Sequoya 3s had NO lock at all** — `setup_sequoya_threes` was a bare
`update_or_create`, so match 1's pairing could be rewritten on the 17th. That
is worse here than in Sixes rather than better: Sequoya stores no hole results,
all six matches are DERIVED from `match1_side1` through `pairings()`, so a
redraw silently re-decides the matches already settled. Nothing would have
looked wrong; the money would just have been different. Now `SequoyaLocked`,
on the same ceiling — and it is Sequoya that SET the ceiling: three scored
holes is one complete match, so the window shuts exactly as match 2 begins.
Only the PAIRING is locked; stake, allowance and press mode stay open.
`[B, A]` is not a redraw of `[A, B]` — a side is a set of two golfers, so an
idempotent save from a client that reordered the list is not refused.

### NOT built, and why

**The tee-box / handicap-index half.** `FoursomeTeesView.patch` still refuses
on the FIRST real score. Loosening it to the ceiling is only safe together with
the retroactive rescore — rewriting each touched `HoleScore`'s
`handicap_strokes` (`net_score` and `stableford_points` follow from
`HoleScore.save()`) and recomputing every game on top — plus the stored prior
value Design specified for undo, and the confirmation sheet, since the money
can move under a group that is looking at it. Those three land together or not
at all: a ceiling on its own converts a refusal into silent corruption.

Also unbuilt from that packet: the stroke-dot cap removal (measured — three
dots fit the 40px score box but collide with the centred digit in the 32px
scorecard-grid cell, which needs a design answer) and the
new-match-carrying-gross-scores escape hatch.

Tests: `scoring/tests/test_edit_window.py` (20) and the rewritten
`SixesTeamLockTests` (`scoring/tests/test_sixes.py`).

## The tee / index half — retroactive rescore and one step of undo

`FoursomeTeesView.patch` used to refuse the moment any real golfer posted a
gross score. It now refuses past the **edit ceiling** instead, and inside the
window it accepts the change and rescores the round.

**Why the refusal existed.** `HoleScore.handicap_strokes` is denormalised off
the membership and `net_score` is stored for query performance, so accepting a
tee change is not a recompute — it is a **rewrite of every scored row** for
that golfer, after which every game's summary has to be rebuilt on top. Get it
wrong and you do not display a wrong total, you corrupt completed holes.

### `services/setup_edit.py`

- **`rescore(foursome)`** rewrites `handicap_strokes` on every scored hole from
  the CURRENT memberships, **retroactive to hole 1** — applying a new tee going
  forward only would leave the round scored under two allocations, which is not
  a real result. It sets the strokes and calls `save()`; **`net_score` and
  `stableford_points` are NOT written here**, because `HoleScore.save()` already
  derives both and a second copy of that arithmetic is how the two come to
  disagree. Returns the rows actually changed, so "4 holes rescored" is honest
  and can legitimately be 0 (off 12 and off 17 both stroke on SI 7).
- **`snapshot(foursome)` captures the WHOLE foursome**, not the golfers named in
  the request: a tee change can shift the group's lowest par and re-derive every
  real member's par-adjusted playing handicap, so an undo restoring only the
  named golfer would leave the others on numbers nobody chose — and nothing
  would look wrong.
- **`restore()` writes the stored numbers rather than re-deriving them**, and
  uses `QuerySet.update()` for the hole rows precisely because `save()` would
  re-derive `net_score` from the strokes and overwrite the restored value. The
  numbers being restored were computed under settings that no longer exist
  anywhere — that is the whole reason they had to be kept.

### `tournament.FoursomeSetupUndo` (migration `tournament/0070`)

OneToOne, not a log: **one step back, replaced by the next edit**, so a second
edit makes the first permanent. "Prior value" means the ROWS — membership *and*
`HoleScore` — because once `handicap_strokes` is overwritten there is nothing
left to derive the old one from. Under the 3-hole ceiling that is at most three
holes per golfer, which is what makes keeping them affordable.

**The undo RESCORES as well as restoring.** The round does not stand still
between the edit and the undo: holes played in between were scored under the
new setting and are not in the snapshot, so restoring only what was captured
left them allocated off a tee the golfer was no longer on — the "hole 1 used
one index and hole 4 used another" corruption, arriving through the back door.
A rescore over everything fixes exactly those, because the allocation is a pure
function of (playing handicap, tee, hole): on the captured holes it recomputes
the value just restored and writes nothing.

**The undo is deliberately NOT gated on the ceiling.** The window governs
making a change; putting one back is safe at any hole, and noticing on the 9th
that the wrong tee went on at the 2nd is exactly when it is wanted.

`POST /api/foursomes/{id}/tees/undo/` restores, rescores and recalculates; the
step is **spent** afterwards (an undo of an undo is a second step, and a second press
would re-apply values the round has moved past). `GET` reports whether one is
standing and what it would put back. The PATCH response carries
`holes_rescored`, `undo_available` and `undo_note` — the client shows the
standing step **before** the next save, since discovering it afterwards is no
use.

Deliberately **not an audit trail.** If a record of who changed what is ever
wanted, that is a different table with different retention; this one is
designed to be thrown away.

### The gate that would have hidden all of it — `setup_editable`

**The hub button was gated on `has_any_score`**, which matched the OLD server
rule exactly: refuse the moment a real score lands. The moment that rule became
a 3-hole window, a button still hidden at the first score would have made the
entire edit window **unreachable from the app** — shipped, tested, and
impossible to open. Same shape as the casual receipt nothing could open.

`FoursomeSerializer.setup_editable` (+ `setup_edit_note`, `2 of 3 holes used`)
now carries the answer, and `round_screen.dart` gates BOTH **Tees & Handicaps**
and **Edit Configuration** on it. Edit Configuration mattered too: Sixes and
Sequoya accept a redraw inside the window, and the settings that were always
editable mid-round (handicap mode, allowance, stake) were behind that button as
well — equally unreachable.

**The client is told rather than counting to three itself.** A phone deriving
the rule would be an eleventh copy of it, and would not know a Banker round has
no window at all. `setupEditable` defaults **true** in `Foursome.fromJson`, so
an older server that sends neither field behaves as it always did rather than
hiding the button everywhere.

### Mobile

`confirm_tees_screen.dart`: the standing "neither tees nor handicaps can change
once a hole is scored" line was now false and says the real rule; a save that
rescored anything gets an 8-second snackbar naming the hole count with an
**Undo** action (the round provider and messenger are captured before the
await, because the action outlives the screen); and a standing undo draws a
banner above the controls saying that saving again replaces it.

**The net money effect is DECIDED AGAINST, not outstanding.** Design's item 3
wanted the confirmation sheet to show `you −$15, Kevin +$15` before committing,
computed by applying the change in a transaction and rolling back — the
technique the flights preview uses. Paul killed it (12 Sep) with the argument
that settles it: **the edit is a mistake being corrected.** The money moving is
not news, it is the correction landing — the OLD money was wrong. Showing a
before/after figure presents fixing a typo as a transaction the TD has to weigh,
and invites second-guessing a change that was already right.

So the reporting stays as it is: `Updated 1 player · 2 holes rescored`, said
after, with the way back. The hole count is the honest unit — it says what was
touched without pricing it.

Do not build the preview endpoint for this. (The transaction-and-roll-back
technique itself is still right where a TD is genuinely CHOOSING — the flights
preview, where the split is a decision rather than a repair.)

Still outstanding: the stroke-dot cap, and the new-match-carrying-gross-scores
escape hatch.

Tests: `api/test_setup_edit.py` (29), including a `ReachabilityTests` class
asserting the button is offered after hole 1 — the failure mode above.

## Stroke dots — the cap is gone, and the grid changed axis

`strokes.clamp(0, 2)` lived on **nine** surfaces and silently misreported a real
state: the row drew two dots and the golfer had three. It was never a constraint
on the score box, which has room for four — it was invented for the 32px
scorecard cell, where three horizontal dots reach the centred digit, and then
applied everywhere.

**Measured rather than argued** (`test/stroke_dots_test.dart` renders the real
cell): three horizontal dots in a 32×26 cell overlap the digit by **8.1px**. So
the collision is real and the cap was the wrong answer to it.

Design's answer (`~/Downloads/handoff-app-fixes/stroke-dots.html`, option B) is
the **same dot rotated ninety degrees** in the grid — a 4px column down the
right edge, inset 3px, vertically centred. Three dots then cost **7px of the
cell's width instead of 14**, so they cannot reach the digit at three strokes or
at four. Rejected alternatives, both for stated reasons: smaller dots only
reduce the overlap (and make the grid disagree with the score box about how big
a stroke is), and two-dots-plus-a-numeral puts a second small number in a cell
that already has one — the failure that retired `gets N`.

**The column is anchored at the TOP right, not centred** (Paul, 12 Sep). The
first dot therefore sits exactly where a single stroke has always sat — the
corner — and the column only grows downward when there is a second and a third.
The common case is one stroke; centring it moved the familiar corner dot on
every ordinary hole to accommodate a three-stroke case that, in strokes-off, is
extreme. One stroke now lands in the same place in the grid as in the score box,
which is pinned by a test.

`widgets/stroke_dots.dart` holds both treatments, because **nine copies of one
4px dot is how a single vocabulary becomes several**:

- **`StrokeDotRow`** — the score box (40×36) and the phantom's box. Horizontal,
  top-right, unchanged apart from the cap.
- **`StrokeDotColumn`** — every scorecard grid: `hole_grid_scorecard` (32×26),
  score entry ×4 and Nassau (34×28), the leaderboard's Nassau net grid (28×26,
  the narrowest in the app, so `inset: 2`).
- `scoreCellWithDots` in `net_score_button.dart` keeps its own 5px strip ABOVE
  the box — it never had the collision, so it only lost the cap.

Dot size, gap and colour are identical across both; only the axis differs, which
is what keeps it one mark rather than two meaning the same thing. **Do not
restyle the score box to match the grid** — they are different sizes for good
reasons.

`top: 0, bottom: 0` on the column stretches it to the cell's full height so the
`Center` has something to centre against; measuring from an edge would put it
level with the digit at one row height and nowhere near it at another.

Tests: `mobile/test/stroke_dots_test.dart` (9) — the counts, and the geometry,
since the geometry IS the argument for the shape.

**Still outstanding from that packet:** `gets N` survives on about fifteen call
sites — Wolf, Banker, Points 5-3-1, Rabbit, Triple Nassau, Skins, Nassau, score
entry and the leaderboard. (An earlier note of mine claimed Wolf only; that was
a bad grep.) Design keeps it as its own cleanup item. Also open: the new-match
escape hatch, and the scroll-inset sweep.

## Scorecard grids: the label column is pinned, and they open on the hole in play

Reported from a fourball (12 Sep 2026): scrolling the progress grid under score
entry took the NAMES away with the holes, so by the 14th the four rows were
anonymous — exactly when a fourball needs to know whose ball is whose. It also
parked the current hole in the MIDDLE of the viewport (`(pos - 6) * cellW`), so
the thing you are about to do sat in the centre with empty columns to its right
while the holes you had finished ran off the left.

**`HoleGridScorecard` had already been fixed** and carries the note explaining
why — *"by hole 12 the rows were anonymous"*. Eighteen other grids were never
converted. That is the argument for doing them as a family rather than one
more.

**`widgets/pinned_hole_grid.dart`** holds both behaviours:
- The label column sits OUTSIDE the horizontal scroller. Bands and rules are
  added to the two halves TOGETHER (`HoleGridBand` / `HoleGridBand.rule()`),
  because a grid whose columns disagree by one row is worse than one that
  scrolls.
- The current hole's RIGHT EDGE lands on the viewport's right edge — a paper
  scorecard is read with the round so far to the left and the hole in front of
  you at the card's edge.
- `contentWidth` / `currentRightEdge` exist for non-uniform grids: Stroke Play
  interleaves OUT / IN / TOT among the holes, so a back-nine hole sits one
  summary column further right than its index suggests, and a rule measured in
  hole cells stops short of the grid it underlines.

**Converted (12):** score entry's fourball, Nassau, Irish Rumble, Stroke Play,
Stableford and Points 5-3-1; and the Nassau, Points 5-3-1, Rabbit, Survivor,
Wolf and match-play screens.

**The fourball card carries OUT / IN / TOT** (13 Sep), built the same way the
Stroke Play card does so the two read as one object — front nine, OUT, back
nine, IN, TOT, with `contentWidth` and `currentRightEdge` counting the summary
columns so the rule reaches the end of the grid and a back-nine hole scrolls to
the right place. A golfer's subtotal is an **em dash until every hole in that
nine is scored**, the same rule `_GridPlayerRow` uses: a subtotal appears once
its nine is complete and never as a misleading partial. The `Won by` row leaves
its summary slots blank — a nine has no winner, and inventing one would be
worse than the gap.

Things the sweep turned up:
- **Rabbit, Survivor, Wolf and match play never scrolled to a hole at all** —
  on the back nine you hunted for the one you were standing on, every hole.
  Survivor is the worst of them: the elimination you are looking for is the
  hole you have just played.
- **Four grids scrolled by HOLE NUMBER rather than play-order position**
  (Irish Rumble, both Points 5-3-1 grids, the Nassau screen), so a back-nine
  round aimed at a column that does not exist.
- **Match play has no hole in play** — it is read after the fact — so it opens
  on the last hole SCORED, which is the same reading.
- `_AutoScrollHoleRow` is deleted: a generic "scroll the whole grid" wrapper is
  the shape that made the label column scroll away in the first place.
- `_GridPlayerRow`, `_NassauGridPlayerRow` and both `_P531PlayerGridRows` now
  yield `HoleGridBand`s rather than finished `Row`s (the P531 ones yield TWO —
  scores, then points). A built `Row` cannot be taken apart afterwards without
  introspecting widgets, and their `build` composes the halves back for any
  caller that still wants one row.

**The six review grids followed** — `_StablefordPointsGrid`,
`_IRLeaderboardScorecard`, `_Points531HoleGrid`, `_TpmPhase2HoleStrip`,
`_TripleCupHoleDetail` and `scorecard_grid`'s `_LandscapeGrid`. **Eighteen of
eighteen; nothing in the app now scrolls its label column away.** A board read
after the fact has no hole in play, so those open on the LAST column — the same
"round so far, far end at the right edge" reading.

**The landscape card could not use `PinnedHoleGrid`** — it is a `Table`, and
`TableBorder.all` is what rules it like a scorecard. It is split the same way
instead: every `TableRow` is built with its label cell FIRST, so the halves come
apart into two Tables that share their row heights (22 for headers, 38 for a
player) and stay in step. It also **centred** the current hole rather than
right-edging it, which on a near-full landscape card put the hole you were about
to play in the middle with finished holes pushed off the left.

`HoleGridBand.gap(h)` exists for grids that separate rows with space rather than
a hairline — the Points 5-3-1 board is the one that does.

Tests: `mobile/test/pinned_hole_grid_test.dart` (8) — the pin and the offset
are geometry claims, so both are measured rather than eyeballed.

**Editing one of these grids:** use EXACT string replacements. A conversion
script that computed a block's end by searching forward from a landmark
swallowed several classes at once; the damage was invisible until `analyze`
ran. Convert and COMMIT one grid at a time, so a bad edit costs one grid.

## Combo tees — which tee a golfer plays on a given hole

A combo is one row in the tee dropdown with one rating and one slope, so **the
data never says which parent set a hole comes from** — the indicator has to be
derived. Spec: `~/Downloads/handoff-app-fixes 2/COMBO-TEES.md` (12 Sep 2026).

`services/combo_tees.py`. Two steps, and the first runs **once per round**:

1. **Fix the parents at setup** — the smallest set of the course's ordinary
   tees whose yardages account for all eighteen holes. All eighteen check out →
   the set is fixed and the indicator is guaranteed to name one of those tees on
   every hole. A hole matching none → **unsupported**, and the indicator is off
   for the whole round. One decision up front with one clear failure, instead of
   eighteen chances to quietly come back empty.
2. **Match the yardage per hole**, against the fixed set only — without that
   restriction a hole could resolve to `Black` on a Blue/White combo merely
   because Black happens to share the yardage.

**Ties take the LONGER parent.** Identical yardage means an identical shot, so
there is nothing to get wrong; longer rather than first-named because name order
carries no meaning ("Blue/White" and "White/Blue" are the same tees) while total
yardage is a property of the tees. Determinism matters more than the choice —
the chip must not read Blue on the lock screen and White in score entry.

### Two departures from the spec, both forced by the real data

**The parents are NOT parsed from the name.** The spec proposes parsing with
yardage matching as a fallback. Against all **56** combo tees in the database,
matching alone resolves **54** — including `B/W Combo` (initials) and Pacific
Grove's bare `Combo`, neither of which parses. Matching would have to verify a
parse anyway, so the parse step only adds a way to disagree with the check that
follows it.

**The parent set is not always a PAIR.** Three real combos need three sets
(Corica's `Team Match Combo`, California GC's `Back/Middle Combo`, Richmond's
`Senior Combo`). The guarantee is unchanged: a fixed set of size N either
accounts for every hole or the feature turns off. `_all_needed` refuses a set
that still covers the card with one member dropped — a spare parent would put a
tee on the chip the combo does not use.

### The two unsupported combos are course-data bugs

- **Corica Park South, `Black/Blue Combo` (Women), tee 362.** Eleven holes match
  nothing — and all eleven equal the MEN'S Black tee exactly, while the other
  seven equal the women's Blue. The women's card simply has no Black row.
  Adding it (Black markers, women's rating/slope) fixes the combo.
- **California GC of SF, `Senior Combo` (Men), tee 482.** Hole 9 alone: 338y
  against Venturi 419 / Back 402 / Middle 380 / Forward 270.

`unsupported_reason()` produces those lines. **It is for the log, never for a
golfer** — the cause is a course-data problem worth fixing once.

### Surfaces

- **Score entry, and every dedicated play screen** — a chip on the combo
  golfer's own row, in the slot `gets N` is vacating, so nothing new competes
  for width and the other golfers' rows are untouched.
  `MembershipSerializer.combo_tee_by_hole` sends the whole map at once; an
  ordinary tee sends `{}`.

  **It is `widgets/combo_tee_chip.dart`, not markup on one screen.** The first
  version went onto the generic score-entry screen alone, so a Sequoya 3s round
  showed nothing — reported from Metropolitan on 12 Sep, where the data
  resolved all eighteen holes perfectly. Eleven screens draw a golfer's name
  beside his score box and all eleven carry it now: score entry, Sequoya 3s,
  Nassau, Skins, Points 5-3-1, Rabbit, Survivor, Wolf, Triple Nassau, Quota
  Nassau and Pink Ball. **Banker and Triple Cup need nothing** — they push
  `/score-entry` for scores and keep their own screens for the betting board.

  Same lesson as the scorecard grids: **the games with their OWN play screen
  are the ones that get missed.**
- **Lock screen** — `combo_tee()` in the registry feeds a `tee` slot on every
  card, drawn by a shared `TeeRow` below a rule. **This is a third element on a
  surface capped at two**, and it earns the space by appearing only for a golfer
  on a combo; for everyone else the row is absent and the two-item rule holds
  exactly. Below a rule rather than beside the status because status and strokes
  are about the bet and the tee is about the next shot.
- **Both are a neutral outline, not a filled/green chip.** Tee names ARE
  colours, so a coloured chip reading "White" asks the eye to reconcile two at
  once, and a white chip on a white row is invisible. Green is the app's voice
  for something happening *to* you — strokes, bets, doubles — and a tee box is
  a fact about the hole.

**No `UNSHIPPED_KINDS` gating needed**: `tee` is a new optional FIELD on an
existing card, not a new card kind, and Swift's `Codable` ignores keys an older
build does not know.

Tests: `scoring/tests/test_combo_tees.py` (26).


## OUT / IN / TOT — every card that shows scores

Reported from a fourball (13 Sep): the scorecard under score entry had no nine
subtotals. The sweep that followed found eleven more cards in the same state.

`utils/nine_totals.dart` holds the split, because three facts follow from it
and two are easy to get subtly wrong: a `contentWidth` measured in hole cells
alone leaves the rule stopping short of the grid it underlines, and a scroll
target that ignores the OUT column lands a back-nine hole one column shy of the
right edge. Both were about to be written by hand eleven more times.

**A nine not in play has no column** — a back-nine round shows IN alone rather
than an OUT that could only ever be blank — and the split is by hole NUMBER, so
a shotgun round starting on the 7th still has a front nine meaning the same
nine holes.

**A subtotal is an em dash until every hole in that nine is scored**, the rule
`_GridPlayerRow` already used: it appears once its nine is complete and never
as a misleading partial.

**Rows with no nine total get blank slots, not an invented one:** stroke index,
per-hole verdicts (Won by, Top, Bot, a Triple Nassau match), a PHANTOM's row
(no card of its own), and POINTS — Paul ruled points out with Wolf.

Carrying them: `HoleGridScorecard` (which is the leaderboard's cards, **Banker,
Sequoya and Sixes** in one change), score entry's fourball, Nassau, Stroke Play,
Stableford, Irish Rumble and Points 5-3-1; the Nassau, Points 5-3-1, Quota
Nassau, Rabbit, Survivor and match-play screens; the Triple Cup hole detail,
the Triple Nassau card, the IR leaderboard card, and the landscape scorecard.

**Deliberately without them:**
- **Wolf** — its grid is POINTS, not gross. Paul excluded it twice.
- **The Survivor rail** — a lane timeline, not a scorecard.
- **Irish Rumble** (both grids) — shows net-to-par with a RUNNING team total on
  every hole, so the figure at the 9th already is OUT and the one at the 18th is
  TOT. Adding columns would print the same number twice.
- **The Sixes grid in score entry** — a strip of 6-hole match cards. A segment
  is six holes; the card's unit is the match, not the nine.

**Quota Nassau was also never PINNED** — its labels come from a `labelCell`
helper rather than a literal width, so the earlier pin sweep's regex missed it
and "eighteen of eighteen" was really nineteen. Fixed here.

Tests: `mobile/test/nine_totals_test.dart` (9).

## A finished round never opens a setup screen

Reported from a completed Sixes match (13 Sep): **"View Scorecard" landed on
the team-picker slot machine.**

The hub's one button — Enter Scores while a round is live, View Scorecard once
it is over — runs a single routing chain, and **fourteen of its branches can
choose a `*-setup` route**. Every one asks only whether the game is
CONFIGURED; not one asks whether the round is over. On a live round that is
right: an unconfigured game has to be set up before it can be scored. On a
finished one there is nothing to set up, and drawing teams for a match already
played and settled is the one thing the button must not offer.

Guarded once, after the chain and before the push, rather than in each branch:
the next game added will get a branch of its own and it will be written like the
other fourteen.

```dart
if (isComplete && route.contains('-setup')) route = '/score-entry';
```

**`contains`, not `endsWith`** — `/nassau-setup-18` ends in its hole count, so a
suffix test let the Singles Match picker through. Caught by the test, not by
reading. No play route contains `-setup`, so it cannot over-match.

It falls back to the gross card rather than the game's own screen: the only way
to reach a setup route is for the game to be unconfigured, and an unconfigured
game has nothing of its own to show.

Note the DATA was fine throughout — every completed Sixes foursome in the local
database serialises `configured_games: ['sixes', …]`, so that branch's guard
was working. The bug is reachable through any of the fourteen, by any round
whose game row is missing, or from a stale offline cache.

Tests: `mobile/test/completed_round_routing_test.dart` (5).

## Lock screens: the personal three, Wolf, and the shared strip

Built from `~/Downloads/handoff-lock-screens 2/` (13 Sep). Five new cards were
specified; four are built and **all of them are gated in
`UNSHIPPED_KINDS`** — these are games with NO card today, so an ungated kind
would replace nothing at all with a lock-screen nag pointing at an update that
does not exist.

### The four-across strip — `strip_column()` / `StripView`

Four stacked rows of place / name / score / thru measured **201pt** against the
160 ceiling (clipped on device); the same four figures cost **62pt** across.
Wolf established it, the Stableford foursome and the Stroke Play flight proved
it retroactively, and it is now the set's answer to any four-name card. Built
once, in the shared frame, because three cards use it.

Two rules the design argues for and the code honours: the side marker is a 2px
**rule**, not a coloured name (a name at 62% white in orange is unreadable at a
nit, and colouring the figure would collide with mint, which means *leads*);
and the label slot is spent even when empty, because the columns are read
ACROSS and one starting a row higher stops the figures lining up.

**`WhoRow` is back** — the reader named above the number. Survivor's fitted card
deleted that row for 19pt and was right to: it names two sides. The personal
cards headline a PERSON, and a phone handed round a cart otherwise breaks the
assumption about whose card it is.

### The cards

| Card | Kind | The departure |
|---|---|---|
| Stableford | `stableford` | headline is the total; state slot is the PLACE, because place is the money |
| Stroke Play | `stroke_play` | `E` never `EVEN`; header names the MODE; the line under the headline inverts — a chaser is told who leads, a leader who is coming |
| Points 5-3-1 | `points` | three ROWS stay; the HEADLINE gave way to 21px; money live from hole one |
| Wolf | `wolf` | the headline is the PRICE of the hole, not a standing |

**Points keeps three rows** where every other four-name card became a strip,
because the format is three-handed and the row count can never grow — the nine
points are DIVIDED, so a point you took is one neither of the others got and a
single number cannot describe it. Its headline gave way instead: the reader's
own total already sits three lines below at full weight, so the big number was
the only slot repeating something. Opposite call to Survivor, where the 36px
word was protected — the difference is duplication, not importance.

**Points' money is live from hole one** and still settled money, never a
forecast. The only card in the set where that holds, because there a hole IS
the settlement. Its per-hole award carries **no plus sign** (the card already
spends one on the money and one on the gross) and **mint marks the best award
on that hole, never the leader** — a leader who scrambled a 3 while somebody
else took the 5 reads dim, which is the column's whole job.

### Wolf's 17 and 18 — the packet's open question, settled

**Paul, 13 Sep: the lowest point total is wolf on 17; then recalculate, and the
lowest is wolf on 18.** The packet drew "the two lowest in points", which fixes
both seats off one standing — a different rule. The confirmed one resolves them
one at a time, so **the same golfer can be wolf twice** if 17 does not lift him
off the bottom; that is the point of a catch-up.

**The engine already worked this way** (`_last_place`, walked per hole with
"Advance standings for the NEXT hole's last-place calc"). Nothing changed;
`LastTwoHolesTests` exists so it is not "simplified" later.

Two Wolf bugs the tests caught, both mine:
- **`1–6 PTS` on a group that never plays blind.** `blind_wolf_points` has a
  non-zero default whether or not the rule is in force, so a naive `max()` over
  the table named a price nobody could pay. `_blind_on()` is the one line to
  replace if a real switch is ever added.
- **The strip reordered itself as money moved.** `summary['players']` is sorted
  by money for the leaderboard; the strip follows the **rotation**, or the
  `NEXT` label — which is about the seat — jumps around. Same finding as
  Survivor's track.

### The three-sided gate, and the flag that lied

Shipping a card is a server builder, `UNSHIPPED_KINDS` + the Swift layout, AND
`hasLiveActivity` in the Dart catalog. A previous session found that at two
after a Banker round played through hole one with a card that was ready and
never started. **Its test derived the Dart constant from the slug**, which
cannot match `strokePlay = 'low_net_round'` — it reported a wired card as
unwired. It resolves the constant by VALUE now.

Separately: **`canBePrimary: false` sat on Stableford while the picker offered
it as a primary anyway** (the picker filters on `sideGameOnly`; `canBePrimary`'s
only reader is a `primaryGames` getter nothing calls). I read the flag, believed
it, and wrote that the Stableford card could never appear. It can. **A flag with
no reader is documentation, and a wrong one is invisible until somebody
believes it.**

### Triple Cup — one composition, two games

The casual configuration is built. **The headline is the CUP SCORE, including
`0–0`** — Triple Cup exists to produce one, and the match in front of you is a
way of earning a point in it, which is a different question and gets the
smaller slot. An earlier design pass swapped the slots for the Fourball to
avoid `0–0` and it was wrong: *a headline that means one thing before the first
point and another after is a slot nobody can learn.*

The strip is four cells because **four points in a fixed order is the FORMAT,
not a guess** — which is precisely why Sixes cut its pips, since a round there
has no fixed number of matches.

Two constraints in this packet are requirements rather than preferences, and
both buy the strip's 16pt: the state slot is inline on one baseline, and **the
sides line is one row everywhere.** A row each for the two live Singles
measured 163pt, over the ceiling on its own; surnames buy both matches for
nothing. Yours first, always.

### The team cup — the same composition, a different view model

Both configurations now ship off one builder, and **what selects between them
is whether there is a cup score to report** — not a setting, not a flag. A
Triple Cup inside a Ryder Cup is a different product from four men playing for
twenty-five dollars, and `_cup_standings()` asks the only question that
separates them: does this round carry a cup config.

Six slots change meaning, none change position. The headline becomes the whole
cup (`6½–4½`), the right slot `12½ · TO WIN` — **your own match cannot go
there**, because the headline now counts twenty-four points and eleven other
golfers and a `1 up` beside it reads as a contradiction. Your match keeps the
sides line, written as a share of the cup (`Your Triple Cup · 1–0, in the
foursomes`) rather than as a match. The footer-left counts groups still out;
cup money settles in the team room.

**The cells become one needle**, and the rule that matters is that both fills
are shares of the points AVAILABLE, not of points scored. Normalised to points
played the grey band vanishes at the turn and the centre tick stops meaning
half the cup — the only thing on the card that answers *is it gone*.

Three things the spec did not settle, decided here:

- **`ROUND 2`, not the design's `DAY 2`.** The app has said rounds since it had
  them, and a cup can play two rounds in one day. Same argument that kept the
  Points payoff models in the config screen's words.
- **The sides line became a LIST of entries rather than one joined string**,
  each with a dim `note`. That is what lets the two live Singles share a row —
  and the casual card got it too, which is how `Kelly & Moran v. Reid &
  Naylor` gets its two dots back.
- **`_cup_palette()`.** A cup's teams have their own names and colours, and a
  blue headline over a slot reading `ORANGE TAKES IT` is the fourball's
  hardcoded-blue defect arriving by another route. Declared colours win when
  both are drawable and different; anything else falls back to position, where
  the two halves of the needle are at least distinguishable.

The cup can also clinch **while your group is on the fourteenth**, and when it
does it takes the state slot — the same rule that gives the casual cup its
`CANNOT LOSE`.

### The two pushes — `services/live_activity_cup_push.py`

The only alerting updates in the set. Everything else moves the board silently,
because a push for something the reader watched is a phone telling him what he
knows. **The team cup is the opposite case and the one the pattern was written
for:** points land in groups an hour ahead. But twenty-four points is
twenty-four pushes, and a golfer who turns the activity off loses the nineteen
that were worth having — so lead change and cup decided, and nothing else.

**A lead change is a property of two cup scores**, and the card is rebuilt from
scratch every request, so the last observed score lives on
`TeamTournament.last_cup_push` (migration `tournament/0071`). Three things fall
out of it: level counts as a lead change (from somebody to nobody) while a
second point that keeps it level does not; the clinch fires once instead of on
every score after it; and `cup_alert()` is called **once per posted score, not
once per recipient** — inside the loop it would fire four times for one
half-point and again for the group behind.

**Decided outranks lead change.** A clinch is by definition also a lead change,
and two pushes for one half-point is the noise this design exists to avoid.

*The body is not the design's copy.* `Group 2 took their Foursomes. First lead
change since the turn.` — neither half is derivable: no query attributes a
resolution to a group, and *since the turn* needs a history nothing keeps. It
says what is still out instead, which is what a captain asks next. **A push
that guesses is wrong on a lock screen**, which is the one place this set
refuses to be.

### Still to do

The final states, which are `{}` on all five builders.

### The five Swift layouts — and what the shared frame owed them

All five are drawn. Two needed views of their own; three did not, and the
reason is the same one that keeps this widget small: **a card earns a layout by
having a shape no other card has, not by being a different game.**

- **Stableford** and **Stroke Play** draw through `BoardView` unchanged. They
  are the shared composition — a name, one figure, a line naming who is ahead,
  the state, a footer — and adding views for them would have been three copies
  of it.
- **Wolf** draws through `BoardView` too, at a 21px headline instead of 36.
  Its headline is the PRICE of one hole and the four totals below it are the
  standing; a 36px price over a strip of 18px totals says the hole outranks
  the round. That is the only thing about Wolf the frame did not already do.
- **Points** and **Triple Cup** have their own (`PointsBoardView`,
  `TripleCupBoardView`) — three ranked rows with an award column, and four
  format cells with a tick at the winning line. Neither shape exists elsewhere.

**Two changes to the frame, and both were owed to every card, not to the five.**

*The headline and the state now share one baseline, with the sides line running
the full width beneath both.* They used to sit in a left column with the state
stacked top-right, which left a 15px slot floating against the top of a 36px
numeral and boxed the sides line into competing with it for width — the thing
that forces four surnames to shrink on the cards that have four.

*The state slot is inline:* `DORMIE · 2 TO PLAY`, not stacked. The packet
restated seven already-delivered cards to match rather than let the five new
ones read as a different family. Worth recording what it bought, because the
packet is honest about it and it is less than it looks: **17pt, and only where
this slot was the tallest thing in its row, which on most of them it was not.**

The dot beside a sides line now draws only when a colour is sent. **The dot
marks a SIDE** — Stableford, Stroke Play and Triple Cup have none (Triple Cup's
line names both matches in running text), so they send an empty colour and get
no dot. That was a rule the frame had been applying by accident.

### The widget type-checks from the command line

Discovered building these, and it should have been found much earlier:

```
cd mobile/ios/SixesActivity && xcrun -sdk iphoneos swiftc -typecheck \
  -target arm64-apple-ios16.2 *.swift
```

Clean exit, real diagnostics, no Xcode project and no build. Until now the only
check on this file was that the next IPA built. `swiftc -parse` is *not* a
substitute — it is syntax only and will happily accept a field that does not
exist.

### Four server bugs the layouts found

Building the view that draws a value is how you find out the value is wrong.

1. **Points printed `41.0 PTS`** — and `43.0` on every row, and `BY 2.0` in the
   state slot. Points are floats because a tied hole is SPLIT (5 and 3 become 4
   and 4), so the decimal is load-bearing *when it is a half* and noise on
   every whole number. `_pts()` formats with `:g`; two tests pin both halves of
   that.
2. **The reader and the leader were one field.** `colour: mint` meant *the
   reader* on the server and *the leader* in the design, and they are usually
   different men — the card would have marked the chaser as ahead in exactly
   the state that matters. Split: `colour` is the leader, new `is_reader` is
   the reader. A watcher gets the first and not the second, which is also what
   makes "nothing is bold on his card" fall out for free rather than need a
   case.
3. **Stableford had no leader line at all.** `sides: []`, so the slot the
   layout draws would have been permanently blank. `2ND` is the same fact
   whether the man in front is one point clear or eleven.
4. **Points rows carried a money column the card has no room for** — three more
   figures under a 160pt ceiling. The reader's own net is in the footer.

### The gate, now checked once for the whole set

`ShippingGateTests` replaces the per-card assertions: **no ungated kind may be
missing a layout**, keyed on the card kind rather than the game (two games can
share one card — `sequoya_threes` sends `sequoya`). The reverse direction is
allowed on purpose — the Swift lands first and the gate comes off in the commit
that bumps the build carrying it, so a gated kind with a layout is the only
safe sequence, and a test that forbade it would forbid the sequence.

All five stay in `UNSHIPPED_KINDS` until that build.

### The five final states — and the two that were already broken

**These five keep the BOARD.** Sixes, Skins, Match, Sequoya and Banker sign off
by replacing the card with three lines — what you won, who to see. The newer
packets do not, and the reason is the one that made their running cards worth
having: *the number a golfer spent four hours on is the last thing he wants
replaced at the 18th by a figure he cannot check.* So the slots are repurposed
and `final` stays null; `closed` is what tells the widget.

Both patterns are in the design record and they answer different questions. A
match card's last word is the settlement. A personal card's last word is still
the reader's own number, with the settlement beside it.

| Card | What moves |
| --- | --- |
| **Stableford** | Total stays; the state slot gains the **gross**, which the running card never had room for and which is what a golfer is asked for in the car park |
| **Stroke Play** | The two slots **swap** — `2ND` at 36px, the score beside the mode. When there is nothing left to do about the score, the place becomes the question |
| **Points** | The **money becomes the headline** (21→26px), and the award column turns from what a man won on the last hole into what he won on the round. All three rows survive — they are the card |
| **Wolf** | Points become money, and the headline is free for the first time all round: there is no hole, so no price. The strip loses its `WOLF` label and side rules, both of which described a hole that no longer exists |
| **Triple Cup** | **The headline does not move.** It has been the cup score since the third tee. The least-changed closing frame in the set, because the thing it reports is the thing that just finished |

Three departures from the mocks, all for the same reason — *the card must not
claim something the app cannot know*:

- **No `CUP RETAINED`.** Retaining is a holder keeping a cup he already had,
  and nothing tracks who held it last. `CUP WON` / `LOST` / `HALVED`, from the
  reader's side.
- **Stableford never names a man to collect from.** It is a pool; the ante was
  already in. Same reasoning Skins' final already used.
- **Stroke Play collects at the desk**, not from a golfer. Inventing a transfer
  sends somebody looking for a man who does not owe him anything.

### The bug this found: Banker and Sequoya never showed their final card

`Final` in Swift is `{amount, detail, collect}`, none optional. **Both were
sending `headline`.** That does not fail loudly — APNs accepts the push, the
phone cannot decode the content-state and drops the WHOLE thing, so the board
freezes on its last live frame and the card the round was building toward never
appears. Shipped, on two cards, for as long as they have existed.

Every per-card test asserted the *contents* of its own final. None asserted the
*shape*, because the shape is the contract with the other language and no card
owns it. `FinalStateShapeTests` now checks it across the set, in both
directions — and one Banker test was pinning the bug, asserting `headline`.

### Rabbit, Nassau and Survivor — and the rule that decides which card ends how

All three now have one, so **every card in the set signs off**. The test that
listed them as exceptions is now an assertion that the list is empty, which is
the only version that keeps working: a card added tomorrow with a `{}` final
fails there instead of being quietly appended to a set of allowances.

Building these settled a question the two patterns had left open. It is not
old cards versus new ones:

> **A card keeps its board when the board still has something to say, and gets
> the three-line replacement when it does not.**

Nassau is the clean case for the replacement. Its running frame is two match
rows and two named sides, and a settled nine *leaves the card* by the game's
own rule — a row that cannot change spends space on history. When the last one
settles there is no board with empty slots, there is nothing. Sixes, Skins,
Match, Sequoya and Banker are the same shape.

Rabbit and Survivor keep theirs: a headline, a state slot and a personal line
all still have something to report. Rabbit's headline turns into the money and
its state slot into `83 · GROSS`; Survivor's headline turns from *are you still
in it* into what that was worth, and its track — only ever about the Survivor
being played — comes off.

**Survivor's `who` row comes back**, which the fitted running card deleted on
purpose (19pt spent telling a man his own name). On the closing frame it is
doing a different job: this is the card that gets screenshotted and sent to the
group, and a money figure with no name on it is not evidence of anything.

Three pieces of copy that are about not reading like a loss — two of them the
Survivor packet's own open questions:

- **A Survivor that reaches 18 unresolved** (`no_blood`). Nobody was
  eliminated, so nobody pays. *Won 0 of 5* would be telling four men they all
  lost a leg nobody lost.
- **A Zombie win on 18** (`killed`) credits the trophy and pays nothing, which
  the engine already does deliberately. He genuinely won it, so it is named
  among the wins; it simply does not appear in the money.
- **Nassau with everything halved** says `Nothing settled`, not silence — on a
  card whose whole job was a money forecast, a blank reads as a failed fetch.

Rabbit's wins name **the extras as extras**, never as rabbits four and five: a
round that opens as three can finish as five, and a golfer told he won *rabbit
5* would go looking for it on a card that shows three.

`FinalView` also gained the footer it had been dropping. Every card signing off
that way was sending one; Nassau's `The range has converged` is what made it
visible, since it is that card's own argument for why it never needed a special
final treatment until now.

### The duplication lesson that did not take the first time

`gross_to_par` carries a comment about three copies of one traversal, each
guessing at the key a summary uses for per-hole scores, one of them guessing
wrong and failing **invisibly**. Building these finals I wrote four more — and
two of them read the `scorecard` block, which carries scores under `scores`
where the `holes` block carries them under `entries`. Both returned 0 and drew
an empty state slot. Exactly the failure the comment describes, in the same
file, under the comment.

There is now one `gross_total()` and one `par_total()` beside it, and every
card calls them. The one genuine exception is Stroke Play, whose holes belong
to the standings ROW rather than to the summary — noted at the call site so it
does not read as another stray copy.

Survivor also keeps a private `_gross_to_par` returning `(to_par, played)` for
the running card. Handing that tuple to the shared formatter is what drew
nothing on the first run of the closing card.

## Las Vegas lock screen — the card that carries arithmetic

`services/live_activity_las_vegas.py`, `VegasBoardView`. Spec:
`~/Downloads/handoff-las-vegas-lock/`.

Each hole a side's two net scores become digits — low as the tens — so a 4 and
a 5 is `45`. The lower number wins and the DIFFERENCE is the points. 45 against
57 is twelve points at a quarter a point; a birdie against a bad hole is
ninety. **Nothing else in the app swings like that, and nothing else asks a
golfer to do two-digit subtraction between shots.** That is the whole case for
the card, and it puts Vegas with Stableford rather than with Sixes.

At **129pt** it is the clearest card in the set, and what leaves the room is
the sides line doing two jobs in 18pt.

### The headline is SIGNED — a real departure

Every other match card headlines a *neutral* margin and names both sides,
because four golfers read the same string and the pairing changes at the turn.
**Vegas has no perspective problem to solve:** the sides are fixed at setup and
never change. So a signed figure that agrees with the money two rows below
beats a neutral one that does not.

The same fact settles the packet's sharpest open question. **The reader's own
side is blue, per phone** — assigned per reader, never per team record. On a
card whose headline is signed, two golfers in one group seeing the same hole in
opposite colours is not cosmetic.

### The flip needed an engine change, and that was the point

The card draws `67 → 76` with the old number struck through, so the swing is
shown rather than asserted. `VegasHoleResult.team{1,2}_number` is stored
POST-flip and the original was not recoverable — the flip is its own inverse,
so all that was missing was a flag.

`team{1,2}_flipped` and `team{1,2}_capped` now come off `calculate_vegas`
(migration `games/0079`), which is where the net scores and the birdie test
already are. **Re-deriving the birdie rule in the activity module would have
been a second copy of it**, waiting to disagree — the same failure mode as the
four `gross_total` implementations one commit earlier. Completed rounds show
`False` and simply draw no strike-through; any live round self-heals, because
the calculator deletes and rebuilds its rows on every score.

### The four open questions, answered

- **Which side is blue** — the reader's, per phone. Above.
- **Three-digit numbers** — impossible, confirmed rather than assumed:
  `_team_number()` caps each digit at 9 *before* composing, so 99 is the
  ceiling whatever the blow-up guard is set to. The line is built for two.
- **Multiply, drawn nowhere** — built anyway. Under multiply a birdie changes
  what the hole is WORTH rather than what the numbers are, so the state reads
  `24 PTS · DOUBLED` and the sides line carries no strike-through.
- **Strokes off the low man** — deliberately NOT in the header. It changes the
  inputs to the number; the birdie rule changes what a hole can be worth, and
  the card cannot show that any other way. One slot, and it goes to the rule
  that moves the money.

### One thing the packet did not account for

**A settled hole's `carry` is the carry it ABSORBED, not one pending.** The
engine records it on the row that consumed it and then resets. Reading the flag
alone put the `CARRY` chip up on the hole that *ended* the carry — the hole it
is least true of. The chip now requires a halved hole, and a settled hole that
absorbed one says `THE CARRY DOUBLED` instead, which the packet leaves silent
and which otherwise leaves a reader wondering why one hole was worth triple.

## Triple Nassau lock screen — three matches, and never the word DOWN

`services/live_activity_triple_nassau.py`, `TripleNassauBoardView`. Spec:
`~/Downloads/handoff-triple-nassau-lock/`.

Three golfers, no teams, every pair playing its own match — nine bets on the
round. **The card exists for one confusion: a golfer knows he is two up and
cannot remember two up on whom.** Two-player Nassau never has it (one opponent,
so a bare number is unambiguous); here a bare number is worthless, and the
whole design problem is attaching each score to its match inside the ceiling.
122pt, second clearest in the set.

The registry used to say three simultaneous pairings would not fit. **The grid
version proved it** — three matches across, two bets down, six figures. It fit
at 148pt and was unreadable: *a table of numbers on a phone held at a tee box
is a thing you resolve to look at later.* What fits is one bet at a time.

### Colour is load-bearing, not decoration

A figure wears the colour of **whoever is winning that match**, and there is no
`2 DN` anywhere on the card. That is not a style rule: a direction word is
relative to a reader, and in `BEN·CAL` **there is no reader to be relative
to** — `1 UP` between two other men is meaningless until you know which one.
Colour answers it inside the same glyph that carries the number and costs no
width.

**The reader is blue on his own phone**, assigned per reader. Same question Las
Vegas raised and sharper here, because three golfers in one group would
otherwise read the same match in three different schemes.

The third match — the two other men — is **held back and never dropped**,
because Triple Nassau settles three ways and the question after the round is
not *did I win* but *who owes whom*. **The dimming applies to the score, not
the identity:** the label keeps 9.5pt/68%, since an earlier design had it at
8pt/38%, measured 3.04:1 and went invisible under always-on — leaving a reader
able to see a score with no way to know whose it was, which is the exact
confusion the card exists to remove.

### The bug: the bet key followed settlements, not holes

The packet says the three matches are always on the same bet at the same time.
**That is true of holes and false of results.** A front nine can be 5&4 in two
matches and all square in the third.

My first `_bet_key` skipped a nine whose `result` was set, so with two matches
closed out it **jumped to the back nine on the eighth hole** — reporting a bet
with no holes played while two of the front nine were still to come. It now
keys on holes played. The clock is shared because the HOLES are shared; that is
the only sense in which it is shared.

A second one from the same root: a nine's `result` only appears once its ninth
hole is in, but a match decided 4&2 has been over for two holes. `_figure()`
reads `decided_margin` first, so a closed-out match goes quiet when it closes
rather than when the nine ends.

### Two reuse calls

`exposure_range()` now takes `game=None` and falls back to the summary's own
`play_front`/`play_back`/`play_overall` flags, so Triple Nassau sums the
**tested** two-player arithmetic across the reader's six bets instead of
carrying a second copy of it.

And Nassau's money line was the one place in the set using a hyphen where
everything else uses U+2212. Fixed, with the test helper taught to parse it —
at 11px beside a `+` the hyphen is visibly the wrong length, and that row sets
both within six characters of each other.

### One departure worth flagging

The packet specifies plum `#B48CF0` as "new to the set". **The set already has
a plum** — `#C9A6E8`, Survivor's Zombieville colour, already tuned for
lock-screen glass. Triple Nassau uses the existing token rather than
introducing a second purple two shades away: they never appear on the same
card, and two near-identical hexes for one semantic slot is how a palette
drifts. Worth a design confirmation.

## The Android board — a notification, because Android has no Live Activity

`services/live_activity_android.py`. **Off unless `ANDROID_BOARD=1`.**

There is no phone-side Android surface that behaves like a Live Activity: lock
screen widgets returned in Android 14 on TABLETS only, and Android 16's "Live
Updates" are a promoted ongoing notification shaped around a progress bar
(delivery, rideshare, navigation) and gated well above what the closed-test
fleet runs. So this does not port the card. It is a different object answering
the same question — **one notification per round that rewrites itself every
hole.**

**The whole composition layer is reused unchanged.** `activity_state(rnd, user)`
was already platform-neutral and already built per recipient (which is what
makes the money line right on each phone), so this module only flattens and
delivers. A game with a builder has an Android board for free; there is no
second list to add to.

It rides the hook that already exists — `api/views.py` `_push_lock_screen`,
which fires on every scoring AND betting change, runs `on_commit`, and swallows
its own exceptions. One call after the two APNs ones.

### What it does and does not do

**`AndroidNotification.tag` is the mechanism**: a second notification with the
same tag REPLACES the first instead of stacking, so four hours leaves one row
rather than eighteen. The tag is the ROUND (`halved-board-<id>`), not the
foursome — keyed on the foursome a TD watching a multi-group tournament would
carry one row per group, each claiming to be the board.

**Deliberately NOT `sticky=True`.** A sticky notification cannot be swiped away
and **FCM cannot cancel a notification it has displayed** — removing one needs
`NotificationManager.cancel` on the device, which is client code this tier does
not have. A sticky board would outlive its round and be undismissable.

**The text is a degraded view on purpose.** When FCM displays a notification
itself, the Firebase SDK uses `setContentText` with no `BigTextStyle` — so the
body is one truncated line with nothing to expand. The full ordered board still
travels as `lines` in the data payload, read by nothing today: a client that can
draw `BigTextStyle` or a RemoteViews layout renders the rich version with **no
server change**. That is the seam, and it is why `notification_text` returns
`lines` rather than only the two strings it can use.

**The body is ordered by what it costs to lose**, because the system truncates
it: ribbon (only present on a hole where the reader actually strokes), money
(the point of the game), segment (the card's own hole/par/yards corner), thru,
then the game LABEL last — the only one of the five a reader can infer from the
title and from being in the round at all.

**`channel_id` is named forward.** `halved_board` exists on no shipped build;
FCM falls back to the manifest's `halved_default` for a channel the app has not
created, so naming it is inert today and correct the moment the Kotlin lands.
Until then the board posts on the default channel and **makes a sound** — on
Android 8+ sound is a property of the CHANNEL, not of the message, so no field
here can silence it. `default_sound=False` would be theatre. **Tier 1 is ~15
lines of Kotlin in `MainActivity` creating `halved_board` at
`IMPORTANCE_LOW`**, and needs no server change at all.

`services/push.py` gained an `android` passthrough (a plain dict of tag /
collapse_key / channel_id / priority, resolved into an `AndroidConfig` in
`_send_fcm`) so `firebase_admin` stays confined to the module that owns the
credentials. `'board'` is its own `NOTIFICATION_CATEGORIES` entry, so muting the
board does not mute birdies.

### The three defects the real fleet found

Rendering all 51 live boards against the production database turned up three
things no fixture would have shown, because all three are shapes the cards emit
legitimately and draw correctly in a laid-out column. **Flattening to one line
is what exposes them.**

- **Sixes sends `—` as its state word** once a segment is done (5 of 51 boards).
  A dash between two middots reads as a value that failed to load.
- **Rabbit sends the same string twice** — `number.text` and `state.word` are
  both `LOOSE` while the rabbit is loose. The card draws them in two different
  places; one line printed `LOOSE · LOOSE`.
- **Nassau empties all three headline slots** on a finished round. The card
  survives it because its header and sides rows carry the round; an Android
  notification with no title renders as the app name alone, which reads as a
  fault rather than as a round that has ended. **The header is now the floor.**

### The double space that must NOT be fixed upstream

`live_activity_registry.group_stroke_band` emits `POPPING  YOU · MA` with a
deliberate double space, and its docstring says why: the label is a separate
span drawn at reduced opacity, and the gap is what separates the spans on a
build that has not learnt the layout. **That is correct there.** It is wrong
only in a notification, which is one run of text where the gap reads as a hole
in the sentence — so `_squash` collapses internal whitespace in this module and
the registry is left alone. (I went looking for a stray f-string before reading
the comment four lines above it.)

### The allowlist, and why empty means everyone

`ANDROID_BOARD_PHONES` is a comma-separated E.164 list narrowing the board to
those golfers — phones rather than user ids, following `accounts/otp.py`
`_review_bypass_phones`, because the phone is the identity the whole app
already matches on and it is a value you know rather than one you look up.
Normalized on both sides, so a pasted `(510) 282-3126` works.

**Empty means EVERYONE, not nobody.** `ANDROID_BOARD` is the feature switch and
this is a narrowing on top of it; a narrowing that defaulted to nobody would
make `ANDROID_BOARD=1` on its own do nothing at all — the shipped-tested-and-
unreachable failure this codebase has already hit twice (the casual receipt no
round could open, and the setup-edit button gated on the rule it replaced). A
switch that silently does nothing is worse than one that does the whole thing,
because the whole thing is at least visible.

The cost is that turning the feature on without also setting the list reaches
every Android phone following any round with a board. That is documented rather
than a trap, and it is why both are meant to be set in ONE change.

Checked BEFORE `activity_state`, which is the expensive call: a trial
restricted to one phone should not cost a summary per golfer.

Tests: `scoring/tests/test_live_activity_android.py` (40) — the flattener's
judgements as pure tests, the three fleet defects as regressions, and the
recipient claim: the set is the INTERSECTION of "can read this round" and "has
an Android phone", so an iOS follower who already has the real card never gets
the degraded one as well.

## The shotgun sweep — one mistake, six places

Run 17 Sep 2026 after a round at Ranch Solano turned up three shotgun bugs in
one afternoon. **The pattern is a single mistake made repeatedly:** the
play-order helpers (`services/hole_plan.play_order`) are correct and widely
used, but the code that SUMMARISES or SCORES a round keeps reaching for the
hole NUMBER where it means position in play order. On a round starting at the
1st the two are the same integer, which is exactly why it survives review.

Three shapes, and every finding is one of them:

| Shape | Reads | Should read |
|---|---|---|
| **Progress** | highest hole number scored | count of holes played |
| **Remaining** | `18 - hole_number` | holes left in the group's order |
| **Walk** | `for h in range(1, 19)` + `break` | the group's play order |

The third is the dangerous one, because `break` on the first unscored hole
means a shotgun group scores NOTHING — the walk starts at hole 1, finds no
score and stops — and then, as the back of the round comes in, scores those
holes while ignoring the ones already played.

### Fixed

- **`_round_current_hole`** (`api/views.py`) — the rounds list said "Through
  18" six holes into a shotgun. A round that looks finished.
- **`share_card.holes_played`** — the same bug one file over, on the share
  card and its link preview.
- **`calculate_vegas`** — the summary already ordered its chips by play order
  while the calculation carried ties by hole number, so a tie on the 18th lost
  its carry instead of doubling the 1st. **The display half was right and the
  money half was wrong.**
- **`cup_singles._play_18_hole_match`** — walked 1..18 with a `break`.
- **`cup_singles._compute_sub_match`** — its own copy of the remaining-count
  mistake, and the one that reached the card: six straight wins from the 13th
  reported "4 up, complete, finished on 16", because 18 − 16 = 2 while
  fourteen holes were still to come. **A cup point decided that was not.**
- **`quota_nassau`** — both the walk and the quota proration, which divided by
  hole number: six holes ending on the 18th demanded 18/18 of the quota.

Cup singles and Quota Nassau are **cup formats, and a cup day is very often a
shotgun** — the two places it matters most were the two with no test file at
all. Both have one now.

A closeout margin is now computed server-side (`holes_to_play` on the cup
singles summary) because only the server knows the order; the client prefers it
and keeps `18 - finished_on_hole` as a fallback for older payloads.

### The `&M` rule (second pass, 17 Sep 2026)

**The `M` in "3&2" ships from the server or it is wrong.** It is holes left in
the match's own window counted along the group's play order, and the client
cannot derive it from anything it holds. Every card now reads a
`holes_to_play` field; none of them subtract a hole number.

`fourball_summary`, `cup_singles_summary`, `cup_round_live_summary` and
`triple_cup_summary` all emit it (plus `f9_holes_to_play` / `b9_holes_to_play`
per nine). The two Dart helpers that took an `endHole` argument for the sole
purpose of computing `endHole - finishedOn` now take the count instead, so the
wrong sum is no longer expressible at those call sites.

Three things this pass turned up that the first sweep missed:

- **A segment can wrap the turn.** A Triple Cup third off a shotgun on the 8th
  is holes 14..1, where the last hole has the SMALLEST number. Every
  "finished early?" test of the form `finished_on_hole < end_hole` answered no,
  which dropped the `&M` and made the card claim the match ran to its scheduled
  end. Positions in `_match_hole_list`, never numbers.
- **`_compute_sub_match` takes the order, and five callers were not passing
  it** — including `services/ryder_cup.py`, which awards the cup POINTS from
  the result. A group's back nine runs 13..18,10,11,12 off a shotgun from the
  13th, so the leg went dormie a hole early: closed on 16 with two left when
  five of nine had been played with four to go. `test_cup_sub_match.py` pins
  the behaviour and greps the call sites, because the argument defaults and a
  caller who forgets it gets a plausible wrong answer rather than an error.
- **Sorting hole rows by `hole_number` un-does the sweep.** Both hole-result
  models order by number in their Meta, so `rows[-1]` is the highest number
  and not the last hole played: `cup_standings` read the running margin from a
  hole played nine holes earlier. Sort by play-order position.

### Checked and correct

`multi_skins` and `points_531` (no carry — order-independent), `irish_rumble`
(accumulates with `continue`, not `break`), `triple_cup` and `fourball` (both
already count by play position), `sixes` (uses `pos_of` throughout), and the
client's `.reduce(max)` calls, which compute the course SIZE rather than
progress.

### Deliberately not fixed

**`services/tournament_match_play.py` hardcodes semis on holes 1–9 and the
final on 10–18.** That is not an off-by-one to patch but a format question: a
bracket whose two rounds ARE the two nines cannot mean the same thing off a
shotgun, and deciding what it should mean (first nine played? still holes 1–9?)
is a rules call rather than a code one. Flagged rather than guessed.

**`services/tournament_match_play.py`'s two client labels** (`score_entry_
screen.dart:7381` and `:8177`) still read `round == 1 ? 9 : 18` to get a
scheduled end. They cannot be fixed before the format question above is
answered: the bracket's rounds ARE the two nines, so there is no correct
number to put there off a shotgun.

**`pink_ball_screen.dart:1564`** does `18 - lastHole` for a devil-ball match
result, and its payload has no `holes_to_play` yet. Same fix as fourball,
different engine.

### Still outstanding across the set

The rest of `changed-since-delivery/` is CSS-level and already matches how we
built it — the Skins header fix and the inlined state slot were the two parts
that applied.

---

## The day bet is a switch on the side games screen

The day bet is not an `active_games` entry — it is `DayBetConfig`, a
`OneToOne` on the round with its own endpoint — so it could not ride in
`SideGamesPicker`'s `selected` set, and for a while that was reason enough to
leave it off the list. **What that cost: the only way to turn one off was an
action inside `day_bet_setup_screen`, under the Save button.** A TD who wanted
no day bet went looking for a switch, found none, and reported that it could
not be turned off. Same shipped-and-unreachable shape as the casual receipt no
round could open and the setup-edit button gated on the rule it replaced.

It is a card in `SideGamesPicker` now, **last**, and it is an ORDINARY side
game. **The only thing that is special about it is where it appears**: the
final round of a multi-round event and nowhere else. Paul set that boundary
explicitly after a first pass made it special in two more ways — its switch
wrote at once and turning it on pushed the setup screen, which made it a
second kind of switch on one screen and needed a sentence on the card to
explain itself.

So: the switch is **moved here and written on Save**, with the games beside
it; `_dirty` covers it, so one Save covers the lot. Turning it ON posts
`entry_fee: 0, payouts: []` — on and worth nothing, which is exactly what a
game looks like between being switched on and being configured — and the fee
and prizes are set from the round hub's **Configure Day bet** button, the same
way Hot Spot's and Better Ball's are. Turning it OFF deletes the config.

- **The SERVER decides whether the card appears**, via the setup GET's
  `eligible`: it also wants a tournament and more than one round, so an
  ineligible round draws no card rather than a switch that would 400.
  `dayBetOn == null` ⇒ no card, which also covers the moment before the fetch
  lands, so nothing flips itself.
- **The hub's button is gated on `has_day_bet`**, not on `is_final_round`.
  `is_final_round` says one COULD live here; `has_day_bet` (new on
  `RoundSerializer`) says one does. Without it a day bet turned off left a
  live Configure route into a bet nobody was playing. Turning one ON is the
  switch's job; the button is only for its numbers, which is why it reads
  `Configure Day bet` rather than naming the game alone.
- **Off means GONE, and that is the one genuine exception** to this screen's
  "turning a game off leaves its setup in place": the day bet has no `active`
  flag — the config's existence IS its on switch — so its fee and prizes do
  not survive. Nothing scored is touched (standings derive from the round),
  and the footer says both halves.
- **`_save` only writes on a CHANGE.** Re-posting an untouched day bet would
  replace a TD's $4 and $20 with the blank defaults the moment he toggled it
  off and back on in one visit.
- `_SideGameCard` takes title/blurb/moneyNote **as strings, not a `GameMeta`**,
  because the day bet has no catalog entry; that is what keeps it from coming
  to look different from the games above it.
- A payout is `{place, amount}`, not a number. The first version of the note
  read it as a number and would have thrown on any configured day bet.
- The setup screen keeps its Turn off action. It and the switch both call
  `deleteDayBetSetup`, so there is nothing to drift.

**Every caller of the picker has to pass it, and a source test enforces
that.** The day bet went into `round_side_games_screen` and NOT into
`setup_round_players_screen`, which draws the same picker — so a TD going
through Edit Groups, which is how he reaches round 2, never saw it. Reported
exactly that way. `dayBetOn == null` means "no card", and that is also what a
caller who simply forgot looks like: there is no runtime difference between
declining to offer it and not knowing you could, which is why it is checked
at the source. `new_round_wizard` is the one exemption and carries its reason
(its own `_GameFeeCard` holds the fee and payout table inline, right for a
wizard where the round does not exist yet; the picker's card would be a
second control on one screen). A second test asserts the exempt file still
exists, because an exemption for a renamed file is an exemption for nothing.

Tests: the `the day bet` group in `mobile/test/side_games_picker_test.dart`
(6) — the card's presence is the thing worth pinning, since its absence is
what the bug was — plus `every caller offers the day bet` (2), and
`TheHubButtonFollowsTheSwitchTests` (`api/test_day_bet.py`), including that
an entry of $0 still counts as set up.

### `\$` in an API path is a 404 that looks like a missing endpoint

`_delete('/rounds/\$roundId/day-bet/setup/')` compiles, analyses clean and
passes every test, then asks the server for a round called literally
`$roundId`. **The asymmetry is what makes it expensive:** the POST beside it
had the correct string and worked, so the evidence pointed at the endpoint, at
permissions and at the round — everywhere except the string. Reported as "I
still can not Turn it off"; I diagnosed a stale round id first and was wrong.

Introduced by inserting a method through a script that escaped `$` without
needing to. `mobile/test/client_paths_test.dart` greps every `_get/_post/
_patch/_delete` path literal for an escaped `$`, and for the opposite slip (an
id written with no `$` at all, also a literal and also a 404). **Currency
strings legitimately use `\$`** — `'\$${fee}'` is a dollar sign then an
interpolation — which is why the test looks only inside path arguments.

## Hot Spot's anchor order — the sheet, and the per-POSITION lock

Three findings from one round at the course, all in `hot_spot_order_sheet.dart`
and its caller in `score_entry_screen.dart`.

**The sheet could not be dragged, and the gesture was there all along.** It was
built with `buildDefaultDragHandles: true`, which draws a handle on desktop
and NOTHING on a phone — it wraps each row in a
`ReorderableDelayedDragStartListener`, so the only gesture that moves a row is
a long press, under copy that said "drag". The long press worked; that is the
bug rather than its absence. **Every other reorder list in the app gives a
visible handle** — `wolf_screen`, `wolf_setup_screen`, `pink_ball_screen`,
`match_play_setup_screen`, `team_splitter_4`, `new_round_wizard`, six of six,
and `pink_ball_screen`'s own comment already says why. This sheet took the
default, which is why it is the one that broke. It now draws `drag_handle` in
the trailing slot at a 44pt target. All eight call sites still use the
deprecated `onReorder`; that is an app-wide sweep, not one file's business.

**Full names here, short names everywhere else.** Short is right over a 40pt
score box where the reader knows the group. This sheet asks a golfer which of
four men he is before anybody has hit a shot, and `P Lip` over `P Lee` is a
coin toss. The test measures a 24-character name on a 375pt screen beside the
holes label and the handle, because overflow is the risk a full name brings.

**It opens itself on the first tee.** Card order is not a choice the group
made: the server falls back to it so an unset order cannot make a round
unscoreable, but that fallback decides who anchors hole 1. `order_is_set` is
the server's own signal and its docstring already said the client should
prompt — it never did. Once per visit, dismissible, with the amber banner and
its Set order button left behind. The gate is `!order_fully_locked &&
!order_is_set` and **that is the whole of it**: `order_locked` is the server's
`has_any_real_score`, so nothing is scored, and `order_is_set` says nobody has
chosen. My first version also required `_selectedHole == playOrder.first`,
which is wrong twice — redundant (a scored hole would have locked it, so there
is nothing to review) and `_selectedHole` defaults to 1 while a shotgun group
off the 7th has `playOrder.first == 7`, so it would never have opened for
exactly the rounds a Hot Spot is played on.

### Each position locks as it is spent (Red Ball's rule)

`set_anchor_order` refused the WHOLE order at the first score. Not wrong about
hole 1 — wrong about holes 2, 3 and 4, which had decided nothing and could no
longer be arranged. A group that teed off and then noticed it had the back
three the wrong way round had no way back. Red Ball has locked positions
rather than the whole rotation since it shipped.

- **`spent_positions(foursome)` is a SET, not a leading count.** Position `p`
  anchors play-order positions p, p+n, p+2n…, so it is derived from the scored
  holes: a group that posts the 3rd first has spent position 3 and nothing
  else, which no leading count can describe (0 would let it move, 3 would
  freeze two positions that decided nothing). Red Ball's `lockedCount` has
  that gap and gets away with it. Counted along **play order**, so a shotgun
  group off the 7th spends position 1 on the 7th.
- **Re-posting the same order is not a change.** Without that, the sheet's own
  Save button would fail on a round under way — a lock that becomes a dead
  end.
- **The client permutes the FREE slots only** (`_reorder`). A plain
  `removeAt`/`insert` shifts everything between the indices, so a drag past a
  locked row would move the golfer who anchored a played hole. The free slots
  are treated as a list of their own, which is also what makes a
  non-contiguous lock work. A locked row draws `lock_outline` where its handle
  was and reads `anchored 1, 5, 9 — played`, past tense, on the row it applies
  to.
- **`order_locked` is unchanged on purpose** — still `has_any_real_score`, so
  the shipped client keeps hiding Change at the first score, which is the old
  all-or-nothing rule and is safe. The new pair is `order_positions_locked`
  and `order_fully_locked`, and the new client gates Change on the latter.
  Gating on `order_locked` would hide the way in at the first score, which is
  the bug.

Tests: `PositionsLockOneAtATimeTests` (`scoring/tests/test_hot_spot.py`, 10 —
including out-of-order entry and the shotgun), three in `api/test_hot_spot.py`,
and the `locked positions` group in `mobile/test/hot_spot_order_test.dart`
(7 — the locked row never moves even dragged through, and a legal move across
one steps over it). `test_the_first_score_locks_it` was renamed and the API
test's copy assertion updated: the behaviour is the same for a full reversal,
the message now names the position.

## Hot Spot's card and its anchor — two things nobody could see

Both reported from the course on the same round.

### The leaderboard card was unreadable, and the cause is a contract

`_HotSpotCard` hand-rolled its own bands into `PinnedHoleGrid` and **never
sized the cells**. That widget uses `cellWidth` for the scroll offset and the
rule's width only, and leaves the CALLER to put `width: cellWidth` on each
box — which `wolf_screen` and the other eleven callers do. The result on a
phone was eighteen hole numbers run together into
`123456789101112131415161718` with the scores crushed against the left edge.

It now draws through **`HoleGridScorecard`**, the card every other board uses,
which owns the geometry so it cannot be got wrong and brings the stroke-index
band, OUT / IN / TOT and the pinned label column the hand-rolled version had
no room for. If another game ever needs raw bands, the rule is: `PinnedHoleGrid`
sizes nothing.

That needed two things the payload lacked:
- `stroke_index` per hole.
- **gross + strokes.** The card's `scores` are the capped NETS the game is
  scored on, which is not what a scorecard prints. `_build_ir_score_index`
  gained a `detail` out-param — the same shape as the `capped_out` it already
  had — rather than a second walk over the same rows with the same allocator,
  which is the shape that eventually disagrees. **Strokes are recorded BEFORE
  the cap**: the dots show what was allocated, and a blow-up must not silently
  lose one.

**The anchor is gold, the other counted ball green.** The anchor is always one
of the counted when there is one, so marking it green too would hide the role
behind the result. The shared grid's gold key is now `role_id` (`banker_id`
still read beside it, because Banker is where it started and its payload still
says that), and it gained a `capped` per-score flag — last in the if-chain,
because how a number was arrived at never outranks what it did, and inert
everywhere that omits it.

### "I don't know who is in the hot spot on hole 2"

There IS a banner above the card and its data was correct. It is the wrong
place: a strip over the top of a card full of names is not where anybody looks
for which of four men it is, and **the anchor changes every hole**. It now
also draws as a gold `HOT SPOT` chip on that golfer's ROW, in the slot the
combo-tee chip uses — which is the row treatment the original handoff drew and
this file previously recorded as deferred.

`_HoleScoreCard.anchorId` is **not gated on the primary game**: Hot Spot
rotates the anchor every hole and the group needs it whether or not Hot Spot
is the round's headline. (Note `hotSpotIdx` on the same class is unrelated —
it is which row the entry cursor sits on, and the collision of names is
historical.)

**`Halved.role` / `roleFill` / `roleLine`** now hold the gold. It was private
to `hole_grid_scorecard.dart`, and the chip would have been a second copy of
three hexes: a reader who learns the colour on the board must not meet a
different shade in score entry.

**Not built, and explicitly declined:** highlighting the two counted scores in
score entry. Paul's reason is the right one — the counted pair is an outcome
of the hole, not the thing the group is deciding on the tee.

Tests: `TheCardDrawsGrossWithDotsTests` (`scoring/tests/test_hot_spot.py`, 5 —
including that the cap does not take a stroke away).

## Redrawing groups, and the swap a late arrival actually needs

### The redraw window asked the wrong question

A TD re-pairs for round 2 — leaders out last, or mixing the groups so the
same four men are not together all week. He could, exactly once: the Set Up
button rendered only while a round was `pending`, and **setting a round up
flips it to `in_progress`**, so the door shut the instant the draw was saved,
hours before anybody played, with no other route back to the pairings.

The gate is now `can_regroup` — has anybody teed off — answered by the server,
because the real rule is that `HoleScore.foursome` is **CASCADE** and that is
not a fact a phone can see. A drawn, unplayed round shows **Edit Groups** and
says in its subtitle that the groups can still change, so the window is
legible before it closes rather than discovered after.

**`setup_round` now refuses once a real score exists**, which it did not at
all. It opens by deleting every foursome in the round and CASCADE takes every
score with it, silently, in the same transaction; its docstring said the
function was "safely re-callable if you need to redo the draw", true of a
pending round and silent data loss on any other. Phantom scores do not count —
setup writes them itself, so a round would otherwise refuse to redraw on its
own output.

**Edit Groups starts from the draw it is editing.** The draw is sent as an
ordered list sliced by group sizes, so both come back: members in group order
and the sizes, read off the groups rather than recomputed, which is what
preserves a deliberate 3/4/4. The sibling-round field seeder is skipped when
this fires, or it would append another round's extra golfers to a draw being
adjusted.

### The late arrival needs a SWAP, not a move

`POST /rounds/{id}/move-player/` and its sheet were both fully written and the
sheet had **no caller** — a menu item was all that was missing, so the feature
had never run. Wiring it up surfaced the thing that makes it a swap:

> *Foursome 1 is short-rostered (3 real players) but no full 4-player group
> tees off before it.*

A group playing short takes its phantom's scores from a full group teeing off
AHEAD of it, so **the first group cannot go short** — and the first group is
exactly where the golfer stuck in traffic is. `validate_donor_foursomes`
refuses the plain move, correctly, and nothing about the move endpoint can
help him. A swap changes nobody's size, so the donor pool is untouched and the
first group tees off on time with four.

So the endpoint takes an optional `swap_with_player_id`. Notes:

- **Neither group may have started**, same as a move and for the same reason:
  a group that has scored holes as a given four must not be rewritten. Past
  that point a golfer leaving is `withdrew_after_hole`, which settles the
  money.
- **Each golfer keeps his OWN tee and handicaps.** A swap moves the golfer,
  not the tee box, and playing handicap is per-tee — carrying the other man's
  would re-net every hole he plays.
- **Cup groups are refused**, not reconfigured: swapping across cup sides
  changes what each match IS, which is a pairing decision rather than a late
  arrival.
- Mobile: the destination list **leads with the tee time** (the reason for the
  move) and a full group is **no longer greyed out** — it cannot take a fifth
  but it can trade, and disabling it hid the only option that works. Step 3
  offers the swap first, with "Just move him" below.

**The endpoint had no account scoping** — a bare `get_object_or_404(Round,
pk=pk)` where all 18 other round-level TD views use `account_get_or_404`, so
any authenticated user could rearrange any account's groups. Having no caller
is almost certainly why nobody noticed; wiring it up is what made it matter.

Tests: `api/test_regroup.py` (20) — including 18 posted scores surviving an
attempted redraw, the donor refusal that forces the swap, and the cross-account
404.

## The day bet: a tie is not a clean win, and the table is a shape

Two rules Paul settled on 10 Oct 2026, from one question — "what happens if
I have a tie for 2nd?"

### Excluded only if you won CLEANLY

`_championship_money_ids` excluded anyone with a championship payout. Combined
with the money model — ties split the money for the PLACES THEY OCCUPY — that
punished a tie twice. With $50/$30 on offer, two golfers tied for 2nd take 2nd
AND 3rd, 3rd pays nothing, so they get **$15 each instead of $30** — and were
then locked out of a $24 day bet the man who finished BEHIND them could still
win. **Tying for 2nd was worse than losing to the tie.**

A golfer is out only when **every place his tie group occupies pays**:

| finish | day bet |
|---|---|
| alone in 1st, alone in 2nd | out, pays nothing |
| two tied for 1st — they take 1st and 2nd, both pay | out, pays nothing |
| two tied for 2nd — they take 2nd and 3rd, 3rd pays $0 | **in**, and they pay the entry |

Tied rows share a rank, so the rank is the group key and the group occupies
`rank .. rank + size - 1`. A three-way tie for 1st against a two-place table
spills into 3rd and therefore comes back in too — not an oversight: nobody
won cleanly.

**The pot follows for free**, because `pool = entry_fee × len(eligible)`: an
eight-man $24 pot becomes **$28**. That figure is Paul's own and it is what
confirmed the reading of the rule — it only comes out if exactly one golfer
is excluded.

### `scale_to_pool` — the configured places, fitted to the money collected

The table is a SHAPE, not a set of amounts: the eligible count is not
knowable when the TD sets it, precisely because a tie can put golfers back
in. One place takes the lot; **more than one splits in the configured
PROPORTIONS** — $18/$6 against a $28 pot pays $21/$7, not $22/$6, because the
proportions are the only thing the TD actually chose. Rounds to the cent with
the remainder to FIRST, so the payouts sum to the pot exactly.

**This fixed something bigger than the tie.** The existing fixture is a $20
entry with six eligible — a **$120 pot** — against a table of $100 + $60 =
**$160**, and the board paid both places in full: $40 more than was ever
collected, with the TD making up the difference. The same test file asserted
`pool == 120.0` two tests below, so the contradiction was written down.
`test_the_board_never_pays_out_more_than_the_pot` is the invariant now; the
pool and the payouts used to be computed from different things and never
compared.

**Decided, not open:** `check_day_bet_floor` still checks the CONFIGURED
first prize against the championship's last paying place, even though the
figure actually collected is now the scaled one and can land either side of
it. Paul, 10 Oct 2026: *"we live with the anomaly... It will be small dollar
differences at that point and I am not worried about someone gaming it."*
Do not "fix" this later — the guard exists so nobody is better off DQ'ing
the 36 holes, and a scaled overshoot big enough to be worth gaming needs a
field far larger than this bet is played in.

### The odd cent — `split_tied_places` loses and invents money

Paul's actual priority: *"I am more concerned that the numbers add up."*
`split_tied_places` returns one figure **per RANK**, so three golfers sharing
$100 are each handed $33.33 and the board pays **$99.99**; $200 three ways
pays **$200.01**, a penny from nowhere.

**`split_to_cents` already solved this** — written for Team Play, and its own
docstring says that *"`round(total / n, 2)` — what the rest of this module
does — silently loses or invents money."* Diagnosed once, fixed in one game,
never swept. The day bet now pools per tied group and assigns **per GOLFER**
through it, so the board balances exactly; the odd cent lands on the first
golfer in BOARD order, arbitrary but stated and deterministic.

**NOT swept to the other nine callers** (flights, low_net_round, forty_balls,
red_ball, mini_singles, team_play_scoring, group_field,
tournament_settlement). A per-rank return structurally cannot carry an odd
cent, so a general fix means changing the shape at every call site — a
project, not a tidy-up. Flagged under Flights already.

**Writing a test for this:** three golfers all paying the same entry and all
tying divides EXACTLY every time — each gets his own entry back. The odd cent
needs a pot that does not divide by the size of the tie, so the fixture is
four golfers with three tied. Two of my fixtures were wrong this way first.

**Test-file shape:** `api/test_day_bet.py`'s fixture and its endpoint tests
were one class, so a subclass installing its own championship table re-ran
four of them against a fixture they were not written for and they failed for
reasons unrelated to the subject. Split into `_DayBetBase` (fixture) and
`DayBetEndpointTests` (tests); new classes take the base.

Tests: `ATieIsNotACleanWinTests` (6) and
`ThePotIsSharedInTheConfiguredProportionsTests` (7) in `api/test_day_bet.py`.

## "No data yet" was describing the wrong thing

Reported from a 40 Balls round with **128 scores in it**: the board said *No
data yet*. The scores were fine; the game had never been SET UP.

The chain: a tab exists for every game in `active_games`, but the server only
sends a `games[...]` block once the game is configured —
`forty_balls_summary` returns `{}` with no `FortyBallsConfig` and
`if summary:` drops it. The client then found no block and fell through to a
generic `Center(child: Text('No data yet.'))`.

**It was never that game's problem.** Every game switched on and left
unconfigured said the same thing, on a round full of scores. The fix is at
the generic branch, not in 40 Balls: `_NotSetUpYet` names the game and says
its stake and prizes have not been set, and points at the round's Game Setup
— which is where the setup screens are reached from, and which a tab cannot
take you to.

`game == null` for an ACTIVE game means "not configured", not "no scores":
a configured game with nothing scored still emits a block and draws its own
empty board. That is what makes the new message safe to state flatly.

Tests: `mobile/test/not_set_up_test.dart` — the message leads with
`gameDisplayName(gameKey)`, so a slug falling through would read
"forty_balls is not set up yet".

## The TD can close a round the field has not finished

Reported from PRODUCTION, 11 Oct 2026: *TPSGC 2026 Ryder Cup* would not move
to Completed. It was working as designed, and the design was wrong.

`RoundCompleteView` flips a MULTI-FOURSOME round only when every group has
its expected holes in. Round 420 had twelve groups and four short — group 7
on **0** holes, 8 on 12, 9 on **0**, 10 on 5 — so the POST returned **200
with the round unchanged**, the tournament stayed in Active (the list reads
`rounds.every(status == 'complete')`), and the only feedback was a
four-second snackbar saying the round would close "once every other group
also completes". Closed by hand over SSH.

**The guard is about a SCORER, not the TD.** Its own comment says it stops
the first foursome to finish locking its siblings out of scoring — a real
hazard, and entirely a hazard about a group scorer. The code already knew
the TD is a different person: the cup branch refuses a non-TD outright. He
is the one who knows two groups went home, and he had no way to say so.

- `POST /rounds/{id}/complete/` takes **`force`**, honoured only when
  `round.account_id == request.user.account_id`. A scorer passing it gets
  the ordinary wait.
- The response gained **`groups_outstanding`** — `{group_number, name,
  holes_scored, holes_expected}` per unfinished group — and
  **`can_force_complete`**. The client NEVER derives the second: offering a
  button the server will ignore is how you arrive back at the original bug.
- The dialog NAMES the groups and counts their holes. "Some groups have not
  finished" is not something a TD can act on; "Group 7 — 0 of 18" is. That
  was missing more than the force was.
- It says what closing costs (matches score on what is entered, a group with
  no scores counts for nothing) and that `RoundReopenView` exists.

**`all_foursomes_done` had no reader.** The server had been sending it since
the multi-group rule was written, precisely so the client could show this
state, and nothing consumed it — `_completeRound` re-derived the same thing
from `lb.status` instead. Worth a look whenever a response field exists for
a UI that does not draw it.

Tests: `api/test_force_complete.py` (8), including that a cross-account
scorer passing `force` still cannot close the round.

## `thru` has one writer — `group_field.holes_thru`

The 40 Balls board showed a group's budget (`34 of 40 · slack 6`) and nothing
saying how far round it was. Those answer different questions, and the board
needs both: a group at −5 **thru 9** and one at −5 **thru 17** are not in the
same position, which is the comparison the board exists for. `thru` now sits
beside the group's name, between it and the figures.

**It is NOT `18 - holes_left`.** A hole can be fully scored and still be
`pending` to the budget, because its balls have not been committed yet — and
the converse bites too: once the budget forces the tail the app writes a count
on every hole to the finish, so a committed hole with no scores is not played.
`forty_balls.group_card` emits `thru` from the played holes, never from the
budget.

Checked against the live round (533) before claiming it: there the two
coincide, because every scored hole already carries a count. The divergence
is a TRANSIENT, and it lands on every hole — the group posts its scores and
then picks, so for that window `18 - holes_left` under-reports by one, which
is precisely when somebody is looking at the board. The forced tail is the
case that is not transient.

**The definition was extracted rather than copied.** `services/group_field.py`
now exports `scored_holes_by_foursome(round)` (one query for the round) and
`holes_thru(round, foursome, played)`, and `group_standings` uses them too.
Every board that shows a thru figure has to answer it the same way; three
copies of one traversal with one of them wrong is the standing `gross_to_par`
lesson. The rules the helper carries:

- **Counted along the group's OWN play order**, never `Max('hole_number')` —
  the two are the same integer only off the 1st tee. The shotgun sweep's
  "progress" shape.
- **None, not 0**, before a group starts: the slot stays empty rather than
  claiming a hole.
- `group_card(foursome, scored_holes=None)` takes the batched map so the board
  asks once for every group; a single-group caller may pay for its own, which
  is why the argument is optional. Pinned by a spy test — an N+1 here is one
  extra round-wide query per group.

**`F` on the 40 Balls board is measured against the holes IN PLAY**, not
against 18, because that board has the list and a nine-hole round would
otherwise never finish. The shared group board still compares against 18;
that is older and was not this change's to fix.

**Extracting it broke the phantom branch**, which is worth recording because
of how it was found. Hoisting the query took two locals (`order`, `played`)
with it, and the `fs.has_phantom` block twenty lines below still used both —
a `NameError` on every group with a borrowed ball, in Irish Rumble's standings
and its money. Caught by READING the diff before the suite reached it; the
suite then confirmed it at exactly 5 errors, all phantom. A hoist that deletes
a variable's only assignment is invisible in the hunk that deletes it, so the
thing to check after one is every later use, not just the call site you
replaced.

Tests: `ThruTests` (`scoring/tests/test_forty_balls.py`, 7) and the five in
`mobile/test/forty_balls_test.dart`, one of which MEASURES the position —
"next to the team name" is a position, so presence alone would not pin it.

## Website SEO pipeline — `website/build-seo.py`

halved.golf is static HTML zipped to Cloudflare Pages (`website/build-zip.sh`).
`build-seo.py` runs inside `build-zip.sh` before zipping and **aborts the zip on
audit errors**. Standard library only. `./build-seo.py --check` writes nothing
and fails if anything is stale or wrong (for CI).

- **Generated `<head>` block** between `<!-- seo:begin … -->` / `<!-- seo:end -->`
  on every page, rebuilt from scratch each run — never hand-edit inside it. The
  page's own tags always win; the block only fills gaps (canonical, description,
  OG/Twitter) and adds the iOS Smart App Banner (`apple-itunes-app`) plus JSON-LD:
  Organization + WebSite + MobileApplication (home), CollectionPage + ItemList
  (`/games/`), Article + BreadcrumbList (each guide). FAQPage schema stays in
  `build-guides.py`. Game name for breadcrumbs comes from the H1 ("How to play X").
- **`sitemap.xml` is generated** — don't edit it. `<lastmod>` only moves when a
  page's content (minus the SEO block) changes, tracked by hash in
  `seo-manifest.json` (commit it). Rebuilding guides doesn't reset dates.
- **URL model:** `x/index.html` → `/x/`, `x.html` → `/x`. Canonicals/sitemap use
  those; the audit warns on links that redirect. **Pages canonicalises with a
  307 — temporary — not a 308**, measured against the live site 9 Oct 2026, and
  it does it to FOUR forms per page: `/x`, `/x/index.html`, `/x.html` and
  `/x/`. A temporary redirect never consolidates the duplicate pair, so
  `build_redirects()` emits an explicit **301** for every one of them into the
  generated half of `_redirects` (55 rules). Hand-written rules stay ABOVE the
  block and must point at the FINAL form — the Eclectic rule aimed at
  `/games/dream-round` and chained through a second hop to add the slash.
- **Search-tool verification:** `SITE_VERIFICATION` holds the meta-tag codes for
  Search Console, Ahrefs Webmaster Tools and Bing, emitted on the homepage only.
  Prefer DNS verification for Search Console (a Domain property in Cloudflare) and
  let Ahrefs/Bing import it — then these stay empty. Removing a code in use
  un-verifies the site.
- **Search copy overrides:** `OVERRIDES` replaces titles/descriptions that run past
  Google's limits, surviving guide rebuilds; `docs/seo-copy-for-design.md` carries
  them back to Design.
- **Config** at the top of the script: descriptions for pages without one,
  `NOINDEX`, and `PLAY_PACKAGE` — set it to `golf.halved.app` once Android leaves
  closed testing to add Android to the app schema.
- **Audit:** errors = missing title/description, canonical ≠ served URL, ≠1 H1,
  img without alt, invalid JSON-LD, broken internal links, duplicate titles,
  page missing from sitemap. Warnings = titles >65 chars, descriptions outside
  50–165, redirecting links, orphan pages.
- No `aggregateRating` in the app schema on purpose — never fabricate ratings;
  Google's app rich result needs real review data.

## Solo games — one golfer, and the opponent is par

`handoff-solo-games`. Three variants off one engine (`services/solo.py`,
`games.SoloGame`): **Stroke Play** (net total against par), **Nassau** (front,
back and all 18, each a match against par) and **Match Play** (one 18-hole
match, closing score when it is decided early). A hole against par is
**net under = won, net = halved, net over = lost**.

**Always Net, and always for fun.** There is no `handicap_mode` — a solo game
against par in gross is stroke play with extra words, and the allowance is the
whole point of playing par. `net_percent` is the only setting and it runs
**50–130%**: above 100 is deliberate and unique in the app, because a golfer
who wants par beatable gives himself more and nobody is paying. No stake, no
entry fee, no payout table, nothing in `round_settlement`.

**Par is not a player.** No phantom, no second card, no membership — every
hole is compared with `hole.par`. A phantom would need a handicap, a tee and a
place in every grouping rule in the app, to represent a number the scorecard
already prints.

- **`sizes: {1}`** is what keeps the three off every other picker: the casual
  screen filters on the size segment, so they appear under **Solo** (first in
  *Who's playing?*) and nowhere else. Their display names deliberately match
  the multi-player games — a golfer on his own is still playing Stroke Play —
  and no size filter matches both, so the two can never be shown together.
- **One `solo` block for all three** on the leaderboard
  (`games['solo']`, labelled with the game's own name), and the three slugs are
  stripped from the leaderboard's `active_games` the way `dream_round` is:
  leaving one in gave a solo Nassau round TWO tabs, the board and an empty
  `solo_nassau` that `_RawJsonView` printed as the payload. A solo round also
  gets **no generic Stroke Play tab** — a field of one is a single row with a
  $0 payout, which reads as a fault.

### The create flow skips the player step
A solo round goes **New Round → Tees → Create**. That step was already a
no-op: the logged-in golfer is auto-selected and LOCKED on it, and
`_createRound` refuses a second golfer, so the only correct action was to
press Next. Paul (Oct 2026) confirmed a solo round is always your own, which
is what the lock had always said.

Tees stays, because the tee decides the course handicap and the step exists so
the sex-based suggestion is confirmed rather than defaulted silently.

Two things the skip needs, both of which are about not stranding somebody on a
screen that is no longer there:
* **`_skipPlayerStep` requires the logged-in golfer to BE the selection.** A
  login with no `Player` row selects nobody, and skipping would walk into
  Create with an empty field.
* **Switching the size filter TO solo prunes the field to one.** Four golfers
  picked a moment earlier would otherwise reach Create as "a solo round is one
  golfer", with no screen left to fix it on.

Back undoes the jump rather than landing on the step Next skipped.

### Auto press (Nassau only) — Paul, 13 Oct 2026
`SoloGame.auto_press` (`games/0094`), **off by default** as `press_mode` is in
a real Nassau. A press here is an extra **MATCH, not an extra bet**: there is
no stake to double, so what it buys is a way back into a nine already lost.
Fires when **either side** goes 2, 4, 6 or 8 down, each level once, starting
the NEXT hole and running to the end of that nine — the same levels
(`services/nassau.AUTO_TOP_THRESHOLDS`) and the same next-hole start, so
nobody has to learn a second rule. Presses belong to the two NINES, never the
overall bet. Nothing is stored — a press is derived on every read, so
correcting a 6 to a 4 un-fires one.

**Par presses back**, and the first version got this wrong. It fired one way
only, on the argument that par has no agency — true of par as a NUMBER and
false of what the game is for. Paul: *"so that a user could simulate a full
match against a player shooting par with a 0 index. (Par shooter is
pressing)"*. A scratch player two down presses; one-directional presses make
that opponent a man who never fights back, which is the one thing a practice
match should not teach. Each press carries `pressed_by` — the margin is read
from the golfer's side whoever opened it, so the owner is not needed to SCORE
a press, only to say what happened, and the chip reads `F9 Par press 1`.

### No dedicated play screen — it plays through score entry
One golfer with no per-hole decision is exactly what `score_entry_screen`
already does, and a dedicated screen would have been ~600 lines of duplicated
entry machinery (pending scores, the offline overlay, withdrawal, the combo-tee
chip) for three read-outs. Those three read-outs are
`widgets/solo_board.dart`: `SoloStatusBar` (in the bottom bar above the pager,
beside `_CupSinglesStatusBar`), `SoloHoleLine` (under the hole card) and
`SoloScorecard`. `SoloBoard` in the same file is the leaderboard tab — a solo
round has no standings, so the board is those same three pieces.
- The app bar reads **`Nassau — Net 95%`** (`_soloTitle`): the allowance is the
  only setting the game has, and the one thing a golfer who gave himself 110%
  should be reminded of while he is beating par.
- **Red is a SIDE here, not a loss** — a deliberate deviation from
  `docs/color-standard.md`. Par is the opponent and the handoff names its
  colour. Quota Nassau already draws its sides blue and red.
- **The Won row's blue chip is the GOLFER'S OWN INITIAL**, against par's `P`.
  The handoff draws `P` against `P` and explains it as "Paul / Par", which
  reads as a rule about the letter and is really a fact about that golfer —
  Paul's initial happens to be par's. Dave gets a `D`. Paul (Oct 2026) on
  seeing it: *"the blue P … should be the first letter of the person's name."*
  `soloGolferMark` is the one place that decides it; an unnamed golfer gets
  `Y`, which agrees with the setup screen calling him You. A golfer who IS a
  P still collides, and the colours carry it, exactly as the mock draws.
- `HoleGridFooterRow` gained **`fill`** for that row: a tint drawn as a chip
  inside the grid's own box, so a caller can mark a hole without being handed a
  widget builder it could get the geometry wrong with.
- `HoleGridScorecard` gained `parColor` / `playerColor`, null on every other
  card — the other 18 read par as a baseline, and colouring it would say
  something untrue about it.

### Four defects found building it
- **`setup_solo` left the caller's Round holding a stale `solo_game`.**
  Creating one populates that reverse cache, so a SECOND setup made
  `solo_summary(round_obj)` — which the setup POST calls on that very instance
  — answer with the settings the golfer had just replaced.
- **Start Round passed the ROUND id to `/score-entry`, which wants a
  FOURSOME id.** The setup payload now carries `foursome_id`, as the
  stableford screen reads it off the loaded round.
- **The hub had no way back in**, so an allowance typed on the 1st tee was the
  allowance for the round. Solo is round-level, so it joins
  `_roundLevelEditTargets`; `configured_games` reports `solo_<variant>` so the
  button says Edit rather than Set up.
- **The hub's route passes no variant**, so the screen reads the STORED one.
  Defaulting there would re-open a Nassau round titled Stroke Play and save
  that — changing the game under a round being played.

Tests: `scoring/tests/test_solo.py` (33), `api/test_solo.py` (18),
`mobile/test/solo_board_test.dart` (15), `mobile/test/solo_setup_test.dart`
(12).

## Sixes — match 2 is the group's pick, not a reveal

`handoff-solo-games` §3, which **reverses** `handoff-sixes-draw`: match 2 was
an automatic, write-once draw. Nothing is drawn automatically now.

**What the reel actually was.** All three pairings were decided and stored at
SETUP, so the slot machine on the 6th green uncovered a pairing the server had
already written — `winnerIndex` always pointed at it, and nothing about the
teams could change when it ran. The group chooses now: spin for it, or tap
`Pick the teams instead` and set them by hand.

**Two options, not a free drag.** Four golfers pair off three ways; match 1 is
one of them, so two are left — and choosing one FORCES the other, which is the
guarantee that everybody partners everybody exactly once. A free drag could
repeat match 1's pairing and leave match 3 underivable, so the picker offers
the two legal pairings and the last match is derived. (The handoff says
"drags the teams"; with two options a drag would be a worse control than a
tap, and the design's own screen lists them as candidates A and B.)

- **Setup sends match 1 only.** `setup_sixes` creates a segment with NO TEAM
  ROWS when the ids are missing — not team rows with no players, which is the
  extra match's long-standing shape and what keeps
  `SixesConfiguredGamesTests`' invariant true. `_score_segment` already
  answered `pending` for a segment with fewer than two teams, and
  `configured_games` stays honest because match 1 has its teams: a second
  golfer opening the round still goes to score entry, not the picker.
- **`services.sixes.set_segment_teams`** is a separate writer from
  `setup_sixes`, and the reasons are the two things that function does that
  are wrong here: it DELETES every segment and rebuilds (taking a spawned
  extra's teams with it), and it refuses outright while any segment is
  `is_void` — so a group with a withdrawal could never pick match 2 at all.
  It sets the chosen match, forces the remaining one, and recalculates.
- **`remaining_pairings` ships on the summary**, because which two are legal
  is the format's rule and a client deriving it would be a second copy. It is
  emitted whenever there ARE two, not only while a match is waiting for them:
  the group may still swap before teeing off, and a list that emptied the
  moment the teams were stored would leave the picker with nothing to re-open
  on.
- **`POST /api/foursomes/{id}/sixes/segment-teams/`**; `extra-teams` is
  untouched, since an extra is a free drag of all four and not part of the
  rotation.

### The lock is per MATCH, and "any scored hole" would have killed it
Refused once a real golfer has posted a score on one of **that match's**
holes — but **setting teams for the first time is always free**, whatever has
been scored. That case is normal rather than exotic: when match 1 closes out
early the group plays on, `calculate_sixes` hands those holes to match 2, and
match 2 routinely has scored holes before anybody is asked to pick its
partners. A lock reading "any scored hole" would have refused the very first
pick and left the picker permanently dead — the shipped-and-unreachable shape
this repo keeps hitting. What it protects is a hole scored AS part of a match
being re-scored under different teams, which needs teams to have existed.

It does **not** borrow `edit_window.closed_reason`: that names the round-wide
3-hole ceiling, and quoting a number that has nothing to do with the refusal
is worse than writing one sentence.

### Mobile
- `shouldRevealSixesSegmentTwoDraw` is gone, and **the per-device "already
  shown" `SharedPreferences` flag with it** — it was a convenience standing in
  for the rule, and it is the wrong shape for a decision: a reinstall or a
  second phone lost it, and a draw that has not happened yet has to be
  openable on any phone in the group. `sixesMatchNeedingTeams` /
  `shouldOpenSixesTeamPicker` replace it.
- `SixesSegmentDrawScreen` gained `allowManualPick` and now pops
  **`(int index, bool byHand)`** rather than `bool`: the caller records how the
  pair was formed (`random` against `loser_choice`) instead of guessing from
  the index, since a group that spins and then picks the same pairing by hand
  would otherwise be indistinguishable from one that accepted the reel.
- **The pre-spin note is deleted.** It read "Result is drawn before it
  animates", true of a reveal and now false — a line explaining that the
  answer already exists would be describing a different screen.
- The entry-card gate was extra-only (`_unconfiguredExtraForHole`) and now
  covers standard matches too, so scores cannot be posted into a match with no
  sides. Only the EXTRA auto-opens from that gate; a standard match has its
  own moment (the match before it being decided), and popping a second picker
  because the scorer scrolled onto its first hole would ask twice.
- **Edit Configuration re-posts the teams it already has.** `setup_sixes`
  rebuilds from what it is sent, so an edit posting empty teams for matches 2
  and 3 would silently un-pick match 2 — a TD opening the screen to change the
  stake. They are dropped only when match 1 has been RE-DRAWN, because the
  rotation hangs off it.

**Not built:** an in-round "change the teams we just set" button. The draw
screen's own `Change teams` covers the moment the group is actually in (they
have spun and not yet confirmed), and the server permits a change until the
match tees off — so the capability is there and only the second surface is
missing.

Tests: `MatchTwoPickerTests` (`scoring/tests/test_sixes.py`, 15 —
including the early close-out and the withdrawal that used to wedge it),
`api/test_sixes_segment_teams.py` (6) and the rewritten
`mobile/test/sixes_draw_reveal_test.dart` (9). Not to be confused with
`MatchTwoIsTheGroupsToPickTests`, which is older and covers the SETUP path's
narrowing — re-posting all three segments, which is what Edit Configuration
still does.

## Multi-Group Skins — who shares a scorecard

A group in a casual Multi-Group Skins round is a `Foursome`, which is a
scorecard, which is **one person keeping the score**; the pool federates
across them, which is the game. So the sizes are genuinely arbitrary.

**Every selected golfer was seated solo, with no control to say otherwise.**
`71cf970` (13 Jul 2026) replaced the per-golfer `G1 / G2` dropdown with
automatic solo groups, on the feedback that the dropdown was easy to miss.
Paul, 12 Oct 2026: that change was made for one specific round and he missed
that it changed the design. His round that day was a 15-foursome shotgun whose
pool was **one full foursome playing together, two individuals and a twosome —
4, 1, 1, 2**. Neither "everyone solo" nor "fill groups of four" describes it.

### A step, not a block
`Groups` sits between Players and Tees and is shown **only for Multi-Group
Skins** (`_hasGroupsStep`; the tee step becomes 3). It is a step because the
thing being fixed is that the control could not be FOUND — a block under a
roster list that scrolls is the same trap one layer down. Each group draws a
header and its golfers, every golfer has a **Move** button, and the move sheet
lists the other groups BY WHO IS ON THEM: the old dropdown offered `G1 / G2`,
which says nothing about the only thing a golfer deciding this cares about.

Solo stays the default on selection (most of a pool is spread across the
field); the work is saying which few play together. Group NUMBERS can have
gaps — moving the last golfer off card 2 leaves 1 and 3 — so the label comes
from POSITION and the list never reads "Group 1, Group 3".

### A login-less golfer can play, if somebody can score him
The picker greyed out every non-Halved golfer for this game. The engine never
required that — `services.multi_skins.valid_participant_ids` admits host-round
members "(login-less OK)" — and it cannot describe the ordinary case: a guest
in a foursome that has a scorer.

Paul named two cases and they differ: **when skins is the only game being
played** (this screen) a guest may join *"only when sharing a card with
somebody on halved"*, because nobody else can enter his score; when skins is
**attached to groups that already exist** (a linked round, a tournament
foursome) the group already has a scorer and the question does not arise.

So the grey-out is gone and the rule moved to the Groups step, where it is
fixable: `utils/skins_cards.cardsProblem` names the golfer and blocks Next.
**Two guests together are still stranded** — sharing a card with somebody who
also cannot score it changes nothing.

`cardsProblem` is also the gate at Create, replacing a second copy of the
group-size check that lived there — and whose comment still described "a user
could overstuff a group by manually reassigning", guarding a control that had
not existed for three months.

Tests: `mobile/test/skins_cards_test.dart` (11 — the sizes, the gap, and both
halves of the scoring rule), `mobile/test/scorecard_groups_test.dart` (9 — the
positional labels, the full group, and that the move sheet NAMES who is on
each one) and `api/test_multi_skins_groups.py` (3 — the server takes 4/1/1/2,
pads nobody into the short groups, and the pool scores across four different
cards).

### From the hub, once the round exists
`Groups & golfers` on the hub's Multi-Group Skins card (`/round-groups` →
`RoundGroupsScreen`). **The two halves have different rules and the screen
says so**, because they are different operations:

* **Re-grouping rewrites the draw**, so it goes through `setup_round` and the
  server refuses it once anybody in the round has teed off — that function
  deletes and rebuilds the foursomes and `HoleScore.foursome` is CASCADE. The
  screen reads `hasAnyScore` and draws the groups read-only with the reason,
  rather than offering a Save the server would reject.
* **Adding a golfer on a card of his own touches nothing that exists**, so it
  works whenever the round is live. `POST /api/rounds/{id}/add-player/`
  (`RoundAddPlayerView`) seats him, computes his par-adjusted playing
  handicap, and adds him to the pool if the round has one — a golfer seated in
  a skins round who is not in the pool would be scoring for nothing. Joining
  an EXISTING group is refused once that group has scored a hole: his tee can
  lower the group's minimum par, which re-derives every other member's playing
  handicap, and those are the numbers their played holes were scored against.

The pool's own card already carried `Edit configuration`, whose roster can add
an **on-app** golfer mid-round (`reconcile_pool_seating` seats him solo —
which is the same move this endpoint makes, and where the confidence that it
is safe comes from). What it cannot do is seat a GUEST, because
`valid_participant_ids` filters a golfer who is neither a host-round member
nor on Halved — so he can never be seated, and so never becomes a member. That
chicken-and-egg is what the endpoint breaks.

**`_roundLevelEditTargets` is NOT where this went**, and the first attempt put
it there: that list renders inside a foursome card behind
`allFoursomes.length == 1`, and a pool is never one foursome. It would have
been a button nobody could reach — the failure this file records twice
already. `mobile/test/round_groups_reachable_test.dart` pins the wiring
instead of the widget tree.

#### The POOL ROSTER refused a seated guest too
Reported from testing, 13 Oct 2026: a guest in the TD's own foursome — his
score kept on that card like everyone else's — was **missing from the skins
leaderboard while appearing on the round's Stroke Play tab**, and linking a
Sixes round reported an overlap of two golfers when three were in it.

`multi_skins_setup_screen` carried the same Halved-only assumption the
picker's grey-out did: a login-less round member's checkbox was DISABLED
("Not on Halved — invite them to include them"), so he could never ante in.
Everything downstream then behaved correctly on a roster he was not in.

**The engine was never the problem.** `valid_participant_ids` admits
host-round members "(login-less OK)", and both `pool_overlap` and
`_resolve_participant_memberships` match on **exact player id before phone** —
the latter's docstring naming this very case, *"a login-less roster golfer
parked in the host round who actually PLAYS in a linked Sixes round"*. Within
one account the same `Player` row is in both rounds, so no phone match is
needed; the Halved requirement is about CROSS-ACCOUNT federation.

The rule now is the same one the Groups step enforces, stated per golfer
(`utils/skins_cards.canJoinPool`): a guest may join when somebody ELSE on his
scorecard is on Halved. His row says which — `scored on Group 1's card` — or,
when nobody can, `Needs somebody on Halved on his card`, which is a thing to
fix rather than a fact about him.

**Two statements of one rule, and they must agree.** `cardsProblem` answers
for a whole draw and `canJoinPool` for one row, because they are asked at
different moments; a test pins them against each other.

#### ...and so did the API boundary, which is where it actually bit
The screen fix above let the TD tick the guest; **the save then came back
400**: *"Everyone in a Multi-Group Skins pool must be on Halved."*

`not_on_app_ids` is a blanket Halved-only check run at the boundary of
`MultiSkinsSetupView`, and it knew nothing about the round. So it
**contradicted `valid_participant_ids`** — one filtered silently and kept
host-round members, the other refused the whole roster — and the boundary
won, which is why a guest in the TD's own foursome could not be in the pool
at all.

It now takes `round_obj` and exempts a golfer **already seated in this
round**: he is found by his MEMBERSHIP, not by a phone match, and
`_resolve_participant_memberships` matches on exact player id before it ever
looks at a phone. A golfer from OUTSIDE the round still has to be on Halved,
because he is scored in his own round and phone identity is the only key a
cross-account pool has.

`api/test_skins_pool.py::test_setup_rejects_non_halved_member` **had pinned
the bug**: it seated the golfer in the host round and asserted the refusal.
It now asserts the opposite, with a sibling that keeps the outsider refused.

The lesson worth carrying: two functions answering "may this golfer be in the
pool" disagreed for months, and the one with the stricter answer was the one
nobody had read. Both are now reachable from one docstring.

#### The strict rule stays, and so do the multiple Moves
Both confirmed by Paul (13 Oct 2026) after testing, and both worth recording
because the arguments against them are the obvious ones:

* **The on-Halved requirement is NOT relaxed for a round the TD could score
  himself.** It is true that an account owner can enter scores for every group
  in his own round — but *"because the golfers are spread throughout the
  course, I want to keep the in a foursome with an app strict"*. He is out
  playing; a card two fairways away is not one he can keep.
* **Assembling a foursome one Move at a time is fine** — *"I don't mind
  multiple moves for a foursome"* — so the multi-select "these play together"
  alternative is deliberately not built.

And the sentence that bounds the whole feature: *"If most are in a foursome,
then it is a tournament, not a skins game."* A pool is spread out BY
DEFINITION. A design that optimises for everybody playing together is
optimising for a different product.

#### `is_on_app` was False for every golfer in a round
Reported from the Groups screen on the hub: it told a TD that **seven golfers
were not on Halved when six of them were**, and refused to save his draw over
it.

`PlayerSerializer.is_on_app` is a **context-fed field** — it reads
`context['on_app_phones']`, and only `PlayerListView` filled it. Everywhere
else it answers False, which its own docstring described as the default "for
single-player uses (login/me)". A ROUND payload nests `PlayerSerializer` under
every membership, so it inherited that default and quietly claimed nobody in
the round had an account.

`round_payload_context(round_obj, request)` builds it once for the whole
round, at every call site that hands a round back for the client to draw. On
the hub's own fetch that costs ONE query and no more: `_ROUND_QS` already
prefetches `foursomes__memberships__player`.

The casual create screen was never wrong — it reads its golfers from
`getPlayers()`, which is the endpoint that fills the context. Which is also
why this took a new consumer to find.

Tests: `api/test_multi_skins_groups.py` (16 — `AddPlayerTests` and
`RoundPayloadKnowsWhoIsOnHalvedTests`) and
`mobile/test/round_groups_reachable_test.dart` (6).

## Hot Spot is now Hot Seat — the name moved, the id did not

`~/Downloads/handoff-hot-seat/RENAME.md` (15 Oct 2026). The game is unchanged:
one anchor per hole whose score always counts, plus the best net of the other
three. The two sections above that still say **Hot Spot** describe this game.

**`GameType.HOT_SPOT`'s VALUE is still `hot_spot`**, and the two halves of
that pull opposite ways, which is why there is a test pinning both
(`test_the_key_is_the_old_slug_and_the_label_is_the_new_name`):

- Renaming the value to match the label would orphan every round already
  holding it — `Round.active_games`, a cup config's `game_type`, and the
  **leaderboard key the client tabs off**. The rename doc asks for exactly
  this ("keep it as the stored ID … only the display name has to change").
- Leaving the label would leave the app calling it by a name the website, the
  guide and the organiser no longer use.

So the slug is history and the label is the name. Routes
(`/rounds/<pk>/hot-spot/`), class names (`HotSpotConfig`), file names
(`services/hot_spot.py`, `hot_spot_order_sheet.dart`) and the comments that
describe the game all keep the old spelling — the same call the Ryder Cup
scrub made, with a note at each entry point (`core/models.py`, the service
docstring, the catalog entry) so the next reader does not have to infer that
two names mean one game. **Seven golfer-facing strings moved**: the catalog
`displayName` and its money note, the setup app bar, `Configure Hot Seat` on
the hub, the order prompt in score entry, the order sheet's title, and the
leaderboard's not-set-up line — plus the server's leaderboard `label`.

`tournament/0079_hot_seat_label` is labels and `help_text` only; **its SQL is
empty** and no row changes.

**Two RENAME items were already no-ops.** The app never links to
`halved.golf/games/<slug>`, so there are no deep links or share URLs to teach
both spellings; and the anchor banner's button has always read `Change`, not
the doc's `Change Hot Spot order`.

**Not renamed: the lock screen.** Section 4 of the handoff is marked a
proposal and the card was never built — `hasLiveActivity: false` in the
catalog, and no Swift or builder references it at all. There is no `HOT SEAT`
header to change.

### The web half, and why the handoff's page was not used

`web/hot-seat.html` is offered as publish-ready. Diffed against the live page
with the name normalised, the **content is identical** and the only other
difference is its links: `/games/` and the three related-game links come back
as `https://halved.golf/games` — absolute, and **without the trailing slash**.
Under this site's URL model that is the redirecting form, so adopting the file
would have silently traded five audit-clean internal links for five 301s on
the one page the rename is about. The design-system export is what does this
(the handoff says so of `design-reference/`, just not of this file).

So `games/hot-spot/` was **renamed** and its strings changed in place.

`web/hot-spot-redirect.html` is deliberately unused. It is the handoff's own
stopgap for "if a server redirect can't go out the same day", and `_redirects`
already carries the reason it would be actively harmful: a static file at the
old path **shadows** the redirect rule and keeps the old name serving as
duplicate content. That is the Eclectic lesson, and this rename is the same
shape — hand-written 301s above the generated block, pointing at the final
slashed form, with the old directory deleted rather than left behind.

### Hot Seat joins the Road Trip sheet — and the family exclusion it exposed

`kRoadTripFieldGames` offered four games and `RoundFieldGamesView.FIELD_GAMES`
held the same four, so the two agreed and nothing was broken — Hot Seat was
simply never offered. It was reachable from the per-round side-games screen
(which saves through `client.updateRound`) and not from the trip's own sheet,
**one game reachable from one screen and not the other**, the shape the day
bet arrived in. Hot Seat is recent (`games/0091`) and this list predates it.

Both halves moved together, because a chip the server refuses is worse than
no chip: `hot_spot` is in `FIELD_GAMES` and in the sheet, with a test
asserting both.

**The one-pool family is now enforced on this path.** Irish Rumble, Better
Ball, Hot Seat and 40 Balls are one competition scored four ways — one pool,
one board, the same groups ranked — so a round runs one. The endpoint had NO
such check and would happily write two; `test_setting_them_writes_the_round_s_list`
posted `irish_rumble` + `forty_balls` and asserted both landed, so the hole
was pinned as behaviour. Adding a fourth member to a free multi-select sheet
is what made it worth closing.

- The sheet calls the shared **`applyGameToggle`**, the same function the
  new-round wizard uses, reading the catalog's own `excludes`. Turning one on
  turns an incompatible one OFF rather than greying it out — a TD who taps the
  second has changed his mind, not made a mistake to block.
- `ONE_OF_THESE` repeats it server-side, because an endpoint that trusts the
  client for a rule has no rule. **Stroke Play is deliberately not in it**: it
  is an overlay the board emits for every individual-ball round and sits
  beside any of them.
- Worth knowing how thin the rest is: of the family's six pairs **only
  Rumble ↔ Better Ball is guarded in the services**
  (`refuse_if_better_ball` / `_refuse_if_rumble`). Hot Seat and 40 Balls guard
  nothing, so for the other five pairs this endpoint and the pickers are the
  whole of it. The catalog comment claiming the exclusion is "enforced on the
  server in both services too" is true of that one pair and of no other.

**`_notify_field_games` built its labels by hand and indexed them with
`labels[g]`** — a game in `FIELD_GAMES` and missing from the dict is a
KeyError inside a best-effort notify, i.e. a 500 on a change the TD has
already saved. It reads `GameType(g).label` now, with `low_net_round`
overridden to Stroke Play (the enum says "Low Net (Round)"), and a test walks
all five. That dict was also a second place Hot Seat is named, which is the
other reason it went: the rename would have left it announcing the old name.

**The sheet's labels come from `gameDisplayName` too.** `kRoadTripFieldGames`
was a list of `(id, label)` tuples, so the screen named every game a second
time — and the round card's chips read from it. It is a list of ids now and
`kFieldGameLabel` delegates to the catalog, which is what makes the next
rename one edit instead of a search.

**The sheet now SAYS the rule**, in copy derived from the catalog rather than
typed: `kOnePoolFieldGames` is the offered games that exclude at least one
other offered game, so the sentence cannot name three games on a screen that
offers four, and Stroke Play falls out of it on its own rather than being
special-cased. A chip that silently deselects another is visible but
unexplained, and the TD needs to know which games trade off.

#### The wizard let Hot Seat and Irish Rumble both stay on

Found while wiring the above, and older than it. `GameMeta.excludes` was
**asymmetric**: Hot Seat excluded the other three, and none of the three
excluded it back. `gamesCompatible()` is symmetric, so the pair looked
guarded — but `new_round_wizard.dart` reads `gameMeta(g)?.excludes` DIRECTLY
and one way, removing what the game being turned ON excludes. Turning Hot
Seat on cleared the others; turning Irish Rumble on afterwards left Hot Seat
exactly where it was, and with only one of the six pairs guarded in the
services nothing downstream caught it.

**`forty_balls_test` already had a test for this and its comment states the
hazard in as many words.** It listed six ordered pairs by hand when the family
had three games; Hot Seat arrived later with its own three edges and no
reverse ones, so the test went on passing about the three games it knew. The
pairs are DERIVED from the family now — a fifth game joins the loop or fails
there — and it asserts `gamesCompatible` as well as the raw set, because
those are the two ways callers ask and only one of them was ever wrong.

The lesson is the hand-written list, not the missing edge: an exhaustive test
that enumerates today's cases stops being exhaustive the moment the set grows,
and it fails silently by continuing to pass.

### Sixes' match-2 anchor was picked out of a set

Found because the Road Trip tests above tripped it: adding three tests to
`api/test_road_trip.py` shifted the pk sequence, and
`MatchTwoPickerTests.test_the_anchor_stays_on_team_one_in_both_options` went
red after months of passing. Nothing in Sixes had changed.

`remaining_pairings` keeps match 1's team-1 **anchor** on team 1 in both
options, so the two read as "who Ann partners next" rather than as four
unrelated names. It took that anchor with `next(iter(first[0]))`, and
`first[0]` is a frozenset — so the choice was by pk VALUE:
`next(iter({7, 8}))` is 8, `next(iter({23, 24}))` is 24. Which of match 1's
two golfers anchored depended on the ids those rows happened to get.

**Both readings satisfy the promise**, which is why nothing ever looked
wrong: the options still read as "who somebody partners next", just not
always the same somebody. What it cost was explainability and a test. It is
`anchor_of(side, roster_order)` now — the first of team 1 in **creation
order**, which `FoursomeMembership.Meta.ordering = ['id']` already
guarantees and which is the order the names appear on the card.

**The test lesson is the sharper half.** My first replacement walked all
three possible match-1 pairings through the database and passed against the
bug — a fixture's pks are whatever the sequence is at that moment, so an
end-to-end test agrees with either implementation by luck. That is the same
property that made the original flaky, reproduced while trying to fix it.
The rule was extracted into `anchor_of` for one reason: so the test can hand
in `(7, 8)`, `(9, 16)`, `(23, 24)`, `(31, 32)` — pairs where set iteration
reverses — and fail on all four against the old reading. The end-to-end
version is kept beside it to say that `remaining_pairings` actually asks.

Worth remembering generally: **a test whose inputs are pks cannot pin
anything about pk order.** If the rule is about ordering, hand the ordering
in.

### One group game per round — settled, and enforced in the services

Paul, 15 Oct 2026, answering the question the Road Trip work raised. Two
decisions:

1. **All four stay mutually exclusive.** Irish Rumble, Better Ball, Hot Seat
   and 40 Balls. Worth recording what was declined, because the technical
   path was open: each config carries its OWN entry fee, payout table and
   handicap settings, so two pools could have been collected and paid
   separately, each with its own board tab and settlement line. Only Rumble
   and Better Ball are the same competition scored two ways; Hot Seat (a
   named anchor) and 40 Balls (a budget) are genuinely different games. The
   call is that a group plays ONE group game, so there is one board to read
   and one pot to settle.
2. **A setup screen REFUSES rather than switching.** See below — the app had
   three different answers to this.

**`services/group_field.py` owns the rule**: `ONE_POOL_GAMES`,
`GroupGameExcluded`, `refuse_if_another_one_pool_game(round, this_game)`.
Called from every path that writes one of their configs — `setup_better_ball`
and `setup_hot_spot` in their services, and the Irish Rumble and 40 Balls
setup VIEWS, because those two have no service-level setup function. There is
no single layer to put it in, which is the reason it is shared rather than
repeated.

**It keys on `active_games`, not on whether a config row exists, and that is
a fix.** Both old guards asked
`BetterBallConfig.objects.filter(round=...).exists()` — but a config row
deliberately SURVIVES its game being turned off (`RoundFieldGamesView` drops
the slug and leaves the row so the stake and payouts come back). So a TD who
configured Better Ball, turned it off and picked Irish Rumble was told *"This
round is already running Better Ball — turn Better Ball off first"*, which he
had already done: a dead end whose instructions he could not follow. Verified
against the local database before it was changed, and four existing tests had
pinned the old basis by creating a config row and never activating it.

#### The three answers to one question

What the four setup endpoints did when a peer was already active:

| game | before |
|---|---|
| Irish Rumble | refused 400, naming Better Ball — and only Better Ball |
| Better Ball | refused 400, naming Irish Rumble — and only Irish Rumble |
| 40 Balls | **silently stripped the other two** out of `active_games` and turned itself on; never knew about Hot Seat |
| Hot Seat | nothing at all |

All four refuse now. **40 Balls losing its auto-switch is the deliberate
part**: configuring a game is for its numbers, and turning one off belongs to
the side-games picker, where the chips are visible and the TD can see what he
is dropping. A setup screen that silently ends the competition the round is
playing is what that avoids. Turning ITSELF on stays — that is how 40 Balls is
started.

The pickers keep switching rather than refusing (`applyGameToggle`, the wizard
and the Road Trip sheet), and that is not an inconsistency: a picker is where
a TD says which game he wants, so the chip going quiet IS the answer.

#### `except` on a subclass does not catch the base

`IrishRumbleExcluded` and `BetterBallExcluded` were kept as subclasses of
`GroupGameExcluded` so an outside importer still resolves them, and I wrote
that this meant the existing catches "keep working". **It does not.** The
shared guard raises the BASE, and `except BetterBallExcluded` does not catch
a `GroupGameExcluded` — so the Better Ball setup endpoint 500ed on every
refusal. Caught by the new tests, not by reading. Both views catch the base
now and nothing raises the old names; they are vestigial, which
`TheOldNamesAreVestigialTests` says out loud.

**Left alone deliberately:** the Irish Rumble config auto-created during cup
group setup (`api/views.py`, the `has_ir` branch). That is a cup round's
PER-FOURSOME `game_type`, a different axis from a round-level field game, and
that path never touches `active_games` — so the guard would not fire there
anyway.

Tests: `api/test_one_pool_games.py` (11 — all twelve directions of the six
pairs, every setup endpoint both ways, the turned-off config row, and the
vestigial names).

## Spots v2 — named types, the greenie carry, birdies off the card (BACKEND done)

Built from `~/Downloads/handoff-spots/`. Setup lists which spots are in play,
greenie can carry, and the hole asks WHICH spot was made (the handoff's option
D). **This supersedes the "Spots v2 is a checklist, not a taxonomy" note
above**, and the way it does is worth keeping: it is a checklist over a FIXED
vocabulary with an `OTHER` catch-all, not a taxonomy the user grows. The
checklist IS the agreement Paul wanted — the 18th-green argument is never "how
many sandies" but "we weren't playing pollies" — and `OTHER` is what keeps the
app from owning the whole vocabulary.

**Nothing was in use.** Zero Spots games and zero rows in local AND production
(15 Oct 2026), which is why `count` could be dropped outright rather than
migrated, and why the tally's request shape could change.

### The three kinds of type, which is the whole design

`core.SpotType` + `services.spots.SPOT_META`. Where a type is captured follows
from what it is:

| | types | why |
|---|---|---|
| **pick** | greenie | the app has the pars, so it knows the par 3s, and closest-to-the-pin is one winner or nobody. That is also what makes the carry possible |
| **derived** | birdie, eagle | read off the entered scores, so they never appear on the hole card at all |
| **sheet** | sandy, poley, chippy, barky, snake, other | a tick in the hole's bottom sheet |

**One of each per golfer per hole** — two bunkers on a par 5 is one sandy — so
`SpotsPlayerHoleResult` is a TICK of one named type and the unique constraint
`(game, player, hole, spot_type)` IS the rule. A tick's price belongs to the
TYPE (`SPOT_META`), never to the row, which is what lets an eagle be 2 and a
snake −1 wherever either appears.

**`SNAKE` is Paul's call (15 Oct 2026), and it is not in the handoff.** v1
allowed a NEGATIVE count — the achiever pays everyone — and the eight designed
types are all achievements, so a three-putt (which our own glossary defines)
had nowhere to go: you would have had to tick `OTHER` for everyone except the
man who three-putted. One named type that settles the other way keeps the tick
shape and keeps the pool's all-negative branch meaningful instead of
unreachable.

### Nothing derivable is stored

`greenie_plan()` walks the par 3s **in play order** and derives each one's
worth; `derived_spots()` reads birdies off `HoleScore`. So correcting an
earlier hole moves every later one — the same reason Survivor's legs are
derived rather than written down, and a stored worth is how the card and the
money come to disagree after an edit. Three rules in the walk:

- **Only an explicit Nobody carries.** A par 3 with no pick has not been
  played, so it adds nothing. Picks legitimately arrive out of order, and a
  blank that carried would invent one out of a hole nobody has reached. This
  is why `pick_greenie(player_id=None)` and `clear_greenie()` are DIFFERENT
  operations: Nobody is an answer, undecided is not.
- A win resets the next par 3 to 1.
- **An unclaimed LAST par 3 voids the carry**, and it falls out of the walk
  rather than being special-cased: the pending worth has no later par 3 to
  land on.

**An eagle is 2, not 3** — it does not stack with the birdie. And when eagles
are NOT in play but birdies are, an eagle still scores the birdie: a group
paying birdies has not agreed that the best score on the hole is worth less
than the second best. The design leaves that case open; that is the reading,
and a test says so.

**Net birdies are strokes off the LOW golfer**, not full course handicap,
which would make a net birdie most of a par. Spots carries its own
`net_percent` (default 100, no slider) rather than reading the primary game's,
because **every side game owns its handicap** — the rule the parallel-games
work settled. The handoff's phrase "the group's handicap allowance" would have
re-introduced inheritance.

### The shape that changed

`POST …/spots/tally/` takes `{player_id, types: [...]}` where it took
`{player_id, count}`, and **the list is the whole truth for that golfer on
that hole** — what is absent is unticked, which makes the sheet's Done button
a plain save rather than a diff. An empty list clears him; golfers not named
are untouched. New route `POST/DELETE …/spots/greenie/`.

### The deploy window, measured rather than guessed

The app release goes through review on Apple's schedule, so production runs
this backend while phones run 2.11.2 for an unknown stretch. I first wrote
here that the backend must not deploy ahead of the app build. **That was right
about the symptom I had checked and wrong about the one that mattered**, so
`api/test_spots_old_client.py` replays 2.11.2's exact requests and pins what
each one does:

| 2.11.2 does | result |
|---|---|
| `postSpotsSetup` (no `types`) | **works** — 201, playable |
| `getSpotsSummary`, the leaderboard, the hole strip | **work** — the summary gained keys and lost none, and its `fromJson` ignores what it does not know |
| the `⊖ N spots ⊕` stepper | **400**, and nothing is written |
| a birdie on the card | **was quietly paid** — see below |

The last row is the one worth the test. Birdie and Eagle are read off the
SCORES, and they were in the defaults — so a 2.11.2 round would have paid for
birdies the group never agreed to and that its screens cannot draw: no row
explaining it, no way to turn it off, and a total that matches nothing anybody
tallied. Worse than the 400 by a long way, and invisible.

**The rule now: nothing pays for a spot the client cannot show.** A setup POST
that does not mention `types` gets `legacy_default_types()` — the defaults
minus the derived two. Decided at the API boundary rather than in the service,
because the boundary is what knows the caller's capability; a client that
SENDS `types` is one that can render them, and gets exactly what it asked for.
Greenie stays in: it cannot pay without a pick, that app has none, so it is
inert and starts working the moment the phone updates rather than needing the
game reconfigured.

So the window costs the hand-tally stepper and nothing else, loudly, with no
money moving. A legacy `count` alias stays declined, and the reason is sharper
now than "it would be lossy": the stepper posts the hole's RUNNING TOTAL, so
mapping it would let the first tap through and fail the second. A consistent
refusal beats a control that works once.

The real protection remains that Spots has never been played — zero games in
production — but it is no longer the only one.

`_in_play_block()` is the one place a slug becomes a name, so no board can
print a raw `eagle`. It also **orders every list by the catalogue**, which a
test caught: the per-hole list comes off a query ordered by slug while the In
play pills come off the game's own list, so one hole read "Chippy, Sandy" over
a sheet reading "Sandy, Chippy".

Tests: `scoring/tests/test_spots.py` (37) and `api/test_spots.py` (27).

**Still to build: the whole mobile half** — the setup checklist card, option
D's Spots button and tick sheet, the greenie card on par 3s, and the
leaderboard's In play card with the carry state. Also outstanding: the
glossary sentence at `/glossary/` saying Halved "counts them rather than
naming them", which this makes false.

### Spots v2 — the mobile half

Option **D** of the five the design compared: one line per golfer — name, a
`+ Spots` button, score box — and the button opens a tick sheet of the types in
play. The old `⊖ N spots ⊕` stepper is gone.

**All eight score screens carry both halves**, which is the thing this repo
keeps getting wrong: the combo-tee chip, Spots' own capture control and the
scorecard grids were each shipped on the universal screen first, and *the games
with their OWN play screen are the ones that get missed*. So score entry, Wolf,
Points 5-3-1, Sequoya 3s, Quota Nassau, Rabbit, Survivor and Nassau all get the
sheet AND the par-3 footer, and a source test asserts each of the eight still
does — plus that none of them still threads a spots COUNT, which would compile
(an int is an int) and silently post nothing the server accepts.

- **`SpotsButton`** reads `+ Spots` empty and `2 Sandy, Chippy` filled. The
  badge is laid out first and never shrinks, so a long type list eats into the
  names and not into the number — a row that loses its count says nothing. The
  count is a sum of WORTHS, so a sandy and a snake reads `0`.
- **The button shows only SHEET types.** A golfer's birdie is real and counts,
  but it is not something he can untick, so it must not appear on a control
  that unticks things. `sheetTypesFor` / `allTypesFor` are that split.
- **`spotsFooter()` is the one thing at the foot of the hole card**, and it
  carries two: the greenie pick on a par 3, and a `SPOTS · THIS HOLE` line.
  That line is **the only place a DERIVED spot is visible on the hole** —
  without it a birdie adds money with nothing on the card saying so, and the
  greenie's worth is only legible beside it (`Greenie 2 + Birdie = 3`).
- **Nobody is a chip in the row**, not an absence of one, because it is what
  rolls the carry; tapping the current answer again clears the hole back to
  undecided, which is a different state.
- `openSpotsSheet` **resolves the golfer's name itself** rather than taking
  it: eight screens call it and each had its own route to a short name, so an
  argument would have been eight chances to pass the wrong one. The sheet uses
  the FULL name, the same reasoning as Hot Seat's order sheet.
- The sheet posts **only the golfer who was edited**. The endpoint leaves
  golfers it was not given alone, so posting the whole foursome would make one
  scorer's save overwrite another's on the same hole.
- Setup gets the **Which spots are we playing** card under Stake, with
  greenie's Carry over switch and the one Gross / Net (SO) control — which
  sits under Birdie, or under Eagle when Birdie is off, as the design
  specifies. Save is dead until one type is ticked, which is the half that
  keeps the TD out of a form the server refuses.
- The leaderboard's **In play** card lists the pills with a non-1 worth spelled
  out (`Eagle or better · +2`, `Snake · -1`) and says the carry state in a
  sentence, because it is two facts read together: whether it rolls, and what
  the next par 3 is worth.

`_delete` in the client gained an optional body and a return value, for
clearing a greenie — an endpoint that deletes one hole's answer and hands back
a recomputed summary, since the carry on every LATER par 3 moves with it. Both
additions are backward compatible; the sixteen existing callers pass no body
and ignore the return.

**The glossary sentence is corrected.** `/glossary/` said Halved "counts them
rather than naming them", which this makes false; it now says the group ticks
what it is playing before the round, with anything else going in as Other.

Tests: `mobile/test/spots_types_test.dart` (13). Flutter 965 green.

#### A greenie takes on-in-one AND a par

Paul, 15 Oct 2026: *"It has to be both on the green on the first shot and a
par."* The app can only see the second. Being closest from the tee is a human
judgement, so the PICK records who it was and the SCORE decides whether he
keeps it — on in one and then three putts is a bogey and pays nobody.

So a par 3 has four outcomes, not two (`greenie_plan`):

| | |
|---|---|
| a winner who **parred** | collects the worth; the next par 3 resets to 1 |
| a winner who **did not** (`missed`) | nobody collects, and it carries exactly as Nobody would — he was closest, he just did not keep it |
| a winner whose **score is not in** (`pending_score`) | provisional, and the carry does NOT move: the answer is not known. It resolves when the score lands, which on a real hole is seconds |
| **Nobody**, or no pick | as before |

**Par is GROSS.** The greenie is a shot — on the green from the tee, then up
and down — so a net par off a stroke is not what is being paid for, and
`birdie_basis` stays scoped to birdies and eagles. Worth flagging as a
decision rather than a derivation: a high handicapper gets no help here.

The card **states the rule**, because "on in one" is the half the app cannot
enforce and a par is the half it can — without it a bogey that pays nobody
reads as a bug. A missed par names the man and says nobody keeps it.

### The greenie Paul could not select, and what it was not

Reported mid-build: the greenie would not select on hole 7, before or after
scoring a par. **The server and the client were both already right**, which
took measuring rather than reasoning to establish, and the sequence is worth
keeping because the same shape will recur:

- the local game had `greenie` in `types`, carry on, par 3s at **4, 7, 11 and
  16** off the real Tilden Park tee;
- `greenie_plan` returned a row for every one of them, hole 7 included;
- `_HoleScoreCard` has exactly ONE instantiation and it passes `cardFooter`,
  which renders as the last child of the card's own column;
- and `SpotsSummary.fromJson` of **the exact payload that round returned**
  parses `greenieInPlay` true with a row for hole 7.

That last one is now a test carrying the captured JSON verbatim
(`_tildenPayload`), because the parse is the only link between a correct
server and a correct widget that a stale build hides. **The remaining
explanation is the build**: adding a constructor parameter to
`_HoleScoreCard` and methods to `SpotsCaptureMixin` is not something hot
reload picks up — it needs a full restart, and a mixin change often a
rebuild.

Worth remembering the cheaper check first: `ticks: [(2, 'chippy')]` was in
the local database, which proves the new client had already talked to the new
server successfully. Without that, "wrong build" and "pointing at Railway"
(where none of this exists — `flutter run` with no flags does exactly that)
would both still have been live.

**It was none of those. A screenshot settled it in one look**, and the answer
was discoverability: the Spots sheet was open on a par 3 showing Sandy and
Chippy, and the greenie pick was the row directly behind it. He had gone
looking for Greenie *in the list*, which is the one place it is never going
to be — it is a single-select pick at the foot of the card because only one
golfer can win it.

So the sheet now says where it is, on par 3s with the greenie in play. **A
list that silently omits the type a man came looking for reads as the type
being missing, not as it living somewhere better.** That is the general
lesson: the capture lives where the design put it, and the place people
*look* has to point at it.

I had spent four checks proving the server, the widget tree and the parse
were right — all worth having as tests, and none of them the answer. **Ask
for the screenshot earlier.** The same note sits above the tournament watch
link: "worth asking for the exact words before theorising about the page".

#### ...and then two real ones, from the same round

**A played par 3 with no winner now carries.** Paul: *"there should have been
a carry over"*, from a round whose first par 3 was fully scored with no
greenie ever recorded. The rule was "only an explicit Nobody carries", on the
reasoning that a blank must not invent a carry out of a hole nobody has
reached — right about an unplayed hole and wrong about a played one.
**Nobody taps to record an absence**: they miss the green, say nothing and
walk on, which is exactly what he did. So the gate is whether every ACTIVE
golfer has a score (`unclaimed`), not whether somebody pressed a button; a
partly-scored par 3 still adds nothing, which is the case the old rule was
protecting. Naming the winner afterwards takes the carry back, because the
auto-carry is a reading of the scores rather than a decision written down.

That makes the greenie's worth depend on SCORES for the first time, so the
card goes stale if a score lands without a summary refresh.
`_loadGameSummaries` already runs on every save and again after the sync
drain, so it is covered — but it is why Paul saw the right answer only after
going to hole 8 and back.

**A carried greenie lost its ×2 on the way out.** The per-hole `types` block
was built with `_in_play_block`, which labels a CATALOGUE and takes each
worth from `SPOT_META` — the TYPE's price. A carried greenie is the one
thing whose worth belongs to the HOLE, so the board drew `Greenie on 7` for
a greenie worth two and the hole's own line totalled it as 1 while the money
said 2. `_types_block` carries the real worth through. Worth remembering as a
shape: the summary kept `(type, worth)` pairs internally and threw the worth
away at the boundary, so the bug was invisible in the settlement and visible
only in the labels.

#### The board names the spots, not just the count

Paul, 15 Oct 2026: *"We spent the energy to capture what spot it was on a
hole. We should report it on the leaderboard."* Each golfer's row now carries
his own spots as bubbles — `Chippy on 2 · Birdie on 2 · Greenie on 7 ×2` —
built by `utils/spots_earned.dart`, pure for the same reason `nine_totals` and
`roster_sections` are.

Three decisions in it:

- **`on` is in the text.** `Chippy 2` reads as two chippies, and removing
  that ambiguity is the only thing these bubbles exist for.
- **A worth over one is named** (`×2`), because `Greenie on 7` and
  `Greenie on 7 ×2` are different money and the carry is the whole reason the
  second exists. A snake's sign lives in the colour, not the text.
- **It replaced the hole-ordered `SPOTS BY HOLE` strip** rather than joining
  it. That strip read `2  A +1`: the same facts grouped the other way and one
  short of the only new one, the type. Two renderings of one dataset on one
  card is how they come to disagree, and a leaderboard ranks GOLFERS — "what
  am I being paid for" is the question it is open for. The chronological read
  still exists where it is actually useful, on the hole, in score entry's
  `SPOTS · THIS HOLE`.

**Not put behind a caret**, which Paul offered. The repo's own precedent cuts
the other way than it first looks: the Stroke Play tab hides a player's
18-hole strip behind a tap because that board holds a whole FIELD, and Spots
holds a foursome. More to the point, a Spots total is not checkable without
the itemisation — `5 spots +$10` tells a golfer nothing, where
`Chippy on 2 · Birdie on 2 · Greenie on 7 ×2` is something he can agree or
argue with. Hiding it would be hiding the answer. It is one line to collapse
if it reads long on a real round.

#### Hogan, and the second place names were living

Paul added **Hogan** on 15 Oct 2026 — fairway, green, two putts, with a par 5
adding a second fairway — **off by default**, like Poley, Barky, Snake and
Other. Nothing the app can detect, so it is a sheet tick.

Adding it is what exposed a real flaw in the mobile half above. The setup
checklist has to draw a row for every type including the unticked ones, but a
configured game's `in_play` holds only the group's own picks — so the first
version merged `in_play` with `sheet_types` and **filled the gaps from a label
map typed into the screen**. That made the client a second place every type is
named, against the rule this file keeps restating: one place holds a name, and
the server holds it.

The cost was concrete rather than theoretical. Hogan would have needed adding
in two places, and forgetting the client half shows a golfer `hogan` in a
checkbox. So `catalogue_block()` now ships the WHOLE list on every read — slug,
label, worth, how it is captured, whether it starts ticked — and
`_mergeCatalogue` is one line returning it. A test asserts the catalogue
matches the enum exactly, and another greps the setup screen for any type name
typed into it.

**The grep test was passing vacuously first.** It read
`src.contains("'\$label'")`, and in Dart `\$` is an escaped dollar, so it
looked for the literal text `'$label'` and would have agreed with any
violation. Same shape as the Sixes anchor test that passed against its own
bug. It is unescaped now, and I checked it fails when a name is typed back in
before trusting it.

`games/0096` is choices only — no row changes, and "off by default" is
`SPOT_META`'s flag rather than anything in the database, so a game already
configured keeps exactly the types it was given.

#### The button did not read as a button

Paul, 16 Oct 2026: *"I am afraid people don't see the button and think they
have to press on the + key exactly."*

**The hit area was never the problem.** The whole pill has always been inside
the InkWell, and a test tapping its far right edge passes against the old
build too — it is kept as a guard against somebody later shrinking the target
onto the glyph, which is the thing being feared rather than the thing that
was happening. What was wrong is everything that made it LOOK untappable, on
a row already carrying a bold name and a big score box:

- the three faintest tokens in the theme — no fill, `outlineVariant` border,
  `onSurfaceVariant` text — which together read as a disabled chip;
- **32pt tall**, under every touch-target guideline there is;
- and a filled state that **swallowed its own ripple**. A decoration painted
  by the InkWell's CHILD paints over the splash, so `InkWell > Container(color:)`
  gives no feedback at all. It is `Material > InkWell > Ink(decoration:)` now.
  A control that does not flinch when you touch it is one people decide is
  not a control.

Now: tinted in the primary at 7% empty and 12% filled, a primary border, a
primary label at w600, `add_circle_outline` at 17, and **36pt tall** — 38 was
tried first and cost a four-ball's hole card about 24pt for 2pt nobody could
feel. The height was never what made it read as a button; the fill, the
border and the label colour were, which is why the height is the part to
give back.

**Not built:** the design's open question about very long names on the Spots
button (four golfers fit; the ellipsis handles the rest, untested against a
real 24-character name).


## Skins junk, set up like Spots — `handoff-skins-junk`

Junk now has the same named types, the same greenie pick and carry, and the
same tick sheet as Spots. The handoff says to build them on the same code and
that is what makes this worth recording: **`services/spot_types.py` is the
shared half**, extracted from `services/spots.py` rather than copied.

**Nothing in that module reads a game row.** Every function takes what it
needs — the types, the carry flag, the allowance — and duck-typing would have
walked straight into a real collision: `SkinsGame` already has `net_percent`
and it means *who wins the SKIN*. Junk's birdie basis is a different
question, and the handoff is explicit that **net skins with gross birdies is
a valid setup**, so junk carries its own `junk_net_percent` and
`junk_birdie_basis` beside them.

The widgets are shared the same way: `SpotsButton`, the tick sheet and
`GreenieCard` take a noun. **Junk has no plural** — "3 junk", never "3
junks" — which is why the Done label asks for both forms rather than adding
an `s` itself.

### A junk is worth a SKIN

One share of the same pot, so the types fold into `total_skins` rather than
settling on their own. A birdie that wins the skin is **1 skin and 1 junk**;
one hole can give one golfer several shares. The skin carry and the greenie
carry are **independent** — a tied par 3 can carry the skin while somebody
takes the greenie — and a test pins that, because it is the thing most likely
to get quietly fused.

### The legacy rows are kept, not migrated

Unlike Spots, junk **had been played**: sixteen `junk_count` rows in four
COMPLETED rounds from May and July 2026, four of them a 2. Those rounds were
settled against exactly those numbers, so they are read and never rewritten —
and a tick could not represent them anyway, since "2 of something unnamed"
has no name and one of each type per hole is the rule.

So `junk_count` survives as a deprecated column and `junk_type` is nullable:
**null IS the legacy row.** The engine reads them alongside ticks and the
board shows the count without inventing a label. `tally_skins_junk` CLEARS a
row's count when it writes ticks for the same golfer and hole, so an old hole
converts the moment anybody touches it and the two can never be
double-counted — while the untouched holes of that round keep their history.

### The shipped-app window, and why it matters more here

Same rule as Spots: a setup that never mentions `junk_types` gets the
defaults **without** birdie and eagle. It matters more than it did there,
because this money is a share of the skins pot — paying a birdie the client
cannot draw moves everybody else's payout too, not just one man's.

The old `{"player_id": N, "junk_count": N}` body is refused rather than
guessed at, for the reason the count cannot be mapped: one of each type per
hole.

### What the sweep turned up

- **Both screens that captured junk batched it** into a pending map and
  flushed on the way to the next hole. The sheet posts on Done, so that
  machinery is gone from both; `_saveJunkIfNeeded` survives as a documented
  no-op so a caller that drains before navigating still reads the same.
- **A test caught two things reading the files**: an orphaned `_JunkDots`
  class left in `score_entry_screen` after its use was replaced, and the
  greenie footer wired into score entry but **not** into `skins_screen` —
  the dedicated play screen, which is this repo's most reliable omission.
- Three existing tests named their `junk_types` rather than inheriting the
  defaults. With birdies on, a man who takes the skin with a 3 earns a
  second share: correct, and a different subject.

Tests: `scoring/tests/test_skins.py::JunkTypesTests` (10),
`api/test_skins_junk.py` (16), `mobile/test/skins_junk_test.dart` (9).


### 40 Balls: the picker's two boxes ask two different questions

Paul, 16 Oct 2026. They sat side by side as **To reach 40** and **Slack**,
which made them look like two halves of one answer. They are not: the left
one is about PACE and the right one about where the group stands.

- **TO REACH 40** keeps `2.2 a hole` and its note becomes
  `8 chosen · 15 holes to play`. The hole count alone never said how much of
  the budget was already gone, which is the other half of whether that
  average is comfortable.
- **STATUS** replaces Slack: `Net −3` as the headline with `28 balls slack`
  underneath. A group reads the number it is being ranked on first, and the
  slack is a qualifier on it rather than a figure of its own. Level is `E`,
  as it is everywhere else in the app.

**The net comes from `group_card`, not a second walk.** The settled-hole rule
is the subtle part — a count the group cannot yet fill is a commitment and
not a figure, which is what once gave a group −20 on an unplayed par 5 — and
two readings of it would differ on exactly the holes that are hardest to
reason about. `hole_state` pays for `group_card`'s own queries, which its
docstring sanctions for a single-group caller. The same module's note about
`average` says why that rule is worth obeying: a second version is the one
that is wrong half the time.

Three existing tests pinned the old copy and now state the new; a fourth
asserted a dash on BOTH boxes when the budget is spent, which is no longer
true — the Status box still has a net to report, which is the point of it
being a status.

Watch the hole count when writing a test here: `_holesLeft` counts the hole
in front of you while nothing is picked and drops it once something is, so
`holesAfter: 14` with no pick reads `15 holes to play`. My first test had it
off by one.

## Skin validation — a minimum, and gross birdies steal

Asked for by Paul on 27 Oct 2026 after a user described his Friday game:
*"you win the skin with your stroke but you have to validate the skin with a
gross par and birdies steal."* Added to **both** skins engines —
per-foursome `SkinsGame` and the cross-group/cross-round `MultiSkinsGame`.

`SkinsGame.skin_minimum` / `birdie_steal` and the same pair on
`MultiSkinsGame` (`games/0098`). Both default OFF, so every existing game and
the shipped app keep playing plain skins.

### Two minimums, because they are different house rules

`NET_PAR` requires the score the game is scored on to be par or better;
`GROSS_PAR` requires the GROSS to be — **stricter, and the one the user
actually described**, since a net par made off a stroke is a gross bogey and
fails it. Paul asked for "net par minimum"; the user's own rule was gross par.
Both are built rather than one guessed at, which is the Spots-checklist
principle: the app is not the authority on which rule a group plays. In a
GROSS game the two coincide, which is correct and not a collision — there is
no net score to be more lenient about.

### The design: TWO FILTERS, ONE RANKING

`services/skin_rules.py`. Both rules decide **who is eligible**; neither
changes **how scores compare**. Ranking stays on the score the game is already
scored on, so a net game stays a net game and two players who both make a
natural birdie are separated by their NET rather than re-ranked on gross. That
is what makes the rules compose — either, both or neither, in any
combination — instead of three special cases, and it means a stroke is never
silently ignored.

**The steal outranks the minimum and can never contradict it**: a gross birdie
is better than par, so anyone passing the steal filter passes either minimum
automatically.

**A minimum is a validation on the WINNER, so the next valid claim takes the
skin** rather than the hole going unwon. Low net over par, somebody else at
net par: the second man wins it.

### `decide()` returns LEADERS, not a winner

0, 1 or several ids, and the caller owns what a non-single answer means —
because the two engines disagree: round skins CARRIES a tied hole (when
`carryover`) while the pool KILLS it. **Nobody qualifying returns an empty
list, which both callers already treat exactly like a tie**, so the third
outcome needed no new branch in either engine. That is the whole reason it is
a filter returning leaders rather than a `winner_id`.

### Par is per golfer, which is a deliberate departure

Each man is measured against the par of HIS OWN tee. Every other game here
takes one layout for the foursome (`services.triple_cup._par_by_hole` says
so), which is right when the question is about the hole. This question is
about the GOLFER — did *he* make par — so on a mixed-tee card, where men's and
women's pars can differ, his own card decides. In the cross-round pool that
also means his own tee in his own ROUND, read through
`_resolve_participant_memberships`.

**Everything fails open.** An unknown minimum normalises to `none`, and a
missing par or gross passes rather than voiding a skin — a typo must not
quietly start changing who gets paid.

### The decorator trap, hit again

`setup_sixes` has a note in this file about a helper inserted immediately
above a function landing BETWEEN `@transaction.atomic` and the `def`. **I did
exactly that to `calculate_skins` and `_calculate_game`**, moving atomicity
onto two new read-only helpers and stripping it from both calculators. The
traceback gave it away (`contextlib.py inner` in the frame above the helper)
along with a second error — `HoleScore` is in `scoring.models`, not
`tournament.models`, and skins.py already imports it at module level. Insert
**above the decorator**, and check the line above the `def` afterwards.

### Mobile

`widgets/skin_validation_card.dart` is ONE control used by both setup screens,
for the same reason the rule is one module. It passes the server's own slugs
through untranslated, and its footer states the consequence that plain skins
never has — **a hole can now go unwon**. `SkinsSummary` and
`MultiSkinsSummary` both gained `skinMinimum` / `birdieSteal` / `skinRules`,
the last being the server's own phrase and **empty when neither rule is on**,
so a client tests it instead of printing "no minimum" at a group playing plain
skins.

`mobile/test/skin_validation_test.dart` asserts at the SOURCE that both setup
screens render the card AND post both values, and that the client sends them
on both endpoints — this repo's recurring failure is a rule reachable from one
screen and not the other (the day bet, Hot Seat on the Road Trip sheet). A
screen that draws the control and never posts it looks identical until
somebody plays a round.

**The board states them** (`_SkinRulesInPlay`, `leaderboard_screen.dart`), on
BOTH the per-foursome skins card — beside `_JunkInPlay`, because the two
divide one pot — and the cross-group pool. It draws nothing when neither rule
is on, rather than announcing "no minimum" at a group playing plain skins.

**The chips carry the SERVER'S words.** `utils/skin_rules_display.dart`
`skinRuleChips()` SPLITS `summary['skin_rules']` on the middot rather than
re-deriving labels from `skin_minimum` / `birdie_steal`. The first version did
re-derive them, which made the board a second place that names the rules —
exactly the failure the `detail` / `problems` split had just been about, two
commits earlier, in a docstring claiming the opposite. The slugs are still
read, but only for a yes/no.

**The note states the CONSEQUENCE, not the setting**, because the setting is
already in the chip above it: *"A hole where nobody qualifies goes unwon."*
That is the thing plain skins never does, and the reason any of this belongs
on a board — a player looking at a carried pot otherwise has no way to work
out why nobody won. The minimum outranks the steal in that line, since a
natural birdie clears any minimum and so can never cause an unwon hole.

Tests: `scoring/tests/test_skin_rules.py` (28 — the semantics as pure units,
including both-naturals, mixed par and every fail-open case),
`SkinValidationTests` in `scoring/tests/test_skins.py` (12 — the wiring, and
one hole where all three minimum settings give three different answers),
`MultiSkinsValidationTests` in `scoring/tests/test_multi_skins.py` (7 — across
groups, and that re-running setup updates the rules),
`SkinValidationEndpointTests` in `api/test_skins_junk.py` (7),
`mobile/test/skin_validation_test.dart` (14) and
`mobile/test/skin_rules_display_test.dart` (13 — including that the board does
not start naming the rules itself again).

### `build-ipa.sh` — the generated Swift package is EDITED, not deleted

The archive fails Target Integrity unless
`ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift`
declares `.iOS("15.0")`: firebase-core, firebase-messaging and halved-sms all
require 15.0. Flutter generates it at **13.0**, its own default, and does NOT
read the Xcode project's deployment target (which is 15.0 and always was).

**Two orderings were tried and this file documented both as the fix. Both are
wrong**, and the second claimed "`flutter build` reads the Xcode project and
writes 15.0" — it does not. That claim cost build 57 (27 Oct 2026), and a
previous commit (`a55ea48`) had already cost one discovering the note was
backwards.

- `rm` then build → the build runs pub resolution itself and re-creates 13.0.
- `pub get`, `rm`, then build → the same thing.

So the script **stops deleting it and raises the platform in place**: generate
(`pub get`), `sed` 13.x → 15.0, then build WITHOUT removing it. The build only
regenerates the package when it is absent or pub resolution is stale, so an
edited one survives. It fails loudly before the archive if the platform line
has changed shape, and re-checks after it in case the build regenerated it
anyway.

## The skins board — one widget, every skins leaderboard

Built from `~/Downloads/handoff-skins-leaderboard` (28 Oct 2026), whose first
instruction is the one that shaped it: *"one widget used by every Skins
leaderboard (casual, multi-group, side game tabs). Do not draw a second skins
table anywhere."* Three cards — what the next hole is worth, where the skins
went, what everyone is owed.

`widgets/skins_board.dart` + `utils/skins_board_model.dart`. Both
`SkinsSummary` and `MultiSkinsSummary` convert into one `SkinsBoardData`, so
the widget never learns which produced it. It **replaced** the per-foursome
`_SkinsStandingsBlock` (241 lines, deleted) and the pool's own player `Table`,
which were the two skins tables the packet is about.

### What is derived and what is taken verbatim

Only what the server does not answer: which hole is next, which holes carried
into it, how many skins ride, how far round the group is.

**The money is NOT computed.** The reference derives
`net = stake × (golfers × won − total)`, which is right for per-point/all with
no junk, no withdrawal and no loss cap — and wrong for pool mode, which we
also support. `skins_summary` emits a signed zero-sum `net` that accounts for
all of it, and the board renders that. A test fixes a case where the
reference formula says `+$3` and the truth is `+$1.50`. Same rule as
`gross_to_par` and the skin-rules chip: one place decides, everywhere else
renders.

**Skins riding is not re-counted from the carried run.** A carried hole's
stored `skins_value` is already the pot INCLUDING itself, so two carried
holes ride as three — which is what the design draws, arrived at from the
engine rather than by counting tiles.

### Play order for the walk, hole number for the grid

The summary's holes come back in `hole_plan.play_order`, so "up next" off a
shotgun from the 7th is the 8th and not hole 1, and the last hole played can
have the smallest number. The GRID sorts by hole number, because a scorecard
is a scorecard whatever order it was played in. Two tests cover the split —
this is the mistake the shotgun sweep found six times.

### Three departures from the packet, all because it could not know

- **Junk.** The design has none, and junk is a share of the same pot. Ticks
  total `skins_won + junk_skins`, junk **outlined** rather than filled, so the
  count always reconciles with the money beside it (Paul, 28 Oct). Note junk
  only ever appears when Skins is the PRIMARY game.
- **The pool never carries**, so its Up-next card would read "No carry · 1
  skin" eighteen times. `showNext: false` — which is the design's own config
  flag, so this is using the packet rather than departing from it.
- **Per-golfer `thru` in the ledger, pool only.** A cross-round pool spans
  groups at different paces and a board that hid that would be misleading
  about who still has holes to come. Null in a single foursome, where it would
  be the same number four times.

**The validation rules sit under HOLES** (Paul's call), as a footnote on the
grid: they decide what it takes for a tile to be won at all, which is why a
hole can carry with nobody tied. That retired `_SkinRulesInPlay`, which had
been its own chip on each card for a day.

**Golfer colours are shared now** — `Halved.golferColours` / `Halved.golfer(i)`,
six wrapping. They were about to be a third private copy (the Sixes board
declares its own clay). Six is the ceiling and it WRAPS: a foursome never
exceeds it, a cross-round pool can, and a board that big has to identify
golfers by name.

**Colour follows the ROSTER, not the standings**, or a golfer changes colour
the moment he wins a skin and the hole tiles stop matching the ledger
swatches.

**`SkinsHole.par`** is parsed at last — the server has always sent it; nothing
read it until the Up-next card.

**Still open:** the **game switcher** at the top of every leaderboard is now
specified by a THIRD packet (40 Balls, Sixes, this) and still is not built.
It is shared across every board, not this one's to own. Also note the "API
shape (skins summary)" block above shows `handicap_mode` flat; the real
payload nests it as `handicap: {mode, net_percent}`, which is what the Dart
has always parsed.

Tests: `mobile/test/skins_board_model_test.dart` (18 — the walk, both shotgun
cases, the pool, and the money) and `mobile/test/skins_board_test.dart` (16,
including that both cards render the one board).

#### In a pool, the column adds up to the pool
Paul, 29 Oct 2026, on a six-man $10 pool with three skins won: the board
read **+$10 / −$10** under **"$60 pool"** — numbers that sum to zero under a
header promising sixty. The server was right (each winner's `payout` was
$20, three of them, $60); the per-group board was showing each golfer's
`net` (share minus his ante) instead.

The board was designed for the share — the header comment already said the
column "is already each golfer's share" — and the CROSS-GROUP pool path was
feeding `payout`. Only `fromSkins` fed `net`, so one widget meant two things
by "pool". Now:
- **Pool:** `payout`, the share, shown UNSIGNED (`$20`, `$0`) — a "+$20"
  claims twice what a winner gained on a $10 ante.
- **Per skin:** the signed, zero-sum `net`, as before.

The field is `SkinsBoardGolfer.money` (was `net`, which it no longer always
is). **Why no test saw it:** both test helpers set `payout` and `net` to the
same value, so nothing could tell them apart; the helpers take them
separately now, and the pool test is the screenshot's round — verified to
fail on the old line.

## The game switcher — four packets asked, none had built it

`widgets/game_switcher.dart`. 40 Balls, Sixes, skins and Nassau all open with
the same paragraph: *"shared segmented control… Past five items it scrolls and
keeps the active one centred. Where boards swipe, the thumb tracks the swipe.
**Do not use pill or underline tabs.**"* The leaderboard was using a Material
`TabBar`, which is exactly the underline tabs that sentence rules out — so
every board built to a packet was quietly assuming a control that did not
exist.

**It is not `HalvedSegmented`.** That one is a `Row` of equal or fixed-width
segments with no scroller, which is right for a closed set read in one glance
(the size picker, Survivors/Standings). A leaderboard carries as many games as
the round is playing, so this is **sized to each label**, **scrolls**, and
**centres the active game**. Same visual language, different job — split for
the reason `StrokeDotRow` and `StrokeDotColumn` are.

**It takes a `TabController`, not a selected index**, because an index cannot
describe a half-finished drag. `controller.animation` is a FRACTIONAL index
mid-swipe, and the thumb lerps both its offset and its width between the two
neighbouring labels — which is what the reference's `place(p)` does. The
active label darkens over the same fraction, so a swipe reads as half-finished
rather than snapping. The `TabBarView` is untouched, so the swipe itself is
unchanged.

**Labels are measured with a `TextPainter`, not laid out.** The thumb has to
know a label's width before the first frame or it starts at zero and snaps.

### The bug worth remembering: a height that excluded its own margin

`GameSwitcher.height` is what a caller hands to `PreferredSize`, and it first
read `38 + 3*2 = 44` while the control also carried a 6pt bottom margin. The
row then overflowed its box by exactly that margin — which **does not look
broken**. It moves the labels out of the hit area, so taps silently miss. The
height now includes the margin. If an app-bar control ever stops responding to
taps while looking perfect, measure its box against its contents first.

### Two test-environment traps this hit

- **`MediaQuery` does not resize the test surface.** The default window is 800
  wide, so a phone-width assertion made against a `MediaQuery` override is
  measuring nothing. `t.binding.setSurfaceSize(...)` with a tear-down.
- **The test font is one square per glyph**, so `Settlement` is far wider here
  than on a device and starts off-screen at 390pt. The tap test calls
  `ensureVisible` first — which is what the strip is for, and what a user
  does.

Finders in these tests are **scoped to the switcher** (`_inSwitcher`), because
the `TabBarView` pages carry the same words and an unscoped `.first` picks
whichever comes first in the tree — which may be off-screen, so the tap misses
without failing the finder.

Tests: `mobile/test/game_switcher_test.dart` (9), including that the
leaderboard no longer contains a `TabBar(`.

## Team Play was slow because the card paid for the whole field

Reported from the course, 29 Oct 2026: *"The app was very slow today. First
time playing 2 person scramble."* — TPSGC Fall Scramble 2026, fourteen groups
of four paired into twenty-eight two-man teams.

**Reproduced at that size and measured before touching anything**
(`api/test_team_play_perf.py`):

    groups  teams   card          board
         1      2     55 -> 48      41 -> 10
         2      4     66 -> 48      78 -> 12
         4      8     88 -> 48     152 -> 16
        14     28    198 -> 48     522 -> 36

Two facts from the measurement decided the whole fix. **Neither call scaled
with holes played** — 198 and 522 were flat from hole 1 to hole 18 — so it was
never the round wearing on. And **posting a score was 18 queries and did not
move with the field**, which is the 7 Oct offload work still holding; the cost
was entirely in the reads.

**The card was the one that hurt.** It belongs to one playing group, the score
screen refetches it on every hole change and after every save, and it was
paying ~11 queries for every OTHER group in the field — because it calls
`field_standing` for the team's place, which ranks everybody through the same
per-team builders the board uses. It is FLAT now, which is the real result.

**Why this was the first round it showed.** Pairs double the row count for the
same field: a 14-group fours event is 14 teams, this one was 28.

### The cause was the SHAPE of the queries, not their number

Every leaf is cheap for one team. `.filter(...)` and `.select_related(...)` on
a related manager ALWAYS hit the database though, even when the caller has
prefetched that relation, because they build a new queryset — **`.all()` is the
only form that reads the prefetch cache.** So five leaves were unreachable by
any amount of prefetching at the call site.

`services/team_play_state.py` now has `all_memberships` / `all_drive_picks` /
`all_team_hole_scores`, each returning the cached rows when the caller asked
for them and otherwise running exactly the query it used to. That is what keeps
the single-group paths — the card, a score POST — at the cost they already had,
and it is why the fix is additive rather than a rewrite. `_real_memberships`,
`team_slots`, `hole_data`, `drive_picks` and `team_hole_scores` all read
through them, filtering and sorting in Python.

`services/team_play_scoring.field_foursomes` is the one fetch for the field,
used by both `leaderboard` and `field_standing`. **It prefetches exactly what
those leaves read and nothing else** — a prefetch nobody reads is a query
bought for nothing — so that list and those accessors move together.

### What proves it did not change the money

`api/test_team_play_scoring.py` asserts the design packet's whole drawn board:
the finishing order, two ties behaving differently, a three-man team taking
more each, and the odd cents landing on a named man. It passes untouched.

What it does NOT reach is the ordering INSIDE a team, because its fixture never
ties on handicap — and `_real_memberships` is exactly where SQL became Python.
`PrefetchKeepsTheSameAnswersTests` covers that with a deliberate handicap tie
whose names are out of alphabetical order, and asserts the prefetched and
unprefetched paths return the identical list.

**`course_handicap` is NOT NULL**, so the None arm of `_hcap_key` cannot be
reached from the database; it is there because Python cannot compare None with
an int at all. The first version of that comment claimed it was matching
Postgres NULL ordering, which would have been describing a row the schema
cannot hold.

**All three guards were checked by making them fail**, with the prefetch
removed: 522, 198 and 4 queries against ceilings of 45, 55 and 0.

### Still open from the same family

The memory note `live-activity-start-pushes-never-convert` records ~125
queries per posted score on a cup round, with `triple_cup_summary` recomputed
two or three times in one recalculation. That is a different format and
untouched here.

## The Points 5-3-1 board — and the settings strip that could not see four games

`~/Downloads/handoff-points-leaderboard`, the fifth packet with the same
scope line: *"one widget used by every Points 5-3-1 leaderboard. Do not draw
a second Points board."* Three cards — the hole just played, where the points
went, what everyone is owed.

`widgets/points_board.dart` + `utils/points_board_model.dart`. It replaced
the per-group table and the awards grid in `leaderboard_screen.dart` (223
lines down to 48); `_Points531HoleGrid` SURVIVES because Three-Person Match
draws it too, and that is not a second Points board.

### The money is read, and a real round proves it has to be

The packet's reference carries its own `money()` with three modes, and
`(points − 3 × holes) × stake` for vs-Average. Ours settles through the
shared wager engine, which also offers **pool** and an optional **loss cap**
that clips the losers and rescales the winners pro-rata.

Foursome 257 in the local database finished **58 · 57 · 47** over 18 holes
against a target of 54, so the formula says `+$4 / +$3 / −$7`. The $6 cap
settled it **`+$3.43 / +$2.57 / −$6.00`**. A board doing its own arithmetic
would have shown three golfers a figure nobody was paid — which is the same
`gross_to_par` lesson, in the one column where it costs money.

### Target, not par — and three a hole over the holes IN PLAY

"Target" replaces "par" everywhere on this board, which is the packet's rule
and a real one: par is a number of strokes and this card counts points, so
`+15` against par reads as fifteen shots. The reference hardcodes **54**;
`par_per_hole × holes` gives 27 on a nine-holer and 21 to a group thru 7,
from two facts the server already sends.

### Hole number inside each nine, play order for the walk

The grid draws Out and In by hole NUMBER — the skins board settled this one
board ago, and Out only means anything counted that way. The NEXT hole comes
from play order, so off a shotgun from the 18th it is the 1st.

**A nine draws once one of its holes is played, and the nine holding the next
hole always draws.** The reference hides the back nine until hole 10, which
assumes a round starting at the 1st; from the 10th tee the back nine is the
one being played and the FRONT is the one that has not started.

**The nine subtotal is a running total**, deliberately against this app's own
em-dash rule (`utils/nine_totals.dart`). That rule exists because a partial
OUT of strokes reads as a finished one. Points ACCUMULATE, so a partial
subtotal is a real number rather than a misleading one, the dashed cells
beside it say the nine is unfinished, and the packet's worked example depends
on it.

**A tie is read off equal NET, never equal points.** A `4` can be a share of
low (5 and 3 split) or a share of second (3 and 1), so reading the points
back would call an outright second a tie.

`Halved.golferTints` holds the three second-place tints, declared rather than
blended: `#B7D9CB` is 70% of the way from teamPine to white on red, 74% on
green and 69% on blue, so no single ratio reproduces the set. Only three are
designed, because the only game that uses them is three-handed. And
`Halved.clayInk` (`#8A4A1C`) came out of `forty_balls_keypad`'s private
`_Clay`, since a second board now wears the same ink.

### The settings strip could not see four games

`settings_chips` reads `payout_style`, `per_point_mode` and `loss_cap` at the
TOP level of a summary — and **Points 5-3-1, Skins, Spots and Honors all nest
them under `money`**. Only Stableford puts them flat. So the strip shipped
yesterday naming "the rules a golfer forgets he agreed to" found the
settlement chip for one game in five, and foursome 257's **$6 loss cap was
named nowhere in the app**.

`_pick(summary, key)` falls back to the `money` block, top level winning
because a game that states a key outright means it. Points now reads
`Strokes off · Against the average · Loses at most $6`, and Skins gained its
`Pool`.

**That is also what retires the old card's header and footer without losing
anything**: `Points 5-3-1 — SO · Per point` and `Bet unit $1 · Par is 3 pts /
hole · Loss cap $6/player` are now the strip, the ledger's `$1 a point` and
its `Target N pts`. Same collision Sequoya's `_pressLabel` had.

### Two things only the device showed

- **`Flexible` defaults to `flex: 1`**, so the ledger header's label and its
  stake SPLIT the row and the stake sat in the middle. Nothing overflows, so
  no test saw it. The measurement that pins it had to be taken at **900pt**:
  at phone width the test font is wide enough to fill the split half, which
  puts the box's right edge in the same place either way — the first version
  of that test passed against the bug, and was only trusted after being made
  to fail.
- **`TYLaw Law`.** The muted surname exists to tell two Pauls apart; a short
  name that already ends in it gets none.

### `flutter build ios --simulator` fails and exits 0

The `build-ipa.sh` note about the generated `Package.swift` applies to the
SIMULATOR build too, and nothing there edits it — so the build prints
*"Encountered error while building for simulator"*, **exits 0**, and leaves
whatever was in `build/ios/iphonesimulator/` alone. I installed and drove a
four-month-old app for twenty minutes before checking a timestamp. Before
trusting a simulator build:

```bash
cd mobile && flutter pub get && sed -i '' 's/\.iOS("13\.[0-9]*")/.iOS("15.0")/' \
  ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift
```

then build, and check `ls -la build/ios/iphonesimulator/Runner.app/Frameworks/
App.framework/flutter_assets/kernel_blob.bin` is from this minute.

Tests: `mobile/test/points_board_model_test.dart` (16),
`mobile/test/points_board_test.dart` (18) and
`TheMoneyBlockIsReadTests` in `scoring/tests/test_game_settings.py` (6).

## Claremont's two balls, and the settings strip on every board

Two things reported on 28 Oct 2026, from one Nassau round.

### "I don't see the bottom row with the high and low balls"

Claremont's bottom bet is **2 points a hole** — one for the lower LOW ball
and one for the lower SECOND ball — and the board drew the points line
without the balls it is made of, which makes it a figure nobody can check.

The nets were never missing: `nassau_summary` has always emitted `t1_net`,
`t1_2nd_net`, `t2_net` and `t2_2nd_net` per hole, and `NassauHoleData`
already parsed all four. **`NassauBoardData` kept only a winner enum per
hole**, so there was nothing on the board's own model to draw them from. The
model now carries `balls` — one `NassauBallsHole` per hole, Claremont only
(no second ball exists on any other variant, so the list is empty and the
block never draws).

- **Indexed by HOLE NUMBER, not arrival order.** The summary's holes come
  back in play order, so a shotgun round would have put the 7th's balls
  under the 1st's tile. The shotgun sweep's own lesson, and a test holds it.
- **`delta` is the server's.** The engine owns what a tied ball does, so the
  hole's net points are read, never recomputed from the four nets — a test
  hands in nets that would read as two points against a server saying one.
- `_BallsBlock` draws **a row per side** (`4/6`), tinted in that side's own
  colour, then the hole's points. No label column: the 9-wide alignment with
  the tiles above is the point, because a reader checks a hole by reading
  straight down it, and the sides card above already names them in order.
  A ball that side WON is bold in its colour.

The round that reported it was genuinely Claremont — worth knowing that
`_effective_variant` silently degrades a stored `claremont` to `none` off
2v2, so a non-2v2 round would have shown nothing for a different reason.

### The settings a round is played under — `services/game_settings.py`

Paul: *"It would be good to know the settings that I am playing with in the
leaderboard… In all games."*

**One writer, server-side**, because the alternative is twenty-five boards
each spelling the same six rules. That is the `gross_to_par` shape (three
copies, one wrong, failing invisibly) and the skins-rules shape (the client
re-deriving labels the server had already written), and this file records
both. The server emits the WORDS; `widgets/game_settings_strip.dart` renders
them verbatim and formats nothing — a test asserts the widget contains no
`%` and no `toStringAsFixed`.

It reads the keys the summaries already SHARE rather than asking each game:
`net_percent`, `handicap` and `handicap_mode` appear in 69, 58 and 40 places
across `services/`, because they are this codebase's conventions and not one
game's invention. A game with a rule nobody else has still says it on its
own card; this is the common floor.

- **Attached in ONE pass** at the end of `_build_leaderboard` and of
  `TournamentLeaderboardView`, not at the forty-six places a block is built.
- **Unknown values are SKIPPED, never printed.** `handicap_mode` also takes
  `keep_rotating` / `amount` / `place` in other games' fields, so a generic
  reader that printed what it found would show a golfer a slug. A missing
  key is simply a rule this game does not have.
- **The order is FIXED**, so two cards never list the same facts in a
  different order — a summary built off a jsonb column does not preserve key
  order (`console.plan._FIELD_ORDER` exists for the same reason).
- **Multi-group blocks get the chips only when every group AGREES**, which is
  every casual round and most tournaments. Two foursomes can play different
  allowances, and a strip at the top of a tab covering both would be telling
  half the field something untrue — so there the block stays blank and
  `_ByGroupView` draws each group's own chips above its card. The group list
  is found by scanning every list of dicts carrying a `summary`, because the
  key is `by_group` in some games and `foursomes` in others: picking one is
  what hid a Points 5-3-1 round from the Strokes-Off tab.
- **The stake is deliberately absent.** Its unit is game-specific — a hole, a
  skin, a point, a ball — so naming it generically would be guessing, and
  every board already carries its own money line. What belongs here is the
  rules a golfer forgets he agreed to.
- An unconfigured game (`{label}` alone) gets nothing, which is correct:
  there are no settings yet, and that is the `_NotSetUpYet` case.

**Solo states its own**, via the now-public `game_settings.handicap_chip`.
It has no `handicap_mode` to read — a solo game against par in gross is
stroke play with extra words — and it passes `always_percent`, because the
allowance is the ONLY setting that game has and 100% is as worth saying as
110%. `attach` never replaces a `settings` key a game set for itself, which
is the escape hatch for exactly this.

**Verified against the real database before claiming it**: 60 rounds, every
configured game stating its rules (`Strokes off · Claremont · Auto presses`
on the reported round), and the only blanks unconfigured games.

#### The duplication it exposed, and the part not swept

`leaderboard_screen.dart` carries **six private `_hcapLabel` copies** —
Points 5-3-1, Wolf, Rabbit, Red Ball, Three-Person Match, Sequoya 3s — each
spelling the handicap mode into its own card header as `Net (90%)` / `SO`.
The strip now states the same fact above those cards in the server's
wording. **They are NOT removed**: six card headers in a 10k-line file is
its own change, and this file's own note warns that string-matching edits
there hit the wrong card. Outstanding.

What WAS removed is the one straight collision: Sequoya's `_pressLabel`,
which wrote `Auto presses` beside a strip now saying it. Its line keeps the
half the strip cannot know — how many bets are still live. The source test
forbids the board typing any of the strip's other words, so the next one
fails there rather than shipping.

Tests: `scoring/tests/test_game_settings.py` (23 — the words, the fixed
order, the refusals, the unanimity rule), `mobile/test/game_settings_strip_test.dart`
(8) and the `claremont balls` groups in `mobile/test/nassau_board_model_test.dart`
(7) and `mobile/test/nassau_board_test.dart` (4).

## Triple Nassau's board — the picker, and no board of its own

`handoff-triple-nassau-leaderboard`, whose scope line is the whole build:
*"the board in the middle is the shared NassauBoard, mounted once and re-fed
when a match is picked. This packet adds only the match picker and the net
position card around it."*

**There is no Triple Nassau board, and that is the point.**
`TripleNassauMatch.match` is already a full `NassauSummary` — the engine has
always emitted each pair's 1v1 as an ordinary Nassau — so the picker chooses
one and hands it to the same widget the 2v2 and 1v1 boards use. `NassauBoard`
had been documented for this since it was written ("2v2, 1v1, Triple Nassau
— one match at a time") and needed no change at all: `showSides`,
`side0Colour` and `side1Colour` were already there.

What it REPLACED is the old bespoke card — a 3×3 matrix, its own press rows,
a merged round-progress scorecard and a net block, 466 lines. Two drawings
of one game is how the two come to disagree, which is the standing lesson
here.

- **Colour is identity and follows the ROSTER, not the side.** Paul is side 0
  in both his matches but Jim is side 1 in one and side 0 in another, so
  colouring by side would change a man's colour the moment the reader
  switched matches. `Halved.golfer(i)` in roster order, which is the same
  function the skins board uses — so a golfer keeps one colour across every
  board. A test hands in the two matches Jim is in and asserts he does.
- **The sides card is hidden** (`showSides: false`): the picker above already
  names the two golfers.
- **The default match follows the READER** — his first — and a watcher, who
  is in none of them, gets match 1.
- **Net position is the SERVER's per-golfer figure**, never summed from the
  three boards: each board is one match of a golfer's two, and the server has
  already added both plus every press. Zero-sum across the three, which a
  test pins. `Final` only when all three matches have settled — one live
  match keeps the whole card on `now`, because it totals all of them.
- Mint marks a golfer who is UP; everyone else is plain white. Red would be
  a second state on a card whose whole job is one number per man.

**Two things the old card had and this does not**, both deliberate but worth
a decision from Design rather than silence:
- the **merged gross scorecard** across the three matches (the Stroke Play
  tab carries gross for the round, so it is not lost, just not here);
- the note that **each match allocates its own strokes** — the pair's
  handicap difference — so a hole can be a stroke hole in one match and not
  another. That is Triple-Nassau-specific and appears nowhere else now. The
  three pills imply it; nothing states it.

**Open in the packet, left as drawn:** the net position card is dark and sits
directly under the board's dark money card, where the newer group boards use
the light ledger with a pine header. The packet says build what's drawn, so
it is dark.

Tests: `mobile/test/triple_nassau_board_test.dart` (8) — including that the
card renders `NassauBoard` and defines no `_matrix` or `_pressRows` of its
own, which is the thing most likely to creep back.

## The Stroke Play board — `handoff-stroke-play-leaderboard`

The fourth packet with the same scope line, and the one that most needed
it: *"one widget used by every stroke play leaderboard, casual and
tournament. Do not draw a second stroke play table."*

`widgets/stroke_play_board.dart` + `utils/stroke_play_board_model.dart`.
**The casual board is wired; the tournament board is not** — see the
conflict at the end, which is a design question rather than work left.

### What the packet settled that prose could not

Item 9 of `REPLY-design.md` described this board in five bullets and I
built it from them. The packet then carried a good deal those could not: a
dark header row, pine rank badges on the PAID places with `T2` for a tie,
the leader row tinted, a meta line stating basis and counting rule against
the entry, and an open card with a summary line, Out/In grids and score
marks under a legend. Two things the prose actively got wrong:

- **Gross is the raw total**, not gross-to-par. It is read against `Thru`
  beside it — 48 thru 9 says as much as +3 does, and says a different
  thing.
- **The handicap beside a name is the INDEX.** `low_net_round` now sends
  `handicap_index` on its rows; CH is what you play off today and the index
  is who you are. The board falls back to `CH n` on an older payload.

### The column set is a function of the round count, and nothing else

| Rounds | Columns |
|---|---|
| One | `# · Player · Thru · Gross · Tot · Prize` |
| Two | `# · Player · R1 · R2 · Tot · Thru · Prize` |
| Three or more | `# · Player · Prev · R(live) · Tot · Thru · Prize` |

`StrokeLayout` is that rule and the only thing that chooses between them.
**Thru moves AFTER Tot** on a multi-round board: with several rounds the
figure a reader wants first is the total, and thru qualifies the live round
rather than the event.

- **Only Tot is filled** (pine under, deep pine level, grey over). Round
  columns are plain text in the same three colours. One figure per row
  should be findable without reading, and two filled boxes is none.
- **`Prev` is the best COUNTED rounds so far**, which is what makes
  best-4-of-6 legible rather than a column of six. **Null when none of them
  counts yet**, because that is a different thing from level par and has to
  read as one.
- A round that does not count is **struck through, not hidden**: the golfer
  played it, and hiding it invites the question of where it went.
- **Paid places are read off the ROWS, not the payout table.** A tie splits
  the places it occupies, so two golfers sharing 2nd and 3rd are both paid
  while the table has one entry for each place. The server has already
  resolved it.
- Tinting: the paid rows where there is a pot, the leader where there is
  not. Both of Design's boards agree, and the rule falls out of the one
  question (is anybody being paid) rather than being two rules.

**Ranks, ties, payouts and net-to-par stay the server's.** The packet
derives them in its reference implementation, which is a browser toy
holding the whole field in a local array; we have an engine that decides
all of it. A test forbids the board sorting, ranking or assigning a payout.

233 lines of table came out of `leaderboard_screen.dart` — the chip strip,
the header row, the player rows and the inline hole strip.

### The conflict that stopped the tournament half

The multi-round LAYOUTS are built and tested; what is not wired is
`_LowNetChampView`. It is not missing data — `low_net_championship_summary`
already emits `round_ntps`, `round_holes`, `round_labels`, `round_counts`
and `round_complete`, which is everything the board needs. It is that the
tournament board carries **three things this packet does not mention**:

- **Flight headers**, interleaved in server order (`FlightHeader`). The
  Flights work put them there deliberately, and re-grouping client-side was
  rejected then as a second ordering authority.
- **Projected money in muted italic** until every round closes — *"a golfer
  thru 1 showing $48 in green was the single most misleading thing on the
  live board"*.
- **The index the cut was made on**, which is deliberately not today's
  index and not CH.

Wiring the board without them regresses three shipped decisions; wiring it
WITH them means the shared board grows a flight-header slot, a projected
flag and a second handicap field, none of which the casual board uses. That
is a design call, not an implementation one.

**Also superseded, and worth saying out loud:** this packet's `Prev ·
R(live)` answers the same question as P8's `SyncedScrollGroup` round strip
(four columns visible, scrolling, opening on the newest). Both are
Design's. The newer one wins on the stroke play board, but the strip is
also used by the Stableford championship board, which this packet says
nothing about.

Tests: `mobile/test/stroke_play_board_test.dart` (25).

## "Not all holes were scored" on a round that was — two rules, one question

Reported from the course, 26 Oct 2026: a Sixes round (production round
489) finished, Complete Round warned *"1 hole still has no score"*, and
Paul completed anyway. He was right to; the warning was wrong.

**The data was never the problem.** All four golfers had all eighteen
holes, written in hole order, no phantom, no withdrawal, full 18 in play.
`all_holes_scored` and `holes_remaining` both report done. What was wrong
is that **three different rules were answering one question and two of them
disagreed**:

| | asks |
|---|---|
| `RoundCompleteView._all_foursomes_done` (the endpoint gate, and the flag the HUB reads) | does this hole have a score from **anybody** |
| `score_entry._unscoredHoleCount` | does **every** golfer have a score on it |

So a hole with three of four reads as DONE to the hub and the server, and
as *"no score"* to score entry — which then says so about a hole that
plainly has three. Proven against production by deleting one golfer's hole
7 inside a rolled-back transaction: `all_holes_scored` stayed **True** and
`holes_remaining` stayed **0**.

**The leniency stays, and that is the important half.** It is not an
oversight: an alt-shot hole only ever has one partner posting, so a
per-golfer GATE would make every Triple Cup foursomes round permanently
unfinishable. `one_ball` covers the team formats; Triple Cup foursomes
posts per-golfer `HoleScore`s with one partner dimmed, and only the client
knows which.

So the fix is a third answer that gates NOTHING:

- **`holes_awaiting`** — holes where some golfer has no score but not
  nobody. Withdrawn golfers are not awaited (he went home, he is not
  missing a score); phantoms never are; empty on a one-ball format, where
  one score IS the hole.
- **`holes_unscored`** — `holes_remaining` as a LIST, because a count
  cannot be named in a dialog and a warning a golfer can check beats one he
  has to take on trust. `holes_remaining` is kept: the shipped client reads
  it.

**The hub now warns in the same cases score entry does**, which it never
did — it read the lenient flag and said nothing. And it uses the SHARED
`confirmCompleteRound` rather than the second copy of that dialog it had
been carrying, which is how the two came to describe one round differently
in the first place.

The copy distinguishes them and names the holes: `Hole 18 has no score` /
`Hole 7 is missing one golfer's score` / `2 holes have no score (17 and
18), and Hole 7 is missing one golfer's score`. A hole in both lists is
reported once, as blank. Lists over four holes are capped — a dialog
naming eleven is one nobody reads.

Five dedicated play screens (Wolf, Rabbit, Survivor, Sequoya 3s, Triple
Nassau) already counted only truly-blank holes and now pass the hole
NUMBERS instead of a count.

### ...and then the actual cause: the SYNC QUEUE

Paul settled it in one line: *"You can't get by the hole without completing
all four scores, so it should never be a problem."* He is right — the
per-hole gate is sound, so `holes_awaiting` should be empty in practice and
the three-of-four story cannot be what he hit.

**A score lives in three places between the tap and the server**, and the
round-level check could only see two:

1. the **scorecard** — what the server has;
2. the **sync queue** (`RoundProvider.localPendingByHole`) — saved locally
   and committed, waiting on a connection;
3. the screen's own **pending** map — tapped but not yet saved.

`submitHole` writes locally and refreshes the scorecard **only once the
queue DRAINS**, so until a hole syncs it exists in (2) alone. Ten screens
each had their own `_effectiveScores`, and **every one of them merged 1 and
3 and skipped 2** — so on a course with poor signal every hole already
finished and advanced past read as EMPTY to anything asking whether the
round was complete.

The grid still drew those holes (it overlays the queue) and
`_jumpToFirstUnplayed` still let you on (it checks `localPendingByHole` by
name), which is exactly why the warning looked absurd: the scores were on
the screen.

`utils/effective_scores.dart` is now the one merge, and all ten screens
call it. Precedence is chronological — server, then queued, then unsaved —
so a later edit always wins. Two source tests: no screen may grow its own
copy back, and any screen that merges must read the queue.

**Still open, and a design question rather than a defect:** the gate is
hole coverage, so a round CAN be completed with a golfer missing a hole —
in Sixes that hole then scores on fewer balls than the format says. Given
the per-hole gate, that should be unreachable in normal play; the warning
now says so if it ever happens.

Tests: `api/test_complete_warning.py` (7 — including that the gate is
unchanged, that a withdrawal is not a gap, and that the two kinds are never
the same hole) and `mobile/test/complete_round_warning_test.dart` (8).

## The Rabbit board — `handoff-rabbit-leaderboard`

`widgets/rabbit_board.dart` + `utils/rabbit_board_model.dart`. Three cards:
the rabbit in play (or the round's summary once it is over), where every
rabbit went hole by hole, and the ledger. It replaced a standings table and
a per-segment strip in `leaderboard_screen.dart` — 266 lines down to 42.

**The engine already decided everything the packet calls derived.** Its own
line is *"holders, leads, locks, rabbit ranges after rolling, carries and
money are all derived"*, which is true of the reference — a browser toy
replaying the holes in a local array. `services/rabbit.py` emits each
segment's real range AFTER rolling, who held it, the lead, the hole it was
decided on, its stake and its payout. So the board reads. What it derives
is layout: which rabbit is live, which hole is next, and a golfer's
per-rabbit mark.

- **A leg's win is the engine's `payout`**, never `stake × other golfers`.
  A withdrawal changes who pays and the engine knows; multiplying it out
  here would be a second opinion about money.
- **The grid shares one column width across every row**, so the holes line
  up down the card even though each rabbit covers a different stretch —
  which is the whole point of it, and what rolling makes non-obvious.
- A tile is filled in the colour of **whoever held it AFTER that hole**, so
  a rabbit that ended loose still shows who held it on the way. Loose is
  grey — the one state that is about nobody.
- The ledger marks are `+` held, `−` another golfer held it, `=` loose,
  `·` not started; **filled once the rabbit is settled, outlined while it
  is live**. "Not started" is read off the HOLES, not the leg: a leg with
  no holder yet has started the moment one of its holes is played.

### Carry — built as a setup option, OFF by default

Paul, 28 Oct 2026: *"Add carry as a setup option, defaulting to no."*
`RabbitGame.carry` (`games/0099`), `setup_rabbit(carry=False)`, and a switch
on the setup screen.

**It is SETTLEMENT only.** Who holds a rabbit and when it is decided are
untouched, which is what kept the change to one loop and what lets a test
flip the switch on an already-scored round and compare the money. Three
rules that loop has to get right:

- **carries ACCUMULATE** across consecutive loose rabbits — three loose in a
  row hand all three stakes to whoever takes the fourth;
- **a carry rides on the LIVE rabbit too**, so the card says what is
  actually at stake on the hole in front of you (`$10 riding · $5 carried`);
- **it stops at the first incomplete leg.** The money is on that leg, not on
  every unplayed one after it.

**A loose LAST rabbit is won by nobody** — there is nothing to carry into,
so that stake is never collected. It falls out of the walk rather than
being special-cased, and the board says `no winner` there while a loose
rabbit that did roll forward says `carried`: the stake went somewhere, which
is a different thing to be told.

**`max_liability` does not move.** A carry MOVES a stake rather than adding
one, so the loop counts each leg's OWN stake once — a group must never be
told it is playing for more than it put up. Pinned by a test.

`carried_in` is on every segment (0 without carry) and is what the board's
`$5 carried` line reads. Verified against a real round: leg 3 loose rolls
its $2 into leg 4, which becomes worth $4 and pays $8, and the ledger stays
zero-sum.

### The other setup option in the packet still does not exist

**Rolling a decided rabbit forward is UNCONDITIONAL**, not an option.
`setup_rabbit` takes `accumulate`, `num_segments`, `handicap_allocation`,
`extra_rabbits` and now `carry`, and nothing else; a rabbit won on the 4th
always ends there and the next always starts on the 5th. (The half-stake
one-hole extra the packet describes IS built, under `extra_rabbits`.)

So the board draws no `Rolls on` chip. It would tell a group it had chosen
something it never did, which is worse than the setting being missing.

`rabbit_summary` states its own `settings` rather than leaving it to
`game_settings.attach`, which reads the keys the summaries SHARE: how a
rabbit is caught and how the round is split are Rabbit's own rules. Same
escape hatch Solo uses. The split is read off the holes actually in play,
so a nine-hole round says `3 × 3` rather than inventing eighteen.

Tests: `mobile/test/rabbit_board_test.dart` (17), `CarryTests` (9) and
`SettingsChipsTests` (5) in `scoring/tests/test_rabbit.py` — including that
`Rolls on` is never claimed, and that carry stays zero-sum and never moves
the total at risk.

## Annandale Friday (`annandale_friday`) — built (engine, API, group size, mobile)

`~/Downloads/handoff-annandale-friday`. One group of **5 or 6** on one card;
the teams make three better-ball Nassaus — three pairs each playing the other
two (6), or a pair against each pair of a three (5, the pair in all three).
Four golfers is not offered: a foursome plays a standard Nassau.

**Built like Triple Nassau**: `games.AnnandaleFridayGame` (OneToOne foursome,
`teams` = player-id lists in display order) over three child `NassauGame`
rows, `game_type` `af_1/2/3`, linked by `NassauGame.annandale_game`
(`games/0100`, `tournament/0081` enum refresh). The whole Nassau engine is
reused. Two differences from Triple Nassau, both free:
- **Handicap is the FIELD's** (off the group's low man by default), so a
  golfer takes the same strokes into every match. The `af_*` slugs are not
  in `TRIPLE_CHILD_SLUGS`, so `_get_score_index` already routes them to the
  field-wide index.
- **The matches are 2v2**, so 2nd-ball tiebreak (default ON) and Claremont
  apply. With both asked for, Claremont wins — its 2nd ball is already a bet.

`services/annandale_friday.py`: `shape_problem` (pure; the sentence the setup
screen's matches box shows), `matches_for` (pure), `setup_annandale_friday`,
`calculate_annandale_friday`, `press_annandale`, `annandale_friday_summary`.
A golfer's net is read off each match's `payouts.total`, never re-summed.

- **Presses are the engine's rule — the NINE at 2/4/6/8 down.** Paul, 29 Oct
  2026, over the packet's reference, which presses on the LATEST bet (its
  "press 2 starts on 8" example is where the two differ). One press rule for
  every Nassau in the app.
- **Manual press: 1 down or level** (`press_allowed`), wider than a plain
  Nassau's `can_press`, which needs a side to be down.
- **Teams lock at the edit ceiling** (`AnnandaleLocked`); reordering inside a
  team is not a redraw. A settings-only save updates the three matches IN
  PLACE, because rebuilding them deletes the manual presses.

**Fixed in the shared engine:** `add_manual_press` recalculated and read the
loss cap off the foursome's PRIMARY Nassau rather than the `game_type` it was
given. For a child match (Triple Nassau too) the cap lookup found nothing and
was skipped, so a side past its cap could press for free.

**API.** `GET/POST /api/foursomes/{id}/annandale-friday/setup/` (the GET
returns the packet's defaults with `configured: false` before setup),
`GET …/annandale-friday/` and `POST …/annandale-friday/press/`
`{match: 1|2|3, start_hole}`. A shape or lock refusal is a 400 whose
`detail` is the setup screen's own sentence, and a `bet_unit` sent with a
refused setup is rolled back. Recalc after a posted score, the leaderboard
block (`games['annandale_friday']`, `by_group`), `configured_games` (the
container once, never `af_*`) and `services.settlement` are wired. The
summary carries raw `variant` / `press_mode` so `game_settings` builds the
strip in the words every Nassau uses.

**The recalc is keyed off the slug alone.** The children are not `nassau`
rows, so `calculate_all_nassau` only reaches them when a plain Nassau is also
active; `test_a_posted_score_moves_the_matches` fails without the dispatch.
**The score endpoint already took six golfers** — nothing there caps at four.

Not wired yet: the watch page, the Live Activity card, and the strip's loss
cap reads `Loses at most $50` where the cap is per side PER NASSAU.

Tests: `scoring/tests/test_annandale_friday.py` (32) and
`api/test_annandale_friday.py` (24, six and five). Already built and not
part of this: the two Skins options (`skin_minimum` / `birdie_steal`).

**Group size — `services.round_setup.max_group_size(round)`**, the one
answer to how many golfers a card holds: 6 when `annandale_friday` is in the
round's active games or is its `primary_game`, else 4. Read by
`setup_round` (explicit groups, and the automatic split — which put six
golfers into two THREES with no error, a different round), by add-player
and by move-player. A group over the cap at setup was a ValueError that
500ed; `RoundSetupView` now returns it as a 400. The game's own setup still
insists on exactly 5 or 6; this only stops the round refusing the card
first. Client mirror: `GameMeta.maxGroupSize` read through
`maxGroupSizeFor(active)` (the largest wins, so a side game cannot shrink
the card), used by the casual screen's `_nextAvailableGroup`. Tests:
`api/test_group_size.py` (12), `mobile/test/group_size_test.dart` (5).

**Mobile.**
- **Create round:** a `5–6` segment (`kFiveOrSix`) on Who's playing.
  `fitsFiveOrSix` requires the game to seat more than four on ONE card, not
  just accept the count — Stroke Play and Stableford take any number, and
  under the plain size check they appeared here as primaries that would have
  split six golfers into two groups. Annandale Friday is the one primary, with
  its blurb under the chip. Side games under it are exactly Skins, Spots and
  Stroke Play (`sideGamesFor`), and their foursome-sized `maxPlayers` is not
  applied to a side game riding a primary that seats more.
- **Setup** (`annandale_friday_setup_screen.dart`, `/annandale-friday-setup`):
  Teams (team buttons per golfer, the matches box shows the three Nassaus or
  the refusal sentence and gates Next), Nassau, Side games. Step 3 adds side
  games through `client.addSideGame` and opens their setup via
  `utils/side_game_routes.dart` — lifted out of `round_screen.dart` so the
  hub and this step share one table. The team rules are
  `utils/annandale_teams.dart`, the server's `shape_problem` /
  `matches_for` word for word.
- **Score entry** is the SHARED screen, not a dedicated one — so the sync
  queue, combo-tee chip and Spots capture come for free (the dedicated
  screens are where those get missed). `_keypadRound(rp)` is the one gate for
  the 40 Balls keypad (40 Balls, or Annandale Friday as primary). Golfers are
  ordered and headed by team; the stroke dots read the game's own handicap.
  Once the hole's last score is in, `AnnandaleHoleTray` replaces the keypad:
  each match's result and why (`net 4 v 5`, or `2nd ball 5 v 6`), the bets
  after it, any press starting next hole, a Press button when the match's
  `can_press`, and the skin. "Edit scores" or tapping a golfer brings the
  keypad back for one score.
- **Board:** `_AnnandaleFridayGroupCard` — match pills, the shared
  `NassauBoard` with `showSides: false`, and a light net-position ledger off
  the server's per-golfer `net`. The tab reads "Nassau".
- Colours: `widgets/annandale_friday.dart` holds the team colours (pine,
  clay, slate; a five's three is clay) for all three screens, plus light
  tints for the dark tray.

Tests: `mobile/test/annandale_friday_test.dart` (24), the tray against
`test/fixtures/annandale_friday_hole2.json` — REAL engine output, not
hand-written JSON. Regenerate it from the engine when the summary changes.

#### Six things a phone found that 56 tests did not
Played on an iPhone 13 mini against the local server (29 Oct 2026). Every
one was invisible to the suites, and two of them are money:
- **The keypad never posted the hole.** The inline picker posts on the last
  score; the keypad was 40 Balls', and 40 Balls posts with its COUNT. This
  game has no count, so the hole sat unsent and the tray rose over nothing.
  The keypad now posts and stays when it completes (or edits) a hole.
- **Settlement netted the UNCAPPED total.** `payouts.total` ignores the loss
  cap; `total_capped` is the settled figure. With this game's per-side,
  per-Nassau cap on, a golfer would have paid past it.
  `test_the_loss_cap_holds_in_settlement` fails on the old line.
  `services/triple_nassau.py` reads `total` the same way — not fixed here.
- **The ledger read $0 under a board reading +$20 "now".** It showed the
  settled figure mid-round; the summary now carries `live_net` (the board's
  `live_total`, summed per golfer) and the ledger shows it until final.
- **The keypad told the low man "1 stroke".** It read the scorecard's stored
  full-handicap strokes. The summary now carries `strokes_in_play` per golfer
  (the field allocation, read off the matches' own teams) and the keypad
  allocates that by stroke index — no second copy of the handicap rules.
- **The keypad coded keys against the hole's par**, so on mixed tees a
  woman's par read as a bogey. It uses the golfer's own par (helps 40 Balls).
- **The tray could not say who was up**: the light golfer tints made pine and
  slate the same grey on the dark tray. It uses the reference's own dark
  variants (`#3BD89A` / `#F2A86E`, and slate moved from the reference's `#AFC0D8` to `#8FB4FF` because it matched the label grey) with NEUTRAL white-55% labels, and a "Wins hole" pill in the
  winner's colour.
Also: each setup step opens at its top, and the press stake follows the bet
until it is edited.

#### One place for money, and it shows what it is made of
Paul, 29 Oct 2026: *"Paul and Jim are +40 but net position now is +70 and
the bet is 10 and the press $10 — a lot of numbers that are confusing."*
Every figure was right; nothing said how they related. +$40 was ONE match
(the board's "each · now"), +$70 both of Paul's, and "Bet $10 · Press $10"
were prices sitting under winnings.
- The board passes `noMoney: true`: it states the bets, the ledger states
  the money. Two money figures for one golfer on one screen is the problem.
- The ledger shows each total's parts, one per match, from the server's
  `by_match` (`net`, `live_net`, `vs_ids` per golfer) — so they add up by
  construction (`test_each_total_is_the_sum_of_its_matches`).
- The stakes are chips in the settings strip ("$10 a bet", "$10 a press"),
  from `services.annandale_friday.settings_chips` on the leaderboard row —
  `game_settings` leaves stakes out generically; this game's unit is plain.
- A live press on the SHARED Nassau board reads "1 UP · 1 to play" or
  "1 UP · dormie", not "· live" (`_toPlay` walks the window, so a shotgun
  press wrapping the 18th counts right). Reaches every Nassau board.

- **With `noMoney`, the overall is a light "18" card naming the leader**
  ("Jim & Paul 5 UP · thru 8"), not the dark money card holding a status
  line — that made the 18 the loudest thing on the board and said only by a
  swatch whose lead it was. Shared board, so the CUP match board (the other
  `noMoney` caller) gets it too.
- Each match's sides come back in CARD order: the Nassau engine lists a
  team in database order, so the board said "Jim & Paul" under a pill
  saying "Paul & Jim".

- **The board sits in a box that goes round exactly what the pick changes**
  (`widgets/match_panel.dart`, Paul 29 Oct 2026): Front, Back and the 18,
  opened by a line naming the match. The selected pill wears the box's own
  outline (`MatchPanel.accent`), so pill and box read as one control. The
  settings strip and the net-position ledger total EVERY match and stay
  outside. **Deep pine, not pine**: pine is the first team's colour and a
  settled card is bordered in its winner's, so a pine box read as "Paul &
  Jim lead". Triple Nassau uses the same box. Tests:
  `mobile/test/match_panel_test.dart` (7).

**Not built from the packet:** the hole header's "2 skins · 1 carried from 6"
(the tray carries the skin instead), and the Skins card's settings summary
on setup step 3.

### The lock screen — `handoff-annandale-friday-lock`

`services/live_activity_annandale_friday.py`, **in `UNSHIPPED_KINDS`** until
the build carrying the layout ships. It is the Triple Nassau card with the
matches between TEAMS, and it imports that module's bet key, figure and press
chip rather than copying them, so `3&2` and `+1` cannot come to mean two
things on two cards.

- **Two-line labels**: `YOU` over `v DAVE·RAY`; the match the reader is not in
  reads `DAVE·RAY` over `v JIM·SAM`. `StripCol.label2` in Swift, with
  `dots[0]` / `dots[1]` beside each line; absent on every other card.
- **Colour is the team, and the same as the score tray** — pine `#3BD89A`,
  clay `#F2A86E`, slate `#8FB4FF` by team index, for every reader (revised
  packet; the first build made the reader's team blue, which put one team in
  two colours between tray and lock screen). Because mint is now a team's
  colour, the press chip is amber `#FFD36B` and the closing net is white.
  With five, the three is one team and one colour.
- **Weight follows the reader**: two of three with six, all three for the pair
  with five, two of three for one of the three. A watcher holds nothing back.
- **One departure**: with five, a golfer in the three partners a different man
  in each match, so his side reads `YOU·SAM` — the bare `YOU` the packet draws
  would hide the one thing that differs between his two columns.
- Exposure is each match's range summed, **each match clamped to its own loss
  cap first** (the cap is per side per Nassau), and the footer says
  `$10 a bet · capped $20`. **The clamp is symmetric**: with two sides the
  loser's cap is the winner's ceiling, which is what the engine's
  `_clamp_to_cap` does. The revised packet draws a $20 cap as `−$40 to +$60`
  — capping only the floor — which would promise a win nobody can be asked to
  pay; the card shows `−$40 to +$40`. The final reads `total_capped`, the
  figure settlement uses.
- Compact island: the reader's matches only, `AS` for level, `+N` presses.

#### The pushes — the first that differ between phones
`services/live_activity_annandale_push.py`. An auto press, a manual press, and
a nine or the overall closing out ring **only the golfers in that match**; the
third match never pushes (each Nassau settles on its own). `push_round` asks
`annandale_alerts(round)` ONCE per posted score and matches each token's user
to his golfer — the cup's alerts were one per round, these are per player.

- **Fired once**, via `AnnandaleFridayGame.announced` (`games/0101`). NULL
  until the first push, which records what has already happened WITHOUT
  announcing it, so a round under way when this ships does not ring six
  phones with a whole front nine.
- **No "who pressed" is stored.** An auto press's down side is read off the
  nine's margin on the hole that fired it (the press's own first hole is not
  played yet, so that is the last hole in the list); a manual press names its
  presser only when a side is down, and the match and holes alone when level.
- **A zero press stake reads `A new press`**, not the bet's figure — the
  engine pays nothing on it.
- Caught by the tests, worth not repeating: the event builders are closures
  in a loop, and one that read `sides` late named the LAST match's teams on
  every push. Every loop value is bound as a default.

Tests: `scoring/tests/test_live_activity_annandale_friday.py` (23). Not yet
seen on a device: the card is type-checked, not measured against the ~160pt
ceiling the packet puts it at 127.

Still to do: the watch page, and moving the guide from `/preview/` to
`/games/` LAST.
