/// utils/rabbit_standing.dart
/// --------------------------
/// What the standing ribbon says on a Rabbit round.
///
/// **Rabbit has one distinguished party, not two sides**, and that shapes the
/// whole row. There is no margin, no place and no team — the question the game
/// asks all afternoon is *who is holding it*, and the answer is one name or
/// nobody.
///
///   * **the standing** is the holder — `You have it`, `Dave has it`, `Loose`
///   * **the figure** is what has been won — `+$10 so far`, on decided legs
///
/// ## Mint means holds it
///
/// The lock-screen card already made this call: *Rabbit has one distinguished
/// party rather than two sides, so mint is free to mean "holds it" — the thing
/// Sixes could never let it mean.* The row follows it. Mint when the rabbit is
/// the reader's, grey when it is somebody else's or loose, and no team colours
/// anywhere because there are no teams to colour.
///
/// **That is a different use of colour from every other game on this row**,
/// where a hue means *which side you are on*. It is safe here for the same
/// reason it is safe on the card: a game with no sides has no second meaning
/// for the colour to collide with.
///
/// ## Loose is a state, not a gap
///
/// Nobody holds it until somebody wins a hole outright, and a tie never takes
/// it off the holder. `Loose` is the honest word for that and the app already
/// uses it on the leg rows — saying nothing instead would read as a row that
/// had failed to load.
library;

import '../api/models.dart';
import 'match_notation.dart';

class RabbitStanding {
  /// `You have it`, `Dave has it`, `Loose`.
  final String standing;

  /// `+$10 so far` — settled legs only. Empty until one is.
  final String figure;

  /// True when the rabbit is the READER's. The row goes mint for it; that is
  /// the one thing this game's colour says.
  final bool mine;

  const RabbitStanding(this.standing, this.figure, this.mine);
}

/// `+$10 so far` / `−$5 so far`, or empty at nothing.
///
/// **Settled, never a forecast.** A leg in progress contributes nothing, which
/// is what lets the row say `so far` and mean it — the same rule Sixes needed
/// after `1 UP · Even so far` read as a contradiction.
String rabbitMoney(RabbitSummary s, int playerId) {
  final me = s.players.where((p) => p.playerId == playerId).firstOrNull;
  final v = me?.money ?? 0;
  if (v.abs() < 0.005) return '';
  final n = v.abs();
  final amount =
      n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
  // U+2212, not a hyphen — beside a `+` at this size the hyphen is visibly
  // the wrong length.
  return '${v > 0 ? "+" : "−"}\$$amount so far';
}

/// Who held the rabbit at [hole], walking BACK through the leg in play order.
///
/// **Not the leg's current holder.** The rabbit changes hands hole by hole, so
/// backing up to the 4th has to report who had it then — the scores and the
/// tinted row on screen have backed up with it. Walking stops at the leg
/// boundary: a segment resets, and the holder from the previous one is a
/// different game.
///
/// Extracted from the Rabbit screen, which computed this for its own row tint
/// and now shares it. Two walks would disagree about who is tinted and who the
/// standing names, on the one screen showing both.
({int? id, String? short, int lead, int segment}) rabbitHolderAt(
    RabbitSummary summary, int hole, List<int> playOrder) {
  final segment = summary.holeFor(hole)?.segment ?? 1;
  final order = playOrder.isEmpty
      ? List.generate(18, (i) => i + 1)
      : playOrder;
  final start = order.indexOf(hole);
  for (var i = start; i >= 0; i--) {
    final hi = summary.holeFor(order[i]);
    if (hi == null) continue;
    if (hi.segment != segment) break;
    if (hi.isScored) {
      return (id: hi.holderId, short: hi.holderShort, lead: hi.lead,
              segment: segment);
    }
  }
  return (id: null, short: null, lead: 0, segment: segment);
}

/// The row's strings, or null before the round has said anything.
///
/// [hole] is the hole on screen. It picks which LEG the row is about, so
/// backing up to an earlier hole reports the rabbit as it stood in that leg —
/// the rule Sixes and Nassau both needed, for the same reason: everything else
/// on the screen has backed up with it.
RabbitStanding? rabbitStanding(RabbitSummary? summary, int? playerId,
                               {required int hole,
                                List<int> playOrder = const []}) {
  if (summary == null || playerId == null) return null;
  if (!summary.players.any((p) => p.playerId == playerId)) return null;

  final money = rabbitMoney(summary, playerId);

  // **Nothing scored at all.** The row still draws, because the pill is the
  // way in and losing it before the first score gives the feature up exactly
  // when a first-time player goes looking for the leaderboard. `Tee off` is
  // the app's own word for the state.
  if (!summary.holes.any((h) => h.isScored)) {
    return RabbitStanding(kTeeOff, money, false);
  }

  final at = rabbitHolderAt(summary, hole, playOrder);
  final mine = at.id != null && at.id == playerId;
  if (at.id != null) {
    return RabbitStanding(_holderLine(at.short, mine), money, mine);
  }

  // Nobody on it. A leg that has RUN OUT with no outright winner was halved;
  // one still running is loose and up for grabs. Different facts, and the
  // grid below tells them apart too.
  final leg = summary.segments
      .where((s) => s.index == at.segment)
      .firstOrNull;
  return RabbitStanding(
      (leg?.complete ?? false) ? 'Halved' : 'Loose', money, false);
}

/// `You have it` / `Dave has it`.
///
/// **Named, not `Rabbit: DM`.** The leg rows below abbreviate because they
/// repeat eighteen times; this says it once, so it can say it in words — and
/// `You` is the shortest true version of the only case that is about the
/// reader.
String _holderLine(String? short, bool mine) {
  if (mine) return 'You have it';
  final name = (short ?? '').trim();
  return name.isEmpty ? 'Loose' : '$name has it';
}
