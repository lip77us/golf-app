/// widgets/hole_header.dart
/// -----------------------
/// The hole card at the top of score entry (`handoff-score-entry-template`): its
/// OWN white card with the hole tile, `412 yds` and `SI 7 · front nine`. It used
/// to be a grey block at the top of the golfers' card, reading `Par 4  |  412 yds.  |  SI: 7`.
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
import '../theme/halved_brand.dart';

/// The hole's facts, one string each, slashing any the tees disagree on:
/// `par` is `4` (or `4/5`), `yards` is `412` (or `400/340`, null when no tee
/// has a yardage) and `si` is `7` (or `7/3`).
///
/// One entry per distinct TEE, not per golfer — four men off the same tee state
/// the par once. A golfer with no tee keys off his own id so he still counts,
/// which is what stops a phantom or an unassigned golfer collapsing into
/// somebody else's row.
({String par, String? yards, String si}) holeFacts(
    ScorecardHole hole, List<Membership> players) {
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

  final anyYards = yardVals.any((y) => y != null);
  return (
    par: collapse<int>(parVals, (v) => '$v'),
    yards: anyYards
        ? collapse<int?>(yardVals, (v) => v == null ? '—' : '$v')
        : null,
    si: collapse<int>(siVals, (v) => '$v'),
  );
}

/// `Par 4  |  412 yds.  |  SI: 7`, slashing any fact the tees disagree on.
///
/// Kept for the screens and tests that read the single line; the hole card
/// itself draws [holeFacts] in pieces.
String holeHeaderLine(ScorecardHole hole, List<Membership> players) {
  final f = holeFacts(hole, players);
  final parStr = 'Par ${f.par}';
  final siStr = 'SI: ${f.si}';
  return f.yards == null
      ? '$parStr  |  $siStr'
      : '$parStr  |  ${f.yards} yds.  |  $siStr';
}

/// `3 of 9` — where this hole sits in the group's own round.
///
/// **Empty unless the round is a shotgun.** On a round that starts on the 1st
/// the hole number IS the position, so the marker would restate it; the
/// confusion it exists for is the group teeing off on the 9th and not knowing
/// whether that is their first hole or their ninth. A back-nine round counts as
/// a shotgun for this purpose and legitimately gets it — `Hole 14 · 5 of 9`.
///
/// Empty too when [hole] is not in [playOrder] at all. `indexOf` returns −1
/// there and the obvious `indexOf + 1` renders `0 of 9`, which is worse than
/// saying nothing.
String holePositionLine(List<int> playOrder, int hole) {
  if (playOrder.isEmpty || playOrder.first == 1) return '';
  final i = playOrder.indexOf(hole);
  if (i < 0) return '';
  return '${i + 1} of ${playOrder.length}';
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

  /// The group's holes IN PLAY ORDER. Drives the shotgun position marker; empty
  /// (a round nobody has told the header about) simply omits it.
  final List<int> holesInPlay;

  /// A block of its own — rounded on all four corners — rather than the top of
  /// a card. See the class doc.
  final bool standalone;

  /// A game's own figure, bottom-right. 40 Balls puts the group's net there.
  ///
  /// **Bottom-right rather than the top-right the design draws**, because in
  /// this app that corner is already the `?` legend's and has been on six
  /// screens. Same side, one row down, no collision — and the badge does not
  /// need to carry a "thru" either, because the line above it already says
  /// how many holes are left.
  final Widget? badge;

  const HoleHeader({
    super.key,
    required this.holeData,
    required this.holeNumber,
    this.players = const [],
    this.courseName = '',
    this.trailing,
    this.holesInPlay = const [],
    this.standalone = false,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final facts = holeData == null ? null : holeFacts(holeData!, players);
    final nine = holeNumber <= 9 ? 'front nine' : 'back nine';
    final position = holePositionLine(holesInPlay, holeNumber);

    // `handoff-score-entry-template`: the hole is its OWN white card — the hole
    // tile, the yardage, and `SI 5 · front nine` beneath it. Where the game
    // stands is never here (that is the leaderboard line); [badge] is the one
    // optional pill, about THIS hole only (`Carry 2`).
    final sub = [
      if (facts != null) 'SI ${facts.si}',
      nine,
      if (position.isNotEmpty) position,
    ].join(' · ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Halved.cardBorder, width: 1.5),
      ),
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Halved.deepPine,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$holeNumber',
                style: Halved.sectionHead().copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1)),
            if (facts != null) ...[
              const SizedBox(height: 3),
              Text('Par ${facts.par}',
                  style: Halved.body(
                          color: const Color(0xFFB9CCC3),
                          weight: FontWeight.w600)
                      .copyWith(fontSize: 10, height: 1)),
            ],
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The course is the app bar's title now; a screen that has not
                // moved to the new bar still passes it, so it stays as a
                // quiet caption rather than vanishing from those screens.
                if (courseName.isNotEmpty)
                  Text(courseName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Halved.body(color: Halved.muted)
                          .copyWith(fontSize: 11.5)),
                Text(
                    facts?.yards != null ? '${facts!.yards} yds' : 'Hole $holeNumber',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Halved.body(
                            color: Halved.deepPine, weight: FontWeight.w700)
                        .copyWith(fontSize: 15)),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Halved.body(color: Halved.muted)
                        .copyWith(fontSize: 12.5)),
              ]),
        ),
        if (badge != null) ...[const SizedBox(width: 8), badge!],
        if (trailing != null) ...[const SizedBox(width: 4), trailing!],
      ]),
    );
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
