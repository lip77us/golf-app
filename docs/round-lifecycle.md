# Round lifecycle & the "archive" question

Status: **decision — do nothing now.** Captured for a future revisit.

## Current lifecycle

- A round is **Active** (`status = in_progress`). From here the user can **close**
  it (→ complete) or **delete** it.
- A **closed** round (`status = complete`) moves to the **Completed** list.
- From Completed, the user can **delete** it — otherwise it lives forever.

So the only two end-states today are "kept forever in Completed" or "deleted."

Note on delete: it's already **constrained**. `HoleScore` and
`FoursomeMembership` reference players/foursomes with `on_delete=PROTECT`, and a
round's history is **shared** with other players (other accounts see it via
phone-match under "Shared with me"). So a hard delete can't truly erase shared
history — the account-deletion path anonymizes rather than nukes. Practically,
delete is a blunt, rarely-correct tool for an individual completed round.

## The question

Should there be an **Archive** action + a third **Archived** tab — a middle state
between "Completed (kept)" and "deleted"?

## Decision & reasoning (June 2026)

**No third tab, and nothing now.** Two itches get conflated as "archive":

1. **Declutter** — "my Completed list is getting long." (The real driver.)
2. **A safe middle ground** — "done with this, but deleting feels permanent."

### Why defer
- **Stage:** pre-launch / early users have a handful of rounds. The Completed
  list isn't long enough to need archiving. A third top-level tab is real
  cognitive + maintenance weight for a problem we don't have yet.
- **The clutter itch has cheaper fixes** that often make archive unnecessary:
  - **Default to recent**, group older by year ("2026", "2025 ▸") so old rounds
    fall below the fold instead of being deleted.
  - **Search / filter** (course, date, game).
  - **Pagination** so we're not rendering hundreds of rounds.

### If/when we do build archive
- Make it a **per-round `archived_at` flag** + an **"Archive"** action on
  completed rounds + a **"Show archived"** filter toggle on the Completed list.
  **Not** a third tab. Reversible (un-archive).
- Archive then becomes the **primary** "get it out of my way" action; reserve
  hard-delete for the rare true-removal case.

### The catch that makes it non-trivial — multi-account
Rounds are **shared** across accounts (a co-player sees the round via
phone-match). So:
- A **round-level** archived flag means one player archiving it hides/changes it
  for **everyone** — surprising and wrong.
- The correct model is **per-viewer archive**: each account hides it from *their
  own* list only. That's a per-(user, round) join row, not a single column —
  more to build, and the reason a quick round-level flag would behave wrong for
  shared rounds and have to be redone.

## Bottom line
- **Launch:** keep **Active / Completed** as-is.
- **If the Completed list gets long:** add **recency grouping + search** (cheap,
  high value) before considering archive.
- **Only if users ask to tidy up:** build a **per-viewer `archived` flag +
  filter toggle** (not a third tab), reversible, with hard-delete as the rare
  exception.
- Ties into data-retention / privacy (how long we keep data) — already noted in
  the privacy policy that anonymized records may be retained.
