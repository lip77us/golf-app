import 'package:flutter/material.dart';
import 'scorecard_grid.dart';

/// Wraps a round-context screen so that **rotating the phone to landscape**
/// reveals the full-group [ScorecardGrid] — the app-wide replacement for the
/// old standalone scorecard screen + its "Full scorecard" toolbar icons.
///
/// In portrait it shows [child].  In landscape, when a [foursomeId] is known,
/// it lays the read-only scorecard grid over the screen.  When [foursomeId] is
/// null (e.g. a multi-group leaderboard where the target group is ambiguous)
/// rotation is simply a no-op.
///
/// The wrapped [child] is kept mounted (via [Offstage]) while the grid is
/// shown, so rotating out to the card and back preserves the screen's state
/// (selected hole, scroll position, in-flight edits).
///
/// The app has no orientation lock (iOS Info.plist allows landscape; there's
/// no SystemChrome lock), so this is the single place that gives landscape a
/// meaning: "show me the card."
class RoundLandscapeScorecard extends StatelessWidget {
  final int? foursomeId;
  final Widget child;

  const RoundLandscapeScorecard({
    super.key,
    required this.foursomeId,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final showGrid =
        foursomeId != null &&
        MediaQuery.of(context).orientation == Orientation.landscape;

    // No grid to show → just the screen (avoids a needless Stack/Offstage).
    if (foursomeId == null) return child;

    return Stack(children: [
      // Keep the screen alive but hidden while the grid is up, so rotating
      // back restores exactly where the user left off.
      Offstage(
        offstage: showGrid,
        child: TickerMode(enabled: !showGrid, child: child),
      ),
      if (showGrid)
        Positioned.fill(
          child: ScorecardGrid(foursomeId: foursomeId!, showClose: false),
        ),
    ]);
  }
}
