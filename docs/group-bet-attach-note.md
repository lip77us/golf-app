# Group-bet attach path — design note

Prerequisite for the **`leaderboard-group-bets`** screen (the last unbuilt item in
`docs/cup-flow-redesign-plan.md`). That screen *settles* skins / Nassau / rabbit
per foursome from the gross scores already entered — but nothing today lets a
tournament foursome **have** such a bet. This note designs that missing "attach"
path. It is deliberately small because most of the machinery already exists.

## The problem in one line

The group-bets tab is a display with no data source in the cup flow: there is no
way to put a skins / Nassau / rabbit wager on a *tournament* foursome. The Phase‑2
group builder intentionally does **not** offer one (a wager among four players is
theirs, not the tournament director's — see `docs/cup-flow-redesign-plan.md`
group-builder + round-groups rows), and no player-facing entry point exists.

## What already exists — do NOT rebuild

- **Per-foursome game models.** `SkinsGame` / `RabbitGame` are `OneToOneField` to
  `Foursome`; `NassauGame` is a `ForeignKey` (a foursome can hold several
  Nassau-family matches). A tournament `Foursome` can host these exactly as a
  casual one does — no schema change.
- **Setup + result endpoints are already per-foursome:**
  `foursomes/<id>/skins/setup/`, `…/nassau/setup/`, `…/rabbit/setup/`, etc.
- **Write auth already fits.** `accounts/scoring_access.foursome_for_scorer`
  grants write to the foursome's own account **or** a phone-matched member /
  designated scorer — exactly "someone in the group," not just the TD.
- **Settlement is already computed from gross.** The casual leaderboard renders
  these summaries today; the group-bets tab reuses the same summaries.
- **Precedent for a group-initiated attach:** cross-round Multi‑Group Skins
  (`docs/multi-skins-cross-round.md`) already lets a group opt into a pool from
  their own round via a pasted link — a group opening its own wager is an
  established pattern.

**So the gap is only: entry point + ownership + surfacing.** Not scoring, not
data model, not auth primitives.

## Principle (the test the redesign uses)

> If it needs one answer for the whole field, it is the TD's; if it settles among
> four, it is theirs.

Group bets settle among four, so the **foursome owns them**. The attach path must
be **player-initiated**, never a TD control in the group builder.

## Proposed path (smallest viable)

1. **Entry point on the round hub, not the builder.** Each foursome card on the
   cup round hub (`round_screen.dart` `_FoursomeCard`) gains a quiet
   **"Add a bet ▾"** affordance offering Skins / Nassau / Rabbit — shown to a
   **member of that foursome** (or its designated scorer), i.e. gated on
   `isMyGroup || youScore` (the same signal that already gates Enter Scores), not
   on `canManage`.
2. **Reuse the existing setup screens.** Route to `skins_setup_screen` /
   `nassau_setup_screen` / `rabbit_setup_screen` with `returnToHub: true`,
   targeting the tournament foursome's id. They already POST to the per-foursome
   setup endpoints; nothing new server-side.
3. **Attach = the game row on the Foursome.** No new model or join table — the
   bet "attaches" simply by existing on `foursome.configured_games`, identical to
   casual play.
4. **The tab reads it back.** `leaderboard-group-bets` iterates the round's
   foursomes, reads `configured_games`, and renders each game's existing summary,
   grouped by group. A foursome with none shows the empty "Add one" row.

Net new work is a member-scoped launcher on the foursome card + the read-only
tab. Everything under them already ships.

## Decisions to settle before building

- **Who may add/edit** — any foursome member, or only a designated scorer?
  (Recommend: any member *or* the scorer; the TD can via own-account but it's not
  surfaced to them.)
- **Gross vs net skins** — mock draws gross; net needs the stroke dots repeated
  and crowds the hole strip. (Recommend: gross first.)
- **Show currency amounts, or only the result?** Naming amounts makes the app a
  ledger. (Open in the mock — pick one before shipping the tab.)
- **Nassau presses** on the tab — a fourth column or a second row (deferred).

## Non-goals

- Cross-account settlement or money netting between accounts.
- TD-managed group bets (explicitly rejected — ownership sits with the group).
- Any change to score entry: these settle from gross already entered.

## Status

Attach path: **designed, not built.** Once (1) lands, `leaderboard-group-bets`
becomes pure display over `foursome.configured_games` — buildable and testable
with real data rather than hand-seeded rows.
