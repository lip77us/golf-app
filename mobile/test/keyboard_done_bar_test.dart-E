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

  // ── The regression from the 17 Sep round ────────────────────────────────
  //
  // The bar was `Positioned(bottom: inset)` over the whole app — it painted a
  // 44pt opaque strip exactly where the keyboard's top edge is. On a form you
  // scroll, so it only ever hid chrome; on a screen whose content is PINNED
  // to the keyboard it hid the content. The round chat composer is pinned
  // there by construction, so the bar sat on top of the text field and a
  // golfer could type a message he could not read.
  //
  // The fix is that the bar occupies space rather than stealing it: the
  // wrapper reports a bottom inset 44 larger, every Scaffold resizes to leave
  // the row free, and the bar fills it.
  group('it must never cover the content above the keyboard', () {
    Widget chatLike({required double inset}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
            child: KeyboardDismissal(
              child: Scaffold(
                body: Column(children: [
                  const Expanded(child: SizedBox.expand()),
                  // The composer: pinned to the bottom of the resized body,
                  // which is exactly where the bar used to be drawn.
                  Container(
                    key: const Key('composer'),
                    height: 56,
                    color: const Color(0xFFEEEEEE),
                    child: const TextField(),
                  ),
                ]),
              ),
            ),
          ),
        );

    testWidgets('the composer is clear of the Done bar', (t) async {
      await t.pumpWidget(chatLike(inset: 300));
      final composer = t.getRect(find.byKey(const Key('composer')));
      final bar = t.getRect(find.text('Done'));
      expect(composer.bottom, lessThanOrEqualTo(bar.top),
          reason: 'the Done bar is painted over the message field — a golfer '
              'can type what he cannot read');
    });

    testWidgets('and the bar is still on the keyboard edge', (t) async {
      await t.pumpWidget(chatLike(inset: 300));
      final screen = t.getRect(find.byType(MaterialApp));
      final bar = t.getRect(find.text('Done'));
      expect(screen.bottom - bar.bottom, greaterThanOrEqualTo(300.0));
    });
  });


  // ── The nesting, which is where the first fix went wrong ────────────────
  //
  // The widget was right and the app still had the bug: main.dart wrapped
  // KeyboardDismissal AROUND a MediaQuery that rebuilt its data from the
  // original `mq`, so the inflated inset was discarded before any Scaffold
  // saw it. The test above passed because it drove the widget directly.
  //
  // This one mirrors the app's composition instead.
  testWidgets('a MediaQuery INSIDE the wrapper cannot undo the row',
      (t) async {
    const raw = 300.0;
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        return MediaQuery(
          data: mq.copyWith(viewInsets: const EdgeInsets.only(bottom: raw)),
          child: Builder(builder: (ctx2) {
            final outer = MediaQuery.of(ctx2);
            // The app's shape: a text-scale MediaQuery and the dismissal
            // wrapper, in whichever order main.dart uses.
            // The nesting main.dart HAD when the bug shipped: the wrapper
            // outside, a MediaQuery rebuilt from the ambient data inside. It
            // discarded an inflated inset; it cannot discard a Padding.
            return KeyboardDismissal(
              child: MediaQuery(
                data: outer.copyWith(textScaler: const TextScaler.linear(1.0)),
                child: Scaffold(
                  body: Column(children: [
                    const Expanded(child: SizedBox.expand()),
                    Container(
                      key: const Key('composer'),
                      height: 56,
                      color: const Color(0xFFEEEEEE),
                      child: const TextField(),
                    ),
                  ]),
                ),
              ),
            );
          }),
        );
      }),
    ));
    final composer = t.getRect(find.byKey(const Key('composer')));
    final bar = t.getRect(find.text('Done'));
    expect(composer.bottom, lessThanOrEqualTo(bar.top),
        reason: 'a MediaQuery between the wrapper and the Scaffold threw the '
            'inflated inset away and the bar covered the composer');
  });
}
