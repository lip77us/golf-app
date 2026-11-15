import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/reveal_on_mount.dart';

void main() {
  const rowHeight = 100.0;

  Widget list(ScrollController c, int active) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: SingleChildScrollView(
              controller: c,
              child: Column(children: [
                for (var i = 0; i < 6; i++)
                  i == active
                      ? RevealOnMount(
                          key: ValueKey('hot-$i'),
                          child: const SizedBox(height: rowHeight))
                      : const SizedBox(height: rowHeight),
              ]),
            ),
          ),
        ),
      );

  testWidgets('a row in view does not move the list', (t) async {
    final c = ScrollController();
    await t.pumpWidget(list(c, 1));
    await t.pumpAndSettle();
    expect(c.offset, 0);
  });

  testWidgets('a row under the keypad scrolls up into view', (t) async {
    final c = ScrollController();
    await t.pumpWidget(list(c, 0));
    await t.pumpAndSettle();
    await t.pumpWidget(list(c, 4));
    await t.pumpAndSettle();
    expect(c.offset, 200, reason: 'row 5 ends at 500 in a 300 viewport');
  });

  testWidgets('going back to the first golfer scrolls back down', (t) async {
    final c = ScrollController();
    await t.pumpWidget(list(c, 5));
    await t.pumpAndSettle();
    expect(c.offset, 300);
    await t.pumpWidget(list(c, 0));
    await t.pumpAndSettle();
    expect(c.offset, 0);
  });

  test('score entry keys the reveal on the hole and the golfer', () {
    final src =
        File('lib/screens/score_entry_screen.dart').readAsStringSync();
    expect(src, contains("RevealOnMount(\n"));
    expect(src, contains(r"ValueKey('entry-$holeNumber-${m.player.id}')"));
  });

  // The dedicated play screens draw their own rows, so each has to ask for
  // the reveal itself — the fourth golfer sat under the keypad on Sequoya 3s
  // (Paul, 9 Nov 2026) on a screen built the same day.
  for (final f in [
    'screens/sequoya_threes_screen',
    'screens/wolf_screen',
    'screens/points_531_screen',
    // Rabbit and Survivor draw their rows in a card widget of their own.
    'widgets/rabbit_entry',
    'widgets/survivor_entry',
  ]) {
    test('$f reveals the golfer being scored', () {
      final src = File('lib/$f.dart').readAsStringSync();
      final at = src.indexOf('RevealOnMount(');
      expect(at, greaterThan(0), reason: 'the keypad can cover the row');
      final key = src.substring(at, src.indexOf('child:', at));
      expect(key, contains("ValueKey('entry-"));
    });
  }
}
