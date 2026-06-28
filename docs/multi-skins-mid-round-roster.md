# Multi-Group Skins — mid-round roster / pool editing (DESIGN, not yet built)

## Goal / scenario
A late golfer shows up to an un-started group (e.g. the 4th group) and wants to
throw their entry into the **Multi-Group Skins** pool *after other groups have
already started scoring*. Today the only recourse is to delete the round and
re-enter everyone. We want to let the TD add them in place.

## The rule (decided)
**Once a group has started, you cannot change its players. You can only add to
groups that have NOT started.** Enforced **per-foursome**, not per-round:
- A foursome with **any `HoleScore`** is locked (its roster + its pool
  membership are frozen).
- A foursome with **no scores** can still gain/lose players and pool entries,
  even while other groups are mid-round.
- The whole edit is blocked once the **round is `complete`**.

## Why multi-skins is the right (and easy) game for this
- The pool roster is an **explicit `MultiSkinsGame.participants` M2M**, fully
  decoupled from scoring. Scores live in `HoleScore`; the participant list does
  not touch them.
- `MultiSkinsSetupView` (`POST /api/rounds/{pk}/multi-skins/setup/`) already
  *"replaces any existing Multi-Skins game"* — re-running it with a new
  participant list is a supported, side-effect-light operation.
- `setup_multi_skins(round, participant_ids, …)` just validates ids against
  round memberships and does `game.participants.set(pids)`.

So the **pool side is nearly free**. The real work is (a) a per-group guard on
participant changes, and (b) getting a brand-new golfer into an un-started
foursome mid-round.

## Scope (confirmed)
Full version: from a mid-round multi-skins edit screen, the TD can **add a
brand-new golfer into an un-started group AND the pool**, or toggle existing
players — with started groups locked.

## Scoring caveat to surface in the UI
Multi-skins only counts a hole once **every participant** has a gross score on
it. A player added to a group that starts at hole 1 will eventually have all 18,
so no holes are lost — the pool just waits for that group (normal multi-group
behavior). But a player added **after their group has already played some holes**
would cause those earlier holes to never count for anyone (they have no score
there). That's why we lock started groups. The "un-started group only" rule
neatly avoids this — keep it. (If we ever allow joining a started group, we'd
need a per-participant "counts from hole N" concept; out of scope.)

## Backend changes
1. **Per-group-guarded participant edit.** Either extend `MultiSkinsSetupView`
   or add `POST /api/rounds/{pk}/multi-skins/roster/`. Behavior:
   - Allowed while round `in_progress` (not `complete`).
   - Compute the diff between current and requested `participants`. **Every
     added or removed player must belong to a foursome with no `HoleScore`.**
     Reject (400) if a change touches a player in a started foursome, naming the
     group.
   - Players in started foursomes must remain exactly as-is (locked).
   - Leave `bet_unit` / `handicap_mode` editable only if it doesn't change
     already-counted holes — simplest: keep config fields frozen once any group
     has scored; allow only roster delta. (Confirm with product.)
2. **Add a player to an un-started foursome mid-round.** New narrow endpoint,
   e.g. `POST /api/foursomes/{pk}/add-player/` `{player_id, tee_id}`:
   - Refuse if the foursome has any `HoleScore` (mirror `FoursomeRemovePlayerView`'s
     no-score guard, inverted target).
   - Refuse if it would exceed the group cap (4 real players).
   - Snapshot `course_handicap` / `playing_handicap` from the chosen tee at add
     time (same as setup), create the `FoursomeMembership`.
   - Run `validate_donor_foursomes(round)` if the round has phantom/cup
     structure (multi-skins casual rounds usually don't, but be safe).
   - The player must already exist as a roster `Player` (use the existing
     `PlayerCreate` endpoint / inline "Add a golfer" to mint a brand-new one
     first, then add to the foursome).
3. Existing `FoursomeRemovePlayerView` already enforces "no scores" for removal —
   reuse for taking someone back out of an un-started group.

## Mobile changes
1. **Reach the edit mid-round.** Add a round-level entry on the `/round` hub for
   multi-skins that is available **while in progress** (gated `!complete`,
   manager-only) — distinct from the per-foursome "Edit Configuration" (which
   locks at first score). Route to the multi-skins setup screen in an edit mode.
2. **In `multi_skins_setup_screen.dart`:**
   - For each group, show whether it has **started** (lock icon). For started
     groups, render participant checkboxes **disabled** with a "Group started —
     locked" note; their current state is read-only.
   - For un-started groups, allow toggling participants and an **"Add golfer to
     Group N"** affordance (reuse the inline add-golfer flow + tee pick from
     round setup), then auto-check the new golfer into the pool.
   - Submit only the allowed delta to the guarded endpoint(s).
3. Client methods: `addFoursomePlayer(foursomeId, playerId, teeId)` and the
   roster-edit call; refresh the round + multi-skins summary on return.

## Gating summary
- Round `complete` → no edits.
- Per foursome: has scores → locked (no add/remove, pool entries frozen); no
  scores → fully editable.

## Relationship to the round-level "Edit Configuration" work (separate, TODO)
A round-level Edit Configuration entry on the hub for **stableford / low-net /
multi-skins** was discussed but NOT yet built. Note the difference:
- **Stableford / low-net**: config (points table, handicap mode, payout) is
  **retroactive** to scoring, so it should stay editable **only before the first
  score** (lock at first `HoleScore`, like the per-foursome games).
- **Multi-skins roster**: additive and per-group, so it follows THIS design and
  stays editable mid-round (un-started groups only).

## Status
Design only. The casual-wizard rollout (returnToHub + per-foursome Edit
Configuration) is shipped; this feature is queued behind testing that.
