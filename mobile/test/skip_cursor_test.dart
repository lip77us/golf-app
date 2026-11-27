import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/skip_cursor.dart';

void main() {
  final ids = [1, 2, 3, 4];
  bool Function(int) owes(Set<int> scored) => (id) => !scored.contains(id);

  test('a new hole starts on the top golfer owed a score', () {
    expect(SkipCursor().hotIndex(5, ids, owes({})), 0);
  });

  test('a score moves the cursor DOWN, not back to a skipped golfer', () {
    final c = SkipCursor()..skip(5, 1);
    expect(c.hotIndex(5, ids, owes({})), 1);
    c.moveFrom(5, 2);
    expect(c.hotIndex(5, ids, owes({2})), 2);
  });

  test('past the last golfer it wraps to the top', () {
    final c = SkipCursor()..moveFrom(5, 4);
    expect(c.hotIndex(5, ids, owes({3, 4})), 0);
  });

  test('another hole forgets the cursor and the marks', () {
    final c = SkipCursor()..skip(5, 1);
    expect(c.hotIndex(6, ids, owes({})), 0);
    expect(c.skippedOn(6), isEmpty);
    expect(c.skippedOn(5), {1});
  });

  test('nobody owed means -1', () {
    expect(SkipCursor().hotIndex(5, ids, owes({1, 2, 3, 4})), -1);
  });

  // `handoff-score-entry-tap`: tapping is Skip by pointing.
  group('tapping a golfer', () {
    final card = [
      for (final (i, name) in ['Paul', 'Dave', 'Mike', 'Tom'].indexed)
        Membership.fromJson({
          'id': i + 1,
          'player': {'id': i + 1, 'name': name},
        }),
    ];

    test('from Paul, tap Tom, enter 4: back to Paul, who is skipped', () {
      final c = SkipCursor()..tapTo(7, from: 1, to: 4, owes: owes({}));
      // Tom's score lands; the cursor moves down from him and wraps.
      c.moveFrom(7, 4);
      final scores = {4: 4};
      final hot = c.hot(7, card, (m) => !scores.containsKey(m.player.id));
      expect(hot, 0);
      expect(c.skippedOn(7), {1});
      final keys = SkipKeys.of(
          cursor: c, hole: 7, players: card, activeIdx: hot, scores: scores);
      expect(keys.label, 'Skip to Dave ›');
      expect(keys.skippedNow, isTrue);
    });

    test('only the golfer left is skipped, not the ones passed over', () {
      final c = SkipCursor()..tapTo(7, from: 1, to: 3, owes: owes({}));
      expect(c.skippedOn(7), {1});
    });

    test('opening a scored golfer skips nobody', () {
      final c = SkipCursor()..tapTo(7, from: 1, to: 3, owes: owes({3}));
      expect(c.skippedOn(7), isEmpty);
    });

    test('leaving a scored golfer skips nobody', () {
      final c = SkipCursor()..tapTo(7, from: 3, to: 1, owes: owes({3}));
      expect(c.skippedOn(7), isEmpty);
    });

    test('the golfer already there, or nobody there, skips nobody', () {
      final c = SkipCursor()
        ..tapTo(7, from: 2, to: 2, owes: owes({}))
        ..tapTo(7, from: null, to: 2, owes: owes({}));
      expect(c.skippedOn(7), isEmpty);
    });
  });

  // The whole row takes the tap, scored or not, on every screen.
  group('every screen lets an unscored golfer be tapped', () {
    const screens = [
      'score_entry', 'wolf', 'rabbit', 'survivor', 'points_531',
      'sequoya_threes', 'triple_nassau', 'nassau', 'pink_ball',
    ];
    for (final name in screens) {
      test(name, () {
        final src =
            File('lib/screens/${name}_screen.dart').readAsStringSync();
        expect(src.contains('gross != null && !isHot'), isFalse);
        expect(src.contains('hasScore && !isHot'), isFalse);
      });
    }

    test('score entry blocks the resting partner and unassigned teams', () {
      final src =
          File('lib/screens/score_entry_screen.dart').readAsStringSync();
      final at = src.indexOf('final VoidCallback? rowTap');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf(';', at));
      for (final rule in ['!withdrawn', '!dimmed', '!isHot',
          'blockedExtraSeg == null', 'pickedUp']) {
        expect(body, contains(rule));
      }
    });
  });
}
