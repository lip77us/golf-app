# Live Activities — Nassau, Skins, Rabbit

Build spec for `HANDOFF.md` and the three per-game documents. Sixes shipped
first and is the reference implementation
(`docs/design-review/handoff-sixes-lock/SPEC.md`); this is about what the other
three need that Sixes did not.

## What already exists

Sixes proved the whole delivery path, and none of it is Sixes-specific:

| Layer | State |
| --- | --- |
| `SixesActivityAttributes.ContentState` | Generic slots — `header`, `number`, `sides[]`, `state`, `pips[]`, `footer`, `final`. Nothing in the contract says Sixes. |
| Widget extension, MethodChannel, Dart service | Game-agnostic |
| `LiveActivityToken` + `/live-activity/token/` + `/state/` | Game-agnostic |
| `RoundProvider` start/end wiring | Game-agnostic |
| `services/live_activity_push.py` (APNs, ES256, pooled HTTP/2) | Game-agnostic |
| `LIVE_ACTIVITY_ENABLED` | One switch, gates client and sender |
| `services/live_activity.py` | **Sixes only** — a projection of `sixes_summary` |
| State endpoint's game selection | **Hardcoded to `'sixes'`** |

So the work per game is a projection function plus a Swift layout, not a new
pipeline.

## The ownership rule

> One activity per round, owned by the primary game named at setup. A Nassau
> with a skins side game gets the Nassau card and no skins card.

`Round.primary_game` already stores exactly this, with `resolvePrimary` in
`mobile/lib/game_catalog.dart` deriving it for legacy rounds where it is null.
The state endpoint should dispatch on it and return `{}` for anything with no
card. That also replaces the current hardcoded `'sixes'` check, and it means a
side game can never raise an activity — which is the rule, not an accident.

## Three departures that need a contract change

The current `ContentState` was shaped around one 36px number and three segment
pips. Two of the three new cards break it:

1. **Nassau has two numbers.** Two rows at 25px, no 36px number anywhere.
   `number: Number` cannot hold it.
2. **Rabbit has no fixed segment count.** `pips: [String]` was three segments;
   Rabbit's run strip is generated from a computed list that can be five.
   "Never print a denominator" is explicit in the packet.
3. **Skins has a provisional/settled distinction** with no analogue in the
   others, and a sub-label under the state word.

The honest fix is a `kind` discriminator plus per-kind payloads, not stretching
one struct across four games. There is currently **no machine-readable
discriminator** — `header.game` is a display string (`'SIXES · HIGH-LOW'`).
Add `kind` before the second game, not after the fourth.

## Build order

Easiest mapping first, so the contract change is exercised twice before the
hardest game lands on it.

### 1. `kind` + dispatch (no new card)

Add `kind` to the state, dispatch the endpoint on `Round.primary_game`, switch
the Swift on `kind`. Sixes keeps working throughout; the diff is small and it
is the foundation for the rest.

### 2. Rabbit

Closest to Sixes: one number, one distinguished party, no sides.
`rabbit_summary` already returns `segments`, and `current` with
`holder_id` / `lead` / `segment`.

Needs checking:
- Ranges are **computed, never scheduled** — `rabbit.start = previous.end + 1`,
  `end = min(start + 5, 18)`. Confirm `segments` slides after an early lock
  rather than being fixed thirds.
- `LOCKED` is `lead > holes_remaining_in_this_rabbit`.
- Extra rabbit: one hole pays half stake, two or more pays full; orange.
- Money is **settled only, empty not `$0`** until a rabbit closes.
- The money ladder in the packet (`—`, `−$5`, `−$10`, `+$5`, `+$5`) is a test
  to write — it had to be corrected twice in the prototype.

### 3. Nassau

The two-row break, and the exposure range.

`nassau_summary` already returns `front9` / `back9` / `overall` results and
margins, a `presses` list with nine, type, start/end and result, plus
`bet_unit` and `press_unit`. The rows are close to free.

**The exposure range is new work.** `settled ± the sum of every live stake`,
presses included, with all three bets live from the 1st tee — a $5 Nassau opens
at `−$15 to +$15`, not `−$10`. The packet is emphatic that it must reconcile
against the rows above it, and that four of five prototype states were wrong on
exactly this. That is a test, not a comment.

Team variants: 1v1 and 2v2 only. Triple Nassau is explicitly not designed and
must return `{}` rather than a broken card.

### 4. Skins — see the blocker below

## The Skins blocker

The Skins card is built on two things at once: **carries** (`3 skins, carried
from the 10th`) and **a field that has not finished the hole**
(`PROVISIONAL` / `2 GROUPS OUT`). This codebase has two skins games and
neither has both:

| | Carryover | Multiple groups |
| --- | --- | --- |
| `services/skins.py` (per-foursome) | **Yes** — `carryover` is a setup flag | **No** — decided inside the group |
| `services/multi_skins.py` (field-wide) | **No** — "tied best score → skin dies" | **Yes** — crosses foursomes and rounds |

So on the app as built, a per-foursome skin is settled the moment the group
holes out: `outstanding_groups` is always 0, the card is always `ALL IN`, and
the provisional machinery — which is the most distinctive thing on it — has no
source. Wiring it to multi-skins instead means adding carryover to a settled
game, which changes how real money is calculated.

This wants a decision before any of it is built, and probably a question back
to design. Options, worst to best in my view:

- **Build it against per-foursome skins, always `ALL IN`.** Ships something,
  but silently drops the half of the card that earns it.
- **Add carryover to multi-skins.** Faithful, but it is a scoring change to a
  game people have played for money, for the sake of a lock screen.
- **Ship Nassau and Rabbit; take Skins back to design** with the table above.
  The card may be describing a game we do not have yet.

## Open questions worth answering in code, not comments

The packet lists these; these are the ones that need a data field rather than a
ruling:

- **Nassau loss cap.** `nassau-setup.html` has one. A cap truncates the range's
  floor, which is most of its value. Showing the capped floor is almost
  certainly right and needs the cap exposed on the summary.
- **Automatic presses.** `presses[].press_type` is already `'manual'|'auto'`,
  so the copy question is answerable now: an auto-press has no person to name.
- **Rabbit's carry-the-stake-forward option** doubles the next rabbit's pot and
  has no drawn treatment. Silence on a doubled pot is the thing the money slot
  exists to prevent.
- **Which figure is the reader's** in 2v2 Nassau and any team game — own share,
  not the team's. The Sixes money line already resolves per `player_id`; the
  same rule applies.

## Lifecycle — unchanged for all three

Starts on the first score posted; one per round; final state on sign, dismissed
after ~5 minutes; stale after an hour without a score, refreshed on each score.
All of that is already built and game-agnostic.
