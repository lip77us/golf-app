/// The anchor-order sheet labels each row with the holes that golfer anchors.
///
/// It is a LABEL, derived on the client so the sheet can show it while the
/// order is still being dragged. The server owns the real rotation; these
/// tests exist so the label cannot drift away from it without being noticed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/hot_spot_order_sheet.dart';

void main() {
  final full = [for (var h = 1; h <= 18; h++) h];

  group('holesAnchoredBy', () {
    test('the first two anchor five holes and the others four', () {
      // The handoff's own arithmetic, which is what 18 over 4 gives.
      expect(holesAnchoredBy(full, 0, 4).length, 5);
      expect(holesAnchoredBy(full, 1, 4).length, 5);
      expect(holesAnchoredBy(full, 2, 4).length, 4);
      expect(holesAnchoredBy(full, 3, 4).length, 4);
    });

    test('the order repeats every four holes', () {
      expect(holesAnchoredBy(full, 0, 4), [1, 5, 9, 13, 17]);
      expect(holesAnchoredBy(full, 2, 4), [3, 7, 11, 15]);
    });

    test('it follows PLAY ORDER, not hole number', () {
      // A shotgun group off the 7th: its first hole is the 7th, so the first
      // golfer in the order anchors it. Hole number and position are the same
      // integer only on a round that starts at the 1st.
      final shotgun = [for (var i = 0; i < 18; i++) ((6 + i) % 18) + 1];
      expect(shotgun.first, 7);
      expect(holesAnchoredBy(shotgun, 0, 4).first, 7);
      expect(holesAnchoredBy(shotgun, 1, 4).first, 8);
    });

    test('a threesome rotates three', () {
      expect(holesAnchoredBy(full, 0, 3), [1, 4, 7, 10, 13, 16]);
      expect(holesAnchoredBy(full, 2, 3), [3, 6, 9, 12, 15, 18]);
    });

    test('every hole has exactly one anchor', () {
      final all = <int>[
        for (var p = 0; p < 4; p++) ...holesAnchoredBy(full, p, 4),
      ]..sort();
      expect(all, full);
    });

    test('no golfers rotating anchors nothing rather than dividing by zero',
        () {
      expect(holesAnchoredBy(full, 0, 0), isEmpty);
    });
  });

  group('the sheet can actually be reordered', () {
    // Reported from the course: "when I hit change on the Order, it does not
    // allow me to drag and drop". The list was built with
    // `buildDefaultDragHandles: true`, which draws a handle on DESKTOP and
    // nothing at all on a phone — it wraps each row in a
    // `ReorderableDelayedDragStartListener`, so the row moves on a LONG PRESS
    // with no affordance saying so, under copy that said "drag".
    //
    // The long press did work. That is the bug rather than its absence: a
    // gesture nothing on screen mentions, in the one reorder list in the app
    // that does not give a handle — the other six all do.
    //
    // These drive a plain drag, which the shipped version does not answer.
    Future<void> pump(WidgetTester t) => t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: HotSpotOrderSheet(
              foursomeId: 1,
              roundId: 1,
              golfers: const [
                (id: 1, name: 'Ann'),
                (id: 2, name: 'Bea'),
                (id: 3, name: 'Cal'),
                (id: 4, name: 'Dee'),
              ],
              playOrder: [for (var h = 1; h <= 18; h++) h],
            ),
          ),
        ));

    testWidgets('every row has a handle to take hold of', (t) async {
      await pump(t);
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(4));
    });

    testWidgets('the handle is 44 points, the only way to move a row',
        (t) async {
      await pump(t);
      final box = t.getSize(find.ancestor(
          of: find.byIcon(Icons.drag_handle).first,
          matching: find.byType(Padding).first));
      expect(box.width, greaterThanOrEqualTo(44));
      expect(box.height, greaterThanOrEqualTo(44));
    });

    testWidgets('dragging a handle moves that golfer', (t) async {
      await pump(t);
      // Ann is 1st and anchors the group's first hole.
      expect(t.widget<Text>(find.text('anchors 1, 5, 9, 13, 17')), isNotNull);
      final annRow = t.getCenter(find.text('Ann')).dy;
      final beaRow = t.getCenter(find.text('Bea')).dy;
      final rowHeight = beaRow - annRow;

      await t.drag(find.byIcon(Icons.drag_handle).first,
          Offset(0, rowHeight * 1.6));
      await t.pumpAndSettle();

      // Ann is now below Bea.
      expect(t.getCenter(find.text('Ann')).dy,
          greaterThan(t.getCenter(find.text('Bea')).dy));
    });

    testWidgets('the holes follow the position, not the golfer', (t) async {
      // The subtitle is a label for the SLOT. After a swap the man in slot 1
      // anchors slot 1's holes — if the labels travelled with the golfer the
      // sheet would be promising a rotation the server will not run.
      await pump(t);
      final rowHeight = t.getCenter(find.text('Bea')).dy -
          t.getCenter(find.text('Ann')).dy;
      await t.drag(find.byIcon(Icons.drag_handle).first,
          Offset(0, rowHeight * 1.6));
      await t.pumpAndSettle();

      final first = t.getCenter(find.text('anchors 1, 5, 9, 13, 17')).dy;
      final bea = t.getCenter(find.text('Bea')).dy;
      expect(first, closeTo(bea, 24),
          reason: 'the top slot keeps its holes and Bea now holds it');
    });

    testWidgets('the copy names the handle', (t) async {
      // "Drag into the order" described a gesture that did not exist.
      await pump(t);
      expect(find.textContaining('Drag the handles'), findsOneWidget);
    });
  });
}
