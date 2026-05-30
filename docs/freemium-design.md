# Freemium / Subscription Model — Design (v2, post-launch)

> Status: **design draft.** Not part of the first App Store submission. Ship
> v1 free, then add the paywall as a v2 release. This doc captures the model,
> the Apple constraints, the data model, and the open questions.

## 1. Goals

- Self-service onboarding: downloading the app creates a brand-new account with
  an admin login (no manual provisioning).
- A free trial that lets a new account fully exercise casual + tournament play.
- After the trial, a paid subscription is required to keep creating/playing.
- Tiered by **tournament/round participant count** (8 → 16 → enterprise).

## 2. Tiers

| Tier | Price | Max participants / event | Casual rounds | Notes |
|---|---|---|---|---|
| **Trial** | Free, 14 days | 8 | unlimited during trial | app-managed trial, no card up front |
| **Standard** | $2.99/mo or $19.99/yr | 8 | unlimited | monthly + annual = same tier |
| **Plus** | $39.99/yr | 16 | unlimited | |
| **Tier 3** | TBD/yr | 32 | unlimited | IAP |
| **Tier 4** | TBD/yr | 64 | unlimited | IAP |
| **Tier 5** | TBD/yr | 100 | unlimited | IAP — practical ceiling |

**Login/member counts are NOT a gating dimension.** The only paid limit is the
per-event participant count. Members (logins) can be added freely; their value
is already bounded by how many can play a given event. Candidate structural
rule: **one admin per account** (the admin is the subscriber/owner); everyone
else is a non-admin member login. This nudges unrelated groups toward their own
paid accounts — though it isn't airtight (one admin can still run events for
several groups), so the participant cap stays the real monetization lever.

**All paid tiers are Apple IAP auto-renewable subscriptions in one subscription
group — including the large ones, up to 100 players.** This deliberately avoids
any "contact sales" / off-Apple checkout, which sidesteps the Guideline 3.1.1
steering problem entirely. No non-IAP enterprise path for now.

> Residual caveat (future, not building now): real organizations (clubs,
> corporate events) sometimes prefer invoicing over personal-Apple-ID IAP. If
> genuine enterprise demand appears, revisit an off-Apple B2B arrangement then.
> Up to 100 players, all-IAP is simpler and compliant.

Clarified semantics:
- **"8 / 16" caps participants in a single round or tournament**, not the saved
  roster. The account may store more Player profiles than it can field in one
  event.
- **No login-count limits on any tier.** Logins/members are unlimited; gating is
  purely the per-event participant count. (Players without a login can always be
  scored, as today.)

## 3. Apple In-App Purchase constraints (non-negotiable)

- **Auto-renewable subscriptions MUST use Apple IAP / StoreKit.** No Stripe or
  web checkout for the app's digital access on iOS.
- **Commission:** 30% year one → 15% after a subscriber's 12th month, OR a flat
  **15% via the Small Business Program** (revenue < $1M/yr — we qualify).
  Budget ~15%; $19.99/yr nets ~$17.
- **Subscription group:** one group ("Halved") containing the products. Standard
  (monthly + annual) and Plus (annual) are different *levels* in the group, so
  StoreKit handles upgrade/downgrade/proration.
- **No "contact sales" path.** Every tier — up to 100 players — is an IAP
  product, so there's no steering of users to an off-Apple checkout and no
  Guideline 3.1.1 exposure. (A non-IAP B2B path is intentionally deferred; see
  the residual caveat under Tiers.)
- **Added review requirements when subscriptions exist:** Terms of Use (EULA),
  a visible **Restore Purchases** action, subscription disclosures (price, term,
  auto-renew) on the paywall, and a billing section in the privacy policy.

## 4. Trial model + anti-abuse

- **App-managed trial:** `Account.trial_expires_at = created_at + 14 days`,
  enforced **server-side** (never trust the client clock). No card up front.
- **Anti-abuse (stop re-registering for a fresh trial every 14 days):**
  - **DeviceCheck (primary):** Apple API giving 2 bits of per-device storage that
    persist across uninstall/reinstall. Flip a "trial consumed" bit when a device
    starts a trial; refuse a new trial at signup if it's already set.
  - **Verified email (secondary):** one trial per verified email; block
    disposable domains and `+` aliases.
  - **Accepted residual leak:** a determined user with multiple devices *and*
    emails can get extra trials. Acceptable — the 3-month read-only grace and the
    loss of roster/history on re-registration blunt the incentive.
  - (Apple's *built-in* free trial would enforce one-per-Apple-ID, but requires a
    card up front — rejected for friction.)

## 5. Entitlement data model

Add to `Account` (the existing tenant):

```
plan                  : trial | standard | plus | enterprise   (default trial)
subscription_status   : trialing | active | grace | expired    (derived)
trial_started_at       : datetime
trial_expires_at       : datetime
max_event_players      : int   (8 / 16 / 32 / 64 / 100 by tier)
# (no max_user_logins — login counts are not a gating dimension)
# Apple linkage (from StoreKit + Server Notifications V2):
apple_original_txn_id  : str
apple_product_id       : str
apple_expires_at       : datetime
apple_auto_renew       : bool
apple_environment      : sandbox | production
```

Server is the source of truth for entitlement; the client only *reflects* it.

## 6. Self-service signup (new — does not exist today)

Today accounts are admin-created and login is `account_name + username +
password`. Freemium needs a **"Create account"** flow:
- Collects: email (verified), password, optional account/display name.
- Backend creates `Account` (plan=trial, trial_expires_at=+14d) + admin `User` +
  linked `Player`.
- **Open architectural question:** account-name-based login is friction for
  self-signup (collisions, "what's my account name?"). Strongly consider
  **email-based login** for self-signup accounts. (See open questions.)

## 7. Enforcement points (server-side gates)

- **Create round / tournament:** blocked when `subscription_status` is `expired`
  (read-only). Allowed while `trialing`/`active`/`grace`.
- **Add participant to an event:** reject beyond `max_event_players`.
- (No login-count gate — logins are unlimited.)
- **Upgrade prompt:** when a blocked action is attempted, surface the paywall /
  upgrade screen instead of a raw error.
- All checks server-side; the mobile UI mirrors them for UX but is not the gate.

## 8. Lifecycle

```
download → trial (14d) ──subscribe──▶ active ──renews──▶ active
   │                                     │
   │ trial ends, no sub                  │ lapses / cancels
   ▼                                     ▼
read-only (paywall to create) ◀──────────┘
   │
   │ still unsubscribed after 3-month grace
   ▼
data purged (after warning emails)
```

- **Read-only:** can log in, view past rounds/leaderboards/rosters; cannot
  create or score new events.
- **3-month grace** before purge; send warning emails at, e.g., 30/7/1 days
  before deletion. Purge respects existing PROTECT/anonymization rules.

## 9. App Store Connect setup (when building)

- Subscription group "Halved" with products: Standard-Monthly ($2.99),
  Standard-Annual ($19.99), Plus-Annual ($39.99).
- Enroll in the Small Business Program (15%).
- Add EULA / Terms of Use, paywall disclosures, Restore Purchases.
- Update the privacy policy with a billing/subscription section.
- App Store Server Notifications V2 webhook → Railway backend updates
  `Account` subscription fields.

## 10. Open questions

1. **One admin per account?** Make the single admin the subscriber/owner and
   drop the "promote another admin" capability. Simplifies billing + the
   account-deletion last-admin guard. (Leaning yes.)
2. **Login identity:** switch to **email-as-ID** (globally-unique email → user →
   account; account name becomes a display label, not a typed credential).
   Trade-off: one email = one account. Slack-style multi-account picker is the
   richer fallback if multi-group membership ever matters. (Recommend email-as-ID
   with one-account-per-email for now.)
3. Monthly Standard ($2.99) — keep both monthly and annual, or annual-only to
   reduce churn ops?
4. Occasional-user path: a one-time "single tournament" IAP for seasonal users
   who don't want a subscription? (Product idea, optional.)
5. Tier ladder: confirm the participant breakpoints (8 / 16 / 32 / 64 / 100?)
   and set annual prices for Tiers 3–5.

## 11. Suggested phasing (all post-v1)

1. **Backend entitlement model** + server-side enforcement (limits, expiry),
   defaulting everyone to a generous plan so nothing breaks.
2. **Self-service signup** + (recommended) email login.
3. **StoreKit integration** + App Store Server Notifications webhook +
   paywall/upgrade UI + Restore Purchases.
4. **Anti-abuse** (DeviceCheck + email verification).
5. **Lifecycle automation** (read-only gating, grace-period warning emails,
   purge job).

## 12. Phase 2 revision — phone-first identity & viral invites (advisor input)

Revises email-as-ID (§6 / open Q2), the trial-based free tier (§2/§8), and the
anti-abuse plan (§11.4). Goal: viral, phone-native growth.

### Identity
- **Phone number is the primary login**, verified via SMS one-time passcode
  (OTP). Email optional/secondary (recovery).
- Players added **without** a phone stay **login-less** (as today).
- Phone verification doubles as **anti-abuse** (one verified number = one
  account) — replaces the DeviceCheck/email anti-re-trial plan.

### Onboarding / viral loop
- TD adds a player with a phone → a **pending, claimable** account (NOT a live,
  silently-created account).
- Recipient downloads, verifies via OTP, and **claims** the pending player —
  their existing login-less history (rounds, scores, memberships) merges in.
- On round start, participants can get a **follow code + app-download link**
  (the public spectator page already exists via `watch_token`).

### ⚠️ SMS delivery — the critical compliance decision
Auto-texting numbers a third party entered is a legal + App Store landmine:
- **TCPA (US):** automated texts without the *recipient's* consent = $500–$1,500
  per message; a TD consenting for a friend does NOT count.
- **Apple anti-spam (5.x / 4.x):** server-sent SMS on a user's behalf without
  consent gets apps rejected.
- **Carrier 10DLC:** US app-to-person SMS must be brand/campaign-registered or
  it gets filtered.

**Required approach: user-initiated invites.** Open the native iOS Messages
composer (`MFMessageComposeViewController`) pre-filled with the follow code +
link, so the text is sent **from the TD's own phone** as a personal message —
compliant by construction, same viral outcome. Server-sent SMS is a later option
ONLY with opt-in capture, STOP/opt-out handling, 10DLC registration, and a
provider (Twilio) — real recurring cost + overhead.

### Free tier (reframed)
- Replace the 14-day trial with a **perpetual metered free tier**, e.g.
  **2 casual rounds + 1 tournament / month** free; upgrade via IAP for more.
- Better for virality (free users stay and keep inviting); metering is
  per-account per-month, and phone verification makes multi-account gaming hard.

### Costs / risks to model
- **SMS OTP cost** scales with viral volume (~$0.008/msg + verification fees).
- **Number recycling:** reassigned numbers must not inherit prior history; needs
  a recovery / re-verify path.
- International phone formats / deliverability.
- Sign in with Apple still NOT required (phone/OTP ≠ third-party social login).

### Revised open questions
- Exact free-tier limits (2 casual + 1 tournament/month?).
- Phone-only, or phone + optional email for recovery?
- Device-initiated invites for v2.0; evaluate server SMS (Twilio + 10DLC) later.
