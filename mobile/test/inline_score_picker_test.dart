import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/providers/settings_provider.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/inline_score_picker.dart';
import 'package:provider/provider.dart';

/// Reported from a scramble, 30 Oct 2026: *"When selecting par, which was
/// often, the selector was a very subtle change in the green border highlight
/// that was not visible on the course."*
///
/// He was right about where it was worst. Par is the one score with no golf
/// shape of its own, so the selected cell could not take the ring the others
/// used — and the fill it took instead went `green.shade400` → `green.shade600`,
/// **1.40:1**, visible only as a 5px rim around the chip on top of it.
///
/// These measure the mark rather than assert it exists: contrast and area are
/// the whole claim, and "there is a decoration" would have passed on the old
/// build too.

double _lum(Color c) {
  double f(int v) {
    final s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }
  return 0.2126 * f(c.red) + 0.7152 * f(c.green) + 0.0722 * f(c.blue);
}

double _contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _host({required int par, required int? current}) => MaterialApp(
      home: ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: Scaffold(
          body: InlineScorePicker(
            par: par,
            strokes: 0,
            currentScore: current,
            onScoreSelected: (_) {},
          ),
        ),
      ),
    );

/// The cell behind the digit `score` — the box that carries the selection.
Container _cellFor(WidgetTester t, int score) {
  final box = find
      .ancestor(
        of: find.text('$score'),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.constraints?.maxWidth == 50.0 &&
            w.constraints?.maxHeight == 48.0),
      )
      .first;
  return t.widget<Container>(box);
}

Color? _fill(Container c) => (c.decoration as BoxDecoration?)?.color;

void main() {
  const par = 4;

  testWidgets('the contrast check agrees with a known pair', (t) async {
    // The series maths above is only trustworthy if it reproduces a figure
    // computed elsewhere: white on black is 21:1.
    expect(_contrast(Colors.white, Colors.black), closeTo(21.0, 0.05));
  });

  testWidgets('picking par fills the cell instead of shading its rim',
      (t) async {
    await t.pumpWidget(_host(par: par, current: null));
    await t.pumpAndSettle();
    final unselected = _fill(_cellFor(t, par))!;

    await t.pumpWidget(_host(par: par, current: par));
    await t.pumpAndSettle();
    final selected = _fill(_cellFor(t, par))!;

    expect(selected, Halved.deepPine);
    expect(_contrast(selected, unselected), greaterThan(7.0),
        reason: 'the old pair was 1.40:1 and vanished in sunlight');
  });

  testWidgets('a non-par score is marked the same way, not with a ring',
      (t) async {
    const bogey = par + 1;
    await t.pumpWidget(_host(par: par, current: bogey));
    await t.pumpAndSettle();

    final cell = _cellFor(t, bogey);
    expect(_fill(cell), Halved.deepPine);
    // A ring around the notation is how this card draws a bogey; selection
    // must not borrow it.
    expect((cell.decoration as BoxDecoration).border, isNull);
  });

  testWidgets('the band is real area, not a rim', (t) async {
    await t.pumpWidget(_host(par: par, current: par));
    await t.pumpAndSettle();

    final cell = t.getSize(find
        .ancestor(
          of: find.text('$par'),
          matching: find.byWidgetPredicate((w) =>
              w is Container &&
              w.constraints?.maxWidth == 50.0 &&
              w.constraints?.maxHeight == 48.0),
        )
        .first);
    // The chip is inset so the fill shows all round rather than as the 5px
    // rim a 40pt chip left.
    final chip = t.getSize(find
        .ancestor(of: find.text('$par'), matching: find.byType(SizedBox))
        .first);
    expect(chip.width, lessThanOrEqualTo(cell.width - 12));
    expect(chip.height, lessThanOrEqualTo(cell.height - 10));
  });

  testWidgets('selecting does not move or resize the digit', (t) async {
    await t.pumpWidget(_host(par: par, current: null));
    await t.pumpAndSettle();
    final before = t.getSize(find
        .ancestor(of: find.text('$par'), matching: find.byType(SizedBox))
        .first);

    await t.pumpWidget(_host(par: par, current: par));
    await t.pumpAndSettle();
    final after = t.getSize(find
        .ancestor(of: find.text('$par'), matching: find.byType(SizedBox))
        .first);

    expect(after, before, reason: 'a digit that jumps on tap reads as a glitch');
  });
}
