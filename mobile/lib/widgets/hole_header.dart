/// widgets/hole_header.dart
/// -----------------------
/// The grey block at the top of a score-entry card: the course, `Hole 7`, and
/// the hole's own facts — `Par 4  |  412 yds.  |  SI: 7`.
///
/// **Extracted from `score_entry_screen.dart` 25 Sep 2026.** Almost every game
/// is scored through that screen and got this header; the games with their own
/// play screen each drew a header of their own, and Pink Ball's was a mint card
/// with the hole on the left and the par, yardage and index as pill chips on
/// the right. Nothing was wrong with it except that it was not the one the same
/// golfer sees in every other round.
///
/// ## The meta line is a function, not a format string
///
/// `holeHeaderLine` collapses each fact across the tees actually in play and
/// only slashes when they DIFFER: one par on a card where everybody plays the
/// same par 4, `Par 4/5` on a course where the forward tee plays it as a five.
/// Same for the yardage and the index. That is the whole reason it cannot be
/// three chips read off the first golfer's tee — in a mixed group the first
/// golfer's index is not the group's, and a stroke falls where the index says.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';

/// `Par 4  |  412 yds.  |  SI: 7`, slashing any fact the tees disagree on.
///
/// One entry per distinct TEE, not per golfer — four men off the same tee state
/// the par once. A golfer with no tee keys off his own id so he still counts,
/// which is what stops a phantom or an unassigned golfer collapsing into
/// somebody else's row.
String holeHeaderLine(ScorecardHole hole, List<Membership> players) {
  final seenKeys = <int>{};
  final parVals  = <int>[];
  final yardVals = <int?>[];
  final siVals   = <int>[];
  for (final m in players) {
    final key = m.tee?.id ?? -m.player.id;
    if (!seenKeys.add(key)) continue;
    final e = hole.scoreFor(m.player.id);
    parVals.add(e?.par   ?? hole.par);
    yardVals.add(e?.yards ?? hole.yards);
    siVals.add(e?.strokeIndex ?? hole.strokeIndex);
  }

  String collapse<T>(List<T> values, String Function(T) fmt) {
    if (values.isEmpty) return '';
    final seen   = <T>{};
    final unique = values.where((v) => seen.add(v)).toList();
    return unique.length == 1 ? fmt(unique.first) : unique.map(fmt).join('/');
  }

  final parStr  = 'Par ${collapse<int>(parVals, (v) => '$v')}';
  final siStr   = 'SI: ${collapse<int>(siVals,  (v) => '$v')}';
  final anyYards = yardVals.any((y) => y != null);
  final yardStr = anyYards
      ? '${collapse<int?>(yardVals, (v) => v == null ? '—' : '$v')} yds.'
      : null;

  return yardStr == null ? '$parStr  |  $siStr' : '$parStr  |  $yardStr  |  $siStr';
}

/// The header. Rounded at the TOP only by default, because it is the top of a
/// card whose other rows are the golfers — a floating mint banner above the
/// rows was the thing that made Pink Ball look like a different app.
///
/// [standalone] rounds all four corners, for the screens that draw the header
/// as a block of its own above a separate score card (Rabbit, Survivor, Wolf,
/// Sequoya 3s, Triple Nassau). That is a real difference in what the header IS
/// on those screens, not a style choice, so it is a parameter rather than
/// something each of them re-implements.
class HoleHeader extends StatelessWidget {
  /// The hole's row from the group's card. Null (a hole with no data yet) drops
  /// the meta line rather than inventing a par.
  final ScorecardHole? holeData;

  /// The hole as the golfer reads it — its NUMBER, never its position in the
  /// play order. A shotgun group starting on the 7th is on the 7th.
  final int holeNumber;

  /// The golfers whose tees the meta line collapses across. Empty is legal and
  /// yields the hole's own shared par / index.
  final List<Membership> players;

  /// Above the hole number, in the same small font as the meta line below it.
  /// Empty hides it.
  final String courseName;

  /// Sits top-right, inside the 44px horizontal padding kept clear for it.
  /// Score entry puts its `?` legend here; a screen with no legend passes
  /// nothing and the space is simply symmetrical.
  final Widget? trailing;

  /// A block of its own — rounded on all four corners — rather than the top of
  /// a card. See the class doc.
  final bool standalone;

  const HoleHeader({
    super.key,
    required this.holeData,
    required this.holeNumber,
    this.players = const [],
    this.courseName = '',
    this.trailing,
    this.standalone = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A Stack so `trailing` can sit top-right without pulling the centred
    // Hole-N and meta line off centre.
    return Stack(children: [
      Container(
        // Infinite width because a Stack does not propagate the parent
        // Column's stretch, and the grey has to reach both edges of the card.
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: standalone
              ? BorderRadius.circular(8)
              : const BorderRadius.vertical(top: Radius.circular(8)),
        ),
        child: Column(children: [
          if (courseName.isNotEmpty) ...[
            Text(courseName,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 2),
          ],
          Text('Hole $holeNumber',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          if (holeData != null)
            Text(
              holeHeaderLine(holeData!, players),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
        ]),
      ),
      if (trailing != null)
        Positioned(top: 2, right: 2, child: trailing!),
    ]);
  }
}

/// The `?` that opens a screen's row legend, for [HoleHeader.trailing].
///
/// The SHEET is each screen's own — Skins explains junk and the hole-winner
/// marker, Wolf explains the wolf's pips — but the button never was. It was
/// written out longhand on six screens, identical down to the 36×36 minimum
/// target, which is one more copy than a 22px icon deserves.
IconButton holeLegendButton(BuildContext context, VoidCallback onPressed) =>
    IconButton(
      tooltip: 'What do these mean?',
      icon: Icon(Icons.help_outline,
          size: 22, color: Theme.of(context).colorScheme.primary),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: onPressed,
    );
