# App Store review notes — Halved 2.0.0

Paste the **"App Review Information → Notes"** block below into App Store Connect
for the 2.0.0 submission, and put the demo credentials in the **Sign-In
Information** fields (check "Sign-in required").

---

## Sign-In Information (App Store Connect fields)
- **User name:** `reviewer`
- **Password:** `HalvedDemo2026`

(These belong in the dedicated Sign-In Information fields *and* are repeated in
the notes below so the reviewer also sees the account name + the
which-button-to-tap instruction.)

---

## Notes (paste this)

Halved is a golf scorekeeping app for tracking friendly betting games (Skins,
Nassau, Sixes, Stableford, Match Play, etc.) during a round.

HOW TO SIGN IN (please read — the default screen is phone-based):
The app opens to a phone-number sign-in screen that texts a one-time code. That
SMS can't reach your review device, so please use the username/password path
instead:

1. On the sign-in screen, tap **"Sign in with a username instead"** (link below
   the phone field).
2. Enter:
   • Account name: **DemoClub**
   • Username: **reviewer**
   • Password: **HalvedDemo2026**
3. Tap Sign In.

This demo account ("DemoClub") is pre-loaded with sample players, courses,
completed and in-progress rounds, and tournaments so every screen has content.

WHAT YOU CAN TRY:
- Open a casual round from "Casual Rounds" and tap into it to view the
  scorecard and the live Leaderboard.
- Tap "Start your first round" (drawer) or the New Casual Round button to see
  the guided setup wizard (course → players → game).
- Open a tournament from "Tournaments" to see multi-foursome standings.

ACCOUNT DELETION (Guideline 5.1.1(v)):
In-app account deletion is at **Settings → Delete Account**. To test it without
affecting the main demo login, a second account is provided:
   • Username: **reviewer_delete**
   • Password: **HalvedDemo2026**
(Sign in with that one via the same "Sign in with a username instead" path, then
Settings → Delete Account.)

No special hardware is required. The app sends no data to third parties beyond
the app's own backend and an anonymous golf-course lookup (no personal data in
that lookup). Privacy policy: https://halved.golf/privacy

---

## Pre-submit reminders
- [ ] `seed_demo --reset` has been run against **prod** (the reviewer hits prod).
- [ ] Build is **2.0.0 (4)** — `pubspec.yaml` `version: 2.0.0+4`.
- [ ] Leave `CLIENT_MIN_VERSION=1.1.0` on Railway until 2.0.0 is live (don't force
      an update with no downloadable build).
- [ ] Privacy policy URL set in App Store Connect → App Privacy.
