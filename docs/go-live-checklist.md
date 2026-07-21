# Go-live checklist — 2.0.0 (phone accounts + onboarding + mid-round withdrawal)

The big push: deploy the batched backend work to Railway, turn on live SMS via
Twilio Verify, and ship app **2.0.0** to the App Store. The release is **backward
compatible** — existing 1.x apps keep working — so no forced update at launch.

Order matters: **backend first**, then mobile.

---

## 0. Pre-push sanity
- [ ] Working tree clean; everything committed on `main`.
- [ ] (Optional but recommended) Run the withdrawal + scoring tests:
      `.venv-test/bin/python manage.py test scoring api` (real Postgres, slow).

## 1. Backend → Railway
- [ ] `git push origin main` → Railway auto-builds.
- [ ] `railway.toml` start command auto-runs `migrate --noinput`, so the new
      migrations apply on deploy: `tournament/0036` (`withdrew_after_hole`,
      `withdrew_killed_next_hole`) and `games/0038` (`SixesSegment.is_void`).
- [ ] Confirm the deploy is healthy (Railway logs: gunicorn up, no migration
      errors).

## 2. Turn on live SMS (Twilio Verify)
- [ ] Railway → Variables already set: `OTP_BACKEND=twilio_verify`,
      `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_VERIFY_SERVICE_SID`.
- [ ] From the Railway shell, confirm prod delivery end to end:
      ```
      python manage.py send_test_otp +1YOURMOBILE
      python manage.py send_test_otp +1YOURMOBILE --code <texted code>   # → APPROVED
      ```
- [ ] Rollback path if needed: set `OTP_BACKEND=local` and redeploy.

## 3. Demo data for the App Store reviewer
- [ ] Run `seed_demo` against **prod** (the reviewer's app talks to prod):
      `python manage.py seed_demo --reset` (deterministic rebuild).
- [ ] Reviewer uses **password login** (Apple can't receive your SMS OTP) — keep
      the `PasswordLoginScreen` path and put the demo credentials in App Store
      Connect → review notes. Default password `HalvedDemo2026` (or `--password`).

## 4. Version / force-update lever (already staged — do NOT pull yet)
- [ ] Leave `CLIENT_MIN_VERSION = 1.1.0` (Railway env unset = default). 1.x apps
      keep working; nothing is force-updated at launch.
- [ ] `SERVER_VERSION` now reports `2.0.0` (informational, in About).
- [ ] **Later, only after 2.0.0 is LIVE on the App Store:** set
      `CLIENT_MIN_VERSION=2.0.0` in Railway Variables to force stragglers onto
      the new build. Setting it before the store has 2.0.0 bricks users.

## 5. Mobile build + test (ladder, cheapest first)
- [ ] Confirm the build points at the **prod** backend (`mobile/lib/config.dart`).
- [ ] **Local release run** on a device against prod: `flutter run --release` —
      smoke-test phone login (real SMS now), the onboarding wizard, a casual
      round, and a mid-round withdrawal.
- [ ] **Bump the iOS build/version** (`CFBundleVersion` / marketing 2.0.0) or the
      upload is rejected as a duplicate.
- [ ] **TestFlight internal build** — validates the real signed release binary +
      real-device SMS. Internal testers need no Beta App Review.
- [ ] Submit 2.0.0 for **App Store review** (same build), with reviewer notes +
      demo credentials.

### How the build actually gets to TestFlight

```sh
cd mobile
flutter build ipa          # → build/ios/ipa/*.ipa
```

Then upload the `.ipa` with **Transporter** (free, Mac App Store, made by Apple —
it was called *Application Loader* before 2019, which is what you'll half-remember
it as). Drag the file in, upload, and the build appears in App Store Connect →
TestFlight once processing finishes, usually a few minutes.

Transporter authenticates with the App Store Connect API key kept at
`~/.appstoreconnect/private_keys/AuthKey_KQMU88YXV7.p8` (mode 600, never in git).
The Issuer ID that goes with it is in App Store Connect → Users and Access →
Integrations.

Alternatives, same outcome: **Xcode → Product → Archive → Distribute App** (no
extra install, signs in with your Apple ID instead of the key), or `xcrun altool`
if you ever script it.

> Written down because it was not: after the July 2026 machine rebuild, nothing in
> this repo recorded which tool did the upload.

## 6. After 2.0.0 is approved & live
- [ ] (Optional) Flip `CLIENT_MIN_VERSION=2.0.0` on Railway if/when you want
      everyone on the new build (or when a future backend change requires it).
- [ ] Then the toll-free saga is fully behind you — Verify on the managed pool,
      no number, no 10DLC (see `docs/twilio-verify-setup.md`).

---

### Quick rollbacks
- **SMS broken / Twilio issue:** `OTP_BACKEND=local` + redeploy.
- **Bad force-update:** set `CLIENT_MIN_VERSION` back to `1.1.0` in Railway.
- **Bad backend deploy:** redeploy the previous commit on Railway (migrations are
  forward-only — don't roll a migration back without checking the data).
