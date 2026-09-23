/// utils/banker_standing.dart
/// --------------------------
/// What the standing ribbon says on a Banker round.
///
///   * **the standing** is the money — `+$40`, `−$25`
///   * **the figure** is the reader's position on the hole — `You bank`,
///     `Dave banks`, or `Capped` when the house has cut him off
///
/// ## The first row on this strip whose standing IS money
///
/// Every game before it had something else to report — a match, a place, a
/// points total, a word — and the money rode in the quiet slot as a
/// qualifier. **Banker has nothing else.** There is no match to be up in, no
/// field to place in and no points; a hole is three one-on-one bets and the
/// only thing it produces is dollars. So the dollars take the loud slot and
/// the row takes the 💰 glyph, which is what that glyph was defined for.
///
/// ## Which leaves the hole for the figure
///
/// **Whether you are the banker is the position-defining fact of a Banker
/// hole** — one man plays three matches at once and carries the sum of them,
/// where everybody else has one bet and one opponent. The screen says whose
/// hole it is, loudly; it does not say it from the READER's side, and `You
/// bank` is a different sentence from `Dave banks` even when the name is his
/// own.
///
/// `Capped` outranks it. Being cut off by the house floors every bet the
/// reader can make for the rest of the round, so it changes what the next
/// eighteen numbers mean — and on the screen it is a small amber tag inside a
/// card he has to scroll to.
///
/// ## The money is grey, and the sign carries it
///
/// The standings card tints its totals green and red, which is the app's
/// vocabulary for a money column. This row does not, because on every other
/// game here a coloured standing means **a side** — and a row that used colour
/// for profit on one game and for a team on the next teaches a reader to
/// distrust it on both. Banker has no sides for it to collide with, but the
/// strip is read across games and the strip is what has to stay legible.
library;

import '../api/models.dart';
import 'match_notation.dart';

class BankerStanding {
  /// `+$40`, `−$25`, or `Tee off` before a hole has settled.
  final String standing;

  /// `You bank`, `Dave banks`, `Capped`, or empty once the round is over.
  final String figure;

  const BankerStanding(this.standing, this.figure);
}

/// `+$40` / `−$25` — whole dollars, matching the standings card below.
///
/// **Whole dollars because Banker is played in them.** A bet is named out loud
/// on the tee and the floor is a round number; cents here would be an accuracy
/// the game does not have.
String bankerMoney(double v) => v > 0
    ? '+\$${v.round()}'
    : '−\$${v.abs().round()}';

/// The row's two strings, or null when the reader is not in the game.
///
/// **No `hole` argument.** Banker accumulates — a hole settles and never
/// re-opens — so backing up does not change where a golfer stands. The hole
/// that the figure reports is the one IN PLAY, which the summary names.
BankerStanding? bankerStanding(BankerSummary? summary, int? playerId) {
  if (summary == null || playerId == null) return null;
  final me = summary.players
      .where((p) => p.playerId == playerId).firstOrNull;
  if (me == null) return null;

  // **Before a hole has settled the row still draws.** The pill is the way in,
  // and losing it here gives the feature up exactly when a first-time player
  // goes looking for the leaderboard. Banker can say something useful even
  // then, because the first banker is known before a ball is struck.
  final standing =
      me.total.abs() < 0.005 ? kTeeOff : bankerMoney(me.total);

  // Cut off by the house: every bet he can make is floored from here, which
  // changes what the rest of the round is worth to him. It outranks the hole.
  if (me.cutOff) return BankerStanding(standing, 'Capped');

  final bankerId = summary.current?.bankerId ?? summary.nextBankerId;
  if (bankerId == null) return BankerStanding(standing, '');
  if (bankerId == playerId) return BankerStanding(standing, 'You bank');

  final who = summary.players
      .where((p) => p.playerId == bankerId).firstOrNull?.shortName ?? '';
  return BankerStanding(standing, who.isEmpty ? '' : '$who banks');
}
