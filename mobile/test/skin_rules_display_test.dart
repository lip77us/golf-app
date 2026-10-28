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

  group('the board shows it', () {
    // This began as its own chip on each of the two skins cards.  The rules
    // now live INSIDE `SkinsBoard`, under its HOLES grid, because that is
    // what they are a footnote on — and because both cards draw that one
    // board, they still reach every skins surface.  `skins_board_test`
    // asserts the two cards render it; this asserts the board renders the
    // rules the right way.
    test('SkinsBoard reads the server phrase rather than rebuilding it', () {
      final src = File('lib/widgets/skins_board.dart').readAsStringSync();
      expect(src.contains('skinRuleChips('), isTrue,
          reason: 'the board is not using the server phrase');
      // The hand-written labels must not come back.
      for (final typed in ["'Net par or better'", "'Gross par or better'",
                           "'Gross birdies steal'"]) {
        expect(src.contains(typed), isFalse,
            reason: 'the board is naming the rules itself again: $typed');
      }
    });

    test('the consequence is stated with them', () {
      final src = File('lib/widgets/skins_board.dart').readAsStringSync();
      expect(src.contains('goes unwon'), isTrue);
    });
  });
}
