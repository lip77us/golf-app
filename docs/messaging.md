# In-app messaging + event feed — kickoff brief

**Goal:** a per-round message feed that mixes **human chat** and **server-generated
event announcements** (birdie, skin won, lead change, withdrawal…). Built so a
user who isn't staring at their phone can open the app and catch up.

**Where the value is (from the product discussion):** *cross-group* situations
where people can't just talk face-to-face —
- **Multi-group casual skins** (several foursomes, one pool)
- **Multi-foursome tournaments**
- **Watchers** following a round remotely (the main reason to enable it on an
  otherwise-together single foursome).

A lone foursome playing together doesn't need chat, so **the thread unit is the
ROUND, not the foursome** — a round thread spans every foursome in the round +
its watchers. (Per-foursome sub-threads are intentionally **not** built.)

---

## STATUS

- **Slice 1 — backend foundation: IMPLEMENTED** (commit "Messaging Phase 1
  (backend): round threads + chat API"). Models `MessageThread` / `Message`
  (`kind` user|event, idempotent `event_key`) / `ThreadRead` in
  `tournament/models.py` (migration `tournament/0037`). Service
  `services/messaging.py` (`get_or_create_thread`, `list_messages(since_id=)`,
  `post_user_message`, `post_event` (idempotent), `mark_read`, `unread_count`).
  Endpoints — audience = `round_for_reader` (participants + watchers,
  cross-account): `GET/POST /api/rounds/<id>/messages/` (GET → `{messages,
  unread, my_player_id}`; POST `{body}` → 201, auto-advances the poster's read
  marker) and `POST /api/rounds/<id>/messages/read/` `{last_seen_id}`.
  `MessageSerializer` (id, kind, author_id/name/short, body, data, created_at).
  Tests: `api/test_messaging.py` (8, green).
- **Slice 2 — mobile chat: IMPLEMENTED.** Dart `ChatMessage` /
  `RoundMessagesResult` models (`mobile/lib/api/models.dart`) +
  `client.getMessages(roundId, {since})` / `postMessage` / `markMessagesRead`.
  `MessageProvider` (`mobile/lib/providers/message_provider.dart`,
  registered in `main.dart`) drives one round's feed: cache-first load →
  incremental `since=` catch-up → 12s poll while open; `send()` never fails
  (queues via SyncService, shows an optimistic "sending…" bubble);
  `markAllRead()` clears the badge. Outbound offline queue lives in
  `SyncService` (`enqueueMessage` + `_drainMessages`, drained alongside scores
  on reconnect; `pendingMessageCount`) backed by a new `pending_messages` table
  + `cached_messages` inbound cache (LocalDatabase v1→v2 `onUpgrade`). UI:
  `round_feed_screen.dart` (chat bubbles, centered event cards, compose box,
  offline banner) reached via `RoundChatButton` (unread badge) in the round
  screen + leaderboard + EVERY scoring/game screen app bar (score_entry plus
  skins/sixes/points_531/wolf/rabbit/nassau/quota_nassau/pink_ball/match_play/
  triple_cup/multi_skins) — the scorer lives on the scoring screen, so the badge
  (the push-less chat notification) polls there every 25s; the shared-round view
  opens the leaderboard, so watchers get it too. Scoring screens also gained a
  refresh button + pull-to-refresh so a cross-account scorer who fell behind can
  pull the owner's latest holes. Route `/round-feed`. Note: the unread badge counts
  via the GET endpoint, which does NOT advance the read marker (only POST /
  `markMessagesRead` does), so opening the badge doesn't clear unread until the
  feed is actually viewed.
- **Slice 3 — events: AFTER.** Emission hooks (birdie/skin/lead/withdrawal/
  round) call `messaging.post_event(...)` from the scoring recalc; event cards;
  per-category push via `services/push.py`.

---

## Decisions (from the discussion)

- **Channels:** round-level thread (v1) covering all foursomes in the round +
  watchers. Tournament-wide (cross-round) and team (cup) threads are **later
  phases**. The round thread already delivers the #1 case: multi-group skins.
- **Events to announce (all in scope):** birdies/eagles, skin won/carryover,
  lead changes / milestones (F9 result, new money leader, round complete),
  withdrawals + round started/complete.
- **Push policy:** server **events push** (per-category, user-toggleable). Human
  **chat is in-app only** (unread badge) — no push unless it's an @mention
  (@mention deferred). Avoids notification fatigue.
- **v1 scope:** round threads + the event suite + an in-app inbox. Prove it on
  casual (incl. multi-group skins + watchers), then extend.

---

## Reuse — ~70% of the plumbing already exists

- **Push framework:** `services/push.py` — `send_push()`, `NOTIFICATION_CATEGORIES`
  + per-user category toggles (`accounts.User`, see `category_enabled`), FCM via
  `PUSH_BACKEND=fcm`. Already fires `maybe_notify_round_started/_complete`. Event
  announcements are new categories on this exact framework.
- **Offline queue:** `SyncService` + `LocalDatabase` already queue *outbound
  scores* offline and drain on reconnect. Outbound messages reuse this pattern;
  inbound messages cache locally for catch-up.
- **Cross-account audience:** the `round_for_reader` / participant resolvers
  (`accounts/scoring_access.py`) already answer "who's in this round" across
  tenants — that's thread membership. Watchers come from the existing
  invite-a-watcher model (`utils/watcher_invite.dart`,
  `getRoundWatcherCandidates`).

**Greenfield:** the Message/Thread model, the event-emission hooks in the scoring
calculators (birdie/skin detection doesn't exist yet), read-state, and the
in-app inbox UI.

---

## Data model (new)

- **`MessageThread`** — `scope` (`round` | `tournament` | `team`; v1 = `round`),
  nullable `round` / `tournament` FK. Lazily created on the round's first
  message/event (or at round start). Audience is computed dynamically from the
  scope, not a static member list.
- **`Message`** — `thread` FK, `kind` (`user` | `event`), `author` (Player, null
  for system), `body` text, `data` JSON (event payload: type, hole, player,
  value — drives rich rendering + the push body), `created_at`.
  - **Idempotency:** event messages carry a natural `event_key`
    (e.g. `round:hole:player:type`) unique per thread, so scoring **recalcs don't
    double-post**.
- **`ThreadRead`** — per (thread, user) `last_read_at` / last-seen message id →
  unread counts + badge.

**Audience (who sees / can post a round thread):** players in the round's
foursomes + designated scorers + invited watchers. Cross-account via the reader
resolvers. (Open Q: can the *public web* watcher — anonymous `/watch/<token>/` —
post, or read-only? Logged-in in-app watchers can post; lean read-only for
anonymous web.)

---

## Event emission (server)

Hook the scoring recalc / score submission. Emit an `event` Message (idempotent
via `event_key`), then `send_push` to opted-in thread members for that category.

| Event | Where to detect |
|---|---|
| Birdie / eagle / albatross | On hole-score submit — gross vs the hole's par (gross = the universally fun one; net is a future toggle). |
| Skin won / carryover | In `calculate_skins` / `multi_skins` — when a hole's winner (or carry) is *newly* determined. Include $ value. |
| Lead change / F9 / round complete | After recalc — compare new standings to last-emitted (money-game leader flips; F9 settled; round → complete). |
| Withdrawal | The withdraw-player flow (ties into the just-shipped WD feature). |
| Round started/complete | Already have `maybe_notify_*` — also drop them into the feed. |

**Push targeting refinement (optional):** an event is loudest to people *not* in
the originating foursome (the group that just made the birdie saw it live). v1
can push to all opted-in members; "skip same-foursome" is a nice-to-have.

---

## Delivery / "queue in the app"

- **Server is source of truth** — messages persist per thread.
- **Client catch-up:** pull on app open + on push-wake + light poll while a round
  is active; cache in `LocalDatabase` so the feed is there offline / on next open
  (this is the "queue messages in the app" requirement).
- **Outbound:** compose offline → queue locally → `SyncService` drains on
  reconnect (mirrors score sync).
- **Push = nudge, inbox = truth.** Reuse `send_push` + categories for events;
  chat shows as an in-app unread badge.

---

## API (sketch)

- `GET  /api/rounds/<id>/messages/?since=<id>` → thread messages (catch-up).
- `POST /api/rounds/<id>/messages/` `{body}` → post a user message.
- `POST /api/rounds/<id>/messages/read/` `{last_seen_id}` → advance read state.
- Events are emitted server-side by the scoring hooks (no client call).
- Auth via the existing round reader/scorer resolvers (players + scorers +
  watchers). Per-category push prefs reuse the notification-settings surface.

---

## Mobile (sketch)

- A round **feed/inbox** screen: chronological mix of chat + event cards
  (event cards styled by type — birdie, 💰 skin, lead change). Unread badge on
  the round.
- Compose box (queues offline via SyncService).
- Entry points: the round screen + leaderboard; a watcher's shared-round view.
- `Message`/`MessageThread` models + `client.getMessages/postMessage/markRead`.

---

## Phasing

- **Phase 1:** round-level thread, the event suite (birdie/skin/lead/withdrawal/
  round), in-app feed + unread, event push (toggleable categories), outbound
  offline queue. Covers casual + **multi-group skins** + watchers.
- **Phase 2:** tournament-wide (cross-round) threads for multi-foursome
  tournaments.
- **Phase 3:** team (cup) channels; @mentions (+ chat push on mention);
  reactions; anonymous-web-watcher posting.

---

## Open questions

- Net vs gross for the "birdie" announcement (default gross for excitement; net
  is game-relevant — maybe both, labeled).
- Can anonymous `/watch/<token>/` watchers post, or read-only? (Lean read-only.)
- Push targeting: everyone opted-in, or skip the originating foursome?
- Moderation / rate-limiting on user chat (basic length + rate cap to start).
- Gating: do free vs paid tiers differ here? (Ties into `docs/freemium-design.md`.)
