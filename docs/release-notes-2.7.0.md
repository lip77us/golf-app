# Halved 2.7.0 (build 25) — Release notes

Version in `mobile/pubspec.yaml` → `2.7.0+25`. Build 24 was the last TestFlight
upload (2.6.1); **2.6.0 was the last release to reach the App Store**, so the
"What's New" below covers everything since 2.6.0, not since the last build.

Backend is deployed and backward-compatible — no `CLIENT_MIN_VERSION` bump.
Four migrations shipped with it, all additive with safe defaults.

Tag: `v2.7.0`, annotated, on the commit that set build 25.

---

## App Store Connect — what to paste where

| Field | Value |
|---|---|
| Version | `2.7.0` |
| Build | `25` |
| What's New | the block below |
| Promotional text | unchanged from 2.6.0 unless you want to lead with team play |
| Description | **updated** — see "Description change" below |
| Keywords | unchanged |

### App Review Information

**Password login is disabled in production.** Sign-in is a phone number plus a
fixed bypass code — no SMS is sent. The full block to paste, and the deletion
account for Guideline 5.1.1(v), live in **`docs/app-store-review-notes.md`**,
which is the source of truth for this section.

| Field | Value |
|---|---|
| User name | `3105550101` |
| Password | `246810` — the bypass code, not a password |

Both are fictional NANP 555-01xx numbers. The backend accepts the fixed code
for those two numbers only, and only while `REVIEW_BYPASS_PHONE` /
`REVIEW_BYPASS_CODE` are set on Railway.

**Before submitting**, confirm on production — the reviewer's app talks to
production, not a local server:

- `REVIEW_BYPASS_PHONE=+13105550101,+13105550102` and `REVIEW_BYPASS_CODE`
  are set and deployed
- `PASSWORD_LOGIN_ENABLED` is unset or false
- `seed_demo --reset` has been run, so those two numbers map to seeded users

`seed_demo` cannot be run from a laptop: Railway's Postgres has an
internal-only host. It runs inside the app container — Railway dashboard →
**Golf App** service (not Postgres) → Terminal:

```
cd /app
/opt/venv/bin/python manage.py seed_demo --reset
```

Expect `DemoClub seeded successfully`, 12 players, 7 rounds.

---

## What's New (user-facing / App Store "What's New" copy)

Team tournaments, and a rebuilt tournament for individual play:

• **Team tournaments** — run a Saturday scramble or shamble with as many teams
  as you like, all on one leaderboard. Pick the format, decide whether every
  golfer has to give a drive, and Halved works each team's allowance from the
  tees you set and shows it applied to your own teams before you commit.

• **Two-golfer teams** — the same event for pairs, with five formats:
  scramble, best ball, alternate shot, Scotch and Chapman. Two pairs go off
  together on one tee time with one card, scored apart. Each format sets its
  own allowance, and every one is shown before you choose so you can see that
  the same two golfers get four strokes in a scramble and twelve in an
  alternate shot.

• **Alternate shot keeps the order for you** — the pair sets who tees on the
  odd holes before the first shot, and the card names the tee on every hole
  after that.

• **Individual tournaments, rebuilt** — a clearer eight-step setup, best-N-of-M
  scoring across rounds, a Mini Singles bracket in every group, an optional
  final-round day bet, and a settlement screen that shows exactly who owes whom
  and why, game by game.

• **Survivor's Zombie Option** — switch it on and a knocked-out golfer plays on
  as the Zombie. Beat the field on the next hole and you are back in.

• **Better sharing** — a shared round link now opens a real page with the
  scorecard on it, and previews with a proper card instead of a bare link.

Fixes

• A scramble round can be completed. One score per hole meant the round never
  read as finished, so it could not be closed out.
• Every stroke a team receives now shows on the card. A hole carrying three
  strokes was drawing the same single mark as a hole carrying one.
• Tee sheets name the event and list who is in each group.
• A new tournament starts as an individual event rather than a cup.

---

## Description change

The GAMES list gains team formats, and TOURNAMENTS gains a line. Everything
else in the description is unchanged.

Add to **GAMES YOU CAN PLAY**, after "One-round team cup":

```
• Scramble and Shamble team events
• Two-golfer teams — best ball, alternate shot, Scotch, Chapman
```

Replace the **TOURNAMENTS** paragraph with:

```
TOURNAMENTS
Running something bigger? Halved supports multiple foursomes, several games at
once, and multi-round events — with live leaderboards, team cup play, and
formats like Irish Rumble, Pink Ball, and Singles. Team events run small teams
or two-golfer pairs against the whole field on one board, each format with the
allowance it is actually played off.
```

---

## Changes since 2.6.0 (developer summary)

**New — team tournaments**
- **Foursome Play** — the third tournament shape: many small teams, one round,
  one leaderboard. Scramble (one ball) and shamble (four balls, best N). Drive
  requirements as three quotas and one schedule, the phantom 4th for a short
  team, one pool with ties combined and split.
  `docs/design-review/handoff-team-play/`.
- **Pairs Play** — team size 2 with five formats: scramble (35/15), best ball
  (85% each), alternate shot (50% of combined), Scotch and Chapman (60/40).
  The playing group holds **two pairs** — one tee time, one scorer, one card,
  scored apart — implemented as a slot inside the Foursome so the four-golfer
  flow is untouched by construction.
  `docs/design-review/handoff-team-pairs/`.

**New — individual play refresh**
- Tournament scoring settings + best-N-of-M, one money model for every pot,
  the two-stage Mini Singles bracket, the final-round day bet, the ball game
  named rather than coloured, and tournament settlement.
  `docs/design-review/handoff-individual-play/`.

**New — Survivor Zombie Option**
- Engine, API and UI. A knocked-out golfer plays on as the Zombie and can
  return by beating the field on the next hole.

**Improvements**
- Shared scorecard is a page rather than an image; share links carry a real
  card.
- Public game names, so internal labels stop leaking to users.
- Leaderboard scorecards get banded headers and a frozen first column.

**Fixes that reach already-shipped behaviour**
- **A one-ball team round could never be completed.** It posts a
  `TeamHoleScore` and no per-golfer scores, and both the completion check and
  the holes-remaining count read the per-golfer table.
- **Stroke dots capped at two** on the team card while the net line and the
  score picker worked off three; the entry box drew one dot off a boolean.
- Clearing a team name reset it to the colour rather than to `Group N`.
- A shamble was giving every golfer 100% of their handicap.
- The tee sheet ignored a team's name, and named neither the event nor who was
  in each group.

**Migrations**
- `tournament/0055_pairs_play` — `team_size`, `name_is_default`, wider
  `team_format`.
- `tournament/0056` — `team_play_slot` on membership, `slot` + `name` on team
  state, `TeamPlayTeamState` OneToOne → FK.
- `tournament/0057` — pair name widened to 32.
- `games/0069` — `team_play_slot` on `TeamHoleScore` + new unique key.

All additive; every existing row lands on slot 1.

---

## Pre-submission checklist

- [ ] `seed_demo` run against **production**, reviewer accounts intact
- [ ] Build 25 processed in App Store Connect
- [ ] What's New pasted; description updated per above
- [ ] Reviewer notes pasted into App Review Information
- [ ] Export compliance answered (no non-exempt encryption)
- [ ] Tested on device: a scramble round **completes**, since that fix reaches
      rounds already in the wild
