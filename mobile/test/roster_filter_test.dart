/// test/roster_filter_test.dart
/// ---------------------------
/// The roster filter chips (still used by the invite-a-watcher sheet), and a
/// guard that the favorites flag stays removed.
///
/// The Favorites flag and its filter were REMOVED on 14 Nov 2026: the Add
/// players screen's regulars come from rounds played, and two ways to mark the
/// same golfers was confusing. The casual setup's own roster list, and the
/// sectioning rules that went with it, were removed the same day when Across
/// groups moved onto the Add players screen.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/roster_filter.dart';

void main() {
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
