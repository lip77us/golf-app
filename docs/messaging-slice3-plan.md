# Messaging Slice 3 — server-generated event feed (PLAN)

Slice 1 (backend threads/API) and Slice 2 (mobile chat UI) are done. Slice 3 adds
the **server-generated events** that mix into the round thread alongside human
chat: birdies, skins, game-status, withdrawals, round start/complete. Still
product Phase 1.

## Principles (decided)

- **Always on — no gate.** Every round emits events to its thread, even a lone
  scorer with non-app partners (they see what the others are missing → growth
  hook). No Halved-user counting.
- **Birdies = gross only** (gross vs par); eagle/albatross/HIO too. No net birdies.
- **Push includes the originating foursome** (don't exclude the group that made
  the play).
- **Two channels per event, both idempotent:**
  - Feed — `messaging.post_event(thread, event_key=…)` (unique per thread).
  - Push — `services.push.notify_round_event(round, category, dedup_key=…)`
    (deduped via `SentNotification`, gated only by each user's category toggle).
  - The **feed always populates**; **push respects category toggles**. Use the
    same natural key for `event_key` and `dedup_key`.
- **Best-effort:** detection/emission is wrapped so it can NEVER break score
  submission (try/except + log), mirroring the existing `maybe_notify_*`.
- **Always name players, never teams.** User-facing event text uses player FULL
  names (there's plenty of room in the feed), never "Team 1 / Team 2" (players
  don't know their team number). A two-player side is `"{A} & {B}"`; a solo side
  is just `"{A}"`. Applies to every team-based event (Nassau, Sixes, Match Play,
  Triple Cup).

## Architecture

New module **`services/messaging_events.py`** — pure detection + emission, keeps
the calculators untouched. One entry point per trigger:

| Function | Called from | Trigger |
|---|---|---|
| `emit_score_events(foursome, hole_number, submitted)` | `ScoreSubmitView.post`, right after `_recalculate_games` + leaderboard build ([api/views.py:2847](../api/views.py)) | hole score saved |
| `emit_withdrawal(foursome, player, after_hole, killed_next)` | `WithdrawPlayerView.post` ([api/views.py:3199](../api/views.py)) | player withdraws |
| `emit_round_started(round_obj)` | next to `maybe_notify_round_started` ([api/views.py:2490](../api/views.py)) | round starts |
| `emit_round_complete(round_obj)` | `RoundCompleteView` ([api/views.py:2895](../api/views.py)) | round completes |

Each detector resolves `thread = messaging.get_or_create_thread(round)`, then for
every event: `post_event(...)` (feed) and `notify_round_event(...)` (push).

`emit_score_events` is the workhorse — it reads the submitted scores and the
freshly-recalculated game summaries (`skins_summary(fs)`,
`multi_skins_summary(round)`) and the leaderboard, so all per-hole events derive
from one call after recalc.

## Event catalog

Body strings are drafts. `data.type` drives the mobile `_EventCard` icon/label
(extend its existing switch to match these exact strings).

### 1. Birdie / Eagle / Albatross / Hole-in-one
- **Where:** `emit_score_events` — for each submitted score, `par` comes from the
  player's tee hole info already loaded in the submit loop
  (`m.tee.hole(hole_number)`); `diff = par - gross`.
- **Emit when:** `gross == 1` → hole_in_one; else `diff == 1` birdie, `2` eagle,
  `≥3` albatross. (Gross only.)
- **event_key / dedup_key:** `birdie:{round}:{hole}:{player_id}` — one per
  player-hole, first qualifying score wins (a later edit does NOT re-announce;
  acceptable v1, noted).
- **data:** `{type:'birdie'|'eagle'|'albatross'|'hole_in_one', hole, player_id, player_short, gross, par}`
- **body:** `"🐦 {short} made birdie on {hole}"` / `"🦅 … eagle …"` / `"⛳ Hole-in-one!"`
- **category:** `birdie` (NEW)

### 2. Skin won / carryover
- **Where:** `emit_score_events`, after recalc — iterate `skins_summary(fs)['holes']`
  (and `multi_skins_summary` for round-level multi-skins). A hole is *decided*
  when `winner_id` is set (skin won) or `is_carry` is true (halved → carries).
- **event_key:** `skin:{round}:{hole}` (won) / `skincarry:{round}:{hole}` (carry).
  Idempotent, so we can re-scan every recalc and only the newly-decided holes post.
- **data:** `{type:'skin'|'carryover', hole, winner_id?, winner_short?, value, pot?}`
- **body:** `"💰 {short} won the skin on {hole} (${value})"` /
  `"Hole {hole} halved — skin carries (${pot} in the pot)"`
- **category:** `skins` (exists)

### 3. Game status — front-9 & money-leader change
- **Where:** `emit_score_events`, after `_build_leaderboard`.
- **Front 9:** when every active player has holes 1–9 scored, post the F9 standing
  once. **event_key:** `front9:{round}`.
- **Lead change:** compute current overall money leader from the leaderboard;
  compare to the previous leader (read the most recent `lead:money:*` event's
  `data.player_id` in the thread). Emit only on a genuine flip.
  **event_key:** `lead:money:{round}:h{hole}:{leader_id}` (hole in the key so a
  flip-back to a prior leader still posts).
- **data:** `{type:'front9'|'lead_change', ...standings/leader…}`
- **category:** `lead_change` (exists)
- Rationale: "game status is interesting if the scorer doesn't mention it."

### 4. Withdrawal
- **Where:** `emit_withdrawal` from `WithdrawPlayerView.post`.
- **event_key:** `wd:{round}:{player_id}:{after_hole}` (re-withdraw same = dedup;
  reinstate then withdraw at a different hole = new). Optional "back in" card on
  reinstate: `wdback:{round}:{player_id}`.
- **data:** `{type:'withdrawal', player_id, player_short, after_hole, killed_next}`
- **body:** `"{short} withdrew after hole {after_hole}."`
- **category:** `withdrawal` (NEW)

### 5. Round started / completed
- **Where:** co-located with the existing `maybe_notify_round_started/_complete`.
- **event_key:** `round_start:{round}` / `round_complete:{round}`.
- **data:** `{type:'round_started'|'round_complete'}`
- **body:** `"Round under way at {course}."` / `"Round complete — see final results."`
- **category:** `round_start` / `round_complete` (exist)
- **Note:** the FEED always posts these (always-on). The existing round-start/
  complete PUSH stays gated to multi-group rounds via `_is_multi_group` unless we
  decide to open it; lean: leave push as-is, feed always populates.

### 6. Gross scorecard summary (at completion)
- **What:** when the round completes, one card listing every competitor's GROSS
  score as **front–back–18**, e.g. `41-40-81`. A lightweight recap — net / money
  detail lives on the leaderboard, so this stays simple. No per-hole detail.
- **Where:** `emit_round_complete` (after the round_complete card), once per round.
- **Gate:** all rounds **except Triple Cup** (skip when `triple_cup` is active —
  it's team match play, a per-player stroke total isn't the point).
- **Scores:** gross only. front = `gross_score` holes 1–9, back = 10–18,
  total = 18. Competitors = real players only (skip phantoms/donors). A
  **withdrawn** player is listed as **`WD`** (omit their numbers entirely — no
  partial scores). Non-withdrawn players have all 18 (the round can't complete
  otherwise), so they always show full F-B-18.
- **event_key:** `score_report:{round}` (idempotent — one per round).
- **data:** `{type:'score_report', players:[{player_id, short, front, back, total, withdrew:bool}]}`
  sorted by `total` ascending (lowest gross first); WD players last.
- **body (text fallback):** `"Scores — {short} {f}-{b}-{total}, … {short} WD"`
- **category:** FEED-ONLY (no push — the round_complete push already nudged them).
  Mobile `_EventCard` renders `score_report` as a small ranked table; WD rows show
  "WD" in place of the score.

### 7. Match results — Nassau nines, Sixes segments, Match Play / Triple Cup
- **What:** when a match unit is **decided**, announce who won (by player name)
  and the margin. The winner data already exists in each summary.
- **Where:** `emit_score_events`, after recalc — read `sixes_summary(fs)`,
  the Nassau summary, `matchPlay`/`three_person_match` data, `triple_cup` summary
  (all recomputed in `_recalculate_games`).
- **Units & keys (idempotent — emit once when that unit settles):**
  - Nassau: front 9 / back 9 / overall → `nassau:{unit}:{round}:{fs}`.
    (Presses deferred — keep to the three nines for v1.)
  - Sixes: each segment → `sixes:seg{n}:{round}:{fs}`.
  - Match Play / Three-person match: each match → `matchplay:{match_id}`.
  - Triple Cup: each cup match → `triplecup:{match_id}`.
- **Winner text = player short names**, never team labels:
  - `"Paul & Dave won the front nine, 2&1."`
  - `"Mike & Sara took segment 2."`
  - `"Front nine halved."` (no winner → name the unit only)
  - Margin from the summary's holes-up margin: `"{m}&{remaining}"` if it closed
    out early, `"{m} up"` at the last hole, or `"halved"`.
- **data:** `{type:'match_result', game:'nassau'|'sixes'|'match_play'|'triple_cup',
  unit:'front nine'|'segment 2'|…, result:'win'|'halve',
  winner_player_ids:[…], winner_shorts:[…], margin:'2&1'}`
- **category:** `match_result` (NEW). Push-worthy — the other groups want to know.
- Note: this is why Triple Cup is excluded from the gross stroke recap (#6) but
  still gets match-result cards here — its match outcomes are the point, a
  per-player stroke total isn't.

## Push categories (`services/push.py` `NOTIFICATION_CATEGORIES`)

Already present: `round_start`, `skins`, `round_complete`, `lead_change`, `chat`.
**Add:** `birdie: True`, `withdrawal: True`, `match_result: True`. Drop the stale
"Phase 2/3" comments as they ship. Mobile: add the new toggles to the
notification-settings surface.

## Settled details

- **Score edits don't re-announce.** A birdie fires on the first qualifying score
  for a player-hole (`birdie:{round}:{hole}:{player}`); a later correction does
  not post a new card.
- **Self-push ON.** Push every opted-in user, including the submitting scorer /
  their own foursome — don't pass `exclude_user_ids`. A user who doesn't want a
  category mutes it in settings.

## Mobile work (PR B)

- Align `_EventCard`'s `type→icon` switch to the final `data.type` strings; enrich
  formatting (amount, player short).
- Add notification-category toggles for `birdie` + `withdrawal`.
- Verify a push deep-links into the round feed (payload already carries
  `type` + `round_id`).

## Tests (`api/test_messaging_events.py`)

Birdie emits once + idempotent on re-submit; eagle/HIO; skin won + carry; F9 once;
money lead change only on flip; withdrawal (+ dedup); round start/complete land in
the feed; push deduped via `SentNotification`.

## Sequencing

- **PR A (backend):**
  - **Increment 1 — DONE:** `services/messaging_events.py` with round
    started/complete, gross scorecard recap, birdies/eagles/aces, withdrawal;
    hooks in `ScoreSubmitView` / round-start / `RoundCompleteView` /
    `WithdrawPlayerView`; push categories `birdie`/`withdrawal`/`match_result`;
    tests `scoring/tests/test_messaging_events.py` (12, green).
  - **Increment 2 — DONE (except the deferred money-leader, below):**
    - skins won (push) / carry (feed-only); **multi-group skins** wins
      (`multi_skins` IS recalced in `_recalculate_games` line ~184, so it hooks
      off `emit_score_events` like skins); match results for **Nassau** nines,
      **Sixes** segments, **Match Play** bracket matches, **Triple Cup** matches
      — all by player name, never team labels. Tests `test_messaging_events.py`
      now 20, green.
    - Deferred: **three-person match** results (its summary has no single winner
      field — points/phase based).
  - **Money-leader change + front-9 status — DEFERRED (needs infra):** there is
    no combined cross-game per-player money total in the leaderboard (each game
    keeps its own money shape), so a generic "new money leader" can't be computed
    cleanly today, and a generic "front-9 leader" is fuzzy for mixed money games.
    The meaningful "F9 result" is already delivered by the Nassau nine match
    result. Revisit if/when a unified money aggregation exists.
- **PR B (mobile):** `_EventCard` type alignment + settings toggles + push
  deep-link check.
