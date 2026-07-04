# Catalog curation & API updates

How the shared course catalog stays correct as we hand-curate it **and** as
GolfCourseAPI data changes — without either one blowing away the other, and how
a downloaded (account) course learns about updates.

## Background: the two-layer course model

- **`CatalogCourse` / `CatalogTee`** — the shared master, keyed by `golf_api_id`.
  Real API courses use the numeric id; hand-built courses use a synthetic id
  (`manual-…`, `local-<pk>`, `seed-…`).
- **`Course` / `Tee`** (account-owned) — an account **clones** a catalog course
  on add ("copy-on-add"). Local edits (incl. `Tee.sort_priority`) never touch
  the catalog or other accounts.
- **Copy-on-write tees** — once a round references an account `Tee`, editing its
  hole geometry RETIRES it (`superseded_by`) into an immutable revision so the
  played round's scorecard stays frozen; new rounds pick up the new revision.
  Slope/rating changes apply in place (course handicaps are snapshotted at
  setup, so history doesn't shift).

## The problem

1. **Re-import used to wipe curation.** `upsert_catalog_course` did
   `cc.tees.all().delete()` then rebuilt from the API payload — so any rating
   fix or hand-added tee (combos, missing women's tees) was destroyed the next
   time that `golf_api_id` was imported.
2. **No account update path.** After copy-on-add an account course is a
   point-in-time snapshot; the only way to push a later catalog fix down was the
   admin `sync_catalog_tees` command over SSH. There's no user-facing "an update
   is available."
3. The **import quality gate** (`services/course_quality.py`) blocks
   *catastrophic* API data (e.g. all stroke-index-18) but not "plausible but
   wrong" data quietly overwriting good manual data.

Manual courses under a synthetic id were already safe (the API never targets
those ids) — the exposure was real-`golf_api_id` courses we'd corrected
(Metro `19771`, Corica South `26507`).

## Design: two independent mechanisms

### 1. Curation-aware catalog — PHASE 1, IMPLEMENTED

`CatalogTee` gains provenance:
- `origin` — `'api'` (created by `upsert` from GolfCourseAPI) or `'manual'`.
- `curated` (bool) — "a human vetted/edited this; an API re-import must not
  overwrite or delete it."

`upsert_catalog_course` is now a **merge, not delete-and-rebuild** (match by
`(tee_name, sex)`):
- **Curated** tee → left untouched (protected).
- **Uncurated** tee matching an API tee → updated in place from the payload.
- API tee with **no match** → created (`origin='api'`, `curated=False`).
- **Uncurated** tee the API no longer returns → deleted; **curated orphans stay**
  (so a hand-added combo survives even though the API never knew about it).

A course whose tees are all curated therefore survives a re-import intact.

**Backfill (migration `core/0010`):** everything already in the catalog has been
hand-vetted, so it's all marked `curated=True`. Going forward the catalog
lifecycle is:
- New API course imported → tees `origin='api'`, `curated=False` → future
  re-imports keep it fresh.
- Someone hand-edits a tee → mark it curated to protect it.

**Levers:**
- `manage.py mark_catalog_curated --name "X" [--apply]` — protect a course's
  tees after editing them.
- `manage.py mark_catalog_curated --name "X" --uncurate --apply` — deliberately
  RE-OPEN a course to API refreshes.
- `services.catalog.catalog_from_course` (seed-from-account) marks its tees
  curated (they're locally-vetted data).

### 2. Versioned pull updates — PHASE 2, NOT YET BUILT

Give a downloaded (account) course a way to see and apply catalog updates:
- `CatalogCourse.data_version` (monotonic; bump on any catalog change) +
  `Course.catalog_synced_version` (the version the account cloned/synced at).
- Account detects `synced_version < data_version` → surface **"Update
  available"** in Manage Courses.
- Applying it runs the existing `clone_catalog_to_account(replace_tees=True)`
  path → copy-on-write (played tees frozen, current re-rated, local
  `sort_priority` preserved). The same `curated` idea protects an account's own
  local edits from being overwritten by the update.

### 3. Scheduled API refresh with three-way merge — PHASE 3, NOT YET BUILT

GolfCourseAPI has no change feed, so updates are **pull-based**. A
`refresh_catalog_from_api --name X` command (or a scheduled job) re-fetches,
runs the quality gate, and does a **three-way merge** (last-API-snapshot vs new
API vs current) so it only auto-applies fields the API actually *changed* and
that aren't curated — staging conflicts for review rather than clobbering.
Needs a stored `last_api_snapshot` per course. Should DIFF-and-REPORT, never
silently overwrite (same philosophy as the `sync_catalog_tees` dry-run).

## Operating rules today

- New / corrected courses live under **synthetic ids** where practical — they're
  immune to API re-import by construction.
- After hand-editing a real-`golf_api_id` catalog course, run
  `mark_catalog_curated` to protect it (existing catalog is already protected by
  the 0010 backfill).
- Push catalog → accounts with `sync_catalog_tees --name X --apply` (now
  reconciles slope/rating too, not just holes). See
  `docs/` and the [[tee-maintenance-commands]] notes.

## Status

- **Phase 1 — DONE:** `origin`/`curated` fields (`core/0010`), curation-aware
  `upsert_catalog_course`, `mark_catalog_curated` command, `catalog_from_course`
  marks curated, backfill protects the existing catalog. Tests in
  `api/test_catalog.py::CatalogCurationMergeTests`.
- **Phase 2 / 3 — deferred** (version stamps + in-app "Update available";
  scheduled three-way-merge API refresh).
