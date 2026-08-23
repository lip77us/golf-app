/// test/pairs_format_step_test.dart
/// --------------------------------
/// The pairs format step (docs/design-review/handoff-team-pairs/SPEC.md §4).
///
/// The one thing that must not be quietly lost: **the pair's own figure shows
/// on every option, before it is chosen.** A TD picking Chapman because it
/// sounds fun should see that it more than doubles his field's strokes against
/// a scramble, and the argument only works if all five figures are on screen
/// at once.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/team_play/team_format_step.dart';

void main() {
  final pars = {for (var h = 1; h <= 18; h++) h: 4};

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  Future<void> pumpTall(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(child);
    await tester.pump();
  }

  const defaultPair = (name: 'Maiolini & Yau', handicaps: <int>[4, 19]);

  Widget harness({
    int teamSize = 2,
    String format = 'scramble',
    bool withPair = true,
  }) {
    final ({String name, List<int> handicaps})? pair =
        withPair ? defaultPair : null;
    return MaterialApp(
        home: Scaffold(
          body: TeamFormatStep(
            teamSize      : teamSize,
            samplePair    : pair,
            format        : format,
            ballCountMode : 'fixed',
            ballCountFixed: 2,
            perHoleCounts : const {},
            parByHole     : pars,
            locked        : false,
            onFormat      : (_) {},
            onMode        : (_) {},
            onFixed       : (_) {},
            onPerHole     : (_, __) {},
          ),
        ),
      );
  }

  testWidgets('all five pairs formats are on screen', (tester) async {
    await pumpTall(tester, harness());
    for (final name in ['Scramble', 'Best ball', 'Alternate shot',
                        'Scotch', 'Chapman']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    // Shamble is a fours format and must not appear.
    expect(find.text('Shamble'), findsNothing);
  });

  testWidgets("the pair's own figure prints on every option", (tester) async {
    await pumpTall(tester, harness());
    expect(find.text('4'),  findsOneWidget);      // scramble
    expect(find.text('12'), findsOneWidget);      // alternate shot
    // Scotch and Chapman share a table, so 10 appears twice — which is the
    // point being made, not a bug.
    expect(find.text('10'), findsNWidgets(2));
    // Best ball is per golfer, so it reads as two numbers.
    expect(find.text('3 / 16'), findsOneWidget);
  });

  testWidgets('the alternate-shot warning names the gap', (tester) async {
    await pumpTall(tester, harness(format: 'alternate_shot'));
    expect(
      find.textContaining('most generous format by a distance'),
      findsOneWidget,
    );
    expect(find.textContaining('12 strokes against'), findsOneWidget);
  });

  testWidgets('scotch says plainly that chapman shares its table',
      (tester) async {
    await pumpTall(tester, harness(format: 'scotch'));
    expect(find.textContaining('Scotch and Chapman share a table'),
           findsOneWidget);
  });

  testWidgets('with no tees set yet the options fall back to the rule',
      (tester) async {
    // A figure needs a course handicap, which needs a tee. The options still
    // have to say something rather than going blank.
    await pumpTall(tester, harness(withPair: false));
    expect(find.text('Alternate shot'), findsOneWidget);
    expect(find.text('4'), findsNothing);
  });

  testWidgets('pairs never offer a phantom partner', (tester) async {
    await pumpTall(tester, harness());
    expect(find.textContaining('No phantom partner in pairs'), findsOneWidget);
  });

  testWidgets('a foursome event is untouched', (tester) async {
    await pumpTall(tester, harness(teamSize: 4, format: 'scramble', withPair: false));
    expect(find.text('Scramble'), findsOneWidget);
    expect(find.text('Shamble'),  findsOneWidget);
    expect(find.text('Chapman'),  findsNothing);
    expect(find.textContaining('phantom 4th'), findsOneWidget);
  });
}
