/// widgets/triple_cup_pairings.dart
/// -------------------------------
/// The match-ups live on this hole — one line each: the format, both sides in
/// their team colours, and where that match stands.
///
/// ## Why it exists at all
///
/// Removing the Triple Cup match grid from score entry took the scores out
/// and the PAIRINGS with them, and the report was flat: *"nowhere does it say
/// who is playing who in singles on the score entry screen."* The grid came
/// back under the scorecard, but a golfer who does not know it is there will
/// not scroll an 18-column card to find his opponent — which he needs BEFORE
/// he enters a number. So this sits above the score card, where the names
/// and the boxes that go with them live.
///
/// **Singles is the case that needs it.** Two matches run at once over the
/// same six holes, so four tinted rows leave a golfer knowing he is blue
/// without knowing which orange he is playing. Fourball and foursomes have
/// one match on the hole and it still earns its line: the side a man is
/// partnered with is the thing alternate shot is about.
///
/// ## The match score belongs here, not in the standing row
///
/// It used to ride in the standing row's figure, which left `0–1 · 4½ to win`
/// sharing 27px with `Fourball 1 UP thru 1` and truncating to `4½ to w…` —
/// the figure that answers *is it gone* cut off mid-word. The cup now has the
/// bar to itself.
///
/// **It is better here than it was up there**, not merely smaller: a singles
/// segment runs two matches at once, and the row has ONE figure slot, so it
/// could only ever report the reader's. This carries a line each.
///
/// Neutral margin, leader's colour — the division every match row in the app
/// uses — and read through [tripleCupMatchState], the same call the standing
/// row makes, so the two cannot write one match differently.
///
/// Still no CUP here. That is the row's, once.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../utils/triple_cup_standing.dart';

class TripleCupPairings extends StatelessWidget {
  const TripleCupPairings({
    super.key,
    required this.summary,
    required this.hole,
  });

  final TripleCupSummary summary;

  /// The hole on screen. Four matches run over different six-hole ranges, so
  /// the ones covering this hole are the ones being played.
  final int hole;

  static String _side(TripleCupMatch m, int team) => m.players
      .where((p) => p.teamNumber == team && !p.isPhantom)
      .map((p) => p.shortName)
      .join(' & ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = summary.matches
        .where((m) => hole >= m.startHole && hole <= m.endHole)
        .toList();
    if (live.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in live)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(children: [
                // The format, in the same grey the standing row gives it —
                // and the match's own label, so `Singles 1` and `Singles 2`
                // are told apart here as they are there.
                SizedBox(
                  width: 68,
                  child: Text(segmentLabel(m),
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                // The names take whatever the state leaves, and ellipsise
                // rather than push it off the edge. A `Spacer` here would
                // divide the width three ways and squeeze a long pair for
                // room the state does not need.
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text(_side(m, 1),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: summary.team1Color)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Text('v',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    Flexible(
                      child: Text(_side(m, 2),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: summary.team2Color)),
                    ),
                  ]),
                ),
                Builder(builder: (_) {
                  final st = tripleCupMatchState(m);
                  if (st.value.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(st.value,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: switch (st.leader) {
                              1 => summary.team1Color,
                              2 => summary.team2Color,
                              _ => theme.colorScheme.onSurfaceVariant,
                            })),
                  );
                }),
              ]),
            ),
        ],
      ),
    );
  }
}
