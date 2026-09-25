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
/// **The margin is NEUTRAL and wears the leading side's colour.** A Nassau
/// pairing is chosen once and never re-drawn, so blue means the same golfers
/// on the first tee and the eighteenth green — the colour can carry identity,
/// and the row never needs to spend width on names.
///
/// It used to write the margin from the READER's side while colouring the
/// LEADER's, and the two contradicted each other on every hole the reader was
/// behind: `1 DOWN` in orange, on a screen where orange was one UP. Reported
/// from a singles match, 22 Sep 2026.
///
/// Sixes solves the same problem the other way — it colours the READER's side,
/// so `1 DOWN` in his own blue is honest — and it has to, because its pairings
/// re-draw every six holes and a leader-coloured row would change meaning
/// mid-round. Nassau's do not, so it takes the answer that agrees with the
/// leaderboard: **one string for all four phones, and the tint says whose.**
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

/// One bet on the row: which one it is, where it stands, and whose side is up.
///
/// **The label is grey and the value is coloured.** Which bet this is never
/// changes, so it stays quiet; the margin is the news and carries the weight
/// and the hue. `F9` in a team colour would make the row's loudest element the
/// one thing that cannot move.
class NassauPart {
  /// `F9`, `B9`, `Overall` — or empty on a single-bet Nassau, where naming a
  /// division the group is not playing would be worse than nothing.
  final String label;

  /// `2 UP thru 5`, `All Square`, `won 3&2` — **never `DOWN` or `lost`.**
  /// The same string reaches all four phones and [team] says whose it is.
  final String value;

  /// 1 or 2 — whose side is up, and therefore the colour the value wears. Null
  /// while level, where no side is up for a colour to be about. Unlike Sixes
  /// it is never withheld for any other reason, because Nassau's teams do not
  /// re-draw.
  final int? team;

  const NassauPart(this.label, this.value, this.team);
}

class NassauStanding {
  /// The bet the hole on screen belongs to — the nine, or the overall once
  /// the nine has nothing to report.
  final NassauPart main;

  /// The eighteen, beside it. Null on a single-bet Nassau.
  final NassauPart? second;

  const NassauStanding(this.main, this.second);
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
NassauPart? _bet(NassauBetResult bet, {required String label,
                                       bool showThru = true}) {
  if (bet.holesPlayed == 0) return null;
  // **The RAW margin, not the reader's.** It asks which SIDE is up, which is a
  // fact about the match rather than about whoever is reading it — and the
  // colour is about to say the same thing, so the two cannot disagree.
  final team = _side(bet);

  // A DECIDED bet reports its result, not a running margin — `2 UP` on a nine
  // that is over reads as a nine still to play. `decidedRemaining` is the
  // holes that were left, which is what makes it `3&2`; the server computes it
  // along the group's play order, because `9 - finishedOnHole` is right off
  // the 1st tee and wrong off every shotgun.
  if (bet.result != null) {
    if (bet.result == 'halved') return NassauPart(label, kAllSquare, null);
    final m = (bet.decidedMargin ?? bet.margin).abs();
    return NassauPart(
        label, 'won ${closeOut(m, bet.decidedRemaining ?? 0)}', team);
  }

  final thru = showThru ? ' thru ${bet.holesPlayed}' : '';
  return NassauPart(
      label,
      bet.margin == 0
          ? '$kAllSquare$thru'
          : '${marginLabel(bet.margin.abs())}$thru',
      team);
}

/// The two strings, or null when the round has not said anything yet.
///
/// [hole] is the hole on screen. It picks which NINE the row is about, so
/// backing up to the front nine on the 14th reports the front nine — the same
/// rule Sixes needed, for the same reason: the header, the player rows and the
/// scores on screen are all that nine, and a standing describing the other one
/// is the only thing disagreeing with the rest of the screen.
/// **The row is about the MATCH, not about the reader.**
///
/// It used to refuse unless the reader was on one of the two sides, and that
/// refusal was pinned by a test reading *"a watcher gets nothing — he is on
/// neither side."* The rule was written while this row was casual-only, where
/// whoever holds the phone is normally playing.
///
/// On a cup round he normally is NOT: the TD enters scores for a group he is
/// not in, and every golfer in the field can be a login-less roster entry. The
/// screen he is looking at is entirely about that match, and the row said
/// `Tee off` over a match that was 1 UP through two holes — reported from a
/// cup Four Ball, 25 Sep 2026. RULINGS §10.4, one game over.
///
/// Nothing below ever used the reader's side: the margin is neutral and the
/// colour names the LEADER, which is RULINGS §3 and what `_bet` says in its
/// own comment. So the gate was refusing to state a fact it had in hand.
NassauStanding? nassauStanding(NassauSummary? summary, {required int hole}) {
  if (summary == null) return null;

  // **A single-bet Nassau has no nine to name.** Nassau Nine rides `front9` as
  // one match over the holes played, and an 18-hole match play (front and back
  // switched off) rides `overall` — neither has a second row to fill, and a
  // label would be naming a division the group is not playing.
  if (summary.singleMatch) {
    final only = _bet(summary.front9, label: '');
    return only == null ? null : NassauStanding(only, null);
  }
  if (!summary.playFront && !summary.playBack) {
    final only = _bet(summary.overall, label: '');
    return only == null ? null : NassauStanding(only, null);
  }

  // The nine the hole on screen belongs to. By hole NUMBER, because that is
  // what a nine IS — off a shotgun from the 13th a group plays the back nine
  // first, and it is still the back nine.
  final onBack = hole > 9;
  final nine = onBack ? summary.back9 : summary.front9;
  final inPlay = onBack ? summary.playBack : summary.playFront;

  final ninePart = inPlay ? _bet(nine, label: onBack ? 'B9' : 'F9')
                          : null;
  // Derived rather than keyed off which nine it is: the two counts are equal
  // exactly when they would repeat, whatever put them there — a front nine, a
  // nine still on its first hole, a bet switched off mid-round.
  final overallPart = summary.playOverall
      ? _bet(summary.overall, label: 'Overall',
             showThru: summary.overall.holesPlayed != nine.holesPlayed)
      : null;

  // Before the nine on screen has a score, the overall leads the row rather
  // than the row saying nothing — on the 10th tee the front nine is history
  // and the eighteen is the live bet. As the leading slot it keeps its own
  // count, because there is no second one for it to repeat.
  if (ninePart == null) {
    final lead = summary.playOverall
        ? _bet(summary.overall, label: 'Overall')
        : null;
    return lead == null ? null : NassauStanding(lead, null);
  }
  return NassauStanding(ninePart, overallPart);
}

/// The colour: the reader's side while he is up, null while level.
///
/// **All Square is grey**, the same call Sixes made — neither side is up, so
/// there is no side for the colour to be about and picking one reads as a
/// lead.
int? _side(NassauBetResult bet) {
  if (bet.result == 'halved' || bet.margin == 0) return null;
  // `margin` is written from team 1's side by the server.
  return bet.margin > 0 ? 1 : 2;
}
