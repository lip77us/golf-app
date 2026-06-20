# App Store review notes — Halved (phone-only build)

Paste the **"App Review Information → Notes"** block below into App Store Connect,
and put the demo phone + code in the **Sign-In Information** fields.

> **Before submitting** — set these on Railway and run **`seed_demo --reset`
> against prod** so the demo numbers map to seeded users:
> ```
> REVIEW_BYPASS_PHONE=+13105550101,+13105550102
> REVIEW_BYPASS_CODE=246810
> ```
> (`246810` is arbitrary and rotatable — change both this and the App Store
> Connect field together. It only works for the two 555-01xx numbers below.)
> `+13105550101` = reviewer (admin); `+13105550102` = reviewer_delete (for the
> deletion check). Both are fictional NANP 555-01xx numbers — **no real SMS is
> sent**; the backend accepts the fixed code for these numbers only.

---

## Sign-In Information (App Store Connect fields)
- **User name:** `3105550101`
- **Password:** `246810`  (the 6-digit code set above)

---

## Notes (paste this)

Halved is a golf scorekeeping app for tracking friendly betting games (Skins,
Nassau, Sixes, Stableford, Match Play, etc.) during a round.

HOW TO SIGN IN (phone-number login — please read):
The app signs in with a phone number + a one-time SMS code. For review we set up
a demo number that accepts a fixed code WITHOUT sending a text, so you don't need
to receive an SMS:

1. On the sign-in screen, enter phone number: 3105550101
2. Continue / send code.
3. Enter the code: 246810
4. You're signed in to the demo account ("DemoClub"), pre-loaded with sample
   players, courses, rounds, and tournaments.

WHAT YOU CAN TRY:
- Open a casual round from "Casual Rounds" and tap in to see the scorecard and
  the live Leaderboard.
- Tap "Start your first round" (drawer) to see the guided setup wizard.
- Open a tournament from "Tournaments" for multi-foursome standings.

NEW IN THIS VERSION (optional):
- Las Vegas: start a casual round with 4 players and pick "Las Vegas" — the
  Leaderboard shows each 2-player side's running total and a hole-by-hole grid.
- Follow friends: the demo account is added to another group's rounds, so the
  Casual Rounds / Tournaments lists show entries flagged "Observing" (watch-only,
  eye icon) alongside rounds you play in. Tapping an "Observing" round opens a
  read-only leaderboard + scorecard.
- Course search: in round setup, tap the course field and type "Corica" to find
  and add a course (the search merges your courses, a shared catalog, and a full
  course database into one list).
- Scorecard: open any round's Leaderboard and tap the scorecard icon (top right)
  to view the full card — works during and after the round.

ACCOUNT DELETION (Guideline 5.1.1(v)):
In-app deletion is at Settings → Delete Account. To test it on a deletable
account, sign in with demo number 3105550102 and the same code
246810, then Settings → Delete Account.

No special hardware is required. The app sends no data to third parties beyond
the app's own backend and an anonymous golf-course lookup (no personal data in
that lookup). Privacy policy: https://halved.golf/privacy

---

## Pre-submit reminders
- [ ] `REVIEW_BYPASS_PHONE=+13105550101,+13105550102` + `REVIEW_BYPASS_CODE` set
      on Railway (deployed).
- [ ] `seed_demo --reset` run against **prod** (so the two numbers map to users).
- [ ] `PASSWORD_LOGIN_ENABLED` left unset/false — password login stays off.
- [ ] iOS build is 2.1.0 (2.1.0+5); privacy-policy URL set in App Store Connect.
- [ ] Force-upgrade: ensure Railway `CLIENT_MIN_VERSION=2.1.0` (or clear the env
      so the 2.1.0 code default applies). Safe to set now — 2.0.0 only gets a
      soft update nag, and 2.1.0+ is hard-blocked below this (no dismiss).
