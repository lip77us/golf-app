import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/pair_drive_card.dart';

FourballHoleCard _card({int? picked}) => FourballHoleCard.fromJson({
      'hole': 3, 'ball_format': 'scramble',
      'players': [
        for (final (i, n) in ['Ann', 'Bo', 'Cy', 'Di'].indexed)
          {'player_id': i + 1, 'name': n, 'short': n, 'first': n, 'side': i < 2 ? 1 : 2}
      ],
      'drive': {
        'rule': 'per_nine',
        'sides': [
          {'side': 1, 'picked': picked, 'line': 'Ann 0 · Bo 0 — 2 owed, 7 free',
           'warn': false, 'player_ids': [1, 2]},
          {'side': 2, 'picked': null, 'line': 'Cy 0 · Di 0 — every hole left is owed',
           'warn': true, 'player_ids': [3, 4]},
        ],
      },
    });

Future<void> _pump(WidgetTester t, FourballHoleCard c,
    List<(int, int?)> log) async {
  await t.pumpWidget(MaterialApp(
      home: Scaffold(body: PairDriveCard(
          card: c, onPick: (s, p) => log.add((s, p))))));
}

void main() {
  testWidgets('tapping a golfer picks him for that side', (t) async {
    final log = <(int, int?)>[];
    await _pump(t, _card(), log);
    await t.tap(find.byKey(const ValueKey('drive-1-2')));
    expect(log, [(1, 2)]);
  });

  testWidgets('tapping the chosen golfer again clears the pick', (t) async {
    final log = <(int, int?)>[];
    await _pump(t, _card(picked: 2), log);
    await t.tap(find.byKey(const ValueKey('drive-1-2')));
    expect(log, [(1, null)]);
  });

  testWidgets('the server\'s sentence is shown, and a warning is amber', (t) async {
    await _pump(t, _card(), []);
    expect(find.text('Ann 0 · Bo 0 — 2 owed, 7 free'), findsOneWidget);
    final warn = t.widget<Text>(find.byKey(const ValueKey('drive-line-2')));
    expect(warn.style!.color, const Color(0xFF9A5B00));
  });

  test('the setup screen posts the rule and the count, scramble only', () {
    final src = File('lib/screens/fourball_setup_screen.dart').readAsStringSync();
    expect(src, contains("driveRule: _format == 'scramble' ? _driveRule : 'none'"));
    expect(src, contains('drivesRequired: _drivesEach'));
  });

  test('score entry draws the picker for a scramble card only', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();
    expect(src, contains("c.ballFormat == 'scramble' && c.drive != null"));
    expect(src, contains('PairDriveCard('));
  });
}
