/// test/cup_game_lists_test.dart
/// ----------------------------
/// **A cup game the per-foursome picker offers must be plannable in the
/// wizard**, or it is unreachable.
///
/// Two lists describe the same set of games and neither knows about the
/// other:
///
///   * `_kMixedGames` in `new_round_wizard.dart` — what a TD plans a day
///     from, on "Games & points by round".
///   * `_kCupGames` in `cup_round_setup_screen.dart` — what he picks per
///     foursome when building the groups.
///
/// The second FILTERS itself down to the first: on a mixed cup the picker is
/// a worklist of games the plan still needs. So a game in the picker and not
/// in the plan can never be reached — which is what happened to Quota Nassau
/// when the mixed-cup redesign wrote a new plan list and left it out. It has
/// an engine, a play screen, a watch page and a standing row, and no way in.
/// Reported 25 Sep 2026.
///
/// Source-level because the lists are `const` literals in two screens, and
/// what has to hold is a relationship between them that no widget renders.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Throws rather than `expect`s: this runs while the file is being loaded,
/// outside any test body, where the matcher is not available.
Set<String> _ids(String path, String listName) {
  final src = File(path).readAsStringSync();
  final i = src.indexOf(listName);
  if (i < 0) throw StateError('$listName has been renamed in $path');
  final open = src.indexOf('[', i);
  final close = src.indexOf('\n];', open);
  if (close <= open) throw StateError('could not bound $listName in $path');
  // Each entry starts `('id',`.
  return RegExp(r"\(\s*'([a-z0-9_]+)'")
      .allMatches(src.substring(open, close))
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  final plan = _ids('lib/screens/new_round_wizard.dart', '_kMixedGames');
  final picker =
      _ids('lib/screens/cup_round_setup_screen.dart', '_kCupGames');

  test('both lists were actually found', () {
    expect(plan, isNotEmpty);
    expect(picker, isNotEmpty);
  });

  test('every game the picker offers can be planned in the wizard', () {
    final unreachable = picker.difference(plan);
    expect(unreachable, isEmpty,
        reason: 'these can be chosen per foursome but never planned, so on a '
            'mixed cup the picker filters them away and they cannot be '
            'reached at all — add them to _kMixedGames');
  });

  test('Quota Nassau is in both', () {
    // Named rather than left to the set check: it is the one that was
    // missing, and the set check would pass again if it were removed from
    // BOTH lists, which would be the same bug wearing a different shape.
    expect(plan, contains('quota_nassau'));
    expect(picker, contains('quota_nassau'));
  });
}
