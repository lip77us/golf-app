/// utils/better_ball.dart
/// ----------------------
/// The two things that follow the ball count, mirrored from
/// `services/better_ball.py`.
///
/// **Mirrored rather than fetched.** The setup screen is one stepper, and the
/// name and allowance under it have to change on the tap — a round trip per
/// press would make the readback lag the control that drives it, which on a
/// screen whose whole job is a read-back is the one thing it cannot do. Four
/// strings and four integers is not a thing to build a request for.
///
/// The server sends `names_by_count` and `allowance_by_count` on the setup GET
/// anyway, so a screen that has loaded prefers those and these are the
/// offline / first-frame answer. **The server stays authoritative**: it is
/// what writes the config, and a disagreement resolves its way on save.
library;

import 'team_allowance.dart' show kShamblePctByBalls;

/// The title the app gives the game at this count.
///
/// **4 is worth its own word.** `Best 4 of 4` describes the arithmetic and
/// misses the point: when every net counts on every hole, nobody can have a
/// bad hole quietly, and the group plays the round differently because of it.
const Map<int, String> kBetterBallNames = {
  1: 'Better Ball',
  2: 'Best 2 of 4',
  3: 'Best 3 of 4',
  4: 'Aggregate',
};

String betterBallName(int balls) => kBetterBallNames[balls] ?? 'Best 2 of 4';

/// The suggested allowance at this count.
///
/// The published table, which already ships as `kShamblePctByBalls` in
/// `utils/team_allowance.dart` — this reads THAT rather than restating it,
/// because two ladders in one app is how the app comes to pay two different
/// amounts for one format.
///
/// **A suggestion, not a rule.** The TD's number wins the moment he sets one.
int betterBallAllowance(int balls) => kShamblePctByBalls[balls] ?? 85;

/// `Holes 1–18 · Best 2 nets per group` — one line, not eighteen.
///
/// The count cannot change mid-round, so the preview is a statement rather
/// than a grid. At four it stops counting and says what it costs instead.
String betterBallPreview(int balls) {
  if (balls >= 4) return 'Every net counts — nothing dropped';
  return 'Holes 1–18 · Best $balls ${balls == 1 ? "net" : "nets"} per group';
}
