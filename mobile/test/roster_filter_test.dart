/// test/roster_filter_test.dart
/// ---------------------------
/// The player picker's roster filter (Downloads/handoff-select-players §1–2).
///
/// The Favorites flag and its filter were REMOVED on 14 Nov 2026: the Add
/// players screen's regulars come from rounds played, and two ways to mark the
/// same golfers was confusing. What is pinned here is what is left — a filter
/// never touches the selection, search composes with the filter instead of
/// replacing it, and the order handed in is the order handed back — plus a
/// guard that the flag does not quietly come back.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/roster_sections.dart';
import 'package:golf_mobile/widgets/roster_filter.dart';

PlayerProfile golfer(int id, String name, {bool onApp = false}) =>
    PlayerProfile(
      id: id,
      name: name,
      handicapIndex: '10.0',
      isPhantom: false,
      email: '',
      isOnApp: onApp,
    );

/// Alphabetical, which is the order the screen hands in for these cases.
final roster = [
  golfer(1, 'Al Bronson', onApp: true),
  golfer(2, 'Alan Petersen'),
  golfer(3, 'Dave Moran', onApp: true),
  golfer(4, 'Ray Okafor'),
  golfer(5, 'Sam Reid', onApp: true),
];

List<String> namesIn(RosterSection s) => s.players.map((p) => p.name).toList();

void main() {
  group('the two cuts', () {
    test('All is everyone, A–Z, in the one section', () {
      final sections = rosterSections(filter: RosterFilter.all, roster: roster);
      expect(sections.map((s) => s.label), ['All golfers']);
      expect(sections.single.trailing, 'A – Z');
      expect(namesIn(sections.single), roster.map((p) => p.name).toList());
    });

    test('On Halved is the accounts, and says how many', () {
      final sections =
          rosterSections(filter: RosterFilter.onHalved, roster: roster);
      expect(namesIn(sections.single),
          ['Al Bronson', 'Dave Moran', 'Sam Reid']);
      expect(sections.single.trailing, '3');
    });
  });

  group('search and filter compose', () {
    test('typing inside a filter searches that filter only', () {
      final sections = rosterSections(
        filter: RosterFilter.onHalved,
        roster: roster,
        query: 'al',
      );
      // Alan Petersen matches the text but is not on Halved.
      expect(namesIn(sections.single), ['Al Bronson']);
    });

    test('a search that empties a filter comes back empty, not unfiltered', () {
      final sections = rosterSections(
        filter: RosterFilter.onHalved,
        roster: roster,
        query: 'okafor',
      );
      expect(sections.single.players, isEmpty);
    });

    test('the query is trimmed and case-insensitive', () {
      final sections = rosterSections(
        filter: RosterFilter.all,
        roster: roster,
        query: '  MORAN ',
      );
      expect(namesIn(sections.single), ['Dave Moran']);
    });
  });

  test('the roster order handed in is the order handed back', () {
    // The screen floats selected golfers (and You) to the top; sectioning must
    // not quietly re-sort underneath that.
    final selectedFirst = [roster[4], roster[0], roster[1], roster[2], roster[3]];
    final sections =
        rosterSections(filter: RosterFilter.all, roster: selectedFirst);
    expect(namesIn(sections.single),
        selectedFirst.map((p) => p.name).toList());
  });

  group('the chip row', () {
    testWidgets('states the count of each filter before it is tapped',
        (tester) async {
      RosterFilter? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RosterFilterChips(
            value: RosterFilter.all,
            onChanged: (f) => picked = f,
            allCount: 128,
            onHalvedCount: 46,
          ),
        ),
      ));

      // A filter that could empty the list has to say so before it is tapped.
      expect(find.text('128'), findsOneWidget);
      expect(find.text('46'), findsOneWidget);

      await tester.tap(find.text('On Halved'));
      expect(picked, RosterFilter.onHalved);
    });

    testWidgets('there is no Favorites chip', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RosterFilterChips(
              value: RosterFilter.all,
              onChanged: (_) {},
              allCount: 1,
              onHalvedCount: 0),
        ),
      ));
      expect(find.text('Favorites'), findsNothing);
      expect(RosterFilter.values, [RosterFilter.all, RosterFilter.onHalved]);
    });
  });

  group('the favorites flag stays removed', () {
    // Two ways to mark the same golfers was confusing, so there is none. The
    // server's endpoint and field remain for the shipped builds that call
    // them; nothing in THIS app may.
    final offenders = <String>[];
    final pattern = RegExp(
        r'setPlayerFavorite|FavoriteFlag|PinFlagGlyph|isFavorite|'
        r'RosterFilter\.favorites|_favoriteIds|/favorite/');
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) {
        if (pattern.hasMatch(f.readAsStringSync())) offenders.add(f.path);
      }
    }

    test('no screen, widget or client call references it', () {
      expect(offenders, isEmpty, reason: offenders.join(', '));
    });

    test('the flag widget is gone', () {
      expect(File('lib/widgets/favorite_flag.dart').existsSync(), isFalse);
    });
  });
}
