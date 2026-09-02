# Halved 2.7.1 (build 26) — Release notes

Version in `mobile/pubspec.yaml` → `2.7.1+26`. A point release: the game
changes are small and the substance is the **Live Activity** work.

Backend is deployed and backward-compatible — no `CLIENT_MIN_VERSION` bump.
Three migrations shipped with it, all additive.

---

## App Store Connect — what to paste where

| Field | Value |
|---|---|
| Version | `2.7.1` |
| Build | `26` |
| What's New | the block below |
| Promotional text | unchanged |
| Description | **unchanged** — no new games, so the GAMES list is still accurate |
| Keywords | unchanged |

### App Review Information

Unchanged from 2.7.0. **`docs/app-store-review-notes.md` is the source of
truth** — paste its Notes block, and put the demo phone + code in Sign-In
Information.

| Field | Value |
|---|---|
| User name | `3105550101` |
| Password | `246810` — the bypass code, not a password |

**Before submitting**, confirm on production (the reviewer's app talks to prod):

- `REVIEW_BYPASS_PHONE=+13105550101,+13105550102` and `REVIEW_BYPASS_CODE` set
- `PASSWORD_LOGIN_ENABLED` unset or false
- `seed_demo --reset` run **inside the Golf App container**
  (`cd /app && /opt/venv/bin/python manage.py seed_demo --reset`)

### New this release — the reviewer can now see a Live Activity

`LIVE_ACTIVITY_ENABLED=1` is set on Railway, so the lock-screen board is **on
in production**. A reviewer who opens a seeded in-progress round and posts a
score will get one. That is the intended behaviour and it is described in the
What's New, so it should read as a shipped feature rather than a surprise.

If you would rather the reviewer never encounter it, unset
`LIVE_ACTIVITY_ENABLED` — but then **remove the Live Activity paragraph from
the What's New**, or you are describing a feature that cannot be found.

---

## What's New (user-facing / App Store copy)

2.7.0 reached the App Store, so this covers 2.7.0 → 2.7.1 only.

Your lock screen keeps the match now.

• **The match on your lock screen** — Sixes, Skins, Nassau and Rabbit put a
  live board on your lock screen and Dynamic Island: the number that matters,
  who is up, and what the hole is worth. It updates as the group scores.

• **It reaches the whole group, not just the scorer.** Whoever is keeping the
  card already knows the state — everyone else was the one who needed it. The
  board now appears for every golfer in the round, and for anyone you have
  invited to watch, without them opening anything.

• **A rebuilt Skins board** — it names who is winning and how far back you are,
  in skins rather than a placing. When a carry finally breaks it leads with the
  golfer who took it. Pool games show what a skin is worth right now, and junk
  points count as what they are: an equal share of the same pot.

• **Sixes score entry is tidier** — shorter match cards, and the scorecard now
  sits under them so you can read the holes you just played without leaving the
  screen.

• **The draw stays a draw** — the leaderboard no longer shows the pairings for
  matches 2 and 3 before the group has spun for them.

• **Inviting a watcher is quicker** — search your golfers by name or number,
  and filter to the ones already on Halved.

Fixes

• Lock-screen boards could fail to register on some phones and never appear.

---

## Changes since 2.7.0 (developer summary)

**New — Live Activities reach the golfers who are not scoring**
- Push-to-start (`LiveActivityStartToken`): iOS issues a token per app install
  for the activity type, and the server addresses it to raise a card on a phone
  that has done nothing. Before this, only `Activity.request` could start one —
  foreground only — so the only golfer with a board was the one holding the
  phone to score.
- `board_recipients` resolves players (linked user or verified phone) plus
  invited watchers. A watcher gets the board with the **money line withheld**;
  it is the one personal slot.
- Verified on two phones against **production APNs** via TestFlight: a card
  raised on a locked, force-quit phone, then tracking hole by hole untouched.

**New — all four games actually reach the lock screen**
- The client gated on a hardcoded `sixes`, and so did the server before
  pushing. Rabbit, Nassau and Skins had builders all along, so those rounds
  could raise a card and then never receive an update — a board frozen on hole
  1. Now a `hasLiveActivity` catalog flag and a registry-based server gate.

**New — the Skins card, rebuilt** (`design_handoff_skins_live_activity`)
- Three variations with their own headers (carryovers / pool / pool + junk),
  three readings of one state (leader / chaser / watcher), a gap expressed in
  skins rather than a placing, the slots reordering when a carry breaks, junk
  dividing the same pot, and a closing frame where there was a `TODO`.
- Single-group only. The packet's **multi-group card is not built** — that is
  `multi_skins`, a different game with its own summary.

**Improvements**
- Sixes match cards are three rows shorter; the leaderboard scorecard now
  renders under them in score entry (one shared `HoleGridScorecard`).
- Undrawn Sixes matches read "Teams TBD" instead of spoiling the draw.
- Invite-a-watcher gains search and an On Halved filter.
- Non-production release builds show a backend ribbon, and
  `scripts/run-local.sh` makes a mis-pointed test build impossible.

**Fixes that reach already-shipped behaviour**
- **`LiveActivityToken.token` was `varchar(200)`.** A real token is ~320
  characters, so every registration failed with a DataError 500 — for all four
  games. `TextField` now.
- Duplicate cards: the start push repeated on every score, and a start push
  cannot see the lock screen, so each raised another card.
- A push-started card could never hand back its update token
  (`activityUpdates` does not replay existing activities), so it painted once
  and froze.
- A dismissed card left a token that both failed and counted as "already
  carrying a board", so dismissing once went dark for the rest of the round.

**Migrations**
- `tournament/0061` — Live Activity token column widened to `TextField`.
- `tournament/0062` — `LiveActivityStartToken`.
- `tournament/0063` — `LiveActivityStartPush` (start-push cooldown).

All additive. Deployed to production 2026-09-01.

---

## Known, and deliberately not chased

- **~30s after a card is raised by push, it cannot yet be updated.** The
  per-activity token only registers once the app comes alive. A hole scored
  inside that window reaches nobody but the scorer. Holes are fifteen minutes
  apart in play; this only showed under testing that scored holes seconds
  apart.
- **Rabbit and Nassau boards have never been seen on a device.** Same code path
  as Skins with a different builder, and both have passing tests, but neither
  has been eyeballed.
- **Multi-group Skins** (screens 5–7 of the design packet) is not built.

---

## Pre-submission checklist

- [ ] `seed_demo --reset` run against **production**, reviewer accounts intact
- [ ] Build 26 processed in App Store Connect
- [ ] What's New pasted; description left unchanged
- [ ] Reviewer notes pasted from `docs/app-store-review-notes.md`
- [ ] Export compliance answered (no non-exempt encryption)
- [ ] `LIVE_ACTIVITY_ENABLED` decision made, and the What's New matches it
- [ ] Tag the release: `git tag -a v2.7.1 -m "2.7.1+26 — App Store" <commit>`
