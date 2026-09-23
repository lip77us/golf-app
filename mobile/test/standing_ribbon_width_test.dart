/// test/standing_ribbon_width_test.dart
/// -----------------------------------
/// **The standing gets the whole bar that is left, not half of it.**
///
/// `Flexible(flex: 1)` followed by `Spacer()` divides the free space EQUALLY —
/// a Spacer is an Expanded with flex 1 — so the standing could never use more
/// than half the row however empty the other half was. It went unnoticed for
/// as long as every row fitted in half; a two-team scramble clipped
/// `B&P 1st · D&D 2nd of 4` to `D&D 2nd o…` with a visible gap beside it.
/// Reported 23 Sep 2026.
///
/// **Asserted as a RELATIONSHIP, not a width.** Widget tests render in Ahem,
/// where every glyph is a fontSize-wide block, so a measured pixel count says
/// nothing about the device. What the fix guarantees is that no blank space is
/// left between the standing and whatever follows it — which is exactly what
/// the screenshot showed going wrong, and which Ahem cannot distort.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/standing_ribbon.dart';

Rect _text(WidgetTester t, String s) => t.getRect(find.byWidgetPredicate(
    (w) => w is Text && ((w.textSpan as TextSpan?)?.text ?? w.data) == s));

Future<void> _pump(WidgetTester t, String standing, String figure) async {
  // An iPhone at its narrowest ordinary width — the case that clipped.
  await t.binding.setSurfaceSize(const Size(375, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Group 1'),
        bottom: StandingRibbon(
          kind: StandingKind.result,
          standing: standing,
          figure: figure,
          onOpenLeaderboard: () {},
        ),
      ),
    ),
  ));
}

void main() {
  const pairs = 'B&P 1st · D&D 2nd of 4';

  testWidgets('the standing runs right up to the qualifier', (t) async {
    await _pump(t, pairs, 'thru 1');
    final gap = _text(t, 'thru 1').left - _text(t, pairs).right;
    expect(gap, lessThan(1),
        reason: 'blank space between the standing and the qualifier means the '
            'standing was capped before it ran out of room — the '
            'Flexible-before-Spacer defect');
  });

  testWidgets('with no qualifier it runs up to the pill', (t) async {
    await _pump(t, pairs, '');
    final gap = _text(t, 'Leaderboard').left - _text(t, pairs).right;
    // The pill carries its own padding — 6 outer, 9 inner — so the gap to its
    // LABEL is that, and no more.
    expect(gap, lessThan(20));
  });

  testWidgets('it starts immediately after the glyph, not centred', (t) async {
    // The slot expands; the text paints from the start, so a short standing
    // stays on the left and the slack sits between it and the qualifier.
    await _pump(t, '1 UP thru 2', '');
    final glyph = _text(t, '🏆');
    final standing = _text(t, '1 UP thru 2');
    expect(standing.left - glyph.right, lessThan(10));
  });

  testWidgets('the row is still exactly 27px', (t) async {
    // The whole case for D2 over a pinned strip is made in these pixels, so a
    // layout change that grew the bar would be a different feature.
    await _pump(t, pairs, 'thru 1');
    expect(StandingRibbon.height, 27);
    expect(t.getSize(find.byType(StandingRibbon)).height, 27);
  });
}
