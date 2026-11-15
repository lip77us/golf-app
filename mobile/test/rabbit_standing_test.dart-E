/// test/rabbit_standing_test.dart
/// ------------------------------
/// The standing ribbon's two strings on a Rabbit round.
///
/// **Rabbit has one distinguished party, not two sides.** There is no margin,
/// no place and no team — the question is who is holding it, and the answer is
/// one name or nobody. So the subject here is the holder walk: who had it at
/// the hole on screen, which is not the same as who has it now.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/rabbit_standing.dart';

const _me = 11;
const _dave = 12;

/// `isScored` is derived — a hole counts as played once an entry carries a
/// net — so an unscored hole is one with no nets on it.
RabbitHole _hole(int n, {int segment = 1, int? holderId, String? holderShort,
                         int lead = 0, bool scored = true}) =>
    RabbitHole(
      hole: n, segment: segment, par: 4,
      winnerId: holderId, winnerShort: holderShort,
      holderId: holderId, holderShort: holderShort, lead: lead,
      event: null,
      entries: [
        for (final id in const [_me, _dave])
          RabbitHoleEntry(
            playerId: id, shortName: id == _me ? 'Paul' : 'Dave',
            name: id == _me ? 'Paul' : 'Dave',
            netScore: scored ? 4 : null, gross: scored ? 4 : null,
            strokes: 0, isWinner: id == holderId, isHolder: id == holderId,
          ),
      ],
    );

RabbitSegment _leg(int index, int start, int end,
                   {int? holderId, String? holderShort, bool complete = false}) =>
    RabbitSegment(
      index: index, isExtra: false, startHole: start, endHole: end,
      holes: end - start + 1, holderId: holderId, holderShort: holderShort,
      lead: 0, complete: complete, value: 5, payout: 0,
    );

RabbitSummary _summary({
  List<RabbitHole> holes = const [],
  List<RabbitSegment> segments = const [],
  Map<int, double> money = const {},
}) =>
    RabbitSummary(
      status: 'in_progress', handicapMode: 'net', netPercent: 100,
      accumulate: true, numSegments: segments.isEmpty ? 1 : segments.length,
      segments: segments,
      players: [
        RabbitPlayerTotal(playerId: _me, name: 'Paul', shortName: 'Paul',
            money: money[_me] ?? 0, segmentsWon: 0, phcpInPlay: 0),
        RabbitPlayerTotal(playerId: _dave, name: 'Dave', shortName: 'Dave',
            money: money[_dave] ?? 0, segmentsWon: 0, phcpInPlay: 0),
      ],
      holes: holes,
      currentHolderId: null, currentHolderShort: null,
      currentLead: 0, currentSegment: 1,
      betUnit: 5, entry: 5, pot: 10, segValue: 5,
    );

void main() {
  group('the row names the holder', () {
    test('his own rabbit reads You have it', () {
      final s = _summary(
        holes: [_hole(1, holderId: _me, holderShort: 'Paul')],
        segments: [_leg(1, 1, 18)],
      );
      expect(rabbitStanding(s, _me, hole: 1)!.standing, 'You have it');
    });

    test('somebody else\'s is named', () {
      // **Named, not `Rabbit: DM`.** The leg rows abbreviate because they
      // repeat eighteen times; this says it once, so it can use words.
      final s = _summary(
        holes: [_hole(1, holderId: _dave, holderShort: 'Dave')],
        segments: [_leg(1, 1, 18)],
      );
      expect(rabbitStanding(s, _me, hole: 1)!.standing, 'Dave has it');
    });

    test('**mint means holds it, and only when it is his**', () {
      // The lock card's own ruling: a game with one distinguished party frees
      // mint to mean *holds it*, which it could never mean on a card with two
      // sides.
      final mine = _summary(
        holes: [_hole(1, holderId: _me, holderShort: 'Paul')],
        segments: [_leg(1, 1, 18)]);
      final theirs = _summary(
        holes: [_hole(1, holderId: _dave, holderShort: 'Dave')],
        segments: [_leg(1, 1, 18)]);
      expect(rabbitStanding(mine, _me, hole: 1)!.mine, isTrue);
      expect(rabbitStanding(theirs, _me, hole: 1)!.mine, isFalse);
    });
  });

  group('nobody on it', () {
    test('a live leg is Loose, not silent', () {
      // Saying nothing would read as a row that had failed to load.
      final s = _summary(
        holes: [_hole(1)], segments: [_leg(1, 1, 18)]);
      final st = rabbitStanding(s, _me, hole: 1)!;
      expect(st.standing, 'Loose');
      expect(st.mine, isFalse);
    });

    test('a leg that ran out with nobody on it was Halved', () {
      // A different fact from a live leg nobody has taken yet.
      final s = _summary(
        holes: [_hole(1), _hole(2)],
        segments: [_leg(1, 1, 2, complete: true)]);
      expect(rabbitStanding(s, _me, hole: 2)!.standing, 'Halved');
    });
  });

  group('**the holder is read at the hole on screen**', () {
    test('backing up reports who had it then', () {
      // The scores and the tinted row on screen have backed up with it.
      final s = _summary(
        holes: [
          _hole(1, holderId: _me,   holderShort: 'Paul'),
          _hole(2, holderId: _me,   holderShort: 'Paul'),
          _hole(3, holderId: _dave, holderShort: 'Dave'),
        ],
        segments: [_leg(1, 1, 18)]);
      expect(rabbitStanding(s, _me, hole: 3)!.standing, 'Dave has it');
      expect(rabbitStanding(s, _me, hole: 1)!.standing, 'You have it');
    });

    test('an unscored hole carries the holder forward from the last one', () {
      final s = _summary(
        holes: [
          _hole(1, holderId: _dave, holderShort: 'Dave'),
          _hole(2, scored: false),
        ],
        segments: [_leg(1, 1, 18)]);
      expect(rabbitStanding(s, _me, hole: 2)!.standing, 'Dave has it');
    });

    test('the walk stops at the LEG boundary', () {
      // A segment resets — the holder from the previous one is a different
      // game, and carrying him across would credit a rabbit nobody holds.
      final s = _summary(
        holes: [
          _hole(1, segment: 1, holderId: _dave, holderShort: 'Dave'),
          _hole(7, segment: 2, scored: false),
        ],
        segments: [_leg(1, 1, 6), _leg(2, 7, 12)]);
      expect(rabbitStanding(s, _me, hole: 7)!.standing, 'Loose');
    });

    test('it follows the group\'s play order, not the hole number', () {
      // Off a shotgun from the 13th, hole 1 is played near the END — walking
      // back from it must reach 18, not 1-minus-nothing.
      final order = [for (var h = 13; h <= 18; h++) h,
                     for (var h = 1; h <= 12; h++) h];
      final s = _summary(
        holes: [
          _hole(13, holderId: _dave, holderShort: 'Dave'),
          _hole(14, scored: false),
        ],
        segments: [_leg(1, 1, 18)]);
      expect(rabbitHolderAt(s, 14, order).short, 'Dave');
    });
  });

  group('the money', () {
    test('settled legs only, and empty at nothing', () {
      final live = _summary(
        holes: [_hole(1, holderId: _me, holderShort: 'Paul')],
        segments: [_leg(1, 1, 18)]);
      expect(rabbitStanding(live, _me, hole: 1)!.figure, '');
    });

    test('a decided leg puts it beside the holder', () {
      final s = _summary(
        holes: [_hole(1, holderId: _me, holderShort: 'Paul')],
        segments: [_leg(1, 1, 18)], money: {_me: 10, _dave: -10});
      expect(rabbitStanding(s, _me, hole: 1)!.figure, '+\$10 so far');
      expect(rabbitStanding(s, _dave, hole: 1)!.figure, '−\$10 so far');
    });
  });

  group('when there is nothing to say', () {
    test('**before the first score the row still draws**', () {
      // The pill is the way in; losing it here gives the feature up exactly
      // when a first-time player goes looking for the leaderboard.
      final s = _summary(
        holes: [_hole(1, scored: false)], segments: [_leg(1, 1, 18)]);
      expect(rabbitStanding(s, _me, hole: 1)!.standing, 'Tee off');
    });

    test('a watcher is not in the game', () {
      final s = _summary(
        holes: [_hole(1, holderId: _me, holderShort: 'Paul')],
        segments: [_leg(1, 1, 18)]);
      expect(rabbitStanding(s, 999, hole: 1), isNull);
    });

    test('no summary, no row', () {
      expect(rabbitStanding(null, _me, hole: 1), isNull);
    });
  });
}
