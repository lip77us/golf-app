/// test/banker_draw_test.dart
/// -------------------------
/// The first-banker draw.
///
/// Two promises, and the second one was broken in the shipped build: the reel
/// reveals the name that was already drawn, and **every way off the screen
/// carries that answer**. A golfer who watched it stop on one name and then
/// swiped back was handed the default instead, while believing he had drawn.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/screens/banker_draw_screen.dart';

const _names = ['Paul Lipkin', 'Ryan Lipkin', 'Tyler Law', 'Jim Diederich'];

/// Reduce-motion makes the reel land immediately, which is also the path a
/// golfer with that setting takes.
Widget _harness(int winner, void Function(int?) onResult) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final r = await Navigator.of(context).push<int>(
                MaterialPageRoute(
                  builder: (_) =>
                      BankerDrawScreen(names: _names, winnerIndex: winner),
                ),
              );
              onResult(r);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the reel shows the name that was drawn', (tester) async {
    await tester.pumpWidget(_harness(2, (_) {}));
    await _open(tester);
    await tester.tap(find.text('Flip for it'));
    await tester.pumpAndSettle();
    // Tyler Law is index 2 — named on the reel and on the button.
    expect(find.text('Tyler Law banks the 1st'), findsOneWidget);
  });

  testWidgets('the call to action returns the drawn golfer', (tester) async {
    int? result;
    await tester.pumpWidget(_harness(2, (r) => result = r));
    await _open(tester);
    await tester.tap(find.text('Flip for it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tyler Law banks the 1st'));
    await tester.pumpAndSettle();
    expect(result, 2);
  });

  testWidgets('closing after the reel lands returns the drawn golfer too',
      (tester) async {
    // The bug: the draw had happened, the name was on screen, and leaving by
    // any other door threw it away.
    int? result;
    await tester.pumpWidget(_harness(2, (r) => result = r));
    await _open(tester);
    await tester.tap(find.text('Flip for it'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(result, 2, reason: 'a landed draw must survive any exit');
  });

  testWidgets('backing out before spinning draws nobody', (tester) async {
    int? result = -1;
    await tester.pumpWidget(_harness(2, (r) => result = r));
    await _open(tester);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: 'nothing was drawn, so nothing is returned');
  });
}
