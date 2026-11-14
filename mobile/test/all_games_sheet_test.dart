/// The All games sheet (More games on New Round) and the rows behind it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/widgets/all_games_sheet.dart';

bool _fitsSize(String size, GameMeta m) {
  if (size == 'groups') return m.acrossGroups;
  if (m.acrossGroups) return false;
  if (size == 'solo') return m.supportsSize(1);
  if (size == kFiveOrSix) return fitsFiveOrSix(m);
  return m.supportsSize(int.parse(size));
}

List<AllGamesRow> rowsFor(String size, {bool partial = false}) =>
    buildAllGamesRows(
      sizeKey: size,
      fitsSize: (m) => _fitsSize(size, m),
      fitsRound: (m) => !(partial && m.requiresFullRound),
    );

/// Opens the sheet from a button and reports what it popped.
Future<String?> Function() harness(WidgetTester t, List<AllGamesRow> rows,
    {String? current, String size = '4'}) {
  String? result = '__open__';
  return () async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () async => result = await showAllGamesSheet(c,
                rows: rows, current: current, sizeKey: size),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    return result;
  };
}

void main() {
  group('the rows', () {
    test('games for this group come first, the rest are marked not for it', () {
      final rows = rowsFor('4');
      final firstUnfit =
          rows.indexWhere((r) => r.group != AllGamesGroup.playable);
      expect(firstUnfit, greaterThan(0));
      for (var i = 0; i < rows.length; i++) {
        expect(rows[i].playable, i < firstUnfit,
            reason: '${rows[i].name} is out of order');
      }
    });

    test('Singles Match is for two, not four-only; a foursome gets Sixes', () {
      final four = rowsFor('4');
      final byId = {for (final r in four) r.id: r};
      expect(byId['sixes']!.playable, isTrue);
      expect(byId['points_531']!.group, AllGamesGroup.notForGroup);
      final three = {for (final r in rowsFor('3')) r.id: r};
      expect(three['points_531']!.playable, isTrue);
      expect(three['sixes']!.group, AllGamesGroup.notForGroup);
    });

    test('catalog order is kept inside each group', () {
      final order = [for (final g in casualGames) g.id];
      final rows = rowsFor('4');
      for (final grp in AllGamesGroup.values) {
        final ids = [for (final r in rows) if (r.group == grp) r.id];
        final idx = ids.map(order.indexOf).toList();
        expect(idx, [...idx]..sort(), reason: '$grp');
      }
    });

    test('a side-game-only game is never a primary candidate', () {
      final ids = rowsFor('4').map((r) => r.id);
      expect(ids, isNot(contains('spots')));
      expect(ids, isNot(contains('honors')));
    });

    test('one-golfer games stay off every sheet but solo', () {
      for (final size in ['2', '3', '4', kFiveOrSix, 'groups']) {
        final ids = rowsFor(size).map((r) => r.id);
        expect(ids, isNot(contains('solo_stroke')), reason: size);
        expect(ids, isNot(contains('solo_nassau')), reason: size);
        expect(ids, isNot(contains('solo_match')), reason: size);
      }
      expect(rowsFor('solo').where((r) => r.playable).map((r) => r.id),
          containsAll(['solo_stroke', 'solo_nassau', 'solo_match']));
    });

    test('no two rows share a name', () {
      for (final size in ['solo', '2', '3', '4', kFiveOrSix, 'groups']) {
        final names = rowsFor(size).map((r) => r.name).toList();
        expect(names.toSet().length, names.length, reason: size);
      }
    });

    test('a short round puts segment games under their own label', () {
      final byId = {for (final r in rowsFor('4', partial: true)) r.id: r};
      expect(byId['sixes']!.group, AllGamesGroup.needsFullRound);
      expect(byId['wolf']!.playable, isTrue);
    });

    test('every row has a description and a player range', () {
      for (final r in rowsFor('4')) {
        expect(r.blurb, isNotEmpty, reason: '${r.id} has no summary');
        expect(r.range, isNotEmpty, reason: '${r.id} has no range');
      }
    });

    test('ranges read like the handoff', () {
      expect(playerRangeLabel(gameMeta('sixes')!), '4');
      expect(playerRangeLabel(gameMeta('skins')!), '2–4');
      expect(playerRangeLabel(gameMeta('annandale_friday')!), '5–6');
      expect(playerRangeLabel(gameMeta('multi_skins')!), 'Groups');
    });

    test('the label names the group', () {
      expect(notForLabel('4'), 'Not for four');
      expect(notForLabel('3'), 'Not for three');
      expect(notForLabel('2'), 'Not for two');
    });
  });

  group('search', () {
    final rows = rowsFor('4');

    test('filters on the name or the description, case-insensitive', () {
      final names = filterAllGames(rows, 'BA').map((r) => r.name).toList();
      expect(names, contains('Banker')); // the name
      expect(names, contains('Fourball')); // "Better ball"
      expect(names, contains('Nassau')); // "Front, back…"
    });

    test('an empty query keeps everything', () {
      expect(filterAllGames(rows, '  ').length, rows.length);
    });

    test('nothing matches nothing', () {
      expect(filterAllGames(rows, 'zzz'), isEmpty);
    });
  });

  group('the sheet', () {
    testWidgets('lists games and the heading, with Done', (t) async {
      await harness(t, rowsFor('4'))();
      expect(find.text('All games'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Sixes'), findsOneWidget);
    });

    testWidgets('a tap on a playable game picks it and closes', (t) async {
      String? got;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () async => got = await showAllGamesSheet(c,
                  rows: rowsFor('4'), current: 'nassau', sizeKey: '4'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Sixes'));
      await t.pumpAndSettle();
      expect(got, 'sixes');
      expect(find.text('All games'), findsNothing);
    });

    testWidgets('Done closes with no change', (t) async {
      String? got = 'untouched';
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () async => got = await showAllGamesSheet(c,
                  rows: rowsFor('4'), current: 'nassau', sizeKey: '4'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      expect(got, isNull);
    });

    testWidgets('a game that does not fit is under its label and inert',
        (t) async {
      String? got = 'untouched';
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () async => got = await showAllGamesSheet(c,
                  rows: rowsFor('3'), current: 'skins', sizeKey: '3'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      // Search down to a game for four, so it is on screen.
      await t.enterText(find.byType(TextField), 'sixes');
      await t.pumpAndSettle();
      expect(find.text('NOT FOR THREE'), findsOneWidget);
      await t.tap(find.text('Sixes'));
      await t.pumpAndSettle();
      expect(got, 'untouched', reason: 'a greyed game must not pick');
      expect(find.text('All games'), findsOneWidget,
          reason: 'and must not close the sheet');
    });

    testWidgets('search filters live and says so when nothing matches',
        (t) async {
      await harness(t, rowsFor('4'))();
      await t.enterText(find.byType(TextField), 'zzz');
      await t.pumpAndSettle();
      expect(find.text('NO GAME CALLED "ZZZ"'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'wolf');
      await t.pumpAndSettle();
      expect(find.text('Wolf'), findsOneWidget);
      expect(find.text('Sixes'), findsNothing);
    });

    testWidgets('the current primary is outlined in pine', (t) async {
      // Nassau and Sixes are both near the top of the catalog, so both are on
      // screen without scrolling the lazy list.
      await harness(t, rowsFor('4'), current: 'sixes')();
      final material = t.widget<Material>(find
          .ancestor(of: find.text('Sixes'), matching: find.byType(Material))
          .first);
      final shape = material.shape as RoundedRectangleBorder;
      expect(shape.side.color, const Color(0xFF0F6E56));
      final other = t.widget<Material>(find
          .ancestor(of: find.text('Nassau'), matching: find.byType(Material))
          .first);
      expect((other.shape as RoundedRectangleBorder).side.color,
          isNot(const Color(0xFF0F6E56)));
    });
  });
}
