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

### a. `golf_api_client._get` logged the request line — **DONE**

`_safe_url(path, params)` now rebuilds the request line for logging with
unlisted parameter values replaced by `REDACTED`, and it is used in all four
message sites.

**The leak was latent, not live**, and the earlier note here overstated it:
the only caller today is `?near=home`, whose coordinates are the home
*course's* and public. It becomes real the moment `?near=me` sends the
device's position — which is why it is fixed ahead of that rather than with
it.

Two things about the shape, because neither is obvious:

- **The redaction is in the exception message, not just the `logger` call.**
  `CourseFindView` logs `traceback.format_exc()` on a proximity failure, so a
  `RuntimeError` carrying the real query string would have printed it one
  frame up however carefully `_get` logged.
- **`_LOGGABLE_PARAMS` is an allowlist** (`search_query`, `radius`, `limit`).
  A denylist fails open: the next endpoint's parameter would log in full
  until somebody remembered it. A search term stays readable, which is how
  "The Bridges" filed upstream as "Bridges (The)" was diagnosed.

Tests: `CoordinatesNeverReachALogTests` (`api/test_courses_near.py`, 7).

### b. Nothing may persist the coordinates

The near-me request handler must not write them to a model, a cache keyed by
them, or a request log. `Course.latitude/longitude` is course data and stays —
that is a place, not a person.

### c. Round in Dart **and** on the server — **DONE**

`utils/coarse_position.coarsenForPrivacy` cuts it before the request is built
and `services.geo.coarse_position` cuts it again on arrival. Not redundant:
rounding only on the phone makes the server's correctness depend on the
client's, and an older build or a replayed URL would hand us a precise
position we would then measure from and forward upstream. Rounding on both
sides is what makes "the server never holds a precise position" a property of
the server.

`coarsenForPrivacy` returns a **String**, deliberately — a double is a value
somebody can re-format with six places, where a string already cut cannot
grow them back.

---

## 2 · iOS — `Info.plist` — **DONE**

The app declared **no** usage descriptions at all. Two keys went in
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

## 3 · App Store Connect → App Privacy — **DONE 19 Oct 2026**

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
forward — that note is what this section invalidated, and it was updated in
the same commit as the policy (`b2e3ca1`).

**The declaration is now ahead of the binary**, which is worth knowing rather
than worrying about. 2.12.0+53 is what is on the store and it asks for no
location at all, so the product page's privacy label describes a capability
no shipped build has. That is **over**-disclosure, which is the safe
direction — under-disclosing is what gets read as a 5.1.1/5.1.2 problem — and
it resolves itself the moment a build carrying the picker ships. If having
the label match exactly matters, the answer is to get that build out rather
than to roll the declaration back.

---

## 4 · Privacy policy — the exact edits — **DONE 19 Oct 2026**

Source of truth is `docs/privacy-policy.html`; `website/privacy.html` is the
published page and `build-zip.sh` ships it. **The two files differ only by the
generated `seo:begin/seo:end` block**, so every edit below goes into both,
identically. (One published copy at halved.golf is the rule — the GitHub Pages
mirror was unpublished in Oct 2026 precisely because a second copy drifts.)

Bump both dates at the top: `Last updated: <ship date>`. Leave the effective
date. Both now read **October 19, 2026**; the effective date stays May 30.

**Two corrections made while applying this**, because the spec was written
before the picker was:

- The control is **`Courses near me`**, not `Near me` — the policy quotes the
  button, so it has to be the button's actual name.
- §4e originally said course search "starts from your home course or a name
  you type". With `?near=home` deliberately given no surface, that described
  a fallback the app does not have. It now says you can type a name and that
  your home course and recent courses stay one tap away, which is what the
  picker actually does.

It also drops the per-OS settings paths the draft had: naming an Android path
would describe a permission Android users cannot grant yet, and "your device
settings" is true on both and needs no second edit when Android ships.

`build-seo.py` reported the sitemap stale (the content hash moved) and
regenerating it moved **only** the privacy page's `lastmod`, which is the
check that nothing else was touched. Audit: 29 pages, 0 errors, 0 warnings.

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

1. ~~Redact the coordinates from the API client's request line (§1a).~~
   **Done** — it went first because every declaration below depends on it.
2. ~~Build the design's picker.~~ **Done** — see §7.
3. ~~`Info.plist` keys (§2).~~ **Done.**
4. ~~Edit both policy files and rebuild the site.~~ **Done.** Still to do:
   **upload the zip.** The policy must be LIVE before the build is
   submitted — App Review reads the URL on the listing, and a policy that
   does not mention location against a binary that asks for it is a 5.1.1
   finding. `build-zip.sh` only zips; the Cloudflare Pages upload is by
   hand, so this one is Paul's.
5. ~~Answer App Privacy per §3.~~ **Done** — Coarse Location declared in App
   Store Connect. Still to do: **ship a build that contains the feature.**
   2.12.0+53 does not; it needs a version bump and an IPA, and until one goes
   out the declaration describes a capability no shipped binary has (§3).
6. ~~Update the CLAUDE.md data-inventory note.~~ **Done** — it had said the
   app declares no location usage description and that course lookups carry
   no PII, and both stopped being true in one commit.
7. Android (§5) only once the production listing exists.

---

## 7 · What was built

Backend:

- **`?near=me&lat=&lng=`** on `CourseFindView`. `_near_home` and `_near_me`
  now differ only in where the anchor comes from; `_ranked_by_distance` holds
  the one dedup, the one best-effort upstream call and the one sort.
- **`services.geo.coarse_position`** — validate, range-check per coordinate,
  reject `0,0` as a pair, cut to 2 dp. A malformed coordinate is a **400**,
  deliberately unlike the missing home course, which is a state the golfer is
  in and gets a sentence: this is a client fault and an empty list would hide
  it.
- **Whole miles**, and the quantise happens **after** the sort, on the real
  distance — rounding first would let two courses a few hundred yards apart
  swap places because both round to 1. `places` is passed in as the
  resolution the anchor justifies (1 for `near=home`, 0 for `near=me`), so
  the field has one meaning rather than two.

Mobile:

- **`geolocator ^14.0.2`**. Checked rather than assumed: `geolocator_android`
  declares **no** location permissions in its own manifest, so nothing drags
  `ACCESS_FINE_LOCATION` in through the merge — the opposite of what I warned
  about. It does declare a `GeolocatorLocationService` with
  `foregroundServiceType="location"`, which cannot run without a permission
  we are not declaring, but is worth knowing about at Play submission.
- **`AppleSettings.allowBackgroundLocationUpdates` is set to `false`
  explicitly, because the plugin defaults it to `true`.** It is inert without
  `UIBackgroundModes: location` and an Always description, neither of which
  this app has — but a flag that asks for background updates should be off
  because we mean it, not because a plist key happens to be absent.
- `utils/near_me.dart` owns the fix and is the **only file in the app that
  imports `geolocator`** (hence `openLocationSettings`), so the plugin stays
  replaceable.
- The picker: pill → locating → `Near you` + `Clear`, home and Recent hidden
  while results show, whole miles right-aligned in tabular figures.
- **Each failure is its own outcome**, because the picker says something
  different for each and **only `deniedForever` may offer Settings** — the OS
  will never re-prompt there, and offering it on a plain "not now" sends a
  golfer to a screen he does not need. One line is not in the design:
  position-obtained-but-lookup-failed says *Couldn't search for courses near
  you*, because naming the location step there would be the wrong step.

### The Android gate — `nearMeOffered`

**False on Android, and it is one line to flip.** With no permission
declared, `requestPermission` returns denied forever, so the pill would sit
there permanently answering "Location is off" — which reads as a bug, not as
a feature that has not arrived. Hiding it is also what keeps us off the
compliance hook: Play Data safety has to be accurate for any release
including a closed test, so the manifest line and the form go together (§5).

Worth knowing: `defaultTargetPlatform` is **android** under `flutter test`,
so every widget test of this picker has to override it — and the binding
checks no foundation debug variable outlives the test BODY, which runs before
`tearDown`, so the override has to be set and cleared inside each test.

Tests: `api/test_courses_near.py` (41, from 23),
`mobile/test/near_me_test.dart` (15),
`mobile/test/near_me_picker_test.dart` (12).

## The design — `~/Downloads/handoff-near-me/`

Arrived 19 Oct 2026. `course-search-field.html` (the picker's idle / locating
/ results states) and `cup-event-details.html` (the same picker reached from
Cup event details). It is **not a tab**: a `Courses near me` pill directly
under the existing search field, in the existing `CourseSearchField`, built
once for both callers.

It agrees with everything above and independently names the log line
("*Not stored, not logged, not attached to the round*") and the policy's
course-database claim. What it adds:

- **One single fix per tap** (`getCurrentPosition`, no stream, no
  background), and **no request outside the tap** — not on picker open, app
  launch or round start. Same rule the quota wants.
- **Results are not cached**; the next open starts idle.
- The `Near you` section **replaces** the home-course and Recent sections
  while it shows, with a `Clear` link. Typing, clearing, or closing the sheet
  resets. The picker already has both of those sections
  (`_homeCourse`, `_recents`), so this slots in rather than needing them
  built.
- Distance right-aligned, tabular figures, `2.4 mi`, nearest first.
- Named states for every failure: denied (`Location is off. Search by name
  instead.`, linking to system settings when permanently denied, and no
  re-prompt loop), ~10 s timeout (`Couldn't get your location. Try again.`),
  and empty (`No courses within 25 mi.`).
- Suggested 25 mi / top 10, flagged as a product choice. The endpoint already
  clamps radius to 1–50 and defaults to 25.
- Verbatim copy: `Courses near me`, `Finding courses near you…`, `Near you`,
  `Clear`.

### The two open things, decided

**Whole miles, and no `?near=home` surface** (Paul, 19 Oct 2026). So
`?near=home` stays built, tested and unreached — deliberately, not by
oversight, and the class docstring says so rather than leaving the next
reader to wonder. The anchor-fallback item below is therefore not worth
doing.

1. **It never calls `?near=home`.** Slice 1 is built, tested (16 tests) and
   has no surface in this design: the denied path falls back to typed search,
   not to the home-course anchor, and the home course is already a `Play
   here` suggestion in the picker. That is defensible — showing courses near
   a *different* point under a heading that says `Near you` would be a lie —
   but it leaves the endpoint as dead code. Either it earns its own line
   (`Near <home course>`) or it should be understood as unused. Worth
   deciding rather than drifting.
2. **The anchor fallback becomes less urgent, not more.** The open slice-1
   item (fall back to the course of the golfer's most recent round, since
   only 7 of 458 golfers have a home course) was the fix for `?near=home`
   reaching nobody. If `?near=me` is the real answer, that work may not be
   worth doing at all — but the picker's `Recent` section already covers the
   same instinct.

## Not decided here
- **The pre-prompt sheet.** Not built. The design goes straight from tap to
  the OS prompt, which is fine for iOS; Play wants the purpose given before
  the system dialog, so it is needed for Android at the latest. Building it
  once serves both.
- **The distance display contradicts the rounding, slightly.** The design
  specifies `2.4 mi`, one decimal. Rounding the anchor to 2 dp moves it by up
  to ~0.7 mi, so that decimal is below the precision we actually have, and
  two courses a few hundred metres apart can swap places in the list. The
  honest options are whole miles (`2 mi`) or living with it; going to 3 dp to
  earn the decimal back is exactly what makes Apple call it Precise Location.
  **The Coarse label costs us the first decimal of the distance** — that is
  the trade, and it is worth stating rather than discovering.
- **Whether the pre-prompt sheet is built.** The design goes straight from
  tap to the OS prompt. Play wants the purpose given *before* the system
  dialog, so this is needed for Android at the latest; building it for iOS
  too means one path rather than two.
