# Halved 2.9.0 (build 37) — Release notes

Version in `mobile/pubspec.yaml` → `2.9.0+37`. Previous public build: `2.8.3+35`.

**Fifty-eight commits, held back on purpose.** Everything below was finished
during the two weeks before the 14–15 September tournament and deliberately not
pushed, so nothing could move under a live event. This is the release of that
whole span at once.

Three migrations, all additive: `tournament/0070` (`FoursomeSetupUndo`),
`tournament/0071` (`TeamTournament.last_cup_push`), `games/0079` (four booleans
on `VegasHoleResult`). They apply automatically — `railway.toml`'s start
command runs `migrate --noinput` before gunicorn.

**No `CLIENT_MIN_VERSION` bump.** It stays at `2.1.0`; nobody is forced to
update.

---

## The one thing that must ship with this build

`UNSHIPPED_KINDS` went from **seven kinds to empty** in the same commit that
set `2.9.0+37`, which is the rule this project has followed since Sequoya:
*a card leaves the gate in the commit that bumps the build carrying its Swift
layout, and not before.*

The seven: `stableford`, `stroke_play`, `points`, `wolf`, `triple_cup`,
`vegas`, `triple_nassau`. They came off together because they went on together
— the layouts landed across one stretch of work and no build carried any of
them until this one.

**The consequence is the same one 2.8.3 documented, and it is designed rather
than broken:** the server now sends card kinds a 2.8.3 phone cannot draw. Such
a phone shows the Swift's *"Update Halved to follow this round here"*, which
points at an update that exists the moment this build lands and resolves itself
on update.

---

## Lock screens — seven new cards

Every game in the app that can own a round now has one.

| Card | What it reports |
|---|---|
| **Stableford** | The reader's own points total, the gross beside it, and where he stands in the field |
| **Stroke Play** | To par in the mode the round is scored in, and a place in the flight |
| **Points 5-3-1** | Three ranked rows, the money live from the first hole, and what each man won on the last |
| **Wolf** | The price of the hole, and four totals across in rotation order |
| **Triple Cup** | The cup score — including `0–0` — in both the casual and the team-cup configurations |
| **Las Vegas** | The running margin signed from the reader's side, and the hole's two numbers |
| **Triple Nassau** | Three matches across, one bet at a time, and never the word *down* |

**The shared frame changed twice**, and both were owed to every card. The
headline and the state slot now share one baseline with the sides line running
full width beneath both; and the state slot is inline — `DORMIE · 2 TO PLAY`
rather than stacked. The second restates seven already-shipped cards to match,
which the design packet asked for explicitly.

**Every card now signs off.** Rabbit, Nassau and Survivor had no closing frame
at all and so never sent an end push; their activities lingered until iOS timed
them out. All three have one now.

## Two lock-screen bugs that were already shipped

- **Banker and Sequoya never showed their final card.** Both sent `headline`
  where the Swift `Final` struct wants `amount`. That fails silently in the
  worst available way: APNs accepts the push, the phone cannot decode the
  content-state and drops the whole thing, so the board freezes on its last
  live frame.
- **The fourball card wore the leading side's colour** only by accident — a
  double negation meant the margin was never negative, so `1 UP` was blue for
  eighteen holes whoever was up.

## Score entry and scorecards

- **The numeric keypad no longer traps the user.** The 10-key pad has no return
  key, and on Tees & Handicaps it covered Next and Save with no way out. The
  app is now wrapped once — a Done bar riding the keyboard's top edge plus
  tap-anywhere-else — so no screen can have the bug, including screens nobody
  has written yet.
- **Every 18-column grid pins its label column and opens on the hole in play.**
  Nineteen grids across score entry, the play screens and the leaderboards.
- **OUT / IN / TOT** on every card that shows scores, Wolf excepted — it scores
  points rather than strokes, so a nine-hole stroke subtotal would be a
  different number from the one the game is played on.
- **Stroke dots are no longer capped at two**, and in the 18-column grid they
  stack into a column instead of overflowing the cell.

## Mid-round edits

Tee box and handicap index stay editable for **three scored holes**, then lock
— long enough to catch a wrong tee or a wrong index, short enough that a
completed match cannot be rescored underneath itself. Banker's window is zero:
every hole there is its own negotiated bet, priced against the strokes in play
at the time.

An edit rescores every hole already played and **one step of undo** is kept,
because the prior values cannot be recomputed once overwritten.

## Combo tees

A golfer on a rated composite tee now sees which tee he plays on each hole, on
the lock screen and beside his name in score entry. The pair is fixed once at
setup and checked across all eighteen holes; a combo whose holes do not all
resolve turns the indicator off for the round and logs which hole failed. Of 56
combo tees in the catalog, 54 resolve; the two that do not are course-data
problems, logged with the failing hole.

## Smaller

- A finished round never opens a setup screen — "show scorecard" on a completed
  Sixes match was landing on the team picker.
- The Skins round-complete header no longer overflows the panel.
- Stableford is selectable as a primary game, which it always was in practice;
  the catalog flag said otherwise and nothing read it.
