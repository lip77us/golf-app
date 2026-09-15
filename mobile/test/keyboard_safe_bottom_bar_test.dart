import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Save button on a setup screen must stay reachable while a field on that
/// screen is being typed into — reported from Del Monte (14 Sep 2026): the
/// payout amounts could be edited and never saved, because the keypad covered
/// the button.
///
/// The cause is a Scaffold rule that is easy to assume the other way round.
/// `resizeToAvoidBottomInset` insets the BODY; `_ScaffoldLayout` still positions
/// `bottomNavigationBar` at `size.height - barHeight`, where `size` is the whole
/// screen. The soft keyboard is an overlay, so the bar sits underneath it.
///
/// The fix is the in-body pattern Paul established for Sixes, Skins, Points
/// 5-3-1, Multi-Group Skins, Nassau and Irish Rumble: the button goes in the
/// body Column under an `Expanded`, so it rides up with the body.
///
/// These drive the layout rather than a real keyboard: on a test binding no
/// keyboard appears, so the inset is simulated with viewInsets — the same thing
/// the Scaffold reads.
void main() {
  const keyboard = 300.0;

  Widget button() => const SizedBox(
        height: 52,
        child: FilledButton(onPressed: null, child: Text('Save Setup')),
      );

  Widget body() => ListView(children: [
        for (var i = 0; i < 40; i++) ListTile(title: Text('row $i')),
      ]);

  /// What every unconverted screen looked like.
  Widget inBottomNavigationBar() => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
              viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: Scaffold(
            body: body(),
            bottomNavigationBar: SafeArea(top: false, child: button()),
          ),
        ),
      );

  /// The pattern every setup screen uses now.
  Widget inBody() => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
              viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: Scaffold(
            body: Column(children: [
              Expanded(child: body()),
              SafeArea(top: false, child: button()),
            ]),
          ),
        ),
      );

  testWidgets('bottomNavigationBar puts the button under the keyboard',
      (t) async {
    await t.pumpWidget(inBottomNavigationBar());
    final screen = t.view.physicalSize.height / t.view.devicePixelRatio;
    final rect = t.getRect(find.text('Save Setup'));
    // This is the bug, pinned so the pattern is not "simplified" back to it.
    expect(rect.bottom, greaterThan(screen - keyboard),
        reason: 'the button is drawn in the area the keyboard covers');
  });

  testWidgets('in-body keeps the whole button above the keyboard', (t) async {
    await t.pumpWidget(inBody());
    final screen = t.view.physicalSize.height / t.view.devicePixelRatio;
    final rect = t.getRect(find.text('Save Setup'));
    expect(rect.bottom, lessThanOrEqualTo(screen - keyboard),
        reason: 'the button has to clear the keyboard entirely, not just its '
            'top edge — a half-covered button is still untappable');
  });

  testWidgets('with no keyboard the two lay out the same', (t) async {
    Widget noKeyboard(Widget scaffold) => MaterialApp(
          home: MediaQuery(data: const MediaQueryData(), child: scaffold),
        );

    await t.pumpWidget(noKeyboard(Scaffold(
      body: body(),
      bottomNavigationBar: SafeArea(top: false, child: button()),
    )));
    final before = t.getRect(find.text('Save Setup'));

    await t.pumpWidget(noKeyboard(Scaffold(
      body: Column(children: [
        Expanded(child: body()),
        SafeArea(top: false, child: button()),
      ]),
    )));
    // The conversion is a keyboard fix, not a redesign: nothing moves when
    // there is no keyboard up.
    expect(t.getRect(find.text('Save Setup')), before);
  });
}
