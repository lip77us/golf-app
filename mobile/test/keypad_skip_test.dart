import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/forty_balls_keypad.dart';

Widget _pad({String? label, VoidCallback? onSkip, bool skipped = false}) =>
    MaterialApp(
      home: Scaffold(
        body: FortyBallsKeypad(
          playerName: 'Paul Lipkin',
          par: 4,
          strokes: 1,
          onScore: (_) {},
          onClear: () {},
          skipLabel: label,
          onSkip: onSkip,
          skippedNow: skipped,
          progress: const [false, false, true],
          activeIndex: 0,
          skippedIndexes: const {1},
        ),
      ),
    );

void main() {
  testWidgets('Skip replaces Clear and names the next golfer', (t) async {
    var n = 0;
    await t.pumpWidget(_pad(label: 'Skip to Dave ›', onSkip: () => n++));
    expect(find.text('Clear'), findsNothing);
    await t.tap(find.byKey(const ValueKey('keypad-skip')));
    expect(n, 1);
  });

  testWidgets('Skip is inert when nobody else is owed a score', (t) async {
    await t.pumpWidget(_pad(label: 'Skip'));
    expect(find.text('Skip'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('keypad-skip')));
  });

  testWidgets('Clear when the golfer has a score', (t) async {
    await t.pumpWidget(_pad());
    expect(find.text('Clear'), findsOneWidget);
    expect(find.byKey(const ValueKey('keypad-skip')), findsNothing);
  });

  testWidgets('header says skipped', (t) async {
    await t.pumpWidget(_pad(label: 'Skip', skipped: true));
    expect(find.textContaining('skipped · '), findsOneWidget);
  });
}
