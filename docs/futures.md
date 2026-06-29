# Futures list

Deferred ideas to consider later — not committed work. Add an entry when we
park something; move it into a real plan/doc when we pick it up.

---

## Cross-account "courses I've played" in the recents quick-pick (viral hook)

**Why:** growth. When a friend who has the app runs a game and invites you to
their foursome, we'd love that course to be effortless for you to play yourself
next time — ideally surfaced in your course recents, or even pre-selected as the
default when you start your own round soon after.

**Current state (shipped):** the recents quick-pick
(`RecentCoursesView` → `GET /api/courses/recent/`) is scoped to **your own
account's rounds** only. A course you played in a friend's round doesn't appear.
For now, invitees just type the course name in the picker. (Confirmed reasonable
to start there.)

**Approach when we build it:**
- Include courses from rounds you **played** in another account (phone-matched
  `FoursomeMembership`, the `PlayingRoundsView` source). **Exclude observed /
  watcher rounds** (`SharedRoundsView`) — play, not observe.
- Courses are account-private (copy-on-add model), so a cross-account course
  must be **resolved back to your account via `golf_api_id`** (the catalog key):
  - you already own it → instant select (as today);
  - it's in the shared catalog → **add-on-tap** (clone, brief spinner — same as
    a catalog search hit);
  - custom/pasted course with no catalog id → can't be added to your account →
    skip it.
- Mobile: the recents block switches from instant `_commit(CourseInfo)` to the
  shared `_select(hit)` source path (`account` vs `catalog`), so clone-on-tap
  works. Endpoint returns source-tagged entries like `CourseFindView`.

**Stretch:** "course as default" — when you open a new round shortly after being
added to a foursome at a course, pre-select that course rather than just listing
it in recents.

**Trade-off to note:** a not-yet-owned recent would clone on tap instead of
selecting instantly. Judged acceptable.
