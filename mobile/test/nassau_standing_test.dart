/// test/nassau_standing_test.dart
/// ------------------------------
/// The standing ribbon's two strings on a Nassau round.
///
/// **Nassau is the case where one figure is dishonest.** Two matches are
/// always live — the nine being played and the eighteen — and the lock-screen
/// card already ruled that neither can be nominated as the headline. So the
/// first subject here is that both slots are filled.
///
/// The second is that **the margin is NEUTRAL and the colour names the leading
/// side.** It used to be written from the reader's while being coloured from
/// the leader's, and the two contradicted each other on every hole he was
/// behind: `1 DOWN` in orange, on a screen where orange was one UP. Reported
/// from a singles match, 22 Sep 2026.
///
/// The teams are FIXED, which is the whole difference from Sixes: a pairing is
/// chosen once and never re-drawn, so the colour can carry identity, the row
/// never spends width on names, and one string can serve all four phones.
/// Sixes cannot do that — its pairings re-draw every six holes — so it colours
/// the READER's side instead and says `1 DOWN` honestly.
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
      expect(st.main.label, 'F9');
      expect(st.main.value, '2 UP thru 5');
      expect(st.second!.label, 'Overall');
      expect(st.second!.value, '1 UP');
    });

    test('**the same string reaches both sides; only the tint differs**', () {
      // The row is read by four golfers at once and sits above player rows
      // tinted with the two sides' fixed colours. A margin written from the
      // reader's side while coloured from the leader's said `1 DOWN` in the
      // colour of the side that was one UP.
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 5),
        overall: _bet(margin: 1, holesPlayed: 5),
      );
      final mine = nassauStanding(s, _me, hole: 5)!;
      final them = nassauStanding(s, _themA, hole: 5)!;
      expect(them.main.value, '2 UP thru 5');
      expect(them.second!.value, '1 UP');
      expect(them.main.value, mine.main.value);
      // Team 1 is up in both bets, whoever is holding the phone.
      expect(mine.main.team, 1);
      expect(them.main.team, 1);
    });

    test('and the colour follows the LEADER when that is the other side', () {
      final s = _summary(
        front9:  _bet(margin: -2, holesPlayed: 5),
        overall: _bet(margin: -1, holesPlayed: 5),
      );
      final mine = nassauStanding(s, _me, hole: 5)!;
      expect(mine.main.value, '2 UP thru 5');
      expect(mine.main.team, 2);
    });

    test('the back nine takes over after the turn', () {
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 9, result: 'team1'),
        back9:   _bet(margin: -1, holesPlayed: 3),
        overall: _bet(margin: 1, holesPlayed: 12),
      );
      final st = nassauStanding(s, _me, hole: 12)!;
      expect(st.main.label, 'B9');
      expect(st.main.value, '1 UP thru 3');
      // **Both counts on the back nine.** Three holes into this bet, twelve
      // into the eighteen — two different questions, both worth answering.
      expect(st.second!.value, '1 UP thru 12');
    });

    test('the front nine drops the second count, because it repeats', () {
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 5),
        overall: _bet(margin: 1, holesPlayed: 5),
      );
      expect(nassauStanding(s, _me, hole: 5)!.second!.value, '1 UP');
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
      expect(nassauStanding(s, _me, hole: 4)!.main.value, 'won 3&2');
      expect(nassauStanding(s, _me, hole: 12)!.main.value, '1 UP thru 3');
    });
  });

  group('a decided bet reports its result', () {
    test('a close-out takes the app\'s own 3&2', () {
      final s = _summary(
        front9: _bet(margin: 3, holesPlayed: 7, result: 'team1',
                     decidedMargin: 3, decidedRemaining: 2),
      );
      // **`won`, never `lost`** — same rule as the live margin. `lost 3&2` in
      // the winner's colour is the contradiction one move further on.
      expect(nassauStanding(s, _me, hole: 8)!.main.value, 'won 3&2');
      expect(nassauStanding(s, _themA, hole: 8)!.main.value, 'won 3&2');
      expect(nassauStanding(s, _themA, hole: 8)!.main.team, 1);
    });

    test('played to the last hole it is 1 UP, not 1&0', () {
      final s = _summary(
        front9: _bet(margin: 1, holesPlayed: 9, result: 'team1',
                     decidedRemaining: 0),
      );
      expect(nassauStanding(s, _me, hole: 9)!.main.value, 'won 1 UP');
    });

    test('a halved nine says All Square', () {
      final s = _summary(
        front9: _bet(margin: 0, holesPlayed: 9, result: 'halved'),
      );
      expect(nassauStanding(s, _me, hole: 9)!.main.value, 'All Square');
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
      expect(st.main.label, 'Overall');
      expect(st.main.value, '2 UP thru 9',
             reason: 'as the leading slot it keeps its own count');
      expect(st.second, isNull);
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
      expect(st.main.label, '', reason: 'no nine to name on a single bet');
      expect(st.main.value, '1 UP thru 4');
      expect(st.second, isNull, reason: 'no second bet to report');
    });

    test('an 18-hole match play rides the overall alone', () {
      final s = _summary(
        overall: _bet(margin: 2, holesPlayed: 12),
        playFront: false, playBack: false,
      );
      final st = nassauStanding(s, _me, hole: 12)!;
      expect(st.main.label, '');
      expect(st.main.value, '2 UP thru 12');
      expect(st.second, isNull);
    });
  });

  group('the label is grey and the value is coloured', () {
    test('which bet it is never carries the colour', () {
      // The label cannot change, so making it the loudest element would
      // spend the row's one hue on the one thing that never moves.
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 5),
        overall: _bet(margin: 1, holesPlayed: 5),
      );
      final st = nassauStanding(s, _me, hole: 5)!;
      expect(st.main.label, 'F9');
      expect(st.main.value, startsWith('2 UP'),
             reason: 'the margin is the news, and carries the tint');
    });

    test('**the eighteen gets its OWN colour, not the nine\'s**', () {
      // A golfer can be up on the back nine and down overall; one tint for
      // both would be wrong half the time.
      final s = _summary(
        front9:  _bet(margin: 2, holesPlayed: 9, result: 'team1'),
        back9:   _bet(margin: 1, holesPlayed: 3),
        overall: _bet(margin: -2, holesPlayed: 12),
      );
      final st = nassauStanding(s, _me, hole: 12)!;
      expect(st.main.team, 1, reason: 'his side leads the back nine');
      expect(st.second!.team, 2, reason: 'and trails the eighteen');
    });
  });

  group('the colour', () {
    test('it is his side while he is up, and theirs while he is down', () {
      final up = _summary(front9: _bet(margin: 1, holesPlayed: 2));
      expect(nassauStanding(up, _me, hole: 2)!.main.team, 1);
      expect(nassauStanding(up, _themA, hole: 2)!.main.team, 1,
             reason: 'team 1 is up whoever is reading it');
    });

    test('**All Square is grey**, the same call Sixes made', () {
      // Neither side is up, so there is no side for the colour to be about;
      // picking one would read as a lead.
      final level = _summary(front9: _bet(margin: 0, holesPlayed: 2));
      expect(nassauStanding(level, _me, hole: 2)!.main.team, isNull);
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
        expect(nassauStanding(s, _me, hole: hole)!.main.team, isNotNull,
               reason: 'hole $hole');
      }
    });
  });
}
