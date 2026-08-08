# GolfCourseAPI course ids — remap + update workflow

**Where to edit course data upstream (GolfCourseAPI):**
👉 https://golfcourseapi.com/course-update

GolfCourseAPI is the source we sync course ratings from; GHIN/USGA is the ultimate
source of truth, so edits made at the URL above should match GHIN.

---

## The finding (2026-08-08)

GolfCourseAPI **re-keyed their courses** from old numeric ids to alphanumeric
slugs. Most of our catalog is still keyed by the **old numeric ids, which now
404** at `/v1/courses/{id}`. Consequences:

- We can't fetch/re-import those courses by the id we stored.
- A fresh import would land under the *new* id and create a **duplicate** catalog
  course (everything dedups on `golf_api_id`).

So the ids must be **remapped old→new** before any re-import/propagation works.
Data itself is largely already in sync (e.g. Tilden White (M) = slope 122 /
rating 69.0 / par 70 matches live GCAPI) — the ids are the problem.

Scope: **13 catalog courses** on dead numeric ids (+ 25 account clones sharing
them). Only California GC (`1z16d412`) was already on a new-style id.

## Confirmed id remap

| # | Our course | Old id (dead) | New GCAPI id | GCAPI match | Location |
|---|-----------|--------------|--------------|-------------|----------|
| 1 | Chardonnay Gc | 24451 | `0m4sda7m` | Chardonnay Gc | Napa, CA |
| 2 | Corica Park Gc — North | 10423 | `qfv3y37x` | Corica Park Gc / North | Alameda, CA |
| 3 | Corica Park Gc — South | 26507 | `f5cnws7n` | Corica Park Gc / South | Alameda, CA |
| 4 | Fairways Of Halfmoon | 20758 | `edjn213j` | Fairways Of Halfmoon | Mechanicville, NY |
| 5 | Lake Chabot Gc | 19760 | `v7g5pgyj` | Lake Chabot Gc | Oakland, CA |
| 6 | Metropolitan Gl | 19771 | `f19r40nr` | Metropolitan Gl | Oakland, CA |
| 7 | Monarch Bay Gc — Tony Lema | 19919 | `1b3xwtd2` | Monarch Bay Gc / Tony Lema | San Leandro, CA |
| 8 | Paradise Valley Gc | 19624 | `mk2sr65b` | Paradise Valley Gc | Fairfield, CA |
| 9 | Presidio Gc | 19638 | `4yztvh53` | Presidio Gc | San Francisco, CA |
| 10 | Red Rock Country Club — Arroyo | 4753 | `7xmh8n3b` | Red Rock CC / Arroyo | Las Vegas, NV |
| 11 | Sequoyah Cc | 24539 | `46xjvgxt` | Sequoyah Cc | Oakland, CA |
| 12 | Siena Golf Club | 18263 | `64csz6xw` | Siena Golf Club | Las Vegas, NV |
| 13 | Tilden Park GC | 19641 | `tq7659nk` | Tilden Park Gc | Berkeley, CA |

Multi-course clubs to double-check: Corica North vs South (#2/#3), Monarch Bay
picked *Tony Lema* not *Marina* (#7), Red Rock picked *Arroyo* not *Mountain* (#10).

Synthetic-id catalog courses (no GCAPI source) — NOT remapped, add upstream if
wanted: Poppy Ridge — Championship 18 (`manual-poppy-ridge-champ18`), Sheep Ranch
(`manual-sheep-ranch`). Also many acct-1/2/4/7 hand-entered courses have no
`golf_api_id` at all (Bandon, etc.).

## Full workflow to update a course's ratings

1. Edit the course upstream at **https://golfcourseapi.com/course-update** so it
   matches GHIN.
2. (One-time per course) **Remap the id** old→new (see table) —
   `remap_golf_api_ids` updates `CatalogCourse.golf_api_id` + all account
   `Course` rows sharing the old id.
3. (One-time) **Un-curate** the catalog's standard tees so a re-import can update
   them: `python manage.py uncurate_catalog_tees --apply` (holds combos +
   White-Sixes; skips synthetic ids).
4. **Re-import** the course from GolfCourseAPI (now the id resolves) → updates the
   catalog + bumps `CatalogCourse.data_version`.
5. Account copies **sync lazily** via the tee picker (`TeeListView`), or force it:
   `python manage.py sync_catalog_tees --name "<course>" --apply`.

Slope/rating changes update in place (completed rounds keep their snapshotted
`FoursomeMembership.course_handicap`); stroke-index/par changes supersede the tee
so played scorecards stay frozen.

## Related commands

- `suggest_gcapi_ids` — search GCAPI for current ids of dead-numeric-id courses (read-only).
- `remap_golf_api_ids` — stamp new ids onto catalog + account courses (dry-run default).
- `uncurate_catalog_tees` — open standard catalog tees to API re-imports (dry-run default).
- `check_catalog_drift` — diff catalog vs live GCAPI (needs the remap first to resolve).
- `sync_catalog_tees` — push catalog tees to account copies (eager propagation).
- `mark_catalog_curated` — protect/un-protect a catalog course's tees (reverse of un-curate).

## Status

- Propagation feature committed on `main` (unpushed): `ffa523b`, `a3dd6b5`.
- Id remap: **applied 2026-08-08** — all 13 catalog courses + their account clones
  restamped to the new alphanumeric ids (0 numeric ids remain). Next: un-curate +
  re-import per course when you push a rating change upstream.
