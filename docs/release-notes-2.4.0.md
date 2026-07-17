# Halved 2.4.0 (build 16) — Release notes

Version in `mobile/pubspec.yaml` → `2.4.0+16` (build must exceed the last
TestFlight upload; build 15 was the first upload, 16 adds the fixes below).
Backend `CLIENT_MIN_VERSION` left at `2.1.0` (this release is backward-compatible).

---

## What's New (user-facing / App Store "What's New" copy)

- **Honors** — a new side game. Win a hole outright and you hold "the honor,"
  scoring a point every hole until someone beats you. Net / Gross / Strokes-Off,
  with pay-vs-average / pay-above / pay-the-leader settlement.
- **Share your scorecard** — text a copy to your group. A clean portrait card
  (front nine, back nine, gross + net totals) you can send straight to Messages.
- **Total $ tab** — one leaderboard tab that nets every game together so you can
  see who owes whom across the whole round.
- **Multi-group Skins** — link your foursome into a bigger multi-group skins
  pool; your scores flow in automatically and you get the pooled leaderboard.
- **Spots & junk by hole** — see exactly which hole each spot or skins-junk was
  scored on, per player.
- **Smarter recent courses** — a course from a round a friend added you to now
  shows up in your "recent courses" when you start your own round.
- **Refreshed look and feel** and clearer casual-round naming.
- **Faster score fixes** — edit any already-entered score right on the row
  (inline), on every game screen — no more pop-up dialog.
- **Live leaderboards** — they refresh automatically when you come back to them
  or switch between game tabs.

---

## Detailed changelog

### New features
- **Honors side game** (backend + mobile): carry-the-honor points game, derived
  from entered scores. Defaults to Strokes-Off-Low; optional subset of players;
  settlement via the shared wager engine. Tie rule: a tie that includes the
  holder keeps it; a tie that beats the holder is broken by walking back through
  prior holes, and dies (goes loose) if never separated.
- **Share Scorecard**: portrait two-nines card (Stroke-Play styling — highlighted
  header, thin hole dividers, tinted subtotals) captured to a PNG and shared via
  the native share sheet. Entry point: leaderboard ⋮ menu. Scales to fit any
  phone while capturing at full resolution.
- **Total $ / Settlement tab** on the leaderboard (nets all games together).
- **Multi-group Skins linkage** — feed a foursome's scores into a shared
  cross-round skins pool.
- **Spots / skins-junk by hole** — per-player, per-hole display.
- **Recent courses across accounts** — courses from phone-matched rounds you
  played in other accounts are cloned into your account and surface in the
  round-creation recents (excludes your home course, which is pinned separately).

### UX / look & feel
- Refreshed branding/theme; casual-round naming.
- **Inline score editing everywhere** — tapping an already-entered score makes
  that row active and shows the inline picker (retired the modal score sheets on
  Nassau, Points 5-3-1, Skins, and Pink Ball).
- **Dedicated game screens aligned to the casual score screen**: team-colored
  row backgrounds + left bar for non-active players (Nassau, Quota Nassau); the
  net-par picker cell always renders clean (no bogey square); tee label removed
  from the golfer rows.
- **Course picker**: tap the course name (not just the pencil) to change courses.
- **Leaderboards refresh** on return (RouteAware) and on game-tab switch.

### Fixes
- Honors migration split so the participant column is added correctly on an
  already-migrated DB.
- Guard against a Sixes `IndexError` when a foursome carries more standard
  segments than the round has holes for.
- Honors reports in `configured_games` so the hub shows "Edit" vs "Set up."
- Nassau press labels / early-decided announcements; hub plays-to Playing
  Handicap (from earlier in the cycle).

### Fixes added in build 16
- **Watch link no longer forces re-login.** Tapping a spectator/watch link as an
  already-signed-in Halved user opened a blank login screen (the deep-link
  handler read the session as not-yet-restored and pushed `/login`). The watch
  token is now stashed and opened once the session is applied and the app is
  past the splash — a logged-in user goes straight to the round; a signed-out
  user is taken there right after logging in. (`utils/deep_links.dart`,
  `gDeepLinkReady` in `main.dart`.)
- **Share Scorecard now opens the iOS share sheet.** `Share.shareXFiles` was
  throwing a `sharePositionOrigin` PlatformException; it now passes a valid
  source rect so the share sheet (and the iPad popover) appears correctly.

---

## Pre-submit checklist
- [ ] `flutter pub get` (no new native deps in this release).
- [ ] Build a release IPA / archive with build number **16**.
- [ ] **Manually verify on a physical iPhone**: leaderboard ⋮ → Share scorecard
      → Share/Text → the image hands off to Messages and looks correct.
- [ ] Smoke-test Honors, inline score editing, and the Total $ tab.
- [ ] Confirm the app points at the **production** backend (no `USE_LOCAL`).
- [ ] Upload to TestFlight → submit for review.
