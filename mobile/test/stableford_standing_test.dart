/// test/stableford_standing_test.dart
/// -----------------------------------
/// The standing ribbon's two strings on a Stableford round.
///
/// It is the shared points race, so the shape is pinned in
/// `points_race_standing_test.dart`. What is pinned HERE is the two things
/// that are Stableford's own: the place is honest over the whole field, and
/// the money waits for the round to finish.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/stableford_standing.dart';

const _me = 11;

Map<String, dynamic> _row(int id, double pts,
        {double? payout, int holes = 18}) =>
    {
      'player_id': id, 'total_points': pts, 'payout': payout,
      'holes_played': holes,
    };

Map<String, dynamic> _result(List<Map<String, dynamic>> rows) =>
    {'results': rows};

void main() {
  group('**the place is over the whole field**', () {
    test('a twelve-golfer round says of 12', () {
      // Stableford's summary is ROUND-level and arrives already ranked, so
      // this is second of twelve however many groups are out — unlike Stroke
      // Play, which withholds its place because score entry holds one card.
      final r = _result([
        for (var i = 0; i < 12; i++) _row(20 + i, 30.0 - i),
        _row(_me, 27),
      ]);
      expect(
          stablefordStanding(r, _me, roundComplete: false)!.standing,
          contains('of 13'));
    });

    test('and it ranks on points, high to low', () {
      final r = _result([_row(_me, 27), _row(12, 31), _row(13, 22)]);
      expect(stablefordStanding(r, _me, roundComplete: false)!.standing,
             '2nd of 3 · 27 pts');
    });
  });

  group('**the money waits for the round**', () {
    test('a projected prize is silent while the round runs', () {
      // `payout` is a pool split by standings that can turn on the last hole.
      // A figure beside a total still moving reads as money owed.
      final r = _result([_row(_me, 27, payout: 40), _row(12, 31, payout: 60)]);
      expect(stablefordStanding(r, _me, roundComplete: false)!.figure, '');
    });

    test('and speaks once it is over', () {
      final r = _result([_row(_me, 27, payout: 40), _row(12, 31, payout: 60)]);
      expect(stablefordStanding(r, _me, roundComplete: true)!.figure,
             '+\$40 so far');
    });
  });

  group('when there is nothing to say', () {
    test('**before a hole is played the row still draws**', () {
      final r = _result([_row(_me, 0, holes: 0), _row(12, 0, holes: 0)]);
      expect(stablefordStanding(r, _me, roundComplete: false)!.standing,
             'Tee off');
    });

    test('**a zero total is not the same as no holes**', () {
      // A golfer who picked up on every hole has scored; his row says where
      // he is, not `Tee off`.
      final r = _result([_row(_me, 0), _row(12, 30)]);
      expect(stablefordStanding(r, _me, roundComplete: false)!.standing,
             '2nd of 2 · 0 pts');
    });

    test('a watcher is not in the field', () {
      expect(stablefordStanding(_result([_row(_me, 27)]), 999,
                                roundComplete: false),
             isNull);
    });

    test('no standings yet, no row', () {
      expect(stablefordStanding(_result(const []), _me, roundComplete: false),
             isNull);
    });

    test('no result, no row', () {
      expect(stablefordStanding(null, _me, roundComplete: false), isNull);
    });
  });
}
