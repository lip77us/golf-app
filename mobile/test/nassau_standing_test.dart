/// test/nassau_standing_test.dart
/// ------------------------------
/// The standing ribbon's two strings on a Nassau round.
///
/// **Nassau is the case where one figure is dishonest.** Two matches are
/// always live — the nine being played and the eighteen — and the lock-screen
/// card already ruled that neither can be nominated as the headline. So the
/// subject here is that both slots are filled, and that each is written from
/// the reader's side.
///
/// The teams are FIXED, which is the whole difference from Sixes: a pairing is
/// chosen once and never re-drawn, so the colour can carry identity and the
/// row never spends width on names.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/nassau_standing.dart';

const _me = 11;
const _partner = 12;
const _themA = 21;
const _themB = 22;

NassauPlayerInfo _p(int id, String n) =>
    NassauPlayerInfo(playerId: id, name: n, shortName: n);

NassauBetResult _bet({int margin = 0, int holesPlayed = 0, String? result,
                      int? decidedMargin, int? decidedRemaining}) =>
    NassauBetResult(result: result, margin: margin, holesPlayed: holesPlayed,
                    decidedMargin: decidedMargin,
                    decidedRemaining: decidedRemaining);

NassauSummary _summary({
  NassauBetResult? front9,
  NassauBetResult? back9,
  NassauBetResult? overall,
  bool playFront = true,
  bool playBack = true,
  bool playOverall = true,
  bool singleMatch = false,
}) =>
    NassauSummary(
      status: 'in_progress', gameType: 'nassau', variant: 'none',
      handicapMode: 'net', netPercent: 100, pressMode: 'none',
      betUnit: 5, pressUnit: 5,
      playFront: playFront, playBack: playBack, playOverall: playOverall,
      singleMatch: singleMatch,
      team1: [_p(_me, 'Paul'), _p(_partner, 'Jim')],
      team2: [_p(_themA, 'Larry'), _p(_themB, 'GL')],
      front9:  front9  ?? _bet(),
      back9:   back9   ?? _bet(),
      overall: overall ?? _bet(),
      presses: const [],
      bottomPresses: const [],
      payoutFront9: 0, payoutBack9: 0, payoutOverall: 0, payoutPresses: 0,
      payoutTopTotal: 0, payoutBottomFront9: 0, payoutBottomBack9: 0,
      payoutBottomOverall: 0, payoutBottomPresses: 0, payoutBottomTotal: 0,
      payoutTotal: 0, payoutTotalCapped: 0,
      holes: const [], canPress: false,
    );

void main() {
  group('both bets are reported, because both are live', () {
    test('the nine on screen leads and the overall follows', () {
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 5),
        overall: _bet(margin: 1, holesPlayed: 5),
      );
      final st = nassauStanding(s, _me, hole: 5)!;
      expect(st.standing, 'F9 2 UP thru 5');
      expect(st.figure, 'Overall 1 UP');
    });

    test('each is written from the reader\'s side', () {
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 5),
        overall: _bet(margin: 1, holesPlayed: 5),
      );
      final them = nassauStanding(s, _themA, hole: 5)!;
      expect(them.standing, 'F9 2 DOWN thru 5');
      expect(them.figure, 'Overall 1 DOWN');
    });

    test('the back nine takes over after the turn', () {
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 9, result: 'team1'),
        back9:   _bet(margin: -1, holesPlayed: 3),
        overall: _bet(margin: 1, holesPlayed: 12),
      );
      final st = nassauStanding(s, _me, hole: 12)!;
      expect(st.standing, 'B9 1 DOWN thru 3');
      // **Both counts on the back nine.** Three holes into this bet, twelve
      // into the eighteen — two different questions, both worth answering.
      expect(st.figure, 'Overall 1 UP thru 12');
    });

    test('the front nine drops the second count, because it repeats', () {
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 5),
        overall: _bet(margin: 1, holesPlayed: 5),
      );
      expect(nassauStanding(s, _me, hole: 5)!.figure, 'Overall 1 UP');
    });

    test('**backing up to the front nine reports the front nine**', () {
      // The same rule Sixes needed: the header, the player rows and the
      // scores on screen are all that nine, and a standing describing the
      // other one is the only thing disagreeing with the rest of the screen.
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 9, result: 'team1',
                      decidedMargin: 3, decidedRemaining: 2),
        back9:   _bet(margin: -1, holesPlayed: 3),
        overall: _bet(margin: 1, holesPlayed: 12),
      );
      expect(nassauStanding(s, _me, hole: 4)!.standing, 'F9 won 3&2');
      expect(nassauStanding(s, _me, hole: 12)!.standing, 'B9 1 DOWN thru 3');
    });
  });

  group('a decided bet reports its result', () {
    test('a close-out takes the app\'s own 3&2', () {
      final s = _summary(
        front9: _bet(margin: 3, holesPlayed: 7, result: 'team1',
                     decidedMargin: 3, decidedRemaining: 2),
      );
      expect(nassauStanding(s, _me, hole: 8)!.standing, 'F9 won 3&2');
      expect(nassauStanding(s, _themA, hole: 8)!.standing, 'F9 lost 3&2');
    });

    test('played to the last hole it is 1 UP, not 1&0', () {
      final s = _summary(
        front9: _bet(margin: 1, holesPlayed: 9, result: 'team1',
                     decidedRemaining: 0),
      );
      expect(nassauStanding(s, _me, hole: 9)!.standing, 'F9 won 1 UP');
    });

    test('a halved nine says All Square', () {
      final s = _summary(
        front9: _bet(margin: 0, holesPlayed: 9, result: 'halved'),
      );
      expect(nassauStanding(s, _me, hole: 9)!.standing, 'F9 All Square');
    });
  });

  group('nothing is said about golf nobody has played', () {
    test('an unplayed nine falls through to the overall', () {
      // On the 10th tee the front nine is history and the eighteen is the
      // live bet — the row leads with it rather than reporting a back nine
      // with no holes in it.
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 9, result: 'team1'),
        back9:   _bet(),
        overall: _bet(margin: 2, holesPlayed: 9),
      );
      final st = nassauStanding(s, _me, hole: 10)!;
      expect(st.standing, 'Overall 2 UP thru 9',
             reason: 'as the leading slot it keeps its own count');
      expect(st.figure, '');
    });

    test('before any score at all, nothing', () {
      expect(nassauStanding(_summary(), _me, hole: 1), isNull);
    });

    test('a watcher gets nothing — he is on neither side', () {
      final s = _summary(front9: _bet(margin: 1, holesPlayed: 2));
      expect(nassauStanding(s, 999, hole: 2), isNull);
    });
  });

  group('a single-bet Nassau names no nine', () {
    test('Nassau Nine is one match over the holes played', () {
      final s = _summary(
        front9: _bet(margin: 1, holesPlayed: 4), singleMatch: true,
      );
      final st = nassauStanding(s, _me, hole: 4)!;
      expect(st.standing, '1 UP thru 4');
      expect(st.figure, '', reason: 'there is no second bet to report');
    });

    test('an 18-hole match play rides the overall alone', () {
      final s = _summary(
        overall: _bet(margin: 2, holesPlayed: 12),
        playFront: false, playBack: false,
      );
      final st = nassauStanding(s, _me, hole: 12)!;
      expect(st.standing, '2 UP thru 12');
      expect(st.figure, '');
    });
  });

  group('the colour', () {
    test('it is his side while he is up, and theirs while he is down', () {
      final up = _summary(front9: _bet(margin: 1, holesPlayed: 2));
      expect(nassauStanding(up, _me, hole: 2)!.team, 1);
      expect(nassauStanding(up, _themA, hole: 2)!.team, 1,
             reason: 'team 1 is up whoever is reading it');
    });

    test('**All Square is grey**, the same call Sixes made', () {
      // Neither side is up, so there is no side for the colour to be about;
      // picking one would read as a lead.
      final level = _summary(front9: _bet(margin: 0, holesPlayed: 2));
      expect(nassauStanding(level, _me, hole: 2)!.team, isNull);
    });

    test('it never has to be withheld — the teams do not re-draw', () {
      // The whole difference from Sixes. A pairing is chosen once, so blue
      // means the same two golfers on the first tee and the last green.
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 9, result: 'team1'),
        back9:   _bet(margin: 1, holesPlayed: 3),
        overall: _bet(margin: 3, holesPlayed: 12),
      );
      for (final hole in [4, 9, 10, 12]) {
        expect(nassauStanding(s, _me, hole: hole)!.team, isNotNull,
               reason: 'hole $hole');
      }
    });
  });
}
