import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/game_settings_strip.dart';

void main() {
  group('the reader', () {
    test('takes the server\'s strings verbatim', () {
      expect(settingsChipsOf({'settings': ['Net 90%', 'Claremont']}),
          ['Net 90%', 'Claremont']);
    });

    test('a block with none is empty, not null', () {
      expect(settingsChipsOf({'label': 'Spots'}), isEmpty);
      expect(settingsChipsOf(null), isEmpty);
      expect(settingsChipsOf({'settings': 'nonsense'}), isEmpty);
    });

    test('drops anything that is not a non-empty string', () {
      expect(settingsChipsOf({'settings': ['Net', '', 7, null, 'Pool']}),
          ['Net', 'Pool']);
    });
  });

  group('the strip', () {
    testWidgets('draws one chip per setting, in the order given', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: GameSettingsStrip(['Net 90%', 'Claremont', 'Auto presses']),
        ),
      ));
      expect(find.text('Net 90%'), findsOneWidget);
      expect(find.text('Claremont'), findsOneWidget);
      expect(find.text('Auto presses'), findsOneWidget);
      // Order is the server's; the strip never sorts.
      final dx = <double>[
        for (final s in ['Net 90%', 'Claremont', 'Auto presses'])
          t.getTopLeft(find.text(s)).dx,
      ];
      expect(dx[0] < dx[1] && dx[1] < dx[2], isTrue);
    });

    testWidgets('nothing to say draws nothing at all', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: GameSettingsStrip([])),
      ));
      expect(find.byType(Wrap), findsNothing);
    });

    testWidgets('a long list wraps rather than overflowing', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: GameSettingsStrip([
            'Strokes off 90%', 'Claremont', 'Manual + auto presses',
            'Carries on', 'Against the average', 'Loses at most \$20',
          ]),
        ),
      ));
      expect(tester_hasOverflow(t), isFalse);
    });
  });

  group('one writer', () {
    test('the leaderboard never spells a setting itself', () {
      // The words belong to `services/game_settings.py`. A board that typed
      // them would be a second place naming handicap modes, which is the
      // failure `gross_to_par` and the skins rules chip both record.
      final src = File('lib/screens/leaderboard_screen.dart')
          .readAsStringSync();
      for (final typed in [
        "'Auto presses'", "'Manual presses'", "'Carries on'", "'No carry'",
        "'Pay the leader'", "'Against the average'", "'Pay everyone above'",
        "'Loses at most", "'Strokes off '",
      ]) {
        expect(src.contains(typed), isFalse,
            reason: 'the board is naming a setting itself: $typed');
      }
      expect(src.contains('settingsChipsOf('), isTrue);
    });

    test('the strip reads a list and formats no values', () {
      final src = File('lib/widgets/game_settings_strip.dart')
          .readAsStringSync();
      // No percentages, no money, no slug tables: a formatter here would be
      // a second opinion about words the server already chose.
      expect(src.contains('%'), isFalse);
      expect(src.contains('toStringAsFixed'), isFalse);
    });
  });
}

bool tester_hasOverflow(WidgetTester t) =>
    t.takeException() != null;
