# Cross-round Multi-Group Skins — link foursome rounds into one pool (DESIGN)

Parallel-Games **Phase 2** (docs/parallel-games.md): "feed a single foursome's
scores into another group's pool." The parked item + the "multi-host skins as
both a side game and a main game" note. **Not yet built** — design only.

## Goal / scenario

A **Multi-Group Skins pool** is one skins bet whose players are spread across
**independent rounds** (different foursomes, different games, possibly different
accounts). Each round enters its own gross **once**, playing its own game; the
players who are in the pool have those same gross scores fed into a shared skins
competition.

Canonical scenario (from the product discussion):
- Someone creates a **Multi-Group Skins** round (the existing casual flow) and
  puts a **roster** of Halved members into the pool — including players 2 and 4.
  That round appears in their active casual games and has the normal leaderboard
  **spectator link** (`/watch/<token>/`).
- Player 1 hosts a **Sixes** round; his foursome is players 1, 2, 3, 4. He pastes
  the pool's `/watch/<token>/` link into his round. The app **searches his
  foursome against the pool roster and finds the exact overlap — 2 and 4** — and
  links their scores to the pool. Players 1 and 3 don't touch the pool.
- Players 2 and 4's *other* pool-mates are playing Nassau / their own games in
  **other** rounds, each likewise linked to the pool by pasting the same link.
- The pool aggregates gross from every linked round for its participants, awards
  1 skin/hole to the low score, and settles among its participants.

## Why the pool is ANCHORED ON A HOST ROUND (reusing its watch link)

The pool link is the **existing round leaderboard spectator link**
(`/watch/<watch_token>/`) — reused **as-is**. Since `watch_token` lives on
`Round`, the pool must be owned by a round. So we keep the existing
`MultiSkinsGame` (`OneToOne(Round)`) as the pool and **extend it to accept
LINKED rounds** whose scores feed in. The "host round" is exactly the
**Multi-Group Skins round** the organizer already creates today — it appears in
their active casual games, and its leaderboard already surfaces the share link.
No standalone object, no new token, no new watch page.

What changes vs. today's single-round `MultiSkinsGame`:
- Participants may be **Halved members not in the host round's own foursomes**
  (they play in linked rounds instead). The roster is selected from connected
  golfers, not just the host round's memberships.
- The scoring engine unions gross across the **host round + every linked round**,
  resolving each participant's per-round score source by **phone/member identity**.

The host round is a **normal casual round with its own primary game** (the host
plays their Sixes / Nassau / etc.) that *also* hosts the pool. The **host plays
in it and is automatically a pool participant** — today there's no way to opt out
of a casual game you start, so the pool creator is always both a player and a
participant. (A pure non-playing organizer would need a new "opt out of my own
round" capability that doesn't exist today — deferred; see Open questions.) This
is the reclassification `multiSkins` needs: it stops being the round's *main*
game and rides as a cross-round pool on a round that has its own primary.

## Decisions (locked)

- **Same course only.** "Low score wins the skin" is only meaningful when every
  linked round is on the **same course** (same par + stroke index per hole). A
  link is **rejected** if the round's course ≠ the pool's course.
- **Participants are Halved members only — enforced at pool creation.**
  Cross-round / cross-account score sourcing matches players by **phone /
  Halved-member identity**. A login-less "my golfer" (exists only in one
  account's roster, no Halved account) has no cross-account identity to match on,
  so **cannot** be a pool participant. The roster picker offers only connected
  (on-app) golfers, AND the setup endpoint **rejects** any non-member id — the
  invalid state can never be persisted.
- **The host plays and is in the pool.** The pool is hosted on a normal casual
  round with its own primary game; its creator is automatically both a player in
  that round and a pool participant (no opt-out of a game you start today). A
  non-playing pure-organizer pool is out of scope (deferred).
- **Roster is pre-defined; joins auto-match the overlap.** The pool's participant
  roster is set when the Multi-Group Skins round is created. When a foursome
  round links, the app **searches that round's players against the roster and
  offers the exact overlap** (auto-selected, by phone identity) — no manual
  opt-in. A link that overlaps **zero** roster members is pointless → rejected.
- **Always open-join; consent is implicit.** Anyone with the link can link a
  round; possessing the link + being on the roster **is** the approval. No host
  approval step, ever (not just v1).
- **A linked round sends only its overlapping members' scores.** The intersection
  of (round's players) ∩ (pool roster) is what flows in. Non-member players in a
  linked round are invisible to the pool.
- **Visibility generous, settlement strict** (parallel-games rule, verbatim):
  every pool participant (and every member of a linked foursome) sees the pool
  tab incl. money; the pool's settlement involves **only its participants**.
- **Settlement is pool-local.** Pool = participants × bet_unit, split by skins
  won (existing engine). Each linked round's own primary game settles
  independently. **No cross-game / cross-account dollar netting** in v1.
- **Skins rules unchanged.** 1 skin/hole to the outright low; ties kill the skin
  (no carryover, no junk) — same as today's `MultiSkinsGame`. A hole counts only
  once **every participant** has a gross score on it (holes count as the slowest
  linked round completes them).

## Model shape

Extend the existing objects; no standalone pool.

- **`MultiSkinsGame`** (unchanged anchor: `OneToOne(Round)` = the host round).
  Keep `handicap_mode`, `net_percent`, `bet_unit`, `status`. `participants` M2M
  becomes the roster of **Halved members** (see identity note below).
- **`MultiSkinsLinkedRound`** — new join row: `(game, round, linked_by)`. One per
  linked foursome round. Created on join; enforces same-course + ≥1-overlap.
  (The host round is implicitly a source too, for the organizer's own foursome.)
- **Result rows** — `MultiSkinsHoleResult` unchanged (per-hole winner), keyed to
  the game.

### Participant identity (Halved members)

A pool participant is a **Halved member** (a `Player` whose `user` is set, i.e.
phone-verified). To source their scores from each linked round, the engine
**phone-matches** the member to a `Player` in that round (the established
connected-golfers / shared-rounds pattern — `accounts/phone.normalize`). So
`participants` stores canonical member `Player`s; per-round score sources are
resolved at scoring time by matching phone → the round's `FoursomeMembership`.
(Within a single account the match is the same `Player` row; cross-account it's a
phone match.)

Strokes-off-low stays **pool-wide**: lowest playing handicap across all
participants plays to 0; each player's SI comes from their own linked round's tee
membership (widen `_build_so_round_index`'s membership source from one round to
all linked rounds).

## Linkage / consent flow

1. **Create the pool.** The existing "Multi-Group Skins" casual round flow, with
   the participant picker drawing from **connected (on-app) golfers** — the
   roster may include members who won't play in this host round. Pick course,
   handicap mode, bet_unit. The round shows in active casual games; its
   leaderboard has the normal **Share / spectator link** (`/watch/<token>/`).
2. **Link a round to the pool.** During casual round creation (or from the round
   hub), an **Advanced** section: "Link to a Skins pool" → paste the
   `/watch/<token>/` link → the app parses the token, calls
   `GET /api/skins-pool/<token>/`, computes the **overlap** of this round's
   players with the roster, and shows it (auto-selected) → confirm → POST join.
   - Reject if the round's course ≠ the pool's course (surface which).
   - Reject if the overlap is empty.
3. **Scores flow automatically.** On any linked round's score submit, recompute
   the pool (union gross across host + linked rounds → per-hole skins →
   settlement).
4. **Unlink** removes a linked round's contribution (allowed until the pool
   completes; started-round nuance below).

### Cross-account authorization

Reads/writes cross accounts at the ORM layer (FKs/M2Ms span accounts; scoping is
a query filter, not a DB constraint). Authorization to link a round to a pool =
**possession of the watch token** + control of the round being linked. The
`MultiSkinsLinkedRound` record is the standing read grant for that round's
`HoleScore`, analogous to how `round_for_reader` / watch tokens authorize
cross-account leaderboard reads today.

## Endpoints (proposed)

The token in the path is the **host round's `watch_token`** (parsed from the
pasted `/watch/<token>/` URL by the client):
- `GET  /api/skins-pool/<token>/` — resolve the host round + pool summary +
  roster (token-gated; used by the paste-link resolver and the pool tab).
- `POST /api/skins-pool/<token>/join/` — `{round_id}`; the server computes the
  overlap of `round_id`'s players against the roster (by phone), validates
  same-course + ≥1-overlap, creates the `MultiSkinsLinkedRound`.
- `POST /api/skins-pool/<token>/unlink/` — `{round_id}`.
- `GET  /api/skins-pool/mine/` — pools I created or participate in (for casual
  list surfacing).
- Recompute hook: extend the post-score-submit dispatch (`api/views.py`) to
  recompute the `MultiSkinsGame` of every pool this round is linked to.

The existing `rounds/<pk>/multi-skins/setup/` stays for host-round pool config;
the roster picker there is broadened to connected golfers.

## Scoring engine (reuse)

Refactor the core of `services/multi_skins.py` so the score-index builder,
calculator, and settlement operate over a **list of `(round, participant_players)`
sources** instead of a single round's foursomes:

- `_build_pool_score_index(sources, handicap_mode, net_percent)` — union
  `build_score_index` per foursome across the host + every linked round
  (net/gross); pool-wide strokes-off anchored on the lowest participant handicap
  across all sources; per-participant source resolved by phone match.
- `calculate_multi_skins(game)` / `multi_skins_summary(game)` — same per-hole
  "everyone scored → low wins, tie kills" + proportional payout, now over the
  multi-source index.

Today's single-round pool is the one-source case → one implementation, not two.

## Phasing

**Phase 2.1 — Backend: linked rounds + cross-round engine. ✅ IMPLEMENTED.**
`MultiSkinsLinkedRound` model (`games/0055`); `setup_multi_skins` broadened to
accept on-app (Halved) roster members not in the host round
(`valid_participant_ids`); the skins core refactored to multi-source with
phone-matched per-round sourcing (`_resolve_participant_memberships`,
`_build_pool_score_index`, `_calculate_game`, `_summary_for_game`,
`recalc_pools_for_round`, `pool_overlap`); endpoints
`GET /api/skins-pool/<token>/` (resolve, optional `?round_id=` overlap preview),
`POST …/join/`, `POST …/unlink/`, `GET /api/skins-pool/mine/`; the score-submit
recalc hook now recomputes every pool a round hosts OR is linked into; a linked
round's leaderboard surfaces the pool tab (`host_round_id`); same-course
(by `golf_api_id` cross-account) + ≥1-overlap guards. Tests:
`scoring/tests/test_multi_skins.py::MultiSkinsCrossRoundTests` (phone-matched
overlap, scores flow from a linked round, unlinked contributes nothing) +
`api/test_skins_pool.py` (resolve/roster/overlap, cross-account join + scoring,
no-overlap 400, different-course 400, foreign-round 404, unlink, mine).

**Phase 2.2 — Mobile: create + link + pool tab. ✅ CORE DONE.**
Shipped: (1) client + models — `ApiClient.parsePoolToken` /
`resolveSkinsPool` / `joinSkinsPool` / `unlinkSkinsPool` / `getMySkinsPools`;
`SkinsPoolResolve` / `SkinsPoolRosterMember` / `MySkinsPool`;
`MultiSkinsSummary.linkedRounds`/`hostRoundId`/`isCrossRound` +
`MultiSkinsPlayerTotal.roundId`. (2) `utils/skins_pool_link.dart`
`linkRoundToPoolFlow` — paste `/watch/<token>/` → resolve → confirm the exact
roster overlap → join; wired to a round-hub **"Link to a Skins pool"** button
(casual, manager, group 1, hidden on a pool host round). (3) Roster picker
broadened to connected golfers ("Playing in another group" in
`multi_skins_setup_screen`). (4) The linked round's leaderboard renders the pool
tab automatically (`_leaderboard_active_games` surfaces `games['multi_skins']`).
The host shares the pool link via the existing leaderboard "Share spectator
link". **Deferred (polish):** a dedicated pool card in the casual list
(`getMySkinsPools` endpoint exists, unused); reclassifying `multiSkins` so the
HOST can play its own primary AND host the pool in one round (today the host
round is a dedicated Multi-Group Skins round); relabeling the share action
"Share pool link" on a pool round.

**Phase 2.3 — Tournament-foursome side game (design-now, build-later).**
A tournament foursome links its four into a pool on the **tournament's** gross
(the linked "round" is the tournament round). Same objects; the permission
wrinkle is that tournament rounds are TD-owned while the pool is a private side
bet — the link grant must not widen TD control. Built after 2.1/2.2.

**Link + visibility granularity = FOURSOME, not round (the tournament fix).**
Phase 2.1 links a whole `Round`. In a casual round that IS one foursome, so
round == foursome and the leaderboard surfacing (below) is exactly scoped. In a
tournament a round holds many foursomes, so linking/showing at round level would
expose a private 4-person pool to the WHOLE field. Scoring is already safe (the
pool sources by phone-matched roster overlap, so only the four match wherever
they play), but **visibility is too broad**. Fix: add a nullable `foursome` FK to
`MultiSkinsLinkedRound` (null = whole round, back-compatible with 2.1); the
join/link is per foursome; and the leaderboard surfacing scopes the pool tab to
the linked foursome. Casual is unchanged (single foursome).

Confirmed 2.1 behavior this refines: `_build_leaderboard(round_obj)` already
surfaces a linked pool's tab on that round's `/api/rounds/{id}/leaderboard/`
(with `host_round_id`), for BOTH casual and tournament rounds — this is the
too-broad path a tournament needs scoped to the foursome. The tournament-AGGREGATE
leaderboard (`TournamentLeaderboardView`) does NOT surface pools and shouldn't —
a private foursome pool lives on that foursome's own round leaderboard, never the
field-wide standings.

## Mid-round roster editing

Folds in docs/multi-skins-mid-round-roster.md's rule, generalized: **a linked
round that has started (any `HoleScore`) is frozen** — its overlap can't change;
only un-started linked rounds can be added/removed, and only while the pool is
not `complete`. (Adding a player after their round has played holes would orphan
earlier holes — same reason the single-round design locks started groups.)

## Open questions / deferred

- **Roster editing UX** — v1 sets the roster at pool creation from connected
  golfers. Adding a member after some rounds have started follows the freeze rule.
- **Non-playing organizer** — deferred. Today the pool creator must be a player
  in the host round (no opt-out of a game you start). A pure organizer who runs a
  pool without playing would need a new "opt out of my own round" capability;
  not needed for the scenario.
- **Money-privacy gate** ($ hidden to non-participants) — deferred.
- **Cross-account dollar netting** into a unified session cash-out — deferred.
- **Recycled-number / stale-link safeguards** on tokens — deferred.

## What this reuses

- **`Round.watch_token`** + the leaderboard spectator link (`/watch/<token>/`),
  reused as-is for the pool link; the existing share sheet distributes it.
- The **skins engine** in `services/multi_skins.py`, generalized to multi-source.
- The **connected-golfers / phone-matched** identity layer (`accounts/phone.py`,
  `accounts/scoring_access.py`) for roster identity + cross-account read.
- The **observed/shared-round list surfacing** pattern for showing the pool in
  the casual list.
- `MultiSkinsGame` / `MultiSkinsHoleResult` + the mobile Multi-Skins leaderboard
  card, extended — not replaced.
</content>
