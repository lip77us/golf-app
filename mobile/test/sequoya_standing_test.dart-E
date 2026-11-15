/// test/sequoya_standing_test.dart
/// -------------------------------
/// The standing ribbon's strings on a Sequoya 3s round.
///
/// Six matches of three holes, pairings re-drawn every third hole. The subject
/// here is which match the row picks, that it reports the MATCH bet rather
/// than a press, and that its colour names the leading SIDE.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/sequoya_standing.dart';

const _me = 11;
const _b = 12;
const _c = 13;

/// The screen's own notation, inlined so the test pins the WIRING rather than
/// re-implementing it: the row must hand its bet to whatever the screen uses.
String _betState(SequoyaBet b) =>
    b.margin == 0 ? 'All square' : '${b.margin.abs()} up';

SequoyaBet _bet({int margin = 0, String kind = 'match', int? result}) =>
    SequoyaBet(
      kind: kind, label: kind == 'match' ? 'Match' : 'Press',
      holes: const [1, 2, 3], amount: 5, result: result, margin: margin,
      closedOn: null, toPlay: 3, calledBy: null, calledSide: null,
    );

SequoyaMatch _match(int index, int start, int end, List<SequoyaBet> bets) =>
    SequoyaMatch(
      index: index, startHole: start, endHole: end,
      side1: const [SequoyaSide(playerId: _me, name: 'Paul', shortName: 'Paul')],
      side2: const [
        SequoyaSide(playerId: _b, name: 'Jim', shortName: 'Jim'),
        SequoyaSide(playerId: _c, name: 'Dave', shortName: 'Dave'),
      ],
      bets: bets, atRisk: 5,
    );

SequoyaThreesSummary _summary({
  List<SequoyaMatch> matches = const [],
  Map<int, double> money = const {},
}) =>
    SequoyaThreesSummary(
      status: 'in_progress', handicapMode: 'net', netPercent: 100,
      pressMode: 'none', betAmount: 5,
      matches: matches,
      players: [
        for (final id in const [_me, _b, _c])
          SequoyaPlayerTotal(
            playerId: id, name: 'P$id', shortName: 'P$id',
            money: money[id] ?? 0, recordLabel: '', betRecordLabel: '',
          ),
      ],
      transfers: const [],
      cardPlayers: const [], cardHoles: const [], cardHolesInPlay: const [],
      exposureNoPresses: 0, exposureWithAuto: 0, exposureCeiling: 0,
    );

SequoyaStanding? _st(SequoyaThreesSummary? s, {int who = _me, int hole = 1}) =>
    sequoyaStanding(s, who, hole: hole, betState: _betState);

void main() {
  group('**the match is picked by the hole on screen**', () {
    test('a Sequoya match IS a hole range, and the row follows it', () {
      final s = _summary(matches: [
        _match(1, 1, 3, [_bet(margin: 2)]),
        _match(2, 4, 6, [_bet(margin: -1)]),
      ]);
      expect(_st(s, hole: 2)!.label, 'M1');
      expect(_st(s, hole: 5)!.label, 'M2');
    });

    test('backing up reports the earlier match', () {
      // The pairing, the score rows and the header on screen have all backed
      // up with it.
      final s = _summary(matches: [
        _match(1, 1, 3, [_bet(margin: 2)]),
        _match(2, 4, 6, [_bet(margin: -1)]),
      ]);
      expect(_st(s, hole: 6)!.standing, '1 up');
      expect(_st(s, hole: 1)!.standing, '2 up');
    });
  });

  group('**the colour names the leading SIDE**', () {
    test('side 1 up is side 1, whoever is reading', () {
      final s = _summary(matches: [_match(1, 1, 3, [_bet(margin: 2)])]);
      expect(_st(s, hole: 1)!.leader, 1);
      expect(_st(s, who: _b, hole: 1)!.leader, 1);
    });

    test('side 2 up is side 2, whoever is reading', () {
      final s = _summary(matches: [_match(1, 1, 3, [_bet(margin: -2)])]);
      expect(_st(s, hole: 1)!.leader, 2);
      expect(_st(s, who: _b, hole: 1)!.leader, 2);
    });

    test('**the string is the same for both sides**', () {
      // Neutral, like the six-match strip it reuses. A margin written from
      // the reader's side while coloured from the leader's is the defect
      // Nassau had to be corrected out of.
      final s = _summary(matches: [_match(1, 1, 3, [_bet(margin: -2)])]);
      expect(_st(s, hole: 1)!.standing, _st(s, who: _b, hole: 1)!.standing);
      expect(_st(s, hole: 1)!.standing, '2 up');
    });

    test('level takes no colour', () {
      final s = _summary(matches: [_match(1, 1, 3, [_bet()])]);
      final st = _st(s, hole: 1)!;
      expect(st.standing, 'All square');
      expect(st.leader, isNull);
    });
  });

  group('**it reports the MATCH bet, not a press**', () {
    test('the first bet is the match\'s own', () {
      // A match can carry presses; there can be several, and a row reporting
      // one would have to say which. The banner named them; the strip shows
      // `+N`.
      final s = _summary(matches: [
        _match(1, 1, 3, [
          _bet(margin: 1),
          _bet(margin: -3, kind: 'manual_press'),
        ]),
      ]);
      expect(_st(s, hole: 1)!.standing, '1 up');
      expect(_st(s, hole: 1)!.leader, 1);
    });
  });

  group('the money', () {
    test('settled bets only, and empty at nothing', () {
      final s = _summary(matches: [_match(1, 1, 3, [_bet(margin: 1)])]);
      expect(_st(s, hole: 1)!.figure, '');
    });

    test('and it is the reader\'s own side of it', () {
      final s = _summary(
        matches: [_match(1, 1, 3, [_bet(margin: 1)])],
        money: {_me: 10, _b: -5});
      expect(_st(s, hole: 1)!.figure, '+\$10 so far');
      expect(_st(s, who: _b, hole: 1)!.figure, '−\$5 so far');
    });
  });

  group('when there is nothing to say', () {
    test('**a match with no bet yet still draws the row**', () {
      // The pill is the way in, and a state invented for a match that has not
      // started would be worse than naming the one that is coming.
      final s = _summary(matches: [_match(1, 1, 3, const [])]);
      final st = _st(s, hole: 1)!;
      expect(st.standing, 'Tee off');
      expect(st.label, 'M1');
    });

    test('a hole no match covers still draws, unlabelled', () {
      final s = _summary(matches: [_match(1, 1, 3, [_bet(margin: 1)])]);
      final st = _st(s, hole: 17)!;
      expect(st.standing, 'Tee off');
      expect(st.label, '');
    });

    test('a watcher is not in the game', () {
      final s = _summary(matches: [_match(1, 1, 3, [_bet(margin: 1)])]);
      expect(_st(s, who: 999, hole: 1), isNull);
    });

    test('no summary, no row', () {
      expect(_st(null), isNull);
    });
  });
}
