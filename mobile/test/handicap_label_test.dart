import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/handicap_label.dart';

/// One composer, five boards.
///
/// Stroke Play showed the index alone and the other four named nothing, so a
/// net figure could not be checked against anything (Paul, 31 Oct 2026). The
/// label is written in one place because five copies of it is how they come
/// to disagree about what a middot separates.
void main() {
  group('the label', () {
    test('names both when both are known', () {
      expect(handicapLabel(index: '16.2', courseHandicap: 14),
          '16.2 · CH 14');
    });

    test('an older payload with no index still names the CH', () {
      expect(handicapLabel(index: '', courseHandicap: 14), 'CH 14');
      expect(handicapLabel(index: null, courseHandicap: 14), 'CH 14');
    });

    test('no CH leaves the index alone rather than inventing one', () {
      // `CH 0` is a real handicap — scratch — so a missing one must not
      // render as zero.
      expect(handicapLabel(index: '16.2', courseHandicap: null), '16.2');
    });

    test('scratch is a number, not an absence', () {
      expect(handicapLabel(index: '0.4', courseHandicap: 0), '0.4 · CH 0');
    });

    test('neither known is empty, so a board can test it', () {
      expect(handicapLabel(index: '', courseHandicap: null), '');
    });

    test('whitespace from the server is not a label', () {
      expect(handicapLabel(index: '  ', courseHandicap: null), '');
    });
  });

  group('every board composes through it', () {
    const boards = <String, String>{
      'points': 'lib/utils/points_board_model.dart',
      'skins': 'lib/utils/skins_board_model.dart',
      'rabbit': 'lib/utils/rabbit_board_model.dart',
      'nassau': 'lib/utils/nassau_board_model.dart',
      'stroke play': 'lib/screens/leaderboard_screen.dart',
    };

    for (final e in boards.entries) {
      test('${e.key} calls the shared composer', () {
        final src = File(e.value).readAsStringSync();
        expect(src, contains('handicapLabel('),
            reason: '${e.key} must not spell the label itself');
        expect(src, contains("handicap_label.dart"),
            reason: '${e.key} must import the one place it lives');
      });
    }

    test('nobody writes their own middot label', () {
      // The shape that would drift: a board composing `"$index · CH $ch"`
      // on its own.
      for (final f in boards.values) {
        final src = File(f).readAsStringSync();
        expect(RegExp(r"'\$\w+ · CH ").hasMatch(src), isFalse,
            reason: '$f composes a handicap label by hand');
      }
    });
  });
}
