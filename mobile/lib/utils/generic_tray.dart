/// What the generic tray says about a hole, worked out from the scorecard.
///
/// A game with no tray of its own (Irish Rumble, Better Ball, Hot Seat, a cup
/// match, …) still uses the template's keypad, and so needs *a* tray. This one
/// reports only what no game can disagree about: **each golfer's score on this
/// hole, and his gross against par through the holes played** — the
/// template's `Gross` column. It deliberately shows no net and no money: net
/// depends on the game's own handicap treatment (an allowance, strokes-off, a
/// cap) and a wrong net on a tray is worse than none, and the money is the
/// game's to state.
library;

import 'dart:ui' show Color;

import '../api/models.dart';

/// `+9`, `E`, `−2` — gross against par, with a true minus.
String toParLabel(int v) {
  if (v == 0) return 'E';
  return v > 0 ? '+$v' : '−${-v}';
}

/// `Paul Lipkin` → `Paul L.`; a single name is left alone.
String trayName(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return name.trim();
  return '${parts.first} ${parts.last[0].toUpperCase()}.';
}

class GenericTrayRow {
  final int playerId;
  final String name;

  /// The side's colour on the dark tray, or null for a golfer on no side.
  final Color? side;

  /// His score on the hole on screen, or null if he has none (withdrawn, or
  /// the alt-shot partner who did not hit).
  final int? hole;

  /// Gross against par over every hole with a score, this one included.
  final int toPar;

  /// Holes counted, so a golfer with none reads as a dash rather than `E`.
  final int played;

  const GenericTrayRow({
    required this.playerId,
    required this.name,
    required this.side,
    required this.hole,
    required this.toPar,
    required this.played,
  });

  String get toParText => played == 0 ? '–' : toParLabel(toPar);
}

/// One row per golfer in [players].
///
/// [scores] is the screen's EFFECTIVE scores for [hole] (saved + queued +
/// unsaved), which is why the hole on screen is read from it and not from the
/// scorecard: a score typed a moment ago is not in the scorecard yet.
List<GenericTrayRow> genericTrayRows({
  required List<Membership> players,
  required Scorecard scorecard,
  required int hole,
  required Map<int, int> scores,
  Color? Function(Membership)? sideOf,
}) {
  final rows = <GenericTrayRow>[];
  for (final m in players) {
    final pid = m.player.id;
    var toPar = 0;
    var played = 0;
    for (final h in scorecard.holes) {
      if (h.holeNumber == hole) continue; // read from [scores] below
      final e = h.scoreFor(pid);
      if (e == null || e.grossScore == null) continue;
      toPar += e.grossScore! - e.par;
      played++;
    }
    final here = scores[pid];
    if (here != null) {
      final hd = scorecard.holeData(hole);
      final par = hd?.scoreFor(pid)?.par ?? hd?.par ?? 0;
      toPar += here - par;
      played++;
    }
    rows.add(GenericTrayRow(
      playerId: pid,
      name: trayName(m.player.name),
      side: sideOf?.call(m),
      hole: here,
      toPar: toPar,
      played: played,
    ));
  }
  return rows;
}
