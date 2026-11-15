// Picking one thing from a list that may be long.
//
// "add a golfer is just the list with no search. tough with 200 players in my
// membership" (Paul, 4 Nov 2026) — the sheet beside the one that had just been
// given a scroll, a Cancel, a cap and a search. So the four of them live in
// one widget now and the next long list cannot be built without them.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/pick_sheet.dart';

void main() {
  /// Open a sheet over an otherwise empty screen and report what it returned.
  /// `null` means dismissed — and a test for a sheet has to be able to tell
  /// that apart from "not answered yet", so the result is boxed.
  Future<List<String?>> open(
    WidgetTester t,
    List<PickOption<String>> options, {
    List<PickOption<String>> pinned = const [],
    String Function(String)? emptyText,
  }) async {
    final out = <String?>[];
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async => out.add(await pickFromSheet<String>(
              ctx,
              title: 'Move Golfer 01',
              options: options,
              pinned: pinned,
              emptyText: emptyText,
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    return out;
  }

  // The query text lives in the TextField, so a finder for a row whose title
  // the query spells out matches the field too.
  Finder inList(String text) =>
      find.descendant(of: find.byType(ListView), matching: find.text(text));

  List<PickOption<String>> many(int n) => [
        for (var i = 1; i <= n; i++)
          PickOption(value: 'g$i', title: 'Group $i'),
      ];

  testWidgets('a 200-row list is searchable, not just scrollable', (t) async {
    final out = await open(t, many(200));
    await t.enterText(find.byType(TextField), 'Group 137');
    await t.pumpAndSettle();
    expect(inList('Group 137'), findsOneWidget);
    expect(inList('Group 138'), findsNothing);
    await t.tap(inList('Group 137'));
    await t.pumpAndSettle();
    expect(out, ['g137']);
  });

  testWidgets('and the rows that are there can be reached by thumb', (t) async {
    // The original bug: a Column in a bottom sheet does not scroll, it
    // overflows, and every row past the fold is untappable.
    final out = await open(t, many(20));
    final list = find.descendant(
        of: find.byType(ListView), matching: find.byType(Scrollable));
    // scrollUntilVisible is satisfied as soon as the row is BUILT, and a
    // ListView builds a cache extent beyond the viewport — so it can stop
    // with the row still off-screen. ensureVisible is what brings it in.
    await t.scrollUntilVisible(find.text('Group 20'), 200, scrollable: list);
    await t.ensureVisible(find.text('Group 20'));
    await t.pumpAndSettle();
    await t.tap(find.text('Group 20'));
    await t.pumpAndSettle();
    expect(out, ['g20']);
  });

  testWidgets('no search when the whole list fits', (t) async {
    await open(t, many(8));
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('Cancel answers nothing at all', (t) async {
    final out = await open(t, many(3));
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(out, [null]);
  });

  testWidgets('a pinned row sits above the list and survives a search',
      (t) async {
    // It is not one of the many — below a 200-row list it would be exactly as
    // unreachable as the bottom row was, and filtering it out would hide the
    // one option that is always valid.
    final out = await open(t, many(30), pinned: [
      const PickOption(value: 'own', title: 'A card of his own'),
    ]);
    final at = t.getTopLeft(find.text('A card of his own')).dy;
    expect(at, lessThan(t.getTopLeft(find.text('Group 1')).dy));

    // OUTSIDE the scroll, which is the half that matters: a pinned row that
    // merely starts at the top of a 200-row list is gone the moment somebody
    // scrolls, which is exactly when they still need it.
    await t.drag(find.byType(ListView), const Offset(0, -2000));
    await t.pumpAndSettle();
    expect(find.text('Group 1'), findsNothing);
    expect(t.getTopLeft(find.text('A card of his own')).dy, at);

    await t.enterText(find.byType(TextField), 'Group 7');
    await t.pumpAndSettle();
    expect(find.text('A card of his own'), findsOneWidget);
    await t.tap(find.text('A card of his own'));
    await t.pumpAndSettle();
    expect(out, ['own']);
  });

  testWidgets('a row that cannot be chosen still answers the search',
      (t) async {
    // Hiding a full group would read as the group not existing, which sends
    // somebody looking for it.
    final out = await open(t, [
      ...many(10),
      const PickOption(
          value: 'full',
          title: 'Group 11',
          enabled: false,
          trailing: Text('Full')),
    ]);
    await t.enterText(find.byType(TextField), 'Group 11');
    await t.pumpAndSettle();
    expect(inList('Group 11'), findsOneWidget);
    expect(find.text('Full'), findsOneWidget);
    await t.tap(inList('Group 11'));
    await t.pumpAndSettle();
    expect(out, isEmpty, reason: 'a disabled row is shown, not choosable');
  });

  testWidgets('a search that matches nothing says so in the caller\'s words',
      (t) async {
    await open(t, many(30),
        emptyText: (q) => 'No group has a golfer called "$q".');
    await t.enterText(find.byType(TextField), 'Zeno');
    await t.pumpAndSettle();
    expect(find.text('No group has a golfer called "Zeno".'), findsOneWidget);
  });

  testWidgets('the search reads a row\'s own search text', (t) async {
    // A group's subtitle carries SHORT names, because four full ones do not
    // fit; the search has to read the full ones or a golfer cannot be found
    // by his own name.
    final out = await open(t, [
      ...many(10),
      const PickOption(
          value: 'g11',
          title: 'Group 11',
          subtitle: 'W Dom',
          searchText: 'Wendell Doman'),
    ]);
    await t.enterText(find.byType(TextField), 'doman');
    await t.pumpAndSettle();
    expect(find.text('Group 11'), findsOneWidget);
    await t.tap(find.text('Group 11'));
    await t.pumpAndSettle();
    expect(out, ['g11']);
  });

  group('one writer', () {
    // Both sheets that list a roster-length anything go through it, so the
    // four things it owns cannot be half-present on one of them again.
    for (final f in const [
      'lib/widgets/scorecard_groups.dart',
      'lib/screens/round_groups_screen.dart',
    ]) {
      test('$f does not build its own sheet', () {
        final src = File(f).readAsStringSync();
        expect(src.contains('pickFromSheet'), isTrue);
        expect(src.contains('showModalBottomSheet'), isFalse,
            reason: 'isScrollControlled is a flag a call site forgets');
      });
    }
  });
}
