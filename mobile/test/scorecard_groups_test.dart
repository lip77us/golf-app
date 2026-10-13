// Who shares a scorecard, as the golfer sees it.
//
// The control this replaces was a per-golfer `G1 / G2` dropdown, dropped in
// July for being easy to miss — and its labels said nothing about who was
// already in G2, which is the only thing somebody deciding this cares about.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/scorecard_groups.dart';

PlayerProfile _p(int id, String name, {bool onApp = true}) => PlayerProfile(
      id: id,
      name: name,
      handicapIndex: '10.0',
      isPhantom: false,
      email: '',
      isOnApp: onApp,
    );

/// Paul's round: a foursome together, two individuals, a twosome.
final _eight = [
  _p(1, 'Ann Able'), _p(2, 'Ben Best'), _p(3, 'Cal Cole'), _p(4, 'Dee Dunn'),
  _p(5, 'Eve East'), _p(6, 'Fay Ford'), _p(7, 'Gus Gray'), _p(8, 'Hal Hunt'),
];
const _fourOneOneTwo = {1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 3, 7: 4, 8: 4};

Future<Map<int, int>?> _pump(WidgetTester t, List<PlayerProfile> players,
    Map<int, int> groups) async {
  Map<int, int>? out;
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ScorecardGroups(
          players: players,
          groups: groups,
          onChanged: (next) => out = next,
        ),
      ),
    ),
  ));
  return out;
}

void main() {
  testWidgets('the groups are labelled by position and sized out loud',
      (t) async {
    await _pump(t, _eight, _fourOneOneTwo);
    expect(find.text('Group 1'), findsOneWidget);
    expect(find.text('Group 4'), findsOneWidget);
    expect(find.text('4 golfers · one card'), findsOneWidget);
    expect(find.text('2 golfers · one card'), findsOneWidget);
    expect(find.text('own card'), findsNWidgets(2));
  });

  testWidgets('a gap in the numbers does not reach the labels', (t) async {
    // Moving the last golfer off card 2 leaves 1 and 3 stored.
    await _pump(t, [_eight[0], _eight[1]], {1: 1, 2: 3});
    expect(find.text('Group 1'), findsOneWidget);
    expect(find.text('Group 2'), findsOneWidget);
    expect(find.text('Group 3'), findsNothing);
  });

  testWidgets('every golfer has a way out', (t) async {
    await _pump(t, _eight, _fourOneOneTwo);
    expect(find.text('Move'), findsNWidgets(8));
  });

  testWidgets('the move sheet names who is already on each group', (t) async {
    await _pump(t, _eight, _fourOneOneTwo);
    await t.tap(find.text('Move').last);
    await t.pumpAndSettle();
    expect(find.text('Move Hal Hunt'), findsOneWidget);
    // Short names of the golfers on group 1 — the fact the old dropdown's
    // "G1" could not carry.
    expect(find.textContaining('Ann'), findsOneWidget);
  });

  testWidgets('a full group says so and cannot be joined', (t) async {
    await _pump(t, _eight, _fourOneOneTwo);
    expect(find.text('Full — a group is a foursome.'), findsOneWidget);
    await t.tap(find.text('Move').last);
    await t.pumpAndSettle();
    expect(find.text('Full'), findsOneWidget);
  });

  testWidgets('moving a golfer reports the whole map back', (t) async {
    Map<int, int>? out;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ScorecardGroups(
            players: _eight,
            groups: _fourOneOneTwo,
            onChanged: (next) => out = next,
          ),
        ),
      ),
    ));
    await t.tap(find.text('Move').last);          // Hal, on group 4
    await t.pumpAndSettle();
    // Inside the SHEET — "Group 2" is also the header of the card behind it.
    await t.tap(find.descendant(
        of: find.byType(ListTile), matching: find.text('Group 2')));
    await t.pumpAndSettle();
    expect(out![8], out![5]);
    expect(out![7], 4);                           // Gus stays put
  });

  testWidgets('a golfer alone is not offered a card of his own', (t) async {
    await _pump(t, _eight, _fourOneOneTwo);
    // Eve is group 2, by herself.
    await t.tap(find.text('Move').at(4));
    await t.pumpAndSettle();
    expect(find.text('Move Eve East'), findsOneWidget);
    expect(find.text('A card of his own'), findsNothing);
  });

  testWidgets('a guest with nobody to score him is flagged on his own row',
      (t) async {
    await _pump(t, [_p(1, 'Ann Able'), _p(5, 'Gus Guest', onApp: false)],
        {1: 1, 5: 2});
    expect(find.text('needs a scorer'), findsOneWidget);
  });

  testWidgets('and goes quiet once he shares a card with a member', (t) async {
    await _pump(t, [_p(1, 'Ann Able'), _p(5, 'Gus Guest', onApp: false)],
        {1: 1, 5: 1});
    expect(find.text('needs a scorer'), findsNothing);
  });
}
