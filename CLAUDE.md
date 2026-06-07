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