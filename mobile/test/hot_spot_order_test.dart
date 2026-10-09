/// The anchor-order sheet labels each row with the holes that golfer anchors.
///
/// It is a LABEL, derived on the client so the sheet can show it while the
/// order is still being dragged. The server owns the real rotation; these
/// tests exist so the label cannot drift away from it without being noticed.
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
}
