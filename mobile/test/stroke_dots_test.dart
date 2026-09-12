/// The stroke dots, and the 32px cell that caused the cap.
///
/// `strokes.clamp(0, 2)` lived on nine surfaces and silently misreported a
/// real state — the row drew two and the golfer had three. It was never a
/// constraint on the score box, which has room for four; it was invented for
/// the scorecard grid, where three horizontal dots reach the centred digit,
/// and then applied everywhere.
///
/// Design's answer (handoff-app-fixes/stroke-dots.html, option B) is the SAME
/// dot rotated ninety degrees in the grid: a column down the right edge costs
/// 7px of the cell's width instead of 14, so it cannot collide at three
/// strokes or at four. These tests pin the count and the geometry, because the
/// geometry is the entire argument for the shape.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/stroke_dots.dart';

const _cellKey = Key('cell');

/// A 32x26 scorecard cell with a centred digit — the real one.
Widget _cell(Widget dots, {double width = 32, double height = 26}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: _cellKey,
            width: width,
            height: height,
            child: Stack(children: [
              const Center(child: Text('7')),
              dots,
            ]),
          ),
        ),
      ),
    );

Iterable<Element> _dots(WidgetTester t) => t
    .elementList(find.byType(Container))
    .where((e) => (e.widget as Container).constraints?.maxWidth == kStrokeDot);

/// Geometry straight off the render object.
///
/// `find.byElementPredicate` needs exactly one match and there are three dots
/// on purpose, so measuring through a finder fights the thing being measured.
Rect _rect(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

List<Rect> _dotRects(WidgetTester t) => _dots(t).map(_rect).toList();

void main() {
  group('the cap is gone', () {
    testWidgets('three strokes draw three dots, not two', (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotColumn(strokes: 3, color: Colors.green)));
      expect(_dots(t).length, 3);
    });

    testWidgets('and four draw four', (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotColumn(strokes: 4, color: Colors.green)));
      expect(_dots(t).length, 4);
    });

    testWidgets('the score box lost it too', (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotRow(strokes: 3, color: Colors.green),
          width: 40, height: 36));
      expect(_dots(t).length, 3);
    });

    testWidgets('no strokes draws nothing at all', (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotColumn(strokes: 0, color: Colors.green)));
      expect(_dots(t).length, 0);
    });
  });

  group('the column clears the digit', () {
    testWidgets('three dots cost 4px of the cell\'s width, not 14',
        (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotColumn(strokes: 3, color: Colors.green)));
      final boxes = _dotRects(t);
      final left  = boxes.map((r) => r.left).reduce((a, b) => a < b ? a : b);
      final right = boxes.map((r) => r.right).reduce((a, b) => a > b ? a : b);
      expect(right - left, kStrokeDot);
    });

    testWidgets('and do not touch the digit, at three or at four', (t) async {
      for (final n in [3, 4]) {
        await t.pumpWidget(_cell(
            StrokeDotColumn(strokes: n, color: Colors.green)));
        final digit = t.getRect(find.text('7'));
        final dot   = _dotRects(t).first;
        expect(dot.left, greaterThan(digit.right),
            reason: '$n strokes overlapped the score — which is what the '
                    'horizontal run did, and why the cap existed');
      }
    });

    testWidgets('it sits inset from the right edge, not against it',
        (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotColumn(strokes: 3, color: Colors.green)));
      final cellRight = t.getRect(find.byKey(_cellKey)).right;
      final dotRight  = _dotRects(t).first.right;
      expect(cellRight - dotRight, closeTo(3, 0.01));
    });

    testWidgets('the column is centred vertically, so it sits level with '
        'the digit whatever the row height', (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotColumn(strokes: 2, color: Colors.green)));
      final cell = t.getRect(find.byKey(_cellKey));
      final tops = _dotRects(t);
      final top    = tops.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      final bottom = tops.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      expect(top - cell.top, closeTo(cell.bottom - bottom, 0.01));
    });
  });

  group('the narrowest grid in the app', () {
    testWidgets('28px still clears the digit', (t) async {
      await t.pumpWidget(_cell(
          const StrokeDotColumn(strokes: 3, color: Colors.green, inset: 2),
          width: 28, height: 26));
      final digit = t.getRect(find.text('7'));
      final dot   = _dotRects(t).first;
      expect(dot.left, greaterThan(digit.right));
    });
  });
}
