import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';

void main() {
  group('Claremont is its own game in the picker', () {
    test('four golfers only', () {
      final m = gameMeta(GameIds.claremont)!;
      for (final n in [2, 3, 5, 6]) {
        expect(m.supportsSize(n), isFalse, reason: '$n');
      }
      expect(m.supportsSize(4), isTrue);
    });

    test('it cannot run beside Nassau or Nassau Nine, in either direction', () {
      for (final other in [GameIds.nassau, GameIds.nassauNine]) {
        expect(gamesCompatible(GameIds.claremont, other), isFalse);
        expect(gamesCompatible(other, GameIds.claremont), isFalse);
      }
    });
  });

  group('wiring', () {
    final create =
        File('lib/utils/create_casual_round.dart').readAsStringSync();
    final setup =
        File('lib/screens/nassau_setup_screen.dart').readAsStringSync();

    test('a round is stored as a Nassau, never as claremont', () {
      expect(create, contains('g == GameIds.claremont ? GameIds.nassau : g'));
    });

    test('setup posts the variant, automatic presses and no cap', () {
      expect(setup, contains("? 'claremont'"));
      expect(setup, contains("_claremont ? 'auto' : _pressMode"));
      expect(setup, contains('!_claremont && _canEscalate && _capEnabled'));
    });

    test('Nassau no longer offers Claremont as a variant', () {
      expect(setup, isNot(contains("_variantChip('claremont'")));
      expect(setup, contains("'2nd-ball tiebreak'"));
    });
  });
}
