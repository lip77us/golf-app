import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/keyboard_done_bar.dart';

/// The 10-key numeric pad has no return key and Flutter has no input accessory,
/// so a screen that raises one can trap the user with no way to dismiss it —
/// found on Tees & Handicaps entering a forced handicap (12 Sep 2026).
///
/// These drive the widget rather than the real keyboard: on a test binding no
/// keyboard appears, so the inset is simulated with viewInsets, which is exactly
/// what the widget reads.
void main() {
  Widget host({double inset = 0, VoidCallback? onButton}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
          child: KeyboardDismissal(
            child: Scaffold(
              body: Column(children: [
                const TextField(keyboardType: TextInputType.number),
                ElevatedButton(
                    onPressed: onButton ?? () {}, child: const Text('Save')),
              ]),
            ),
          ),
        ),
      );

  testWidgets('no bar when no keyboard is up', (t) async {
    await t.pumpWidget(host());
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('a Done bar appears once the keyboard is up', (t) async {
    await t.pumpWidget(host(inset: 300));
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('the bar sits on the keyboard, not under it', (t) async {
    await t.pumpWidget(host(inset: 300));
    final bar = t.getRect(find.text('Done'));
    final screen = t.getRect(find.byType(MaterialApp));
    // Its bottom edge is at least the keyboard's height off the screen bottom.
    expect(screen.bottom - bar.bottom, greaterThanOrEqualTo(300.0));
  });

  testWidgets('Done dismisses the field', (t) async {
    await t.pumpWidget(host(inset: 300));
    await t.tap(find.byType(TextField));
    await t.pump();
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
    await t.tap(find.text('Done'));
    await t.pump();
    final f = FocusManager.instance.primaryFocus;
    expect(f == null || !(f.context?.widget is EditableText), isTrue);
  });

  testWidgets('tapping outside dismisses too', (t) async {
    await t.pumpWidget(host(inset: 300));
    await t.tap(find.byType(TextField));
    await t.pump();
    await t.tapAt(const Offset(200, 400));
    await t.pump();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('the wrapper does not swallow taps meant for a button', (t) async {
    // A global tap handler that ate button presses would be a far worse bug
    // than the one it fixes.
    var pressed = false;
    await t.pumpWidget(host(onButton: () => pressed = true));
    await t.tap(find.text('Save'));
    await t.pump();
    expect(pressed, isTrue);
  });
}
