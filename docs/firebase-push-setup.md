# Firebase / APNs setup for push notifications

Provisioning the push pipeline (FCM + Apple APNs). Companion to
`docs/push-notifications.md` (design) — that's built through Phase 1 and runs on
`PUSH_BACKEND=console`; this guide is what flips it to real delivery
(`PUSH_BACKEND=fcm`). Bundle this App Store build with the Twilio toll-free
cutover so it's one submission.

**Your app identifiers (use these exactly):**
- iOS bundle ID: `us.lipkin.golfapp`
- Android application ID: `com.lipkin.us.golf_mobile`

Cost: Firebase Cloud Messaging is **free**. Requires your existing Apple
Developer membership.

---

## What's a secret vs. not (important)

- `GoogleService-Info.plist` (iOS) and `google-services.json` (Android) are
  **client config** — they ship inside the app and are **safe to commit** to the
  repo.
- The **service-account private-key JSON** (backend → FCM) is a **SECRET** —
  **do NOT commit it.** It goes into a Railway env var only.

---

## Part A — Firebase project (console.firebase.google.com)

1. **Create a project** (e.g. "Halved"). Disable Google Analytics if you don't
   want it (not needed for push).
2. **Add the iOS app:** Project Overview → Add app → iOS.
   - Apple bundle ID: **`us.lipkin.golfapp`**
   - App nickname: "Halved iOS" (optional).
   - **Download `GoogleService-Info.plist`** → hand it to me.
3. **Add the Android app:** Add app → Android.
   - Package name: **`com.lipkin.us.golf_mobile`**
   - **Download `google-services.json`** → hand it to me.

(You can skip the "add SDK / run script" steps the wizard shows — I handle the
Flutter wiring.)

---

## Part B — Apple APNs auth key (developer.apple.com)

FCM delivers to iPhones via Apple's APNs, so Firebase needs an APNs key.

1. **Enable Push for the App ID:** Certificates, Identifiers & Profiles →
   **Identifiers** → `us.lipkin.golfapp` → check **Push Notifications** → Save.
2. **Create the APNs key:** Keys → **+** → name it "Halved APNs" → check
   **Apple Push Notifications service (APNs)** → Continue → Register.
   - **Download the `.p8` file** — Apple lets you download it **once**, so keep
     it safe.
   - Note the **Key ID** (shown on the key page).
3. **Find your Team ID:** top-right of the Apple Developer membership page
   (10-char string).

→ Hand me (or hold): the **`.p8` file**, the **Key ID**, and the **Team ID**.

---

## Part C — Connect APNs to Firebase

Firebase Console → **Project Settings** (gear) → **Cloud Messaging** tab →
**Apple app configuration** → **APNs Authentication Key** → **Upload**:
- the `.p8` file, the **Key ID**, and the **Team ID** from Part B.

(One key works for all your iOS apps / both debug + production APNs.)

---

## Part D — Backend service-account key (the secret)

Firebase Console → **Project Settings** → **Service accounts** →
**Generate new private key** → confirm → a **JSON file downloads**.

This authenticates the Django backend to FCM (HTTP v1). Treat it like a
password:
- **Don't commit it.**
- On **Railway**, add it as an env var (I'll confirm the exact name when I wire
  `_send_fcm`; likely `FCM_SERVICE_ACCOUNT_JSON` holding the JSON contents, or a
  mounted secret file). Set `PUSH_BACKEND=fcm` at the same time.

---

## Part E — Hand-off checklist (what to give me)

| Item | From | Where it goes |
|---|---|---|
| `GoogleService-Info.plist` | Part A.2 | committed: `mobile/ios/Runner/` |
| `google-services.json` | Part A.3 | committed: `mobile/android/app/` |
| `.p8` + Key ID + Team ID | Part B | uploaded to Firebase (Part C) — you do this, nothing to commit |
| Service-account JSON | Part D | Railway env var (secret) — **not** committed |

You can paste the two client files to me / drop them in the repo; send the
service-account JSON via your secure channel (Railway secret), not chat.

---

## What I do after hand-off (no action from you)

- Mobile: add `firebase_core` + `firebase_messaging`; place the config files;
  add the **Push Notifications** + **Background Modes → Remote notifications**
  capabilities to the iOS target; request notification permission contextually;
  register/refresh the FCM token to `POST /api/devices/register/`; route a
  notification tap to the round/tournament leaderboard.
- Backend: add `firebase-admin` to `requirements.txt`; implement `_send_fcm`
  (services/push.py) using the service-account creds; prune tokens FCM reports
  unregistered.
- Flip `PUSH_BACKEND=fcm` on Railway → "round started / completed" start
  delivering to participants + watchers.

This is the new App Store build — batch it with the Twilio toll-free push.

---

## Verifying it works

1. With `PUSH_BACKEND=fcm`, install the new build on a device (push doesn't work
   on the iOS Simulator — needs a real iPhone), grant the permission prompt.
2. Confirm a `DeviceToken` row appears (the app registered).
3. Start a **multi-group** round (multi-foursome tournament or multi-group
   skins) where that phone is a participant/watcher → you should get a "Round
   under way" push; completing it → "Round complete".
4. Single-foursome casual rounds intentionally send nothing.

(Firebase Console → Cloud Messaging → "Send test message" to a specific token is
a quick way to sanity-check delivery before relying on the in-app events.)
