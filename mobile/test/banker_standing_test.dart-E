/// test/banker_standing_test.dart
/// ------------------------------
/// The standing ribbon's two strings on a Banker round.
///
/// **The first row on this strip whose standing IS money.** Banker has no
/// match to be up in, no field to place in and no points — a hole is three
/// one-on-one bets and the only thing it produces is dollars. So the subject
/// here is what goes in the OTHER slot, and the order the three things that
/// want it are ranked in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/banker_standing.dart';

const _me = 11;
const _dave = 12;
const _c = 13;

BankerPlayerTotal _p(int id, double total,
        {bool cutOff = false, String? short}) =>
    BankerPlayerTotal(
      playerId: id, name: 'P$id', shortName: short ?? 'P$id',
      banking: 0, betting: total, total: total,
      handicapIndex: 10, playingHandicap: 10,
      cutOff: cutOff, cutOffHole: cutOff ? 7 : null, lossCap: null,
    );

BankerHoleState _hole(int n, {int? bankerId}) => BankerHoleState(
      hole: n, par: 4, strokeIndex: 5, isPar3: false,
      bankerId: bankerId, bankerGross: null, bankerHandicap: null,
      maxBet: null, locked: false, countered: false, tieReason: '',
      holeCapped: false, lines: const [], bankerDelta: 0, resolved: false,
      exposure: 0, exposureIfMax: 0, outstanding: const [],
    );

BankerSummary _summary({
  Map<int, double> money = const {},
  Set<int> cutOff = const {},
  int? currentBanker,
  int? nextBanker,
  bool hasCurrent = true,
}) =>
    BankerSummary(
      status: 'in_progress', handicapMode: 'net', netPercent: 100,
      minBet: 5, maxBet: 50, rotationRule: 'rotate', holeCap: null,
      rules: const BankerRules(
          playerDouble: false, counter: false,
          par3Triples: false, birdieBonus: false),
      exposureLadder: const [],
      players: [
        for (final id in const [_me, _dave, _c])
          _p(id, money[id] ?? 0,
              cutOff: cutOff.contains(id),
              short: id == _dave ? 'Dave' : 'P$id'),
      ],
      holes: const [],
      currentHole: hasCurrent ? 3 : null,
      current: hasCurrent ? _hole(3, bankerId: currentBanker) : null,
      awaitingTie: null, tieCandidates: const [],
      nextBankerId: nextBanker, nextBankerName: '',
      biggestSwings: const [], transfers: const [],
    );

void main() {
  group('the standing is the money', () {
    test('up reads a plus, down a minus', () {
      expect(bankerStanding(_summary(money: {_me: 40}), _me)!.standing, '+\$40');
      expect(bankerStanding(_summary(money: {_me: -25}), _me)!.standing, '−\$25');
    });

    test('**whole dollars, because Banker is played in them**', () {
      // A bet is named out loud on the tee and the floor is a round number;
      // cents would be an accuracy the game does not have.
      expect(bankerMoney(40.4), '+\$40');
      expect(bankerMoney(-24.6), '−\$25');
    });

    test('the minus is U+2212, not a hyphen', () {
      expect(bankerMoney(-10).startsWith('−'), isTrue);
    });

    test('**level before anything settles reads Tee off**', () {
      // The pill is the way in; losing it here gives the feature up exactly
      // when a first-time player goes looking for the leaderboard.
      expect(bankerStanding(_summary(), _me)!.standing, 'Tee off');
    });
  });

  group('**the figure is the hole, from the reader\'s side**', () {
    test('his own hole reads You bank', () {
      // One man plays three matches at once and carries the sum of them. The
      // screen says whose hole it is; it does not say it from his side.
      final s = _summary(money: {_me: 40}, currentBanker: _me);
      expect(bankerStanding(s, _me)!.figure, 'You bank');
    });

    test('somebody else\'s is named', () {
      final s = _summary(money: {_me: 40}, currentBanker: _dave);
      expect(bankerStanding(s, _me)!.figure, 'Dave banks');
    });

    test('between holes it names who is UP NEXT', () {
      // A settled hole is a stop, not a step — the screen holds on the result
      // with the rotation announced, and the next banker is known.
      final s = _summary(money: {_me: 40}, hasCurrent: false,
          nextBanker: _dave);
      expect(bankerStanding(s, _me)!.figure, 'Dave banks');
    });

    test('and says nothing when there is no hole and no next', () {
      final s = _summary(money: {_me: 40}, hasCurrent: false);
      expect(bankerStanding(s, _me)!.figure, '');
    });
  });

  group('**Capped outranks the hole**', () {
    test('a cut-off golfer reads Capped, whoever is banking', () {
      // Being cut off by the house floors every bet he can make for the rest
      // of the round, so it changes what the next eighteen numbers mean. On
      // the screen it is a small amber tag inside a card he has to scroll to.
      final s = _summary(
          money: {_me: -80}, cutOff: {_me}, currentBanker: _dave);
      expect(bankerStanding(s, _me)!.figure, 'Capped');
    });

    test('including on his own banking hole', () {
      final s = _summary(money: {_me: -80}, cutOff: {_me}, currentBanker: _me);
      expect(bankerStanding(s, _me)!.figure, 'Capped');
    });

    test('and somebody ELSE being capped does not touch his row', () {
      final s = _summary(
          money: {_me: 40}, cutOff: {_c}, currentBanker: _dave);
      expect(bankerStanding(s, _me)!.figure, 'Dave banks');
    });
  });

  group('when there is nothing to say', () {
    test('a watcher is not in the game', () {
      expect(bankerStanding(_summary(money: {_me: 40}), 999), isNull);
    });

    test('no summary, no row', () {
      expect(bankerStanding(null, _me), isNull);
    });
  });
}
