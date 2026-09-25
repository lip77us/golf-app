/// test/round_count_copy_test.dart
/// ------------------------------
/// **Copy must not state a round count it cannot know.**
///
/// Five strings read `36-hole`, which is a two-round event's LENGTH used as
/// though it were the name of the pot. Reported from the payouts step of a
/// ONE-round tournament — `The 36-hole money`, above a field the TD had
/// defined as eighteen holes. It was wrong on three rounds too, and one of
/// the five only ever renders on a one-round event, where 36 is wrong by
/// definition.
///
/// A computed hole total would have been wrong differently: a nine-hole
/// tournament round is allowed, so `rounds × 18` is a guess. The contrast
/// these strings draw is championship vs side games, so they name that.
///
/// Source-level, because the defect is a literal — no widget test would fail
/// on a sentence being untrue.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const files = [
    'lib/screens/new_round_wizard.dart',
    'lib/screens/tournament_leaderboard_screen.dart',
  ];

  test('no user-facing copy hardcodes a hole or round count', () {
    final offenders = <String>[];
    // `36-hole` and its family. A comment explaining the fix is allowed; a
    // string shown to a TD is not.
    final bad = RegExp(r"'[^']*\b(18|36|54|72)[- ]hole\b[^']*'");
    for (final f in files) {
      final lines = File(f).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (bad.hasMatch(line)) offenders.add('$f:${i + 1}  ${line.trim()}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'these state a length the event may not have — name the pot '
            '(championship / side game) instead of measuring it');
  });
}
