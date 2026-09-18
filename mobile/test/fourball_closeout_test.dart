import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';

/// The `&M` in "3&2" is holes LEFT IN PLAY ORDER. Only the server knows the
/// group's order, so it ships `holes_to_play`; the client must never rebuild it
/// as `18 - finished_on_hole` — right on a round from the 1st, wrong on every
/// shotgun (off 10, a match clinched on hole 1 has 8 left, not 17).
Map<String, dynamic> _summary({
  String status = 'complete',
  int? finishedOnHole,
  int? holesToPlay,
  int holesPlayed = 10,
}) => {
      'status': status,
      'result': 'team1',
      'result_label': '10&8',
      'finished_on_hole': finishedOnHole,
      'holes_to_play': holesToPlay,
      'holes_played': holesPlayed,
      'handicap': {'mode': 'gross', 'net_percent': 100},
      'overall': {'holes_up': 10, 'leader': 'team1'},
      'team1': {'players': ['A', 'B']},
      'team2': {'players': ['C', 'D']},
      'holes': const [],
      'money': {'bet_amount': 20.0},
    };

void main() {
  group('a shotgun close-out', () {
    final s = FourballSummary.fromJson(
        _summary(finishedOnHole: 1, holesToPlay: 8));

    test('takes the holes left from the server', () {
      expect(s.holesToPlay, 8);
    });

    test('does not agree with 18 minus the hole number', () {
      // The old client arithmetic; kept here so the difference stays visible.
      expect(18 - s.finishedOnHole!, 17);
      expect(s.holesToPlay, isNot(18 - s.finishedOnHole!));
    });

    test('holes played plus holes left is the round', () {
      expect(s.holesPlayed + s.holesToPlay!, 18);
    });
  });

  test('a live match has no holes left to report', () {
    final s = FourballSummary.fromJson(
        _summary(status: 'in_progress', holesPlayed: 3));
    expect(s.holesToPlay, isNull);
  });

  test('a round from the 1st still reads right', () {
    final s = FourballSummary.fromJson(
        _summary(finishedOnHole: 16, holesToPlay: 2, holesPlayed: 16));
    expect(s.holesToPlay, 2);
    expect(18 - s.finishedOnHole!, s.holesToPlay);
  });
}
