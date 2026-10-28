import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/nassau_board_model.dart';

Map<String, dynamic> _bet({
  String? result,
  int margin = 0,
  int holesPlayed = 0,
  int? decidedMargin,
  int? decidedRemaining,
}) =>
    {
      'result': result, 'margin': margin, 'holes_played': holesPlayed,
      'decided_margin': decidedMargin, 'decided_remaining': decidedRemaining,
    };

NassauSummary _nassau({
  Map<String, dynamic>? front,
  Map<String, dynamic>? back,
  Map<String, dynamic>? overall,
  List<Map<String, dynamic>> presses = const [],
  List<Map<String, dynamic>> holes = const [],
  String variant = 'none',
  bool single = false,
  double total = 0,
  double? cap,
  Map<String, dynamic>? payouts,
}) =>
    NassauSummary.fromJson({
      'status': 'in_progress',
      'variant': variant,
      'single_match': single,
      'bet_unit': 10.0,
      'press_unit': 5.0,
      'teams': {
        'team1': [
          {'player_id': 1, 'name': 'Paul Lipkin', 'short_name': 'Paul'},
          {'player_id': 2, 'name': 'Dave Moran', 'short_name': 'Dave'},
        ],
        'team2': [
          {'player_id': 3, 'name': 'Sam Reid', 'short_name': 'Sam'},
          {'player_id': 4, 'name': 'Mike Naylor', 'short_name': 'Mike'},
        ],
      },
      'front9': front ?? _bet(),
      'back9': back ?? _bet(),
      'overall': overall ?? _bet(),
      'presses': presses,
      'holes': holes,
      // `loss_cap` lives INSIDE payouts, not at the top level.
      'payouts': {
        ...(payouts ?? {'total': total, 'total_capped': total}),
        if (cap != null) 'loss_cap': cap,
      },
    });

void main() {
  group('a bet states what the SERVER decided', () {
    test('not started reads starts, with the bet\'s first hole', () {
      final d = NassauBoardData.fromSummary(_nassau());
      expect(d.back.headline, '—');
      expect(d.back.sub, 'starts 10');
      expect(d.back.notStarted, isTrue);
      expect(d.front.sub, 'starts 1');
    });

    test('live reads N UP and thru', () {
      final d = NassauBoardData.fromSummary(
          _nassau(front: _bet(margin: 3, holesPlayed: 7)));
      expect(d.front.headline, '3 UP');
      expect(d.front.sub, 'thru 7');
      expect(d.front.leader, 0);
      expect(d.front.done, isFalse);
    });

    test('level live reads AS', () {
      final d = NassauBoardData.fromSummary(
          _nassau(front: _bet(margin: 0, holesPlayed: 7)));
      expect(d.front.headline, 'AS');
      expect(d.front.leader, isNull);
    });

    test('a negative margin is the OTHER side leading', () {
      final d = NassauBoardData.fromSummary(
          _nassau(front: _bet(margin: -2, holesPlayed: 5)));
      expect(d.front.headline, '2 UP');
      expect(d.front.leader, 1);
    });

    test('played out and won reads Final', () {
      final d = NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'team1', margin: 2, holesPlayed: 9)));
      expect(d.front.headline, '2 UP');
      expect(d.front.sub, 'Final');
      expect(d.front.done, isTrue);
    });

    test('played out level reads Push, not AS Final', () {
      final d = NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'halved', margin: 0, holesPlayed: 9)));
      expect(d.front.headline, 'AS');
      expect(d.front.sub, 'Push');
    });

    test('a close-out reads N&M from the server', () {
      final d = NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'team1', margin: 4, holesPlayed: 6,
                      decidedMargin: 4, decidedRemaining: 3)));
      expect(d.front.headline, '4&3');
      expect(d.front.sub, 'Final');
      expect(d.front.done, isTrue);
    });

    test('the &M is READ, never recomputed from holes played', () {
      // The reference derives remaining as (holes in the bet − holes played),
      // which for this bet would say 9 − 6 = 3.  The SERVER says 2, and the
      // server is the only thing that knows the group's play order.
      final d = NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'team1', margin: 5, holesPlayed: 6,
                      decidedMargin: 5, decidedRemaining: 2)));
      expect(d.front.headline, '5&2');
      expect(d.front.headline, isNot('5&3'));
    });

    test('decided_remaining of 0 means it ran to the end, not a close-out', () {
      final d = NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'team1', margin: 1, holesPlayed: 9,
                      decidedMargin: 1, decidedRemaining: 0)));
      expect(d.front.headline, '1 UP');
      expect(d.front.sub, 'Final');
    });
  });

  group('presses', () {
    test('a live press shows its margin', () {
      final d = NassauBoardData.fromSummary(_nassau(presses: [
        {'nine': 'front', 'press_type': 'auto', 'start_hole': 3,
         'end_hole': 9, 'result': null, 'margin': 2, 'holes_remaining': 0},
      ]));
      final p = d.presses.single;
      expect(p.label, 'Press 3–9');
      expect(p.view.headline, '2 UP');
      expect(p.done, isFalse);
      expect(p.nine, 'front');
    });

    test('a closed press uses the server holes_remaining', () {
      final d = NassauBoardData.fromSummary(_nassau(presses: [
        {'nine': 'back', 'press_type': 'manual', 'start_hole': 12,
         'end_hole': 18, 'result': 'team2', 'margin': -4,
         'holes_remaining': 2},
      ]));
      expect(d.presses.single.view.headline, '4&2');
      expect(d.presses.single.view.leader, 1);
    });

    test('a press that ran out level is a Push', () {
      final d = NassauBoardData.fromSummary(_nassau(presses: [
        {'nine': 'front', 'press_type': 'auto', 'start_hole': 5,
         'end_hole': 9, 'result': 'halved', 'margin': 0,
         'holes_remaining': 0},
      ]));
      expect(d.presses.single.view.sub, 'Push');
    });
  });

  group('Claremont', () {
    NassauSummary claremont() => NassauSummary.fromJson({
          'status': 'in_progress',
          'variant': 'claremont',
          'bet_unit': 10.0, 'press_unit': 5.0,
          'teams': {
            'team1': [{'player_id': 1, 'name': 'Paul', 'short_name': 'Paul'}],
            'team2': [{'player_id': 2, 'name': 'Sam', 'short_name': 'Sam'}],
          },
          'front9': _bet(margin: 1, holesPlayed: 9, result: 'team1'),
          'back9': _bet(), 'overall': _bet(),
          'bottom_front9':
              {'result': 'team1', 'margin': 6, 'holes_played': 9},
          'bottom_back9': null, 'bottom_overall': null,
          'bottom_presses': [
            {'nine': 'front', 'press_type': 'auto', 'start_hole': 5,
             'end_hole': 9, 'result': null, 'margin': 2,
             'holes_remaining': 0},
          ],
          'presses': [], 'holes': [],
          'payouts': {'total': 40.0, 'total_capped': 40.0,
                      'bottom_total': 15.0},
        });

    test('the bottom bet becomes a POINTS row', () {
      final d = NassauBoardData.fromSummary(claremont());
      expect(d.claremont, isNotNull);
      expect(d.claremont!.front!.headline, '+6');
      expect(d.claremont!.front!.points, isTrue);
      expect(d.claremont!.money, 15.0);
    });

    test('a points press is labelled apart from a money press', () {
      // Two bars can sit over the same holes; a reader must never have to
      // guess which of two identical ones is which.
      final d = NassauBoardData.fromSummary(claremont());
      final p = d.presses.single;
      expect(p.points, isTrue);
      expect(p.label, 'Points press 5–9');
    });

    test('a plain Nassau has no Claremont block at all', () {
      expect(NassauBoardData.fromSummary(_nassau()).claremont, isNull);
    });

    test('the bottom bet is a MATCH and can be won before the finish', () {
      // Paul, 28 Oct 2026: two points a hole, four to a press, and it can be
      // won early when there are not enough 2-point holes left to catch up.
      // +6 with 2 holes to play is decided: the most that is still available
      // is 4.
      final v = NassauBetView.fromBottom(
          NassauBottomBetResult.fromJson({
            'result': null, 'margin': 6, 'holes_played': 7,
            'decided_margin': 6, 'decided_remaining': 2,
          }),
          startHole: 1);
      expect(v.done, isTrue,
          reason: 'won early — not enough 2-point holes left');
      expect(v.sub, 'Final · 2 to play');
      expect(v.headline, '+6');
    });

    test('the margin stays in POINTS, the unit it is pressed in', () {
      // A bare "3 UP" would read as three HOLES on a bet that moves two
      // points a hole and presses every four.
      final v = NassauBetView.fromBottom(
          NassauBottomBetResult.fromJson(
              {'result': 'team1', 'margin': 6, 'holes_played': 9}),
          startHole: 1);
      expect(v.headline, '+6');
      expect(v.sub, 'Final');
      expect(v.points, isTrue);
    });

    test('still live when the swing is still enough to catch up', () {
      // +3 with 2 to play: 4 points are still available, so nothing is
      // decided.
      final v = NassauBetView.fromBottom(
          NassauBottomBetResult.fromJson(
              {'result': null, 'margin': 3, 'holes_played': 7}),
          startHole: 1);
      expect(v.done, isFalse);
      expect(v.sub, 'thru 7');
    });

    test('a losing points margin shows a true minus sign', () {
      final v = NassauBetView.fromBottom(
          NassauBottomBetResult.fromJson(
              {'result': 'team2', 'margin': -4, 'holes_played': 9}),
          startHole: 10);
      expect(v.headline, '−4');
      expect(v.leader, 1);
    });
  });

  group('the money', () {
    test('it is the server total, already capped', () {
      final d = NassauBoardData.fromSummary(_nassau(
          payouts: {'total': 90.0, 'total_capped': 60.0}, cap: 60.0));
      expect(d.net, 60.0);
      expect(d.lossCap, 60.0);
    });

    test('the board shows the side that is UP', () {
      final up = NassauBoardData.fromSummary(
          _nassau(payouts: {'total': 20.0, 'total_capped': 20.0}));
      expect(up.me, 0);
      expect(up.moneyForMe, 20.0);

      final down = NassauBoardData.fromSummary(
          _nassau(payouts: {'total': -20.0, 'total_capped': -20.0}));
      expect(down.me, 1);
      expect(down.moneyForMe, 20.0);
    });
  });

  _singlesMatchShape();

  group('shapes', () {
    test('sides are named from the short names', () {
      final d = NassauBoardData.fromSummary(_nassau());
      expect(d.sides[0].name, 'Paul & Dave');
      expect(d.sides[1].name, 'Sam & Mike');
    });

    test('a single match carries the overall only', () {
      final d = NassauBoardData.fromSummary(_nassau(single: true));
      expect(d.single, isTrue);
    });

    test('a cup tab hides the money and can hide the sides', () {
      final d = NassauBoardData.fromSummary(_nassau(),
          noMoney: true, showSides: false);
      expect(d.noMoney, isTrue);
      expect(d.showSides, isFalse);
    });

    test('holes map to sides, halves and not-played', () {
      final d = NassauBoardData.fromSummary(_nassau(holes: [
        {'hole': 1, 'winner': 'team1'},
        {'hole': 2, 'winner': 'team2'},
        {'hole': 3, 'winner': 'halved'},
      ]));
      expect(d.holes[0], NassauHoleWinner.side0);
      expect(d.holes[1], NassauHoleWinner.side1);
      expect(d.holes[2], NassauHoleWinner.halved);
      expect(d.holes[3], NassauHoleWinner.notPlayed);
      expect(d.holes.length, 18);
    });
  });
}

/// A Singles Match arrives as `is_eighteen_hole_match` rather than
/// `single_match`, and reading only the latter drew Front and Back cards that
/// could never fill.
void _singlesMatchShape() {
  group('one 18-hole match', () {
    NassauSummary singles() => NassauSummary.fromJson({
          'status': 'in_progress',
          'play_front': false, 'play_back': false, 'play_overall': true,
          'bet_unit': 10.0, 'press_unit': 0.0,
          'teams': {
            'team1': [{'player_id': 1, 'name': 'Paul', 'short_name': 'Paul'}],
            'team2': [{'player_id': 2, 'name': 'Dave', 'short_name': 'Dave'}],
          },
          'front9': _bet(), 'back9': _bet(),
          'overall': _bet(margin: 2, holesPlayed: 12),
          'presses': const [], 'holes': const [],
          'payouts': {'total': 10.0, 'total_capped': 10.0},
        });

    test('is single even though single_match was never set', () {
      final s = singles();
      expect(s.singleMatch, isFalse);
      expect(s.isEighteenHoleMatch, isTrue);
      expect(NassauBoardData.fromSummary(s).single, isTrue);
    });
  });
}
