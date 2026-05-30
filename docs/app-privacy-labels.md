# App Store Connect — App Privacy ("nutrition labels")

Must match the published privacy policy
(https://lip77us.github.io/halved-legal/privacy.html). Apple cross-checks.
Path: App Store Connect → your app → **App Privacy** → Edit.

## Gate question
**"Do you or your third-party partners collect data from this app?"**
→ **Yes, we collect data.**
(Data leaves the device to your Railway backend, so it counts as "collected"
even though it's first-party and only for running the app.)

## Data types to mark as COLLECTED

| Apple category | Data type | Linked to identity? | Used for tracking? | Purpose |
|---|---|---|---|---|
| Contact Info | **Name** | Yes | No | App Functionality |
| Contact Info | **Email Address** | Yes | No | App Functionality |
| Contact Info | **Phone Number** | Yes | No | App Functionality |
| User Content | **Other User Content** (scores, games, rounds) | Yes | No | App Functionality |
| Identifiers | **User ID** (account/username) | Yes | No | App Functionality |
| Other Data | **Other Data** (handicap index, M/W tee designation) — *optional, see note* | Yes | No | App Functionality |

Global rules for every type above:
- **Linked to the user's identity? → Yes** (all of it is tied to their account)
- **Used to track you? → No** (no cross-app/site tracking, no ad networks)
- **Purpose → App Functionality only** (NOT Analytics, NOT Personalization,
  NOT Developer's Advertising, NOT Third-Party Advertising)

## Explicitly NOT collected (do not check these)
- Location (any) — no location features
- Health & Fitness — handicap is a score, not HealthKit/exercise data
- Financial Info / **Purchases** — no in-app purchases in v1 (freemium = v2;
  add Purchases then)
- Contacts — never accessed
- Browsing History, Search History
- Identifiers → Device ID — no IDFA/IDFV collected
- Usage Data, Diagnostics — no analytics or crash-reporting SDKs
- Sensitive Info, Surroundings, Body, Audio/Photos

## "Data Used to Track You" section
→ **None.** No data type is used for tracking. (This is what lets you skip the
App Tracking Transparency prompt — consistent with the app.)

## Notes
- **Handicap / sex (M/W):** these don't fit a named Apple category cleanly.
  Declaring them under **Other Data** is the thorough, honest choice. The "sex"
  field is a men's/women's tee designation, not sexual orientation, so it is
  NOT Apple "Sensitive Info."
- **Course lookups (GolfCourseAPI):** only course search terms are sent, no
  personal data — nothing to declare there.
- When freemium/IAP ships (v2), revisit: add **Purchases**, and if you add
  analytics/crash tools, add **Usage Data / Diagnostics**.
