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
- [ ] Run `seed_demo --reset` against **prod** (the reviewer's app talks to prod).
      Password login is OFF in prod, so this MUST be run inside the app container:
      Railway → **"Golf App"** service (NOT Postgres) → Terminal, then
      `cd /app && /opt/venv/bin/python manage.py seed_demo --reset`
      (the interactive shell lacks the venv on PATH — `/opt/venv` is it).
- [ ] Reviewer signs in via the **phone screen + OTP bypass** — NOT password.
      Set `REVIEW_BYPASS_PHONE`/`REVIEW_BYPASS_CODE` on Railway and put the demo
      phone + code in App Store Connect. Full procedure + copy:
      `docs/app-store-review-notes.md`.

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

Transporter authenticates with an **App Store Connect API key**, which is a
different kind of key from the APNs one and **we do not have one** — there is no
`.p8` on this machine that works against the App Store Connect API, and no
Issuer ID recorded anywhere. Make one in App Store Connect → Users and Access →
Integrations → App Store Connect API (Admin or App Manager role; the `.p8`
downloads exactly once) and keep the Issuer ID from the same page beside it.

**`AuthKey_KQMU88YXV7.p8` is NOT that key**, though this line used to say it
was, with a path (`~/.appstoreconnect/private_keys/`) that is an empty
directory. It is the **APNs** key — `docs/push-notifications.md` and
`services/live_activity_push.py` — it lives in `~/.secrets/`, and signing an
App Store Connect request with it returns 401 however correct the Issuer ID is.
Both keys are ES256 and both are named `AuthKey_<10 chars>.p8`, which is why
one gets mistaken for the other.

Alternatives, same outcome: **Xcode → Product → Archive → Distribute App** (no
extra install, signs in with your Apple ID instead of the key), or `xcrun altool`
if you ever script it.

> Written down because it was not: after the July 2026 machine rebuild, nothing in
> this repo recorded which tool did the upload.

## The listing's primary language is English (Australia)

Wrong, cosmetic, and **not fixable on a whim** — worth reading before anyone
tries again. Nothing on an App Store product page tells a customer which
English it is, so this costs nothing but tidiness.

**English (U.S.) was DELETED on 16 Oct 2026**, while staging 2.12.0. Having
both localizations meant every per-submission field — description, keywords,
promo text, What's New — had to be filled **twice**, which is the only thing
the duplicate was actually costing. One localization, one copy.

**The consequence to know:** US customers used to see the en-US page and now
see the en-AU one. The two carried identical copy and identical screenshots at
the time of deletion, so nothing visibly changed — but if en-AU is ever edited
in isolation, it is now the page *everyone* sees.

### Why the flip could not just be done

`App Information → Primary Language` is a real dropdown and it does let you
pick English (U.S.). **Saving is what fails**, with:

> In order to change this app's primary language, you must first provide all
> the required screenshots for each version in this language.

Two things about that control, both of which cost time to establish:

- It is editable **only while a version is in Prepare for Submission**. Between
  releases it is greyed out, which is the likeliest reason an earlier attempt
  looked like an account-level lock.
- It is in **App Information**, under General in the left sidebar. The language
  dropdown on the *version* page (Product Page Information) only chooses which
  localization you are editing — it is not this setting, and it is the easy one
  to land on by mistake.

Checked at the time: 2.11.0 and 2.12.0 showed the **same screenshots under both
en-AU and en-US**, so what Apple wanted was never obvious from the UI. The
images render identically whether a localization owns them or inherits them,
and the only way to know which is to try the save.

### Doing it properly, at 2.13

The order is forced, because **Apple refuses to delete whichever localization is
currently primary**:

1. Re-add English (U.S.) and give it its **own** screenshots on the editable
   version — do not rely on what the wells already display.
2. App Information → Primary Language → English (U.S.) → Save.
3. Only then remove English (Australia).

**The 6.9-inch set is ready**: `~/Desktop/halved-appstore-6.9/` holds 16 PNGs at
**1320×2868**, the size Apple requires now. Note two near-misses on the same
machine — `~/Downloads` has ~30 at **1284×2778** (the older 6.5-inch slot) and
the Desktop has ~49 at **1206×2622**, which is not an App Store size at all.
`docs/store/play/screenshots` is 1080×1920 and is the **Play Store** set.

Apple takes 3–10 per localization and **the first three are what appear in
search results**.

**Unresolved:** whether step 1 is enough, or whether the validation counts
versions that are already live and therefore uneditable. If deleting en-US
turns out to have moved that wall rather than cleared it, the answer is the
same either way — the listing stays nominally Australian, which costs nothing.

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
