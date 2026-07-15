# Skins junk entry — UX notes

## Problem 1 (fixed): no way to see which holes junk was scored on
The leaderboard Skins card showed junk only as a per-player aggregate
("3 skins and 1 junk"), and the shared per-hole scorecard highlights only the
skin winner — neither tells you *which holes* junk was logged on. Fixed by
adding a **"JUNK BY HOLE"** chip strip to `_SkinsGroupCard`
(`leaderboard_screen.dart`), mirroring the existing "SPOTS BY HOLE" strip: one
pill per hole that had junk, showing hole number + `short_name ×count`. No
backend change — the skins summary `holes` already carry a
`junk: [{player_id, short_name, count}]` list.

## Problem 2 (open): junk +/- control is small AND awkward to reach
Two separate issues:

1. **Size** — the inline `_JunkDots` control in `score_entry_screen.dart` was
   14px outline icons. Bumped modestly to 20px icons + labelMedium text + a
   little tap padding (still inline on every player row) to try in practice.

2. **The real friction — forced entry order.** In score entry, hitting a
   player's score immediately advances the active/hot row to the next player.
   So to add junk to a player *after* entering their score, you currently have
   to: clear the score → tap the junk control → re-enter the score. Junk is
   only comfortably reachable in the brief moment the player is active, before
   you've entered their score.

   Decision (Paul): **do NOT force a score-entry order.** Junk should be
   taggable on any player at any time without having to clear/re-enter a score.
   That's why the junk control stays on **every** row (not active-only) and
   remains functional regardless of whether that player is the active/hot row.
   (An earlier "show junk only on the active player" experiment was reverted for
   exactly this reason — it made junk reachable only during the forced-order
   active moment.)

   Follow-up to consider: decouple junk tagging from the active-row model
   entirely so entering a score never blocks adjusting junk — e.g. keep the
   control tappable inline on scored rows (current behavior) and make sure a tap
   on the junk control never triggers the row's score-edit/advance behavior.
