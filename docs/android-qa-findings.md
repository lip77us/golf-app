# Android device QA — findings

Run 2026-08-30 on a **Motorola moto g play (2024)**, Android 14 / API 34,
720x1600 at density 280, 4 GB RAM — deliberately the low end of what a tester
might carry. Build: `app-release.apk`, versionName **2.7.0**, signed with the
upload key, pointed at **prod**.

Driven over `adb` from the Mac. Navigation was kept read-only throughout — no
rounds created, no scores entered, nothing deleted — because the device was
signed into the live production account.

Companion to `play-store-checklist.md` §8, which lists what to test and why.

---

## Passes

- Installs, cold-launches and runs on real Android 14 hardware.
- **Back unwinds the navigation stack correctly**, one level per press:
  segment draw → hole play screen → round detail → rounds list. The process
  survived every press, and the Completed/Active tab selection was preserved
  on the way back — which is more than the minimum bar.
- The coach-mark bottom sheet ("What do these buttons do?") dismisses with back.
- `POST_NOTIFICATIONS` prompt appears and grants (`granted=true, USER_SET`).
- The app exits cleanly once the stack is genuinely empty.
- Layout holds up at 720x1600 / density 280 — no clipping, no overflow, no
  truncated controls on a screen far smaller than the iPhone it was designed on.

---

## 1. Back at the launch screen doesn't exit the app

**Reproduce:** cold-launch (`am force-stop` first), land on Rounds, press back
once. You get **Tournaments** — a screen the user never opened.

**Cause:** `screens/tournament_list_screen.dart:129`. `/tournaments` is the
post-splash root (`main.dart` → `pushReplacementNamed('/tournaments')`), and on
first load with no active tournaments it **pushes** `/casual-rounds` on top.
The comment says push rather than replace is deliberate, "so the back-arrow
still brings them back here".

**Why it reads differently on Android:** the Rounds app bar shows the hamburger,
not a back chevron, so there is no visible affordance pointing at the screen
underneath. On iOS the edge-swipe gesture still reveals it, which is presumably
why this has never felt wrong. On Android, back at the first screen you see is
expected to leave the app; landing on "No active tournaments" instead reads as
a misfire.

**Fix:** `pushReplacementNamed` instead of `pushNamed` at that line. Rounds
becomes the root, back exits, and Tournaments stays one tap away in the drawer —
where it already is, which is what makes the hidden stack layer unnecessary.

---

## 2. Offline shows a truncated list with no indication, and doesn't recover

**Reproduce:** with the Completed tab showing **27 rounds**, `adb shell svc wifi
disable`, then refresh. The list drops to **4 rounds**. No offline banner, no
stale-data marker, no error. Re-enable wi-fi and the list **stays at 4** until
you manually refresh, at which point all 27 come back.

Two distinct gaps:

- **No offline signal.** A user seeing 4 of their 27 rounds with no explanation
  will read it as data loss, not as a cache. This is the more damaging half —
  it looks like the app lost their history.
- **No refresh on reconnect.** `connectivity_plus` is already a dependency and
  `sync/sync_service.dart:61` already subscribes to connectivity changes, so
  the hook to re-fetch on reconnect is likely a small addition rather than new
  plumbing.

The 4 rounds shown offline are a genuine subset of the 27 (the Aug 21 Corica
Nassau appears in both), so this is a local-cache fallback behaving as built —
it is the silence around it that's the problem.

---

## 3. "View Scorecard" on a COMPLETE round opens the segment draw

On the **completed** Aug 24 Sixes at Tilden Park — status COMPLETE, all three
matches showing results — "View Scorecard" landed on the Segment 2 draw:
*"Who plays together next? Two pairings are left. Spin to pick partners for
Segment 2."*

Not tested further; spinning would have written to production. Not
Android-specific — worth reproducing on iOS. Either the round completed with an
undrawn segment and this is the app resuming correctly, or a completed round is
offering an action it shouldn't.

---

## 4. Cosmetic: server version drift

The About dialog reports **App version 2.7.0 / Server version 2.1.0**.
`SERVER_VERSION` is informational only, but it hasn't tracked the backend.

---

## Not yet tested

Each of these either leaves the app or writes to production, so they were left
for a supervised pass:

- **SMS invite hand-off** — `ACTION_SENDTO` into the messaging app, and the
  return journey via back. The Android-specific half of `packages/halved_sms`.
- **Share sheet** ("Share Watch Link").
- **Push on this handset** — needs a send from the Railway shell. Note the two
  known defects from the 2026-08-22 emulator session still stand: foreground
  pushes display nothing, and notifications land in FCM's fallback channel
  because `halved_default` is never created.
- **Phone-OTP login on this device** — the handset arrived already signed in, so
  the real-SMS login path was never exercised here.
