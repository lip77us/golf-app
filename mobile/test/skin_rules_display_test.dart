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

  group('skinRuleNote — the server\'s sentence, verbatim', () {
    // It used to derive the sentence from the slugs, which made the client a
    // second place the rule was worded. It was worded in FIVE, and by the
    // time Design read them they disagreed: the published note said a gross
    // birdie `beats a lower net score`, which the engine never did.
    test('it returns what the server sent', () {
      expect(skinRuleNote('A hole where nobody qualifies goes unwon.'),
             'A hole where nobody qualifies goes unwon.');
      expect(skinRuleNote('A gross birdie beats a net birdie, not a net eagle.'),
             'A gross birdie beats a net birdie, not a net eagle.');
    });

    test('nothing sent is nothing drawn', () {
      expect(skinRuleNote(null), '');
      expect(skinRuleNote(''), '');
      expect(skinRuleNote('   '), '');
    });
  });

  group('skinRuleCopy — the catalogue, for options not yet chosen', () {
    final catalogue = [
      {'key': 'net_par', 'label': 'Net par or better to win',
       'note': 'A hole where nobody qualifies goes unwon.'},
      {'key': 'birdie_steal', 'label': 'Gross birdies steal',
       'note': 'A gross birdie beats a net birdie, not a net eagle.'},
    ];

    test('finds an option by the server\'s own key', () {
      expect(skinRuleCopy(catalogue, 'birdie_steal')?['label'],
             'Gross birdies steal');
      expect(skinRuleCopy(catalogue, 'birdie_steal')?['note'],
             'A gross birdie beats a net birdie, not a net eagle.');
    });

    test('null for an option the server did not send', () {
      expect(skinRuleCopy(catalogue, 'gross_par'), isNull);
      expect(skinRuleCopy(null, 'birdie_steal'), isNull,
             reason: 'no catalogue is different from an empty option');
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

    test('the consequence is ASKED FOR, and spelled nowhere', () {
      // It began as a const in the widget, which is how a round playing the
      // gross steal alone got told its holes could go unwon over a
      // qualification it had not switched on. Deriving it in
      // `skin_rules_display` fixed that and left the client as one of FIVE
      // places the rules were worded — and by the time Design read them they
      // disagreed: the published note said a gross birdie `beats a lower net
      // score`, which the engine never did. `services/skin_rules.py` writes
      // every one of these sentences now.
      final src = File('lib/widgets/skins_board.dart').readAsStringSync();
      expect(src.contains('skinRuleNote('), isTrue,
          reason: 'the board must ask for the consequence, not spell it');

      for (final f in [
        'lib/widgets/skins_board.dart',
        'lib/utils/skin_rules_display.dart',
        'lib/widgets/skin_validation_card.dart',
        'lib/api/client.dart',
      ]) {
        final body = File(f).readAsStringSync();
        for (final sentence in [
          "'A hole where nobody qualifies",
          "'A gross birdie beats",
          "'A real birdie beats",
          "beats a lower net score'",
          "beats any net score'",
        ]) {
          expect(body.contains(sentence), isFalse,
              reason: '$f still writes a rule the server owns: $sentence');
        }
      }
    });

    test('the setup card reads the catalogue, and is given one', () {
      // A card with no catalogue draws no sentence at all, which reads as a
      // design choice rather than a missing wire.
      final card =
          File('lib/widgets/skin_validation_card.dart').readAsStringSync();
      expect(card.contains('skinRuleCopy(ruleCopy'), isTrue);
      for (final f in [
        'lib/screens/skins_setup_screen.dart',
        'lib/screens/multi_skins_setup_screen.dart',
      ]) {
        expect(File(f).readAsStringSync().contains('ruleCopy:'), isTrue,
            reason: f);
      }
    });
  });
}
