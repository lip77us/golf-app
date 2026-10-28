import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/skin_rules_display.dart';

void main() {
  group('skinRuleChips — the server supplies the words', () {
    test('plain skins draws nothing', () {
      expect(skinRuleChips(''), isEmpty);
      expect(skinRuleChips('   '), isEmpty);
    });

    test('one rule is one chip', () {
      expect(skinRuleChips('net par or better to win'),
             ['Net par or better to win']);
    });

    test('two rules split on the server middot', () {
      expect(
        skinRuleChips('gross par or better to win · gross birdies steal'),
        ['Gross par or better to win', 'Gross birdies steal'],
      );
    });

    test('the steal alone', () {
      expect(skinRuleChips('gross birdies steal'), ['Gross birdies steal']);
    });

    test('it does not invent wording of its own', () {
      // Whatever the server says is what shows, capitalised for a pill and
      // otherwise untouched -- so the board can never disagree with the
      // engine about what is being played.
      expect(skinRuleChips('something nobody has written yet'),
             ['Something nobody has written yet']);
    });

    test('empty segments are dropped rather than drawn as blank pills', () {
      expect(skinRuleChips('a ·  · b'), ['A', 'B']);
    });
  });

  group('skinRuleNote — the consequence, not the setting', () {
    test('a minimum means a hole can go unwon', () {
      for (final m in ['net_par', 'gross_par']) {
        expect(skinRuleNote(minimum: m, birdieSteal: false),
               'A hole where nobody qualifies goes unwon.',
               reason: m);
      }
    });

    test('the minimum outranks the steal in the note', () {
      // Both on: the unwon hole is the surprising one, and a natural birdie
      // clears any minimum anyway, so the steal never causes an unwon hole.
      expect(skinRuleNote(minimum: 'gross_par', birdieSteal: true),
             contains('goes unwon'));
    });

    test('the steal alone says what it does', () {
      expect(skinRuleNote(minimum: 'none', birdieSteal: true),
             'A gross birdie beats a lower net score.');
    });

    test('plain skins says nothing at all', () {
      expect(skinRuleNote(minimum: 'none', birdieSteal: false), '');
    });

    test('an unknown minimum is treated as none', () {
      expect(skinRuleNote(minimum: 'eagle_or_better', birdieSteal: false), '');
    });
  });

  group('both skins boards show it', () {
    // The per-foursome card and the cross-group pool are different widgets
    // over the same three summary keys, and this repo's recurring failure is
    // a thing reachable on one surface and not its twin.
    test('the card and the pool both render _SkinRulesInPlay', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      // Once for the class, once per board.
      final uses = '_SkinRulesInPlay(summary:'.allMatches(src).length;
      expect(uses, 2,
          reason: 'expected the per-foursome card AND the pool to render it');
    });

    test('it reads the server phrase rather than rebuilding it', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect(src.contains('skinRuleChips('), isTrue);
      // The old hand-written labels must not come back.
      expect(src.contains("'Net par or better'"), isFalse,
          reason: 'the board is naming the rules itself again');
    });
  });
}
