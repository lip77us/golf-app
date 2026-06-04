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

Tests: `accounts/test_otp.py` (normalization, request→verify happy paths,
self-signup, wrong/expired/too-many-attempts, rate-limit, phone uniqueness, and
legacy password login still works).

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

## Stableford — hidden until built out
Stableford is **hidden from the tournament menu** (App Store completeness: it
was only partially working — no per-hole points under score entry or on the
leaderboard).
- The per-round `stableford` catalog entry is `enabled: false` (already hidden
  from `tournamentRoundGames`).
- The **Stableford Championship** option is commented out of
  `kChampionshipGames` in `game_catalog.dart`; its display label is preserved
  in `_kExtraGameLabels` so any existing tournament still renders the name.
  Helper text in `new_round_wizard.dart` that listed "Stableford" as a
  selectable championship was updated to drop it.
- Re-enable by uncommenting the `kChampionshipGames` line and restoring the
  helper-text wording.

**TODO before re-enabling (user requirements):**
1. Track and display Stableford points per hole below score entry.
2. Show Stableford points/totals on the leaderboard.
3. Add a Stableford setup screen with an **editable points-per-score table**
   (e.g. eagle/birdie/par/bogey/double values) so the user can modify the
   points awarded per score.
4. Build **both a casual version and a tournament version**:
   - Casual: re-enable the per-round `stableford` catalog entry (`casual: true`,
     `enabled: true`) with its own setup + scoring, like the other casual games.
   - Tournament: the `stableford_championship` accumulator (uncomment in
     `kChampionshipGames`) that totals points across rounds.

## Nassau — implemented
Enabled in `game_catalog.dart` (casual, 2–4 players; excludes Sixes/Points).
Full stack present: `nassau_setup_screen.dart` + `nassau_screen.dart`,
`/nassau-setup` + `/nassau` routes in `main.dart`, and backend
`NassauResultView` / `NassauSetupView` / `NassauPressView`. (This supersedes
the earlier "not yet implemented" note; the "Implemented casual games" list
above predates Nassau and Triple Cup / Match Play / Multi-Skins.)