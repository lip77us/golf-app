/// test/triple_nassau_standing_test.dart
/// -------------------------------------
/// The standing ribbon on a Triple Nassau round.
///
/// Three golfers, no teams, every pair playing its own match — so the reader
/// is in TWO at once and both slots are spoken for. **A bare number is
/// worthless here**: the confusion this game produces is knowing you are two
/// up and not remembering two up on whom.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/triple_nassau_standing.dart';

const _me = 11;
const _js = 12;
const _dp = 13;

NassauBetResult _bet({
  int margin = 0,
  int holesPlayed = 4,
  String? result,
  int? decidedMargin,
  int? decidedRemaining,
}) =>
    NassauBetResult(
      margin: margin, holesPlayed: holesPlayed, result: result,
      decidedMargin: decidedMargin, decidedRemaining: decidedRemaining,
    );

NassauSummary _nassau({
  NassauBetResult? front9,
  NassauBetResult? back9,
  NassauBetResult? overall,
}) =>
    NassauSummary(
      status: 'in_progress', gameType: 'nassau', variant: 'none',
      handicapMode: 'net', netPercent: 100, pressMode: 'none',
      betUnit: 5, pressUnit: 5,
      playFront: true, playBack: true, playOverall: true,
      singleMatch: false,
      team1: const [], team2: const [],
      front9: front9 ?? _bet(), back9: back9 ?? _bet(),
      overall: overall ?? _bet(),
      presses: const [], bottomPresses: const [],
      payoutFront9: 0, payoutBack9: 0, payoutOverall: 0, payoutPresses: 0,
      payoutTopTotal: 0, payoutBottomFront9: 0, payoutBottomBack9: 0,
      payoutBottomOverall: 0, payoutBottomPresses: 0, payoutBottomTotal: 0,
      payoutTotal: 0, payoutTotalCapped: 0,
      holes: const [], canPress: false,
    );

TripleNassauSummary _summary(List<TripleNassauMatch> matches) =>
    TripleNassauSummary(
      status: 'in_progress', handicapMode: 'net', netPercent: 100,
      pressMode: 'none', betUnit: 5, pressUnit: 5,
      players: const [
        TripleNassauPlayer(playerId: _me, name: 'Paul', shortName: 'Paul',
            playingHandicap: 8, net: 0),
        TripleNassauPlayer(playerId: _js, name: 'Jim', shortName: 'JS',
            playingHandicap: 12, net: 0),
        TripleNassauPlayer(playerId: _dp, name: 'Dave', shortName: 'DP',
            playingHandicap: 20, net: 0),
      ],
      matches: matches,
      scorecard: const [],
    );

TripleNassauMatch _match(int p1, int p2, NassauSummary n) =>
    TripleNassauMatch(
      gameType: 'triple_1', player1Id: p1, player2Id: p2, match: n);

void main() {
  group('**both slots are spoken for, and each names its opponent**', () {
    test('the reader\'s two matches, labelled', () {
      final s = _summary([
        _match(_me, _js, _nassau(front9: _bet(margin: 2))),
        _match(_me, _dp, _nassau(front9: _bet(margin: -1))),
        _match(_js, _dp, _nassau(front9: _bet(margin: 3))),
      ]);
      final st = tripleNassauStanding(s, _me, hole: 4)!;
      expect(st.first.label, 'v JS');
      expect(st.second!.label, 'v DP');
    });

    test('**never a direction word** — `2 UP` on both sides of a match', () {
      // A direction word is relative to a reader, and in the third match —
      // the two other men — there is no reader to be relative to. One rule
      // for all three is what keeps the row readable.
      final s = _summary([
        _match(_me, _js, _nassau(front9: _bet(margin: -2))),
        _match(_me, _dp, _nassau(front9: _bet(margin: 1))),
      ]);
      final st = tripleNassauStanding(s, _me, hole: 4)!;
      expect(st.first.value, '2 UP');
      expect(st.first.value.contains('DN'), isFalse);
    });

    test('**the colour is the LEADER\'s own**', () {
      // Each of the three has a colour on this screen, so the leader's says
      // who is ahead inside the same glyph that carries the number.
      final s = _summary([
        _match(_me, _js, _nassau(front9: _bet(margin: 2))),   // me up
        _match(_me, _dp, _nassau(front9: _bet(margin: -1))),  // DP up
      ]);
      final st = tripleNassauStanding(s, _me, hole: 4)!;
      expect(st.first.leaderId, _me);
      expect(st.second!.leaderId, _dp);
    });

    test('level takes no colour', () {
      final s = _summary([_match(_me, _js, _nassau(front9: _bet()))]);
      final st = tripleNassauStanding(s, _me, hole: 4)!;
      expect(st.first.value, 'ALL SQ');
      expect(st.first.leaderId, isNull);
    });
  });

  group('**closed out, not merely finished**', () {
    test('a decided margin reports the close-out, live or not', () {
      // A nine's `result` is only set once its ninth hole is in, but a match
      // decided 4&2 has been over for two holes — and a row still reporting
      // it as live is the one figure here a golfer would act on wrongly.
      final s = _summary([
        _match(_me, _js, _nassau(
            front9: _bet(margin: 4, holesPlayed: 7,
                         decidedMargin: 4, decidedRemaining: 2))),
      ]);
      final st = tripleNassauStanding(s, _me, hole: 8)!;
      expect(st.first.value, '4&2');
      // Grey: the match is over, and the colour means *live, and this man is
      // ahead*.
      expect(st.first.leaderId, isNull);
    });

    test('a halved nine says so', () {
      final s = _summary([
        _match(_me, _js,
            _nassau(front9: _bet(holesPlayed: 9, result: 'halved'))),
      ]);
      expect(tripleNassauStanding(s, _me, hole: 9)!.first.value, 'HALVED');
    });
  });

  group('the bet follows the hole on screen', () {
    test('the back nine takes over after the turn', () {
      final s = _summary([
        _match(_me, _js, _nassau(
            front9: _bet(margin: 3, holesPlayed: 9, result: 'team1'),
            back9: _bet(margin: -1, holesPlayed: 3))),
      ]);
      expect(tripleNassauStanding(s, _me, hole: 12)!.first.value, '1 UP');
    });
  });

  group('when there is nothing to say', () {
    test('an unplayed bet reads Tee off', () {
      final s = _summary([
        _match(_me, _js, _nassau(front9: _bet(holesPlayed: 0))),
      ]);
      expect(tripleNassauStanding(s, _me, hole: 1)!.first.value, 'Tee off');
    });

    test('a watcher is in none of the three matches', () {
      final s = _summary([_match(_js, _dp, _nassau())]);
      expect(tripleNassauStanding(s, _me, hole: 1), isNull);
    });

    test('no summary, no row', () {
      expect(tripleNassauStanding(null, _me, hole: 1), isNull);
    });
  });
}
