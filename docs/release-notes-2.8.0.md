# Halved 2.8.0 (build 27) — Release notes

Version in `mobile/pubspec.yaml` → `2.8.0+27`. A minor rather than a point
release: two new Live Activity cards, a new way to set handicaps, and the
Survivor screens rebuilt against a fresh design packet.

Backend is deployed and backward-compatible — no `CLIENT_MIN_VERSION` bump.
Two migrations, both additive and both already live:
`tournament/0064_settlementsend_player` and
`tournament/0065_foursomemembership_playing_handicap_override`.

---

## THE ONE THING THAT MUST SHIP WITH THIS BUILD

`services/live_activity_registry.UNSHIPPED_KINDS` is **emptied in the same
commit as this version bump**. It held `match` and `survivor` — two cards whose
server side was finished before any build could draw them.

If the server is deployed and the build is NOT released, every fourball,
singles match and Survivor raises the Swift's *"Update Halved to follow this
round here"* card, pointing at an update that does not exist. That happened on
2026-09-02 with `match` and is the reason the set exists.

**Deploy and release together.** If the build slips, revert the set.

---

## App Store Connect — what to paste where

| Field | Value |
|---|---|
| Version | `2.8.0` |
| Build | `27` |
| What's New | the block below |
| Promotional text | worth refreshing — Survivor Zombie is the headline |
| Description | **unchanged** — no new games; Survivor is already listed |
| Keywords | unchanged |
| **Age Rating** | **Gambling = Yes** — see below |

### Age Rating — do not skip this

2.7.1 was **rejected** under Guideline 2.3.6 for having Gambling unset. It is
App Information → Age Rating → Edit → **Gambling = Yes**, and it is metadata
only. Full write-up in `docs/app-store-review-notes.md`.

### App Review Information

Unchanged. `docs/app-store-review-notes.md` is the source of truth — paste its
Notes block, and put the demo phone + code in Sign-In Information.

| Field | Value |
|---|---|
| User name | `3105550101` |
| Password  | `246810` |

**Run `seed_demo --reset` against prod before submitting.** The demo
tournaments now carry a real championship pool, so Settle up shows actual money
rather than the `Staked $0` screen the last reviewer screenshotted.

---

## What's New (paste this)

Your lock screen now covers three more games, and handicaps bend to whatever
card you are playing off.

• **Survivor on your lock screen** — who is still alive, who is in
  Zombieville, and the offer to get back in. Survivor is the game you can lose
  on a shot you never saw, which is exactly what a lock screen is for.

• **Match play on your lock screen** — singles and fourball. It never
  interrupts you: in a two-side match you watched every putt, so the board just
  keeps itself current.

• **Set a playing handicap by hand.** Playing a card someone else manages —
  Golf Genius, a club sheet? Type that card's number beside each golfer under
  Tees & Handicaps and Halved uses it exactly, ignoring their index and
  applying no allowance on top. No more editing indexes and restarting.

• **A rebuilt Survivor** — the Survivors rail shows who took each one and how
  long everyone lasted, on the leaderboard and while you score. Standings is
  one tap away.

• **Zombie is on by default** for new Survivor rounds.

---

## Verified before release

- 1637 backend tests green.
- Widget extension compiles; both new cards render against real local rounds.
- Survivor leaderboard and score entry checked in the simulator against a live
  round, not only against fixtures.

## Known gaps, deliberately

- **Survivor pushes are not built.** The packet lists six push events and a
  round runs up to nine Survivors — against the umbrella packet's "three to
  four a round". Design to rank them. The card is ambient-complete without it:
  it updates on every score, it simply never buzzes.
- **The score picker's BIRD / PAR / BOG captions** are not built.
  `inline_score_picker.dart` is shared by about eight screens, so that is a
  system-wide look change and wants its own decision.
- `match_final_state` is wired but has only ever run against fixtures — no
  local round plays singles or fourball.
