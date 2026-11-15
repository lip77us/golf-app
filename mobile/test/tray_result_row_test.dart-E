import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/tray_result_row.dart';

/// The hole's result on a dark tray: names, then why, then the badge.
///
/// Written into the Nassau tray first and asked for on Sixes the same day
/// (Paul, 10 Nov 2026), which is when it became one widget. The row's
/// behaviour is covered through the Nassau tray in `nassau_entry_test`;
/// these are about it being ONE row, in both.

const _a = Color(0xFF8FB4FF);
const _b = Color(0xFFF2A86E);

Future<void> _pump(WidgetTester t, TrayResultRow row) async {
  await t.binding.setSurfaceSize(const Size(900, 200));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: Scaffold(body: row)));
}

void main() {
  testWidgets('each figure wears its own side\'s colour, the badge the '
      'winner\'s', (t) async {
    await _pump(t, const TrayResultRow(
        name1: 'A', name2: 'B', colour1: _a, colour2: _b,
        decided: true, winner: 2,
        reasonLabel: 'net', figure1: 5, figure2: 4));
    final rich = t.widgetList<Text>(find.byType(Text)).firstWhere((w) =>
        (w.textSpan?.toPlainText() ?? '') == 'net 5 v 4');
    final spans = (rich.textSpan as TextSpan).children!.cast<TextSpan>();
    expect(spans.firstWhere((s) => s.text == '5').style?.color, _a);
    expect(spans.firstWhere((s) => s.text == '4').style?.color, _b);
    final badge = t.widget<Container>(find.ancestor(
        of: find.text('Won'), matching: find.byType(Container)).first);
    expect((badge.decoration as BoxDecoration).color, _b);
  });

  testWidgets('an undecided hole is the names alone', (t) async {
    await _pump(t, const TrayResultRow(
        name1: 'A', name2: 'B', colour1: _a, colour2: _b, decided: false));
    expect(find.text('Won'), findsNothing);
    expect(find.text('Halved'), findsNothing);
  });

  testWidgets('with no figures it is still a result', (t) async {
    // Sixes' High-Low has no single best ball to quote.
    await _pump(t, const TrayResultRow(
        name1: 'A', name2: 'B', colour1: _a, colour2: _b,
        decided: true, winner: null));
    expect(find.text('Halved'), findsOneWidget);
  });

  group('one row, on every tray that reports a hole between two sides', () {
    // Fourball's tray is also the Singles Match's. Las Vegas is NOT on the
    // list, deliberately: its hole result is two built NUMBERS and a points
    // difference, which is a different thing to report (Paul, 10 Nov 2026).
    for (final path in ['lib/widgets/nassau_entry.dart',
                        'lib/widgets/sixes_entry.dart',
                        'lib/widgets/fourball_entry.dart']) {
      test('$path draws TrayResultRow and no badge of its own', () {
        final src = File(path).readAsStringSync();
        expect(src.contains('TrayResultRow('), isTrue);
        // The badge's word belongs to the shared row. A tray spelling it
        // is a tray drawing a second one. (`Halved` is not on the list:
        // the Sixes STANDING line says it of a match that finished all
        // square, which is a different fact from a halved hole.)
        for (final word in ["'Won'", "'Won hole"]) {
          expect(src.contains(word), isFalse,
              reason: '$path spells $word itself');
        }
      });
    }
  });
}
