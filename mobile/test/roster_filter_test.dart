/// test/roster_filter_test.dart
/// ---------------------------
/// The player picker's roster filters and the favorites flag
/// (Downloads/handoff-select-players §§1–5).
///
/// Three things here are easy to "fix" into wrongness later, so they are
/// pinned: favorites are PINNED under All rather than moved out of the
/// alphabet, a filter never touches the selection, and search composes with
/// the filter instead of replacing it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/roster_sections.dart';
import 'package:golf_mobile/widgets/favorite_flag.dart';
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

const favorites = {1, 3, 4}; // Al, Dave, Ray — Ray is a guest.

List<String> namesIn(RosterSection s) => s.players.map((p) => p.name).toList();

void main() {
  group('under All, favorites are pinned rather than moved', () {
    test('they appear twice — once at the top, once under their letter', () {
      final sections = rosterSections(
          filter: RosterFilter.all, roster: roster, shortlist: favorites);

      expect(sections.map((s) => s.label), ['Favorites', 'All golfers']);
      expect(namesIn(sections[0]), ['Al Bronson', 'Dave Moran', 'Ray Okafor']);
      // Somebody scrolling to M for Dave Moran must still find him under M.
      expect(namesIn(sections[1]), roster.map((p) => p.name).toList());
    });

    test('the pinned section carries its count', () {
      final sections = rosterSections(
          filter: RosterFilter.all, roster: roster, shortlist: favorites);
      expect(sections[0].trailing, '3');
      expect(sections[1].trailing, 'A – Z');
    });

    test('with no favorites there is no empty pinned section', () {
      final sections = rosterSections(
          filter: RosterFilter.all, roster: roster, shortlist: const {});
      expect(sections.map((s) => s.label), ['All golfers']);
    });
  });

  group('the two filters', () {
    test('Favorites is exactly the shortlist, guests included', () {
      final sections = rosterSections(
          filter: RosterFilter.favorites,
          roster: roster,
          shortlist: favorites);
      expect(sections.single.label, 'Your favorites');
      // Ray Okafor has no Halved account. A regular fourth who never signs up
      // is the case the filter exists for.
      expect(namesIn(sections.single),
          ['Al Bronson', 'Dave Moran', 'Ray Okafor']);
    });

    test('On Halved is the accounts, and says how many', () {
      final sections = rosterSections(
          filter: RosterFilter.onHalved,
          roster: roster,
          shortlist: favorites);
      expect(namesIn(sections.single),
          ['Al Bronson', 'Dave Moran', 'Sam Reid']);
      expect(sections.single.trailing, '3');
    });
  });

  group('search and filter compose', () {
    test('typing inside Favorites searches favorites only', () {
      final sections = rosterSections(
        filter: RosterFilter.favorites,
        roster: roster,
        shortlist: favorites,
        query: 'al',
      );
      // Alan Petersen matches the text but is not on the shortlist.
      expect(namesIn(sections.single), ['Al Bronson']);
    });

    test('a search that empties a filter comes back empty, not unfiltered', () {
      final sections = rosterSections(
        filter: RosterFilter.onHalved,
        roster: roster,
        shortlist: favorites,
        query: 'okafor',
      );
      expect(sections.single.players, isEmpty);
    });

    test('the query is trimmed and case-insensitive', () {
      final sections = rosterSections(
        filter: RosterFilter.all,
        roster: roster,
        shortlist: const {},
        query: '  MORAN ',
      );
      expect(namesIn(sections.single), ['Dave Moran']);
    });
  });

  test('the roster order handed in is the order handed back', () {
    // The screen floats selected golfers (and You) to the top; sectioning must
    // not quietly re-sort underneath that.
    final selectedFirst = [roster[4], roster[0], roster[1], roster[2], roster[3]];
    final sections = rosterSections(
        filter: RosterFilter.all,
        roster: selectedFirst,
        shortlist: const {});
    expect(namesIn(sections.single),
        selectedFirst.map((p) => p.name).toList());
  });

  group('the flag control', () {
    testWidgets('is a 44pt target and reports its state', (tester) async {
      var taps = 0;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FavoriteFlag(
            isFavorite: true,
            golferName: 'Dave Moran',
            onPressed: () => taps++,
          ),
        ),
      ));

      final box = tester.getSize(find.byType(FavoriteFlag));
      expect(box.width, greaterThanOrEqualTo(44));
      expect(box.height, greaterThanOrEqualTo(44));

      await tester.tap(find.byType(FavoriteFlag));
      expect(taps, 1);

      // The control says WHICH golfer it belongs to, not just "favorite".
      expect(find.bySemanticsLabel(RegExp('Dave Moran')), findsWidgets);
      semantics.dispose();
    });
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
            favoriteCount: 9,
            onHalvedCount: 46,
          ),
        ),
      ));

      // A filter that could empty the list has to say so before it is tapped.
      expect(find.text('128'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('46'), findsOneWidget);

      await tester.tap(find.text('Favorites'));
      expect(picked, RosterFilter.favorites);
    });
  });
}
