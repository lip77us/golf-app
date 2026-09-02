/// utils/course_handicap.dart
/// -------------------------
/// The WHS course-handicap formula, in Dart.
///
/// **`Player.course_handicap` in `core/models.py` is the source of truth** —
/// every stored figure comes from there, and the server recomputes at round
/// setup. This exists for the one place the client needs the number before a
/// round exists: the Team Play build-teams screen, where the allowance has to
/// move as the TD assigns men, and there is nothing on the server yet to ask.
///
///     course handicap = index × (slope ÷ 113) + (course rating − par)
///
/// Rounded to a whole number, as WHS requires and as the allowance table then
/// applies its percentages to.
library;

import '../api/models.dart';
import 'handicap_rounding.dart';

int courseHandicapFor(PlayerProfile player, TeeInfo tee) {
  final index = double.tryParse(player.handicapIndex) ?? 0;
  final ch = index * (tee.slope / 113.0) + (tee.courseRating - tee.par);
  return roundHalfUp(ch);
}
