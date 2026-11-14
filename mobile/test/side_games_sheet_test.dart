/// The More side games sheet, and the casual screen's side-game row.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/widgets/side_games_sheet.dart';

void main() {
  final games = [
    for (final id in ['nassau', 'honors', 'stableford']) gameMeta(id)!
  ];

  Future<Set<String>> open(WidgetTester t, Set<String> start,
      {Set<String> Function(String, bool)? toggle}) async {
    final live = {...start};
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => showSideGamesSheet(c,
                games: games,
                selected: live,
                onToggle: toggle ??
                    (id, picked) {
                      picked ? live.add(id) : live.remove(id);
                      return {...live};
                    }),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    return live;
  }

  testWidgets('lists each game with its one-line description', (t) async {
    await open(t, {});
    expect(find.text('More side games'), findsOneWidget);
    expect(find.text('Honors'), findsOneWidget);
    expect(find.text('Hold the honor, earn the point'), findsOneWidget);
  });

  testWidgets('a tap ticks, a second tap unticks, and it stays open',
      (t) async {
    final live = await open(t, {});
    await t.tap(find.text('Honors'));
    await t.pumpAndSettle();
    expect(live, {'honors'});
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.text('More side games'), findsOneWidget,
        reason: 'side games are any number, so the sheet does not close');
    await t.tap(find.text('Honors'));
    await t.pumpAndSettle();
    expect(live, isEmpty);
  });

  testWidgets('what is already ticked shows ticked', (t) async {
    await open(t, {'stableford'});
    expect(find.byIcon(Icons.check_box), findsOneWidget);
  });

  testWidgets('the sheet draws what the screen says, not what it asked for',
      (t) async {
    // The screen owns the conflict rule: here it refuses the tick outright.
    await open(t, {}, toggle: (id, picked) => <String>{});
    await t.tap(find.text('Honors'));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.check_box), findsNothing);
  });

  testWidgets('Done closes it', (t) async {
    await open(t, {});
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(find.text('More side games'), findsNothing);
  });

  group('the casual screen', () {
    final src = File('lib/screens/casual_round_screen.dart').readAsStringSync();

    test('the row is the pinned chips, ticked others, then the sheet', () {
      expect(src, contains('splitSideGames(_eligibleSideGames, _primaryGame)'));
      expect(src, contains("label: 'More side games'"));
      // Only when something is behind it — an empty sheet is a dead chip.
      expect(src, contains('if (split.other.isNotEmpty)'));
      expect(src, contains('children: _sideChips()'));
    });

    test('the chips and the sheet share one toggle', () {
      expect(src, contains('onSelected: (picked) => setState(() => _setSide('));
      expect(src, contains('setState(() => _setSide(id, picked))'));
    });
  });
}
