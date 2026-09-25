/// test/standing_row_coverage_test.dart
/// -----------------------------------
/// **Every score-entry screen carries the standing row.**
///
/// Three were missed — `nassau_screen`, `quota_nassau_screen` and
/// `pink_ball_screen` — and all three were cup or tournament screens, reached
/// only through `round.isCupRound` or a multi-foursome game. The sweep worked
/// outward from casual games and stopped at the boundary RULINGS §11 drew, so
/// the gap was exactly the shape of that boundary. Found by audit, 25 Sep
/// 2026, and this is the audit.
///
/// Source-level because what is being asserted is that a screen HAS a
/// feature, and the failure mode is somebody adding a twelfth play screen
/// without one.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every screen the round hub can open to enter or read scores.
///
/// Kept as a literal rather than derived from the routing, because deriving
/// it from `round_screen.dart` would make this test agree with whatever that
/// file does — including forgetting a screen.
const _playScreens = [
  'banker_screen.dart',
  'nassau_screen.dart',
  'pink_ball_screen.dart',
  'points_531_screen.dart',
  'quota_nassau_screen.dart',
  'rabbit_screen.dart',
  'score_entry_screen.dart',
  'sequoya_threes_screen.dart',
  'skins_screen.dart',
  'survivor_screen.dart',
  'team_play_score_entry_screen.dart',
  'triple_nassau_screen.dart',
  'wolf_screen.dart',
];

void main() {
  String read(String f) => File('lib/screens/$f').readAsStringSync();

  test('every play screen has a standing row, or says it is unreachable', () {
    // **The contract, not just the feature.** `skins_screen` and
    // `points_531_screen` are dead — nothing pushes `/skins` or
    // `/points-531`, both games play through `/score-entry` — and carry a
    // `NOT REACHED` header saying so. Exempting them by name would mean
    // wiring one up later and silently shipping it without a row; requiring
    // the header instead makes that the failure.
    // **`bottom: ribbon`, not just the type name.** Checking that
    // `StandingRibbon` appears anywhere in the file passes on a screen that
    // BUILDS one and never mounts it — verified, by deleting a builder and
    // watching this test stay green. What has to be true is that the app bar
    // carries it, and every screen mounts it the same way.
    final missing = [
      for (final f in _playScreens)
        if (!read(f).contains('bottom: ribbon') &&
            !read(f).contains('NOT REACHED'))
          f,
    ];
    expect(missing, isEmpty,
        reason: 'these have no standing row, so a golfer on them has no '
            'named way to the leaderboard and no summary of where he stands');
  });

  test('an unreachable screen is unreachable', () {
    // The other half of the contract above: if one of these ever gets a
    // pusher, the header has to go — and then the test above starts
    // demanding a row.
    final wizard = File('lib/screens/round_screen.dart').readAsStringSync();
    for (final route in const ['/skins', '/points-531']) {
      expect(wizard.contains("'$route'"), isFalse,
          reason: '$route is now reachable, so its screen needs a standing '
              'row and its NOT REACHED header removed');
    }
  });

  test('no play screen shows the leaderboard icon unconditionally', () {
    // The pill replaces the glyph; showing both puts two ways in at one
    // corner, and the glyph is the weak target D2 exists to remove. The icon
    // survives only as a fallback for when the row cannot be built.
    final ungated = <String>[];
    for (final f in _playScreens) {
      final lines = read(f).split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('Icons.leaderboard')) continue;
        // An unreachable screen's icon is the only way off it, so it keeps
        // one. Everything a golfer can actually open must gate it.
        if (read(f).contains('NOT REACHED')) continue;
        final before = lines.sublist(i < 8 ? 0 : i - 8, i + 1).join('\n');
        // **The OVERFLOW entry is not the defect.** `Leaderboard` also sits
        // in the three-dot menu on several screens, which is a deliberate
        // second way in that costs no space and competes with nothing. What
        // D2 replaces is the bare glyph in the app bar's actions, so only an
        // `IconButton` counts.
        if (before.contains('PopupMenuItem')) continue;
        if (!before.contains('IconButton(')) continue;
        if (!before.contains('ribbon == null')) ungated.add('$f:${i + 1}');
      }
    }
    expect(ungated, isEmpty,
        reason: 'gate these on `ribbon == null`');
  });

  test('the row reaches the cup and tournament screens, not just casual', () {
    // The three that were missed. Named individually because the reason they
    // were missed is what they have in common, and a list that only counted
    // would pass again the next time a cup screen is added.
    for (final f in const [
      'nassau_screen.dart',          // cup Four Ball
      'quota_nassau_screen.dart',    // cup Four Ball Quota
      'pink_ball_screen.dart',       // tournament Pink Ball
    ]) {
      expect(read(f), contains('bottom: ribbon'), reason: f);
    }
  });
}
