# Asking for location — the paperwork

For `?near=me`: courses near the phone rather than near the golfer's home
course. The engine half is built (`CourseFindView._near_home`,
`services/golf_api_client.courses_near`, `services/geo.haversine_miles`);
this is everything that is NOT code, plus the three code changes that have to
land with it or the declarations become untrue.

Written 19 Oct 2026, after 2.12.0 was accepted. iOS first, Android when Play
accepts us.

`_near_home`'s docstring already named this: *"a separate, deliberate
decision that carries an App Privacy declaration, a privacy-policy rewrite
and a Play Data-safety update with it."* This is that list.

---

## The decision everything else follows from

**Coarse, foreground, on a tap, rounded to two decimal places before it
leaves the phone.**

Each half of that is load-bearing:

| | | why |
|---|---|---|
| **Coarse** | iOS `NSLocationDefaultAccuracyReduced`, Android `ACCESS_COARSE_LOCATION` and **not** `ACCESS_FINE_LOCATION` | the search radius is 25 miles. A 1 km fix and a 5 m fix return the same courses, and the smaller declaration is free |
| **Foreground** | when-in-use only; no `Always`, no `ACCESS_BACKGROUND_LOCATION` | background location triggers Play's separate declaration form and review, and Apple reads it as tracking. We have no use for it |
| **On a tap** | never on launch, never on a screen opening | also a quota rule — `courses_near` is a new line against the 10k/day Pro allowance and its own docstring says callers fire it on a tap |
| **Rounded to 2 dp** | `round(lat, 2)`, `round(lng, 2)` in the Dart layer, before the request | this is what makes "Coarse Location" on the App Privacy label match what the network actually carries. See below — it is the one non-obvious requirement |

### Why two decimal places, specifically

Apple defines the label by the **resolution of what you transmit**, not by
which plist key you set: *Precise Location* is a latitude/longitude with
**three or more decimal places**, *Coarse Location* is anything lower. So an
app can request reduced accuracy, receive a coarse value, and still get its
label contradicted by its own traffic, because CoreLocation hands back a
`CLLocation` whose numbers carry full float precision whatever the accuracy
authorisation is. Declaring Coarse while sending `37.87429, -122.24585` is the
mismatch that gets read as a 5.1.1/5.1.2 problem.

`round(x, 2)` is ~1.1 km of latitude. Under Apple's three-decimal line, and
far inside a 25-mile radius.

**Android's threshold is a different number and 2 dp does not clear it.**
Google calls location *approximate* at an area **≥ 3 km²**; 0.01° at our
latitude is about 1 km², so by Google's definition two decimals is still
precise. What justifies the Approximate answer on the Play form is the
**permission**: declaring `ACCESS_COARSE_LOCATION` without `ACCESS_FINE_LOCATION`
means the OS itself only ever hands us a ≥3 km² fix, and rounding it further
can only lose precision. So the rounding is for Apple and the permission is
for Google, and both want doing.

### And the rule this repo keeps relearning

**The feature must degrade, in three steps, and never dead-end.** Permission
denied or unavailable → fall back to `?near=home` → fall back to plain
search. A golfer who says no keeps a working course picker. This file is
worth re-reading on that point: the casual receipt no round could open, the
setup-edit button gated on the rule it replaced, and the day bet that could
be turned on and not off were all shipped, tested and unreachable.

---

## 1 · Three code changes that are part of the paperwork

These are not polish. Each one is a declaration being true or false.

### a. `golf_api_client._get` logs coordinates at ERROR level

```python
msg = f'GolfCourseAPI HTTP {exc.code} for {url} — {body[:400]}'
logger.error(msg)
```

`url` is the full request line, so a **failed** proximity call writes the
golfer's coordinates into the Railway log, unconditionally, where they sit for
as long as logs are kept. The `logger.debug` line above it does the same on
every call when `DJANGO_LOG_LEVEL=DEBUG`.

That makes "we do not retain it" and the App Privacy answer **Not linked to
the user's identity** both false — the request is authenticated, so a log line
pairs a coordinate with an account.

Fix: redact the query string in the error path (log `path` and the status, not
`url`). Do this *before* answering the questionnaire, because the questionnaire
asks about what the server does, not what the app intends.

### b. Nothing may persist the coordinates

The near-me request handler must not write them to a model, a cache keyed by
them, or a request log. `Course.latitude/longitude` is course data and stays —
that is a place, not a person.

### c. Round in Dart, not on the server

Rounding server-side would mean the precise value already crossed the network
and reached our logs and our host. The 2 dp has to happen before the HTTP
call.

---

## 2 · iOS — `Info.plist`

The app currently declares **no** usage descriptions at all. Two keys go in
(`mobile/ios/Runner/Info.plist`, which is alphabetical — these land between
the close of the `NSAppTransportSecurity` dict and `NSSupportsLiveActivities`):

```xml
<key>NSLocationDefaultAccuracyReduced</key>
<true/>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Halved uses your approximate location once, when you tap Near me, to list golf courses close to you. It is never stored and never shared except to run that one search.</string>
```

- **`NSLocationWhenInUseUsageDescription` only.** No
  `NSLocationAlwaysAndWhenInUseUsageDescription`.
- **`NSLocationDefaultAccuracyReduced = true`** means the app never asks for
  precise accuracy and iOS does not offer the user a Precise toggle that is on
  by default. It is the plist half of the coarse decision.
- The string names the trigger (*when you tap Near me*), the benefit and the
  limit. Apple rejects vague purpose strings; "to improve your experience"
  is the shape that gets bounced.
- **`UIBackgroundModes` stays as it is** — today it holds
  `remote-notification` alone. Adding `location` to it would declare
  background tracking and contradict every answer below, and nothing in this
  feature needs it.

**Privacy manifest.** The app ships no `PrivacyInfo.xcprivacy` today and has
been through review repeatedly without one, so a missing app-level manifest is
not currently blocking an upload. Location is a *collected data type*, not one of the five
required-reason APIs, so it does not by itself create one. What can block the
upload is a **plugin** that uses a required-reason API without its own
manifest — so check whatever location plugin is chosen ships an `.xcprivacy`,
and if we add an app-level manifest anyway, the entry is
`NSPrivacyCollectedDataTypeCoarseLocation`, purpose `AppFunctionality`,
`Linked = false`, `Tracking = false`, matching the answers below.

---

## 3 · App Store Connect → App Privacy

Today the app declares no location at all. One data type is added; nothing
else on the form moves.

| Question | Answer |
|---|---|
| Data type | **Location → Coarse Location** (not Precise — see the 2 dp note) |
| Is it collected? | **Yes** |
| Purpose | **App Functionality** — and nothing else. Not Analytics, not Product Personalisation |
| Linked to the user's identity? | **No** — conditional on §1a and §1b being done |
| Used for tracking? | **No** |

**Do not try to claim the exemption.** Apple's "not collected" carve-out is
for data that never leaves the device; ours is transmitted to our server and
on to a third party. Declaring one coarse, app-functionality, unlinked,
untracked data type costs nothing and is the uncontroversial answer; arguing
an exemption risks a 5.1 rejection for a label that does not match the
traffic.

**The App Privacy answers are also a code claim.** The CLAUDE.md data
inventory says to re-check against `Info.plist` rather than copying the line
forward — that note is what this section invalidates, and it should be updated
in the same commit.

---

## 4 · Privacy policy — the exact edits

Source of truth is `docs/privacy-policy.html`; `website/privacy.html` is the
published page and `build-zip.sh` ships it. **The two files differ only by the
generated `seo:begin/seo:end` block**, so every edit below goes into both,
identically. (One published copy at halved.golf is the rule — the GitHub Pages
mirror was unpublished in Oct 2026 precisely because a second copy drifts.)

Bump both dates at the top: `Last updated: <ship date>`. Leave the effective
date.

### 4a. §2 — the claim that becomes false

This is the important one. It currently reads:

> The App does **not** access your device location, camera, photos, contacts,
> or microphone.

Replace with:

```html
<li>The App does <strong>not</strong> access your camera, photos, contacts,
    or microphone.</li>
<li>The App does <strong>not</strong> track your location. It asks for your
    approximate location only when you tap &ldquo;Near me&rdquo; while
    looking for a golf course, uses it for that one search, and never
    records it. It never reads your location in the background, and the App
    works fully without it.</li>
```

### 4b. §4 — the other claim that becomes false

The *Golf course information service* bullet currently ends:

> We send only the course search terms needed for that lookup; we do
> **not** send your personal information to that service.

That stops being true: the coordinates go straight to the course database.
Replace the tail with:

```html
    terms needed for that lookup. If you ask for courses near you, we send
    that service your approximate location (rounded to about a kilometre) so
    it can return nearby courses; we send it no other personal information,
    and it is not told who you are.
```

### 4c. §1 — a new subsection, after *Golf activity*

```html
  <h3>Approximate location (only if you ask)</h3>
  <p>
    If you tap &ldquo;Near me&rdquo; while searching for a golf course, the
    App asks your device for your <em>approximate</em> location &mdash; about
    a kilometre, not a street address &mdash; and uses it once to list
    courses near you. We do not store it: it is used to answer that search
    and then discarded. We never collect your location in the background or
    while the App is closed, and the App works fully if you decline.
  </p>
```

### 4d. §3 — one bullet in *How We Use Your Information*

```html
    <li>Find golf courses near you, if you ask for that.</li>
```

### 4e. §9 — the choice

```html
  <p>
    You can turn location off at any time in your device settings
    (iOS: Settings &rarr; Privacy &amp; Security &rarr; Location Services;
    Android: Settings &rarr; Apps &rarr; Halved &rarr; Permissions). The App
    continues to work; course search then starts from your home course or a
    name you type.
  </p>
```

Rebuild the site after editing: `website/build-zip.sh` runs `build-seo.py`,
which aborts the zip on an audit error.

---

## 5 · Android — later, after Play accepts us

Nothing here goes in before the production listing is live; the closed test
does not need it. Both halves want doing in one change.

**`mobile/android/app/src/main/AndroidManifest.xml`** — beside the existing
`INTERNET` declaration, and with a comment in the same spirit as that one:

```xml
<!-- Coarse only, and deliberately NOT ACCESS_FINE_LOCATION: a 25-mile
     course search cannot use a 5 m fix, and declaring coarse alone is what
     makes the Play Data-safety "Approximate location" answer true by
     construction (the OS never hands us better than ~3 km²). No
     ACCESS_BACKGROUND_LOCATION — that triggers Play's separate declaration
     form and a review we have no use for. -->
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

**Play Console → Data safety**, which is a different form from Apple's and
asks two things Apple does not:

| Question | Answer |
|---|---|
| Data type | **Location → Approximate location** |
| Collected / Shared | **Collected: yes. Shared: yes** — the course database is a third party, and Play counts sending it as sharing even transiently |
| Purpose | **App functionality** |
| Is it required? | **Optional** — the user can decline and the app works |
| Processed ephemerally? | **Yes** — conditional on §1a and §1b |
| Encrypted in transit | Yes (HTTPS throughout) |
| Can the user request deletion? | Yes — the existing in-app account deletion answer covers it |

**Prominent disclosure.** Play wants the user told what the location is for
*before* the system dialog. An in-app sheet explaining it, with the system
prompt behind the confirm, satisfies that — and iOS's own guidance wants the
same thing, so build it once for both. Do not let the OS dialog be the first
mention.

---

## 6 · Order of operations

1. Redact the coordinates from the API client's error log (§1a). First,
   because every declaration below depends on it.
2. Build the feature with the three-step fallback, the 2 dp rounding and the
   pre-prompt sheet.
3. `Info.plist` keys (§2).
4. Edit both policy files, rebuild and deploy the site. **The policy must be
   live before the build is submitted** — App Review reads the URL on the
   listing, and a policy that does not mention location against a binary that
   asks for it is a 5.1.1 finding.
5. Submit, answering App Privacy per §3.
6. Update the CLAUDE.md data-inventory note, which currently says the app
   declares no location usage description and that course lookups carry no
   PII. Both stop being true.
7. Android (§5) only once the production listing exists.

---

## Not decided here

- **The tab, and where Near me lives.** Paul is taking that to design.
- **Which Flutter plugin.** Whatever is chosen must support iOS reduced
  accuracy, must not pull in a fine-location permission on Android through
  its own manifest (check the merged manifest, not just the pubspec), and
  should ship its own `.xcprivacy`.
- **Whether the displayed distance is rounded.** With a ~1 km anchor error,
  two courses a few hundred metres apart in real distance can swap places in
  the list. Showing whole miles hides it; showing one decimal invites
  "that's not 10.2 miles". Worth a look once there is a screen.
