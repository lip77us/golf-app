# Courses near me — the options

Slice 1 (anchored on the golfer's home course) is **built**; see
`api/test_courses_near.py`. This file is the decision record for what comes
next, written 16 Oct 2026 when Paul asked two questions: what it costs in API
requests, and what it would take to use the phone's location.

---

## 1. What a request actually costs

**The plan is GolfCourseAPI Pro: 10,000 queries a day.** Measured, not
assumed:

| Call | Where | When it fires |
|---|---|---|
| `/v1/search` | `CourseFindView` step 3 | **every** text search ≥2 chars, after a 350ms debounce (`course_search_field.dart:110`) |
| `/v1/proximity` | `CourseFindView._near_home` | once per `near=home` request |
| `/v1/courses/{id}` | `CourseImportView` | once, when a golfer selects an `api` row |

A golfer typing "pebble" and picking a course costs roughly **2–4 calls**:
the debounce collapses a burst of keystrokes into one call per pause, and the
import is one more. At that rate 10k/day is about 2,500 round setups, which is
far beyond current usage. **Today the quota is not the constraint and tuning
it would be premature.**

**Nothing is cached anywhere.** There is no `CACHES` block in settings and no
`cache.get`/`cache.set` in either `api/views.py` or
`services/golf_api_client.py`. Every call goes upstream.

### The one optimisation worth doing, and when

**Cache the proximity result, keyed on rounded coordinates plus radius.**

A home course does not move, and the set of golf courses within 25 miles of a
fixed point changes approximately never. One golfer tapping "Near me" five
times in a round-setup session currently costs five calls and should cost
one. A TTL of days is defensible; a week is not reckless.

Do it **when proximity ships to real users**, not now — an unused cache is a
thing that can be subtly wrong with nothing exercising it.

### What NOT to do

* **Do not skip the live search when local results look sufficient.** The
  unified box exists so a golfer finds a course he does NOT already have;
  suppressing the API call to save quota removes the feature's reason to
  exist. The quota is not scarce enough to pay for that.

* **Do not populate the catalog from proximity results.** Tempting, because
  the catalog is exactly the mechanism that amortises API cost across
  accounts — but `upsert_catalog_course()` needs a full adapted course
  *with tees*, and `/v1/proximity` returns summaries only. Filling the
  catalog from a proximity page would mean a `fetch_course` per result, so
  **25 calls to save one**. The arithmetic runs backwards.

* **Do not fire proximity on screen open.** On tap only. A chip that queries
  when a picker is drawn multiplies the cost by every time anyone opens it.

---

## 1b. The anchor nobody has — measured 16 Oct 2026

**7 of 458 production golfers have a home course set.** It is an optional
profile field and nothing ever prompts for it, so slice 1 as built reaches
about 1.5% of the field; everyone else gets "Set a home course to see
courses near you."

**The fix is to stop asking, not to nag.** The course of a golfer's most
recent round is already in the database, needs no input, and is a better
guess at where he is than a field set once a year ago. Prefer `home_course`
when present, fall back to the last round's course. That takes the anchor
from 7 golfers to everyone who has played a round (136 of 365 locally).

**This is the remaining work on slice 1** and it is not started.

### The coordinate half is DONE — 16 Oct 2026

The other reason slice 1 found nothing: a course with no position cannot be
ranked, so it is dropped. `backfill_course_coords --apply` against
production took account courses from **58 to 126 of 144 (40% -> 87%)** and
the catalog from 24 to 29 of 35, for **15 API calls** — 70 rows but only 15
distinct courses, because Tilden Park is cloned x33 across accounts and
Poppy Hills x20.

18 remain unplaced, all clones of two courses; one is **Corica Park South**,
where upstream genuinely has no usable position. `set_course_coords` is the
command for anything that must be placed by hand, and geocoding by name is
deliberately not done anywhere in this repo.

## 2. Phone location — the whole chain

**Verified 16 Oct 2026, and the app's position today is clean:** zero
`geolocator`/`location` packages in `pubspec.yaml`, zero `NSLocation*` keys
in `Info.plist`, zero `ACCESS_*_LOCATION` in `AndroidManifest.xml`. The claim
is true and currently costs nothing to keep.

What switching it on requires, in order:

| # | Change | Where |
|---|---|---|
| 1 | add a location package | `mobile/pubspec.yaml` |
| 2 | `NSLocationWhenInUseUsageDescription` | `mobile/ios/Runner/Info.plist` |
| 3 | `ACCESS_COARSE_LOCATION` | `mobile/android/.../AndroidManifest.xml` |
| 4 | permission flow + denied / never-ask-again states, falling back to the home-course anchor | mobile |
| 5 | **App Privacy declaration** — Location, purpose *App Functionality*, not linked to identity, not used for tracking | App Store Connect |
| 6 | **Data safety update** | Play Console; the current answers are at `docs/play-store-checklist.md:446` |
| 7 | **Privacy-policy rewrite, BOTH copies** | `docs/privacy-policy.html` **and** `website/privacy.html`, republished via `build-zip.sh` |
| 8 | correct the data-inventory note | `CLAUDE.md` §"The data inventory behind the App Privacy answers" |

### Three things that are easy to get wrong

**Coarse is enough, and ask for nothing more.** A 25-mile radius does not need
a precise fix. `ACCESS_COARSE_LOCATION` alone is a materially easier story on
both stores and in the policy, and precise location invites questions neither
store needs to ask. There is no feature here that improves with GPS accuracy.

**One sentence in the policy becomes false, flatly.** It currently reads:

> The App does **not** access your device location, camera, photos, contacts,
> or microphone.

That is a single clause listing five things, so it cannot be softened — it has
to be split, with location moved into a *what we do collect* section saying it
is used once, on request, to rank nearby courses and is never stored. Both
copies carry identical text today (confirmed by diffing them with markup
stripped), and they must stay that way: `website/privacy.html` is the
published page and `docs/privacy-policy.html` is the source.

**The store paperwork is release-coupled.** The App Privacy answers are edited
in App Store Connect and reviewed with a submission, so slice 2 cannot ship
ahead of a release that declares it.

### The timing argument against doing it now

Play **declined production access on 12 Oct** and wants 14 more days of closed
testing from that date; the earliest reapply is 27 Oct (see
`docs/play-store-checklist.md`). Adding a new runtime permission and changing
the Data safety form in the middle of that window introduces a variable into
a review that has already gone against us once, for a feature that is a
convenience rather than a fix.

**Recommendation: ship slice 1 in 2.13, revisit slice 2 after Play production
access lands.** Slice 1 covers the golfer playing near home, which is most of
them most of the time. Slice 2 earns its cost mainly when TRAVELLING — which
is the Road Trip format — so it should be taken as a deliberate decision with
the paperwork planned, not as a convenience bolted onto a release.
