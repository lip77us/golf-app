# Push notifications — design spec

Status: **spec / not yet built.** Author target: event-driven, in-app push for
live round/tournament moments ("Round started", "Joe won a skin", "Lead
change") delivered to the participants and watchers who have Halved.

## Why push (not SMS, not the TD's phone)

- **Event-driven, automatic.** These fire as scoring happens — a phone can't
  auto-send SMS (iOS always opens the Messages composer and needs a manual
  tap), so they can't come from the TD's phone. They must be server-originated.
- **Push is the right channel for app users:** free, instant, opt-in, and
  **not** regulated like SMS — no Twilio, no 10DLC/toll-free carrier
  registration, no TCPA. It rides the same scoring events that already update
  the leaderboard, and pairs perfectly with the **watcher** feature (a watcher's
  whole purpose is following along).
- **SMS stays for two narrow cases:** (1) *user-initiated* group texts from the
  TD's own phone (invites, "tee times up" — already safe, build separately);
  (2) *server* SMS to people **without** the app — deferred to the Twilio +
  carrier-registration work, and largely redundant once push + watchers exist.

This feature is **independent of the Twilio work** and can ship before it.

---

## Architecture

```
scoring event (hole scored / round started / round complete)
   → service layer detects a NEW notable event (dedup vs already-sent)
   → resolve recipients (participants + watchers who are app users, prefs on)
   → resolve their device tokens
   → services/push.send_push(tokens, title, body, data)  [pluggable backend]
   → FCM HTTP v1  → APNs (iOS) / FCM (Android)
   → tap opens the round/tournament leaderboard (deep link via data payload)
```

**Single delivery channel: Firebase Cloud Messaging (FCM).** FCM fans out to
APNs for iOS and to Android natively — one server integration, one mobile SDK
(`firebase_messaging`). Avoids maintaining a separate raw-APNs path.

---

## Data model (backend)

### `accounts.DeviceToken` (new)
| field | notes |
|---|---|
| `user` | FK → User (CASCADE) |
| `token` | FCM registration token, unique |
| `platform` | `ios` / `android` |
| `updated_at` | refreshed on every register; used to prune stale tokens |

- A user can have several (phone + tablet). Register on login / app start /
  token refresh; delete on logout and in `DeleteAccountView`.

### `core` notification prefs (on User or a small `NotificationPrefs`)
Per-category toggles, default ON for rounds you're in:
`round_start`, `skins`, `round_complete`, `lead_change` (Phase 2), `marketing`
(always default OFF / unused). OS-level permission is separate and checked on
the device.

### `notifications.SentNotification` (new) — idempotency
| field | notes |
|---|---|
| `event_type` | e.g. `skin_won` |
| `round` | FK (nullable) |
| `dedup_key` | stable string, e.g. `skin_won:round=42:hole=7` |
| `created_at` | |

Unique on `dedup_key`. **Critical**: skins/leaderboard recalculate on every
score edit, so without a sent-log we'd re-notify on every recompute. Emit a
notification only when inserting a new `dedup_key` succeeds.

---

## Events

### Phase 1 (highest value, fewest edge cases)
| event | trigger point | dedup_key | recipients |
|---|---|---|---|
| **Round started** | round `status` → `in_progress` (`api/views.py` ~2267 / ~2732) | `round_start:round=<id>` | participants + watchers |
| **Skin won** | `services/skins.py` `calculate_skins` + `services/multi_skins.py`, when a hole resolves to a clear winner (incl. the hole that ends a carry) | `skin_won:round=<id>:hole=<n>` | participants + watchers |
| **Round complete** | round `status` → `complete` (`RoundCompleteView`) | `round_complete:round=<id>` | participants + watchers |

Skin copy: *"⛳ Joe won the skin on hole 7 (2 skins after the carry)."* Round
start: *"Your round at Pebble is underway."*

### Phase 2 (more judgment / tuning)
- **Lead change** (stroke/points/cup) — needs throttling so it doesn't spam on
  a see-saw; consider "new outright leader held for a hole".
- **Your group's turn / pace** and **tee-time reminders** (scheduled).
- **Digest option** for watchers who don't want skin-by-skin (one summary at
  the turn / end).

---

## Recipient resolution

Reuse the phone-match model. For a round/tournament event:
1. Gather **participant** phones (players in foursomes) + **watcher** phones
   (`tournament.Watcher`) — both already normalized helpers exist
   (`scoring_access`, `SharedRoundsView`).
2. Map phones → `User` (verified phone) → active `DeviceToken`s.
3. Drop users whose pref for that category is off.
4. De-dupe tokens; send.

The **actor** (e.g., the scorer who entered Joe's win) can be excluded from that
event if desired.

---

## Delivery service (backend)

`services/push.py` — `send_push(tokens, title, body, data)`, pluggable like
`SMS_BACKEND`:
- `PUSH_BACKEND=console` (default/dev): logs the payload, sends nothing.
- `PUSH_BACKEND=fcm`: FCM HTTP v1 (service-account JSON via env), batched.

Going live = set `PUSH_BACKEND=fcm` + `FCM_*` env on Railway. No code change,
mirroring the Twilio pattern. Failures are swallowed/logged (never block
scoring); stale-token errors prune the `DeviceToken`.

### Endpoints
- `POST /api/devices/register/` `{token, platform}` — upsert for `request.user`.
- `POST /api/devices/unregister/` `{token}` — on logout.
- `GET/PATCH /api/notification-prefs/` — read/update category toggles.

---

## Mobile

- Deps: `firebase_core`, `firebase_messaging` (+ `flutter_local_notifications`
  to show notifications while the app is foregrounded).
- Firebase config: `GoogleService-Info.plist` (iOS) + `google-services.json`
  (Android); APNs auth key uploaded to the Firebase project for iOS delivery.
- Flow: request OS permission (post-login, contextual — e.g. first time you set
  up/join a round, not at cold start) → get FCM token → `devices/register/`.
  Refresh on `onTokenRefresh`. Unregister + clear on logout
  (`AuthProvider.logout` / delete-account).
- **Tap handling**: `data` carries `{type, round_id|tournament_id}` → route to
  the leaderboard (round → `/leaderboard`, tournament → TournamentLeaderboard) —
  reuse the same routing the "Shared with me" screen now uses.
- **Settings**: notification category toggles in `settings_screen.dart`
  (alongside the existing per-device prefs).

---

## Consent / privacy / App Store

- iOS shows the system push-permission prompt; ask **contextually** (better
  grant rate) and degrade gracefully if denied.
- Push to opted-in app users is unregulated, but update the **privacy policy**
  to mention push tokens + notification data, and the App Privacy answers
  (Identifiers / device token) accordingly.
- No marketing pushes — round/event only — keeps us clean.

---

## Phasing

- **Phase 0 — infra:** Firebase project + APNs key; `DeviceToken` model +
  register/unregister endpoints; `services/push.py` (console + fcm);
  notification prefs; mobile permission + token registration + tap routing.
  *Nothing user-visible fires yet — verify with console backend + a manual test
  push.*
- **Phase 1 — events:** round started, skin won, round complete, with the
  `SentNotification` dedup. Demo via `seed_demo` (a round mid-play).
- **Phase 2 — refinements:** lead change (throttled), tee-time reminders,
  watcher digest option, notification grouping/quiet hours.
- **Phase 3 — round chat / "trash talk":** user-originated messages over the
  *same* push delivery (see below).

---

## User-originated messages ("trash talk") — Phase 3

Push is a **delivery channel**, and its trigger can be a *user action* just as
easily as a system event — so banter routes through the **same FCM path**, not
SMS. A user types in an in-app round thread → backend stores the message + fans
it out to the group via `services/push.send_push` → recipients get a push and
see it in the thread. (SMS would be worse: no thread, no round context, plus
cost/compliance.)

What Phase 3 adds **on top of** Phase 0/1 (which it fully reuses):
- A message store: `RoundMessage` (round FK, author Player, body, created_at).
- `POST /api/rounds/<id>/messages/` (send) + `GET` (history); authorized via
  the existing reader resolver (participants + watchers).
- Push fan-out reusing the recipient resolver + `services/push.py`, excluding
  the author; tapping opens the round's chat thread.
- Light moderation: mute-this-round's-chat (a notification pref / per-round
  flag), block + report. Keep it light for a friends app; revisit if abused.
- A `chat` notification category so trash talk can be muted independently of
  game events.

This is why Phase 0 is worth doing cleanly: it's the shared substrate for both
automatic event pushes **and** user-to-user messaging.

---

## Open questions
- iOS: confirm Apple Developer push key (.p8) for the Firebase project.
- Do watchers get **every** skin or an opt-in digest? (Default: same as
  participants; add digest in Phase 2.)
- Exclude the **actor** (scorer) from the event they caused? (Lean yes.)
- Lead-change throttle rule (hold-for-a-hole vs immediate).
- Recycled phone numbers: a token is tied to a `User`, so push is safe even if a
  number was reassigned at the `Player` level — but worth noting.

---

## Touch points (for implementation)
- Triggers: `api/views.py` (round status flips ~2267/2732, `RoundCompleteView`),
  `services/skins.py` (`calculate_skins`), `services/multi_skins.py`.
- Recipients: `accounts/scoring_access.py`, `tournament.Watcher`,
  `accounts.phone.normalize`.
- New: `accounts.DeviceToken`, `notifications.SentNotification`,
  `services/push.py`, device + prefs endpoints.
- Mobile: `firebase_messaging` init, `AuthProvider` (register/unregister),
  `settings_screen.dart` (prefs), leaderboard deep-link routing.
