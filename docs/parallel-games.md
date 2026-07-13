# Parallel games — design doc

**What it is:** let a single foursome run **more than one bet at once over
different subsets of players**, entering each player's gross score **once**.
Today a casual round is essentially *one game among a fixed set of players* (plus
side games that are forced to share the primary's player set and handicap). Real
groups don't play that way — several independent bets coexist inside one
scorecard, over overlapping-but-different players, each with its own handicap.

**Motivating scenarios (all real):**
- **Larry.** Larry plays an NCGA singles match (he's getting 3 strokes from his
  opponent). At the same time he'll play me a Nassau (I give him 1). One
  foursome, two bets, different pairs, **different stroke allocations on the same
  gross scores.**
- **Soft-tension sixes + a side Nassau.** Four players play low-stakes Sixes
  (partner rotation makes it a nice no-money-pressure game). Two of them are
  gamblers and run a higher-stakes 2-man Nassau **in parallel** — quite possibly
  **gross between the two of them**, since they scratch it out.
- **Tournament foursome, private internal skins.** A tournament foursome playing
  Pink Ball + Irish Rumble as tournament side games decides to also run their own
  Skins among the four — a *casual* game riding on tournament scores.
- **Multi-group Skins.** The Skins pool owner is in group 1; group 3 is playing
  Sixes and one of its players is also in the Skins. The game's participants
  span foursomes (and accounts) that have nothing else in common.

---

## The core insight

**Gross is the shared truth; net is a per-game projection.** A player's gross on
a hole is one fact. Stroke allocation, net-to-par, the stroke **dots**, and the
score coloring are all *derived per game per participant* — not properties of the
score. Larry's 5 is one number; through the match it's −3-net, through the Nassau
it's −1-net. Two games, two nets, two displays, one score.

The app can hide this today only because a casual round has exactly **one net
lens** (the primary game's handicap drives the stroke dots — see
`_handicapParams` / `primaryHandicapFor`). Parallel games break the single-lens
assumption, so the design's whole job is to keep **entry = gross (shared)** and
push **net into per-game surfaces.**

Think spreadsheet: one column of gross is the truth; each game is a separate
sheet that references some rows and applies its own handicap formula to produce
standings. The score-entry screen is the gross column; each game's leaderboard is
its sheet.

This is the **tournament model generalized down to casual** — a tournament round
already holds a field's scores and settles multiple games (low net, skins,
stableford championship) over subsets. Casual "primary + side games" is the
constrained special case where side games are forced to share the primary's
players and handicap. Parallel games relaxes exactly those two constraints.

---

## Decisions (from the product discussion)

- **The entry card shows the PRIMARY game's lens, unchanged.** All the existing
  stroke-dot / strokes-off net-per-hole work stands verbatim. The primary is the
  game that **owns the entry structure** — e.g. Sixes *must* be primary because
  it rotates partners and manages the flow. `Round.primary_game` (already stored)
  becomes genuinely load-bearing: it is the entry-owning game.
- **Gross-only rows are the narrow exception, precisely defined:** a player who
  is **in the foursome but not in the primary game** has no primary allocation,
  so their row shows gross with **no dots**. (Larry's opponent, in the group for
  his singles match but not in my primary Nassau, is exactly this row.) This is
  the *only* place gross-only kicks in — the entry card never draws two nets.
- **Side games are leaderboard-tab-only.** They never draw net on the entry card.
  So **what's inline vs. what's a tab** is settled: the **primary's** per-hole
  strip stays below the entry field (as today); **every** game — primary and side
  — gets a leaderboard tab with its own subset + net. No second net ever competes
  for the entry card, so the ambiguity evaporates by construction.
- **Side games carry their own participant subset** (not "all real players").
- **A side game may only use features that need NO score-entry interaction.**
  Corollary of tab-only. A side **Nassau** therefore allows **auto-press /
  Claremont only** — *manual* presses are a score-entry action (tap "press"
  mid-round), so the press mode is limited to None/Auto when Nassau is a side
  game. Same species as **side Skins suppressing junk** (already shipped): a
  capture that lives on the entry card can't ride a leaderboard-only side game.
- **Side games have their own handicap, independent of the primary — including
  gross.** This *reverses* the current casual rule where a side game **inherits**
  the primary's handicap (`primaryHandicapFor` + `InheritedHandicapNote`). The
  Larry case (match = 3 strokes, Nassau = 1) and the two-gamblers case (they play
  each other **gross** while the foursome plays Sixes net) both require a subset
  side game to own its handicap mode + allowance. → We revive per-side-game
  handicap selectors for **subset** side games. (Full-foursome overlay side games
  may keep inheriting; TBD — see Open questions.)
- **Visibility is generous; settlement is strict.** *Being in the scoring session
  grants visibility to every game in it; being in a game determines settlement,
  not visibility.* A foursome member who is **not** in the 2-man Nassau still sees
  the Nassau tab — status **and money**. (Product call: show the $ to everyone
  until a big loser screams; then gate to "status visible, $ hidden to
  non-participants." It's a later flag, not a v1 concern.) The only hard rule:
  a game's money summary involves **only its participants**, and nothing on a tab
  implies a non-participant owes or is owed anything.
- **More games become side-eligible.** A simple **2-man Nassau** and a **1-v-1
  match** must be selectable as side games (today Nassau is locked out of the
  side slot). Structural games that own the entry flow (Sixes, Wolf, Rabbit,
  Vegas, Fourball, Triple Cup) stay primary-only.
- **Games score independently, but dollars net across games into one session
  settlement.** You can't net a Sixes *point* against a Nassau *dollar* at the
  scoring level (different units), so each game computes its own per-participant
  money deltas. But once those are **dollars**, a session-level **"cash out"**
  settlement sums each player's deltas across every game they're in → **one net
  number per player** + a minimal who-pays-whom plan, with the per-game breakdown
  kept for transparency (and shown to all session members, per the visibility
  rule). So a few dollars of Sixes and big Nassau dollars combine into a single
  final payment. Same-session/same-account in **Phase 1**; **cross-account
  netting** (a shared player's other game living in *their* account) is a Phase-2
  concern.

---

## Model shape (Phase 1 — same foursome, same account)

Round = **scoring session**: owns the gross scores for everyone physically in the
group; every player enters gross once. Games are children:

- A **game** gains an explicit **participant subset** of the round's players
  (a through-row `GameParticipant(game, player)` or a `participant_player_ids`
  list on the config — TBD by how each existing config already encodes pairings).
  Many configs (Nassau teams, Vegas/Fourball teams, match brackets) already imply
  participants; the two gaps are letting that set be a **subset** of the round and
  letting the round host **several peer games**.
- A **game** owns its **handicap** (mode + allowance), already true of every
  config's stored `handicap_mode`/`net_percent`. The change is *not inheriting*
  the primary's for subset side games.
- `Round.primary_game` = the entry-owning game (unchanged mechanism, elevated
  role).

Entry-card rules (Flutter, `score_entry_screen.dart`):
1. Render every foursome player; **gross entry once** (the wheel).
2. Dots/net for players **in the primary** = primary's projection (today's code).
3. Players **not in the primary** → **gross, no dots**.
4. Below the entry field: **only the primary's** per-hole strip.
5. Every game (primary + sides) → its own **leaderboard tab**, own subset, own
   net; visible to all session members.

---

## Phasing

**Phase 1 — parallel games in one foursome, one account.** Nails the hard
*conceptual* pieces. Scope = four things:
1. Side-game **participant subsets**.
2. More **side-eligible** games (2-man Nassau, 1-v-1 match).
3. **Gross rows** for non-primary players on the entry card.
4. **Session-wide leaderboard visibility** (+ own-handicap side games, money
   shown to all).

Validated target combos: Sixes (primary) + subset 2-man Nassau (side, own
handicap incl. gross); primary Nassau (me + Larry) + subset 1-v-1 match (Larry +
opponent, its own 3-stroke allocation) with the opponent as a gross-only entry
row.

**Phase 2 — cross-foursome / cross-account score *sourcing*.** Same rules as
Phase 1; the only new problem is *distribution* — a game whose participants live
in foursomes (and accounts) other than the game owner's, reading their gross
wherever it's entered. Canonical object = **Multi-Group Skins** (already a
primitive version exists), plus the tournament-foursome-internal private skins
and "Larry scores from his own account." Leans on the existing phone-matched
cross-account layer (delegated scoring / shared rounds / connected golfers) and
the `SHARED_WATCH_RETENTION`/visibility plumbing. Visibility rule extends
verbatim: a foursome member sees the multi-group tab even if not in the pool.

---

## Open questions / deferred

- **Do full-foursome (non-subset) overlay side games keep inheriting the
  primary's handicap, or also get their own selector?** Leaning: keep inheritance
  for the "all players, no own opinion" case (Stableford/Low-Net-as-side today),
  give **own** handicap only when the side game has a **subset**. Revisit if it's
  simpler to always give side games their own selector and drop the inheritance
  subsystem.
- **Money-privacy gate** ("status visible, $ hidden to non-participants") —
  deferred until someone asks; it's a per-round or per-game flag.
- **Primary designation UX** when neither game is structural (two 2-man games) —
  pick one as primary, or introduce a neutral gross/stroke-play primary that owns
  entry and settles nothing.
- **Cross-account settlement netting.** The combined session cash-out is clean
  when every game lives in one account (Phase 1). When a shared player's other
  game lives in *their* account (Phase 2), the net-out needs an agreed
  source-of-truth for the combined ledger; deferred with the rest of Phase-2
  sourcing. (Within a game, results still stand alone — Larry can win his match
  and lose the Nassau; netting happens only at the dollar layer.)

---

## What this reuses (not greenfield)

- The **primary/side scaffold** in `game_catalog.dart` (`canBeSideGame`,
  `allowsSideGames`, `sideGamesFor`, `primaryGameOf`/`resolvePrimary`) — extend,
  don't replace.
- Stored **`Round.primary_game`** — becomes the entry-owner of record.
- Per-game **handicap configs** already store their own mode/allowance.
- **Tournament** subset-game settlement is the proof-of-concept for "one score
  pool, many games over subsets."
- The **cross-account phone-matched layer** carries Phase 2.
