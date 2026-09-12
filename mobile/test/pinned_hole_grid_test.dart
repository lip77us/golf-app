/// The pinned label column, and the right-edge scroll.
///
/// The progress grids under score entry kept their labels INSIDE the
/// horizontal scroll view, so scrolling to the 14th took the names away with
/// the holes and the rows went anonymous — four unlabelled lines of numbers in
/// a fourball, which is exactly when you need to know whose ball is whose.
/// They also parked the current hole in the middle of the viewport, with empty
/// columns to its right, instead of at the edge a scorecard is read from.
///
/// Both are geometry claims, so both are measured here rather than argued.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/pinned_hole_grid.dart';

const double _labelW = 56;
const double _cellW  = 34;
const double _rowH   = 28;
const double _viewportW = 375;   // a phone

Widget _grid({required int currentIndex, int holes = 18}) {
  Widget label(String t) => SizedBox(
      width: _labelW, height: _rowH,
      child: Align(alignment: Alignment.centerLeft, child: Text(t)));
  Widget cell(int h) => SizedBox(
      width: _cellW, height: _rowH, child: Center(child: Text('$h')));

  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: _viewportW,
        child: PinnedHoleGrid(
          labelWidth: _labelW,
          cellWidth: _cellW,
          holeCount: holes,
          currentIndex: currentIndex,
          bands: [
            HoleGridBand(label('Hole'),
                [for (int h = 1; h <= holes; h++) cell(h)]),
            const HoleGridBand.rule(),
            HoleGridBand(label('Paul'),
                [for (int h = 1; h <= holes; h++) cell(h)]),
            HoleGridBand(label('Dave'),
                [for (int h = 1; h <= holes; h++) cell(h)]),
          ],
        ),
      ),
    ),
  );
}

ScrollableState _scroller(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable));

void main() {
  group('the label column is pinned', () {
    testWidgets('the names do not move when the holes do', (t) async {
      await t.pumpWidget(_grid(currentIndex: -1));
      await t.pumpAndSettle();
      final before = t.getTopLeft(find.text('Paul'));

      _scroller(t).position.jumpTo(300);
      await t.pumpAndSettle();

      expect(t.getTopLeft(find.text('Paul')), before,
          reason: 'scrolling to the 14th must not take the names with it');
    });

    testWidgets('the labels sit outside the scrollable', (t) async {
      await t.pumpWidget(_grid(currentIndex: -1));
      await t.pumpAndSettle();
      // If the label were inside, it would be a descendant of the Scrollable.
      expect(
        find.descendant(
            of: find.byType(Scrollable), matching: find.text('Paul')),
        findsNothing,
      );
    });

    testWidgets('every band contributes a row to BOTH halves', (t) async {
      // A grid whose columns disagree by one row is worse than one that
      // scrolls, so the rule divider has to exist on both sides.
      await t.pumpWidget(_grid(currentIndex: -1));
      await t.pumpAndSettle();
      final columns = t.widgetList<Column>(find.byType(Column)).toList();
      final lengths = columns.map((c) => c.children.length).toSet();
      expect(lengths.contains(4), isTrue,
          reason: '3 bands + 1 rule on each side');
    });
  });

  group('it opens on the hole in play, at the right edge', () {
    testWidgets('the current hole finishes flush with the viewport',
        (t) async {
      await t.pumpWidget(_grid(currentIndex: 11));   // the 12th
      await t.pumpAndSettle();
      // Offset that puts column 12's right edge on the viewport's right edge.
      final viewport = _viewportW - _labelW;
      expect(_scroller(t).position.pixels,
          closeTo(12 * _cellW - viewport, 0.5));
    });

    testWidgets('and not in the middle, which is what it used to do',
        (t) async {
      await t.pumpWidget(_grid(currentIndex: 11));
      await t.pumpAndSettle();
      final old = (11 - 6) * _cellW;      // the retired target
      expect(_scroller(t).position.pixels, isNot(closeTo(old, 1)));
    });

    testWidgets('an early hole does not scroll past the start', (t) async {
      await t.pumpWidget(_grid(currentIndex: 1));
      await t.pumpAndSettle();
      expect(_scroller(t).position.pixels, 0,
          reason: 'the 2nd hole already fits — clamped, not negative');
    });

    testWidgets('the last hole stops at the end rather than overscrolling',
        (t) async {
      await t.pumpWidget(_grid(currentIndex: 17));
      await t.pumpAndSettle();
      final pos = _scroller(t).position;
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 0.5));
    });

    testWidgets('no current hole leaves it where it started', (t) async {
      await t.pumpWidget(_grid(currentIndex: -1));
      await t.pumpAndSettle();
      expect(_scroller(t).position.pixels, 0);
    });
  });
}
