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

  group('full names', () {
    // Short names are right everywhere else in score entry — they sit over a
    // 40pt score box and the reader knows the group. This sheet is the one
    // place a golfer is being asked to say which of four men he is, before
    // anybody has hit a shot, and `P Lip` over `P Lee` is a coin toss.
    //
    // The risk a full name brings is the row, so that is what is measured:
    // name, holes subtitle and a 44pt handle on one line of a phone.
    testWidgets('a long one fits on a phone without overflowing',
        (t) async {
      t.view.physicalSize = const Size(375, 812);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HotSpotOrderSheet(
            foursomeId: 1,
            roundId: 1,
            golfers: const [
              (id: 1, name: 'Christopher Hollinghurst'),
              (id: 2, name: 'Bartholomew Fitzwilliam'),
              (id: 3, name: 'Cal Reid'),
              (id: 4, name: 'Dee Naylor'),
            ],
            playOrder: [for (var h = 1; h <= 18; h++) h],
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Christopher Hollinghurst'), findsOneWidget);
      expect(find.text('Bartholomew Fitzwilliam'), findsOneWidget);
      // The handle survives beside it — it is the only way to move a row.
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(4));
      // And the holes label is still readable, not squeezed out.
      expect(find.text('anchors 1, 5, 9, 13, 17'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('locked positions', () {
    // Red Ball's rule, which Hot Spot did not have: a scored hole fixes the
    // ONE position that anchored it. The old rule refused the whole order at
    // the first score — not wrong about hole 1, wrong about holes 2, 3 and 4,
    // which had decided nothing and could no longer be arranged.
    Future<void> pump(WidgetTester t, Set<int> locked) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: HotSpotOrderSheet(
              foursomeId: 1,
              roundId: 1,
              golfers: const [
                (id: 1, name: 'Ann Able'),
                (id: 2, name: 'Bea Brown'),
                (id: 3, name: 'Cal Reid'),
                (id: 4, name: 'Dee Naylor'),
              ],
              playOrder: [for (var h = 1; h <= 18; h++) h],
              lockedPositions: locked,
            ),
          ),
        ));

    double y(WidgetTester t, String name) => t.getCenter(find.text(name)).dy;

    testWidgets('a locked row shows a lock where its handle was', (t) async {
      await pump(t, {0});
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
    });

    testWidgets('and says its holes are played, in the past tense',
        (t) async {
      await pump(t, {0});
      expect(find.text('anchored 1, 5, 9, 13, 17 — played'), findsOneWidget);
      // The free rows still read as future.
      expect(find.text('anchors 2, 6, 10, 14, 18'), findsOneWidget);
    });

    testWidgets('the free rows can still be arranged', (t) async {
      // The whole point of the change.
      await pump(t, {0});
      final rowH = y(t, 'Bea Brown') - y(t, 'Ann Able');
      await t.drag(find.byIcon(Icons.drag_handle).first, Offset(0, rowH * 1.6));
      await t.pumpAndSettle();
      expect(y(t, 'Bea Brown'), greaterThan(y(t, 'Cal Reid')));
    });

    testWidgets('a locked row never moves, even dragged through', (t) async {
      // A plain removeAt/insert would shift it. Ann anchored hole 1; if she
      // moves, a played hole changes who anchored it.
      await pump(t, {0});
      final before = y(t, 'Ann Able');
      final rowH = y(t, 'Bea Brown') - before;
      // Drag the LAST free row up past the locked one.
      await t.drag(
          find.byIcon(Icons.drag_handle).last, Offset(0, -rowH * 3.5));
      await t.pumpAndSettle();
      expect(y(t, 'Ann Able'), closeTo(before, 1));
      expect(find.text('anchored 1, 5, 9, 13, 17 — played'), findsOneWidget);
    });

    testWidgets('a NON-contiguous lock holds too', (t) async {
      // Entering holes out of order produces one: posting the 3rd first
      // spends position 3 and nothing else. A leading count cannot say that,
      // which is why the sheet takes a set.
      await pump(t, {2});
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      final calBefore = y(t, 'Cal Reid');
      final rowH = y(t, 'Bea Brown') - y(t, 'Ann Able');
      await t.drag(find.byIcon(Icons.drag_handle).first, Offset(0, rowH * 2.6));
      await t.pumpAndSettle();
      expect(y(t, 'Cal Reid'), closeTo(calBefore, 1),
          reason: 'position 3 is spent and stays where it is');
    });

    testWidgets('a legal move ACROSS a locked row skips over it', (t) async {
      // Position 2 is spent. Moving 1 past it has to land on 3 and leave Bea
      // exactly where she is — the free slots are permuted among themselves,
      // so a lock in the middle is stepped over rather than blocking.
      await pump(t, {1});
      final beaBefore = y(t, 'Bea Brown');
      final rowH = beaBefore - y(t, 'Ann Able');
      await t.drag(find.byIcon(Icons.drag_handle).first, Offset(0, rowH * 2.6));
      await t.pumpAndSettle();
      expect(y(t, 'Bea Brown'), closeTo(beaBefore, 1),
          reason: 'the locked row did not move');
      expect(y(t, 'Ann Able'), greaterThan(beaBefore),
          reason: 'Ann went past her into a free slot');
    });

    testWidgets('every position locked leaves nothing to drag', (t) async {
      await pump(t, {0, 1, 2, 3});
      expect(find.byIcon(Icons.drag_handle), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNWidgets(4));
    });
  });
}
