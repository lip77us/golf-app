# Spec: Sixes on the lock screen (iOS Live Activity)

Build-from document for the `handoff-sixes-lock` packet. `live-activity-sixes.html`
is the shipping surface; `live-activity-pattern.html` is the generalised five-slot
container, read when building the container rather than Sixes.

**One surface, five states, no buttons.** The activity is read-only. Every action in
Sixes is group state that wants the app's confirmation, and a mis-tap on a lock
screen is expensive.

---

## 1. What has to be built, and in what order

This is the first native-iOS feature in the app. It is four pieces, and only the
first is pure Dart/Python:

| # | Piece | Where | Blocked by |
|---|---|---|---|
| 1 | **The state contract** — the five slots as data | `services/live_activity.py` | nothing |
| 2 | **APNs sender** for Live Activity pushes | `services/push.py` | an APNs .p8 key |
| 3 | **Widget Extension target** — SwiftUI + ActivityKit | `ios/SixesActivity/` | a new Xcode target |
| 4 | **Dart bridge** — start / end / register token | `mobile/lib/services/` | (3) |

**FCM cannot carry this.** Live Activity updates are an APNs push type
(`apns-push-type: liveactivity`, topic `<bundle>.push-type.liveactivity`) addressed
to the **activity's** push token, not the device token. Firebase Cloud Messaging's
HTTP v1 API does not expose it, so `services/push.py` — which is FCM-only — needs a
second transport. Everything else in the app keeps using FCM.

Piece 1 is built first because it is what the SwiftUI view renders and what the push
carries; getting it wrong is expensive later and it can be tested without Xcode.

## 2. The five slots

Every state is the same five slots. **Build one view; the states are data.**

| Slot | Content | Rules |
|---|---|---|
| Header | Mark · `SIXES` · segment right-aligned | ` · HIGH-LOW` appended when that variant is on. Segment reads `SEGMENT n · HOLES a–b`, or `EXTRA HOLES · a–b`. |
| The number | `2 UP` / `ALL SQ` / `+3 PTS` | Wears the **leading side's colour**. All square is white at 90%. **Never mint** — mint is the app's colour, not a side's. |
| The sides | Both pairings, two lines, colour dot each | Leader bold and coloured, trailing side at 60%. **Never "you are 2 up"** — four golfers read the same string. |
| The state | `DORMIE` / `—` + `n TO PLAY` | Right-aligned. A match-state word when one applies, else the em dash. **Not the money.** |
| Pips | Three bars: segments 1, 2, 3 | Won segments take the winning side's colour; live is white 62%; unplayed white 20%. **Identical in every state** — the eye learns where to look. |
| Footer | Round context left, money right | `Thru 4 · $5 a match` / `+$5 so far`. **Thru lives here**, not on the sides line. |

### Why the number is not personal
A neutral scoreboard, not a report. Four golfers see one string, and the pairing
changes mid-round, so `2 UP` without saying *who* is unreadable forty minutes later.
Naming both sides fixes the partner problem and the perspective problem at once, and
lets two golfers read one phone.

### High-Low
Same composition; the number reads `+3 PTS` because "2 UP" would be a lie when two
points are scored a hole. **The low/high split does not ship** — a running total is
the only thing the match is decided on.

## 3. The states

1. **Ordinary** — 95% of the round.
2. **Draw** — push above, activity already showing the new pairing. **No special
   state**: no banner, no waiting card, no "open to draw" button. It updates.
3. **High-Low** — as above.
4. **Always-on** — identical composition; iOS pulls refresh rate and brightness.
   Nothing is recomposed. The big number is already the only thing that has to
   survive there, which is a useful test before adding any line.
5. **Final** — the one personal state: `+$10`, `Blue won 1 and 3`,
   `Collect from Sam`. Holds ~5 min, then dismisses.

The **quiet** treatment in the prototype is not shipped. It is the fallback if
telemetry says people resent a four-hour activity.

## 4. The push

Fires **once per pairing landing** — not when the draw sheet opens, not per hole.
One push in a normal round, at hole 7; extra holes push on the same rule.

```
Title  New partners — holes 7–12
Body   Pairing 2: Paul & Sam v. Dave & Lee
Label  HALVED
```

Extra-holes copy is **method-neutral** — `New partners — extra holes` /
`Extra holes 5–6: …` — because half the time nothing was drawn.

**Never both.** The activity does not flash or animate on the push; it is already
showing the answer the push announced. Nothing else in Sixes pushes.

## 5. Lifecycle

| Moment | Behaviour |
|---|---|
| Start | **First score posted**, not the tee time — buys back the range against the 8-hour iOS cap, and an abandoned round leaves no ghost. |
| Through | One activity per round. Skins alongside does **not** get one; Sixes is the game with news. Ranking fixed at setup. |
| 8 hours | Not designed — see §7. |
| End | Final state on round sign, auto-dismiss ~5 min. |

## 6. Answers to the packet's four questions for code

**Colour stability — confirmed, and it is free.** Blue/orange are not recomputed per
segment. `sixes_summary` returns each segment's `team1`/`team2` already keyed to the
same underlying sides, and the money map is keyed on *players* rather than a fixed
team number precisely because teams rotate. The activity reads `team1` = blue,
`team2` = orange for the whole round.

**Late score edits — render the new value, do not animate.** Every score post already
recalculates the whole segment and the activity is a push of the resulting state, so
there is no "change event" to animate from; an animation would also fire on an
ordinary hole. iOS animates the diff itself on a Live Activity content update, which
is the right amount.

**Player drops mid-round — end the activity.** Sixes needs exactly four. The app has
mid-round withdrawal (`FoursomeMembership.withdrew_after_hole`), and the Sixes
handling is `apply_withdrawal_to_sixes` → segments go **void** or **solo**. A void
segment has no two sides to name, so the whole composition is wrong. End it rather
than switch game: switching would silently change what the lock screen is reporting.

**Thru vs segment context in the footer — proposal, needs a ruling.** Show the last
segment's result for the **first two holes of a new segment**, then revert to thru.
Rationale: the result is news exactly as long as it is news, and two holes is about
how long a group talks about it. This is a guess at the packet's own suggestion and
design should confirm.

## 7. Not designed — needs design before build

- **The pips under extra holes.** The packet names two candidates (the finished
  segment's pip splits to show its tail, or the stretch borrows the live pip) and
  asks which. Until it is chosen, extra holes render with the pips unchanged —
  candidate two — because it is the one that cannot be wrong about the segment count.
- **The 8-hour expiry.** End silently, or end with the final state pre-empted. A slow
  round with a turn is genuinely close to the cap, so this will happen.

## 8. What must not be touched

Nothing about Sixes scoring changes. `services/sixes.py` is the source of truth and
the activity is a **read**: a projection of `sixes_summary` into five slots. If a slot
needs a number Sixes does not already compute, that is a signal the slot is wrong,
not that Sixes needs a new field.
