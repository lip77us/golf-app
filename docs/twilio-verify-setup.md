# Live login SMS via Twilio Verify — setup guide

This is the from-scratch checklist to take phone-login codes from the dev
"console" backend (which just logs the code) to **real SMS in production**,
using **Twilio Verify** (Twilio generates, sends, and checks the code).

The code is already written and ships **off by default** — production keeps
using the local/console backend until you set `OTP_BACKEND=twilio_verify` plus
the Twilio env vars below. Nothing here changes behaviour until you flip it.

> Why Verify (vs. raw SMS): login is one code per user per device — very low
> volume. Verify owns the code, resends, rate-limits, and most carrier
> compliance, for ~$0.05 per verification (pennies total). See CLAUDE.md.

> **OUTCOME (June 2026): no number needed.** Tested live — Twilio **Verify
> delivers OTP codes over Twilio's managed sender pool** to ordinary US mobiles
> on an upgraded account, with **no verified toll-free and no 10DLC**. The
> toll-free path was tried and **abandoned**: rejected 3× on code **30484**
> (Legal Business Name must match an IRS **CP 575** — a sole-proprietor
> individual name doesn't reliably match). Both purchased numbers were released.
> §4 below is kept for reference / higher-volume futures but is **not required
> at login volume**. Remaining go-live = set the §5 env vars on Railway, run §6,
> then `seed_demo` against prod.

---

## 1. Create a Twilio account
1. Sign up at https://www.twilio.com/try-twilio (free trial includes credit).
2. From the **Console dashboard**, copy:
   - **Account SID** (`AC…`)
   - **Auth Token** (click to reveal)

## 2. Create a Verify Service
1. Console → **Verify → Services → Create new** (or
   https://console.twilio.com/us1/develop/verify/services).
2. Name it `Halved` (this name appears in the SMS: "Your Halved verification
   code is …"). Leave defaults (SMS channel on, code length 6).
3. Copy the **Service SID** (`VA…`).

## 3. Test in trial mode (no number/registration needed yet)
Twilio trial accounts can send Verify codes **only to verified caller IDs**:
1. Console → **Phone Numbers → Verified Caller IDs → Add** your own mobile.
2. Set the env vars locally (see §5) with `OTP_BACKEND=twilio_verify` and run:
   ```
   python manage.py send_test_otp +1YOURMOBILE
   # …read the SMS, then:
   python manage.py send_test_otp +1YOURMOBILE --code 123456
   ```
   `APPROVED` means the integration works end to end.

## 4. Go to production (sending to ANY US number)
> **Not needed at login volume — see the OUTCOME note up top.** Verify routed
> over the managed pool to an arbitrary US mobile without either path below.
> Keep this section only if volume grows or you later want a fixed branded
> sender. (Toll-free for a sole proprietor was a dead end — see 30484 above.)

Trial restrictions lift once you **upgrade the account** (add a payment method).
For US A2P traffic you also need a registered sender. Two paths:

- **Toll-free (simplest for low volume — recommended to start):**
  1. Console → **Phone Numbers → Buy a number →** check **Toll-free** + SMS.
  2. Console → **Messaging → Toll-Free Verification →** submit the use-case
     (one-time passcodes / account verification). Approval is typically a few
     business days.
  3. Attach the toll-free number to the Verify service's messaging config (or
     leave Verify on Twilio's managed sender pool — Verify can route without you
     hand-picking a number).
- **10DLC (standard for local long codes):** register a Brand + a Campaign
  (use-case "2FA / OTP") under **Messaging → Regulatory Compliance → A2P 10DLC**.
  More setup; better throughput/deliverability for high volume. Overkill at
  login-only volume — start toll-free, revisit if volume grows.

> **Start the §4 registration early** — carrier approval has a multi-day lag and
> is the long pole. The code/env work (§5) is minutes.

## 5. Configure the app
Set these as environment variables (Railway → service → **Variables**; or `.env`
locally):

```
OTP_BACKEND=twilio_verify
TWILIO_ACCOUNT_SID=AC...
TWILIO_AUTH_TOKEN=...
TWILIO_VERIFY_SERVICE_SID=VA...
```

`twilio` is already in `requirements.txt`, so Railway installs it on deploy.
Redeploy after setting the vars.

## 6. Verify in production
```
# On the Railway shell (or any host with the prod env):
python manage.py send_test_otp +1YOURMOBILE
python manage.py send_test_otp +1YOURMOBILE --code <texted code>
```
Then do a real end-to-end login from the app pointed at production.

Reminder: with `DEBUG=False` in prod, the `/auth/otp/request/` response does
**not** include `debug_code` (and on the Verify backend there's no code to echo
anyway) — the code only arrives by SMS.

---

## Rollback
Set `OTP_BACKEND=local` (or unset it) and redeploy. The app immediately falls
back to the PhoneOTP/console path — no code change. Handy if Twilio has an
outage or a billing lapse.

## Where the code lives
- `accounts/twilio_verify.py` — `start_verification()` / `check_verification()`.
- `accounts/otp.py` — branches on `OTP_BACKEND` (`_use_twilio_verify()`); the
  account-creation logic is shared by both backends.
- `accounts/management/commands/send_test_otp.py` — the test tool above.
- `my_golf_app/settings.py` — `OTP_BACKEND`, `TWILIO_*` vars.
