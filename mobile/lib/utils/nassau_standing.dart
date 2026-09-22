/// utils/nassau_standing.dart
/// --------------------------
/// What the standing ribbon says on a Nassau round.
///
/// **Nassau is the case where one figure is dishonest**, and the lock-screen
/// card already ruled on it: *two matches are always live — the nine being
/// played and the eighteen — and there is no honest way to nominate one of
/// them as the headline.* That card carries two rows for it. The ribbon has
/// two slots, so it carries the same two facts:
///
///   * **the standing** is the nine being played — `F9 2 UP thru 5`
///   * **the figure** is the overall — `Overall 1 UP`
///
/// Both from the reader's side, because his teams are FIXED here. That is the
/// whole difference from Sixes, and it is why this file is shorter: a Nassau
/// pairing is chosen once and never re-drawn, so blue means the same two
/// golfers on the first tee and the eighteenth green. The colour can carry
/// identity, and the row never needs to spend width on names.
///
/// ## Why no money
///
/// The three bets settle at the turn, at the end, and whenever a press runs
/// out — so for most of the round the only honest money figure is nothing, and
/// a running total would be a forecast of matches that can still turn. Sixes
/// showed what that reads like: `1 UP · Even so far` on the second hole, a row
/// contradicting itself. The overall standing is the more useful second fact
/// anyway; it is what a golfer asks after the nine he is playing.
///
/// Presses are deliberately absent too. They are on the card two rows below,
/// there can be several, and a row that reported one would have to say which.
library;

import '../api/models.dart';
import 'match_notation.dart';

class NassauStanding {
  /// `F9 2 UP thru 5`, `B9 All Square thru 3`, `F9 won 3&2`.
  final String standing;

  /// `Overall 1 UP` — empty on a single-match Nassau, which has no second bet
  /// to report.
  final String figure;

  /// 1 or 2 — always set once the reader is on a side. Unlike Sixes there is
  /// no state where the colour could lie, because the teams never re-draw.
  /// Null only when the match is level, where no side is up for it to mean.
  final int? team;

  const NassauStanding(this.standing, this.figure, this.team);
}

/// Which side the reader is on, or null when he is not in this match.
int? readerSide(NassauSummary s, int playerId) {
  if (s.team1.any((p) => p.playerId == playerId)) return 1;
  if (s.team2.any((p) => p.playerId == playerId)) return 2;
  return null;
}

/// One bet, written from the reader's side.
///
/// `null` when the bet is not in play, or when nothing has been scored in it —
/// an unplayed nine reporting `All Square` would be describing golf nobody has
/// hit yet, the same rule Sixes needed.
/// [showThru] is dropped only where it would REPEAT the other slot's.
///
/// On the front nine the two bets have played the same holes, so `F9 2 UP thru
/// 5 · Overall 1 UP thru 5` says how far in twice. On the back they have not —
/// `B9 1 DOWN thru 3 · Overall 1 UP thru 12` — and each number answers its own
/// question: how far into this nine's bet, and how far into the eighteen. Both
/// are wanted there.
String? _bet(NassauBetResult bet, {required int side, required String label,
                                   bool showThru = true}) {
  if (bet.holesPlayed == 0) return null;
  final margin = bet.margin * (side == 1 ? 1 : -1);
  final prefix = label.isEmpty ? '' : '$label ';

  // A DECIDED bet reports its result, not a running margin — `2 UP` on a nine
  // that is over reads as a nine still to play. `decidedRemaining` is the
  // holes that were left, which is what makes it `3&2`; the server computes it
  // along the group's play order, because `9 - finishedOnHole` is right off
  // the 1st tee and wrong off every shotgun.
  if (bet.result != null) {
    if (bet.result == 'halved') return '$prefix$kAllSquare';
    final won = (bet.result == 'team1') == (side == 1);
    final m = (bet.decidedMargin ?? bet.margin).abs();
    return '$prefix${won ? "won" : "lost"} '
           '${closeOut(won ? m : -m, bet.decidedRemaining ?? 0)}';
  }

  final thru = showThru ? ' thru ${bet.holesPlayed}' : '';
  if (margin == 0) return '$prefix$kAllSquare$thru';
  return '$prefix${marginLabel(margin)}$thru';
}

/// The two strings, or null when the round has not said anything yet.
///
/// [hole] is the hole on screen. It picks which NINE the row is about, so
/// backing up to the front nine on the 14th reports the front nine — the same
/// rule Sixes needed, for the same reason: the header, the player rows and the
/// scores on screen are all that nine, and a standing describing the other one
/// is the only thing disagreeing with the rest of the screen.
NassauStanding? nassauStanding(NassauSummary? summary, int? playerId,
                               {required int hole}) {
  if (summary == null || playerId == null) return null;
  final side = readerSide(summary, playerId);
  if (side == null) return null;

  // **A single-bet Nassau has no nine to name.** Nassau Nine rides `front9` as
  // one match over the holes played, and an 18-hole match play (front and back
  // switched off) rides `overall` — neither has a second row to fill, and a
  // label would be naming a division the group is not playing.
  if (summary.singleMatch) {
    final only = _bet(summary.front9, side: side, label: '');
    return only == null ? null : NassauStanding(only, '', _side(summary.front9, side));
  }
  if (!summary.playFront && !summary.playBack) {
    final only = _bet(summary.overall, side: side, label: '');
    return only == null
        ? null
        : NassauStanding(only, '', _side(summary.overall, side));
  }

  // The nine the hole on screen belongs to. By hole NUMBER, because that is
  // what a nine IS — off a shotgun from the 13th a group plays the back nine
  // first, and it is still the back nine.
  final onBack = hole > 9;
  final nine = onBack ? summary.back9 : summary.front9;
  final inPlay = onBack ? summary.playBack : summary.playFront;

  final ninePart = inPlay ? _bet(nine, side: side, label: onBack ? 'B9' : 'F9')
                          : null;
  // Derived rather than keyed off which nine it is: the two counts are equal
  // exactly when they would repeat, whatever put them there — a front nine, a
  // nine still on its first hole, a bet switched off mid-round.
  final overallPart = summary.playOverall
      ? _bet(summary.overall, side: side, label: 'Overall',
             showThru: summary.overall.holesPlayed != nine.holesPlayed)
      : null;

  // Before the nine on screen has a score, the overall leads the row rather
  // than the row saying nothing — on the 10th tee the front nine is history
  // and the eighteen is the live bet. As the leading slot it keeps its own
  // count, because there is no second one for it to repeat.
  if (ninePart == null) {
    final lead = summary.playOverall
        ? _bet(summary.overall, side: side, label: 'Overall')
        : null;
    return lead == null
        ? null
        : NassauStanding(lead, '', _side(summary.overall, side));
  }
  return NassauStanding(ninePart, overallPart ?? '', _side(nine, side));
}

/// The colour: the reader's side while he is up, null while level.
///
/// **All Square is grey**, the same call Sixes made — neither side is up, so
/// there is no side for the colour to be about and picking one reads as a
/// lead.
int? _side(NassauBetResult bet, int side) {
  final margin = bet.margin * (side == 1 ? 1 : -1);
  if (bet.result == 'halved' || margin == 0) return null;
  return margin > 0 ? side : (side == 1 ? 2 : 1);
}
