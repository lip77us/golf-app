/// utils/skins_standing.dart
/// -------------------------
/// What the standing ribbon says on a Skins round.
///
///   * **the standing** is what you have won — `3 skins`, `1 skin`, `No skins`
///   * **the figure** is what it is worth — `+$12 so far`
///
/// ## A skin count is not a place
///
/// Every other ranked game on this row leads with a place, because a place is
/// the answer: `2nd of 4` tells a golfer where he is. Skins does not rank —
/// **the pot is divided by skins won, so two men on three skins each take the
/// same share** and neither is ahead of the other. A `T-1 of 4` would invent a
/// contest the game does not hold.
///
/// So the count leads. It is also the number a golfer actually tracks: he
/// knows he has two and he knows what the next hole is worth.
///
/// ## `No skins` is a state, not a gap
///
/// Carryovers mean a golfer can play nine holes and hold nothing, and that is
/// ordinary rather than a failure to load. It is the same ruling Rabbit's
/// `Loose` got, for the same reason — silence on a row whose job is to report
/// reads as a row that did not arrive.
///
/// ## Junk counts, because the pot pays it
///
/// A junk skin is won by hand rather than by score, but it takes a share of
/// the same pot, so the row counts it with the rest. `totalSkins` is what
/// settles; `skinsWon` alone would name a smaller number than the money below
/// it is paying for.
library;

import '../api/models.dart';
import 'match_notation.dart';
import 'standing_money.dart';

class SkinsStanding {
  /// `3 skins`, `1 skin`, `No skins`, or `Tee off`.
  final String standing;

  /// `+$12 so far` — empty at nothing.
  final String figure;

  const SkinsStanding(this.standing, this.figure);
}

/// The row's two strings, or null when the reader is not in the pool.
///
/// **No `hole` argument.** Skins accumulates — a hole is won or it carries,
/// and neither re-opens — so backing up does not change what a golfer holds.
SkinsStanding? skinsStanding(SkinsSummary? summary, int? playerId) {
  if (summary == null || playerId == null) return null;
  final me = summary.players
      .where((p) => p.playerId == playerId).firstOrNull;
  if (me == null) return null;

  final money = standingMoney(me.net);

  // **Before a hole is decided the row still draws.** The pill is the way in,
  // and losing it here gives the feature up exactly when a first-time player
  // goes looking for the leaderboard.
  if (!summary.holes.any((h) => h.winnerId != null)) {
    return SkinsStanding(kTeeOff, money);
  }

  final n = me.totalSkins;
  return SkinsStanding(
      n == 0 ? 'No skins' : '$n ${n == 1 ? 'skin' : 'skins'}', money);
}
