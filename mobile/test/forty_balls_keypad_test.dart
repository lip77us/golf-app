// The 40 Balls keypad — the notation, and the one gate on the 10+ field.
//
// The shapes ARE the legend (the handoff asks for none underneath), so the
// mapping from a number to a circle or a square is the whole contract. It is
// pinned per par rather than once, because the same numeral means different
// things on a par 3 and a par 5 — which is the reason the keypad exists.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/forty_balls_keypad.dart';

void main() {
  group('the notation', () {
    test('a number means different things on different pars', () {
      // The case the whole control is for: 4 is a birdie on a par 5, par on a
      // par 4, and a bogey on a par 3.
      expect(shapeForScore(4, 5), ScoreShape.birdie);
      expect(shapeForScore(4, 4), ScoreShape.par);
      expect(shapeForScore(4, 3), ScoreShape.bogey);
    });

    test('two under or better is an eagle, however far under', () {
      expect(shapeForScore(3, 5), ScoreShape.eagle);
      expect(shapeForScore(2, 5), ScoreShape.eagle);   // albatross
      expect(shapeForScore(1, 3), ScoreShape.eagle);   // ace on a par 3
    });

    test('two over or worse is a double, however far over', () {
      expect(shapeForScore(6, 4), ScoreShape.double);
      expect(shapeForScore(11, 4), ScoreShape.double);
    });
  });

  group('the keypad', () {
    Future<void> pump(WidgetTester t,
        {int par = 4,
        int strokes = 1,
        void Function(int)? onScore,
        VoidCallback? onClear}) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: FortyBallsKeypad(
              playerName: 'Alan Petersen',
              par: par,
              strokes: strokes,
              onScore: onScore ?? (_) {},
              onClear: onClear ?? () {},
            ),
          ),
        ));

    testWidgets('it offers 1 to 9, then 10+ and Clear', (t) async {
      await pump(t);
      for (var n = 1; n <= 9; n++) {
        expect(find.text('$n'), findsOneWidget, reason: 'key $n');
      }
      expect(find.text('10+'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('a key reports its number', (t) async {
      int? got;
      await pump(t, onScore: (n) => got = n);
      await t.tap(find.text('7'));
      expect(got, 7);
    });

    testWidgets('the header names the golfer and the hole', (t) async {
      await pump(t, par: 3, strokes: 1);
      expect(find.text('Alan Petersen'), findsOneWidget);
      expect(find.text('1 stroke · par 3'), findsOneWidget);
    });

    testWidgets('it says strokes, plural, when there are two', (t) async {
      await pump(t, par: 5, strokes: 2);
      expect(find.text('2 strokes · par 5'), findsOneWidget);
    });

    testWidgets('Clear reports', (t) async {
      var cleared = false;
      await pump(t, onClear: () => cleared = true);
      await t.tap(find.text('Clear'));
      expect(cleared, isTrue);
    });
  });

  group('the 10+ field', () {
    Future<int?> enter(WidgetTester t, String typed) async {
      int? got;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FortyBallsKeypad(
            playerName: 'Alan Petersen', par: 4, strokes: 0,
            onScore: (n) => got = n, onClear: () {},
          ),
        ),
      ));
      await t.tap(find.text('10+'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), typed);
      await t.pumpAndSettle();
      await t.tap(find.text('Enter'));
      await t.pumpAndSettle();
      return got;
    }

    testWidgets('it swaps the grid for a field', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FortyBallsKeypad(
            playerName: 'Alan Petersen', par: 4, strokes: 0,
            onScore: (_) {}, onClear: () {},
          ),
        ),
      ));
      expect(find.text('5'), findsOneWidget);
      await t.tap(find.text('10+'));
      await t.pumpAndSettle();
      expect(find.text('5'), findsNothing, reason: 'the grid should be gone');
      expect(find.text('Type a score of 10 or more'), findsOneWidget);
      expect(find.text('Alan Petersen'), findsOneWidget,
          reason: 'the name must stay — it is still his score');
    });

    testWidgets('Enter is dead below 10', (t) async {
      // The field exists because the keypad stops at 9; a 7 typed here would
      // be a key press that went the long way round.
      expect(await enter(t, '7'), isNull);
    });

    testWidgets('Enter takes 10 and above', (t) async {
      expect(await enter(t, '12'), 12);
    });

    testWidgets('Cancel goes back to the grid with nothing entered',
        (t) async {
      int? got;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FortyBallsKeypad(
            playerName: 'Alan Petersen', par: 4, strokes: 0,
            onScore: (n) => got = n, onClear: () {},
          ),
        ),
      ));
      await t.tap(find.text('10+'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('5'), findsOneWidget);
      expect(got, isNull);
    });
  });
}
