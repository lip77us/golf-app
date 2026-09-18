import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/sixes_draw.dart';

/// The Segment-2 slot machine is a reveal of a pairing that was decided at
/// setup. It belongs at exactly one moment: Segment 1 settled, Segment 2 not
/// begun. It used to fire off a device-local "have I shown this?" flag, so a
/// group that reopened the round on a reinstalled app — or a second phone —
/// got the spinner on the 13th, and dismissing it sent the card back to the
/// 7th to announce partners they had been playing with for six holes.

Map<String, dynamic> _seg({
  required int start,
  String status = 'pending',
  bool assigned = true,
  List<int> played = const [],
}) => {
      'label': 'Holes $start–${start + 5}',
      'start_hole': start,
      'end_hole': start + 5,
      'is_extra': false,
      'status': status,
      'winner': '—',
      'team1': {'players': assigned ? ['Al', 'Bo'] : <String>[]},
      'team2': {'players': assigned ? ['Cy', 'Di'] : <String>[]},
      'holes': [
        for (final h in played)
          {'hole': h, 't1_net': 4, 't2_net': 5, 'winner': 'T1', 'margin': 1},
      ],
    };

SixesSummary _summary(List<Map<String, dynamic>> segs) =>
    SixesSummary.fromJson({'segments': segs});

/// Segment 1 done, nothing played since — the one moment it should appear.
final _theMoment = _summary([
  _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
  _seg(start: 7),
  _seg(start: 13),
]);

void main() {
  test('it shows when segment 1 settles and segment 2 has not begun', () {
    expect(shouldRevealSixesSegmentTwoDraw(_theMoment), isTrue);
  });

  test('it shows after an early close-out, before segment 2 starts', () {
    // Segment 1 went 4&2: complete with only four holes scored.
    final s = _summary([
      _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4]),
      _seg(start: 7),
      _seg(start: 13),
    ]);
    expect(shouldRevealSixesSegmentTwoDraw(s), isTrue);
  });

  group('once the group has played on it is too late', () {
    test('a single hole of segment 2 is enough', () {
      final s = _summary([
        _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
        _seg(start: 7, status: 'in_progress', played: const [7]),
        _seg(start: 13),
      ]);
      expect(shouldRevealSixesSegmentTwoDraw(s), isFalse);
    });

    test('and standing on the 13th certainly is', () {
      final s = _summary([
        _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
        _seg(start: 7, status: 'complete', played: const [7, 8, 9, 10, 11, 12]),
        _seg(start: 13, status: 'in_progress', played: const [13]),
      ]);
      expect(shouldRevealSixesSegmentTwoDraw(s), isFalse);
    });

    test('even if segment 2 was skipped and only segment 3 has scores', () {
      final s = _summary([
        _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
        _seg(start: 7),
        _seg(start: 13, status: 'in_progress', played: const [13]),
      ]);
      expect(shouldRevealSixesSegmentTwoDraw(s), isFalse);
    });
  });

  group('and it never shows before its moment', () {
    test('segment 1 still in progress', () {
      final s = _summary([
        _seg(start: 1, status: 'in_progress', played: const [1, 2]),
        _seg(start: 7),
        _seg(start: 13),
      ]);
      expect(shouldRevealSixesSegmentTwoDraw(s), isFalse);
    });

    test('a halved segment 1 still counts as settled', () {
      final s = _summary([
        _seg(start: 1, status: 'halved', played: const [1, 2, 3, 4, 5, 6]),
        _seg(start: 7),
        _seg(start: 13),
      ]);
      expect(shouldRevealSixesSegmentTwoDraw(s), isTrue);
    });

    test('pairings not assigned yet', () {
      final s = _summary([
        _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
        _seg(start: 7, assigned: false),
        _seg(start: 13, assigned: false),
      ]);
      expect(shouldRevealSixesSegmentTwoDraw(s), isFalse);
    });

    test('a game with no segments at all', () {
      expect(shouldRevealSixesSegmentTwoDraw(_summary(const [])), isFalse);
      expect(shouldRevealSixesSegmentTwoDraw(null), isFalse);
    });

    test('extra matches do not count toward the three', () {
      final extra = {..._seg(start: 1, status: 'complete'), 'is_extra': true};
      final s = _summary([
        _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
        _seg(start: 7),
        extra,
      ]);
      expect(shouldRevealSixesSegmentTwoDraw(s), isFalse);
    });
  });
}
