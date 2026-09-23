/// test/wolf_strokes_test.dart
/// ---------------------------
/// **One stroke source for the Wolf screen.**
///
/// The score box's dots, the inline picker's and the by-hole grid's all come
/// from `wolfStrokesForHole`. Two copies of this on one screen is how a row
/// shows one dot and the grid shows two for the same golfer on the same hole,
/// which reads as a bug in the scoring rather than in the drawing — and Wolf
/// draws it in three places, more than any other screen.
///
/// It matters more here than the count suggests: the Wolf picks his partner
/// off the tee, and who is getting a shot on THIS hole is the fact that choice
/// turns on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/screens/wolf_screen.dart'
    show wolfStrokesForHole, wolfWonTheHole;

const _me = 11;

Membership _m(int id, {int hcp = 0}) => Membership(
      id: id,
      player: PlayerProfile(
          id: id, name: 'P$id', shortName: 'P$id',
          handicapIndex: '$hcp', isPhantom: false, email: ''),
      courseHandicap: hcp,
      playingHandicap: hcp,
    );

/// One hole, with the server's own allocation on the reader's entry.
ScorecardHole _hole(int n, {int si = 1, int? serverStrokes}) => ScorecardHole(
      holeNumber: n, par: 4, strokeIndex: si, yards: 400,
      scores: [
        if (serverStrokes != null)
          HoleScoreEntry(
            playerId: _me, playerName: 'P11', holeNumber: n,
            grossScore: 5, handicapStrokes: serverStrokes,
            strokeIndex: si, par: 4,
          ),
      ],
    );

void main() {
  test('gross gives nobody a stroke', () {
    expect(
        wolfStrokesForHole(_m(_me, hcp: 18), _hole(1, serverStrokes: 1),
            mode: 'gross', netPercent: 100, lowPlaying: null),
        0);
  });

  test('**at full net it uses the SERVER\'s allocation**', () {
    // `handicapStrokes` is what the calculator actually applied, so the dots
    // report the strokes the engine scored the hole with rather than
    // re-deriving a figure that could differ by one.
    expect(
        wolfStrokesForHole(_m(_me, hcp: 18), _hole(1, si: 1, serverStrokes: 2),
            mode: 'net', netPercent: 100, lowPlaying: null),
        2);
  });

  test('below 100% it allocates the reduced allowance itself', () {
    // The server's figure is the FULL-handicap one, so a partial allowance
    // has to be spread here: 18 at 50% is 9 strokes, which fall on the nine
    // hardest holes. SI 1 gets one; SI 10 gets none.
    expect(
        wolfStrokesForHole(_m(_me, hcp: 18), _hole(1, si: 1, serverStrokes: 1),
            mode: 'net', netPercent: 50, lowPlaying: null),
        1);
    expect(
        wolfStrokesForHole(_m(_me, hcp: 18), _hole(2, si: 10, serverStrokes: 1),
            mode: 'net', netPercent: 50, lowPlaying: null),
        0);
  });

  group('strokes off the low golfer', () {
    test('the low man gets nothing', () {
      expect(
          wolfStrokesForHole(_m(_me, hcp: 4), _hole(1, si: 1),
              mode: 'strokes_off', netPercent: 100, lowPlaying: 4),
          0);
    });

    test('the difference falls on the hardest holes', () {
      // Off 12 against a low of 4 is eight strokes: SI 1..8.
      expect(
          wolfStrokesForHole(_m(_me, hcp: 12), _hole(1, si: 8),
              mode: 'strokes_off', netPercent: 100, lowPlaying: 4),
          1);
      expect(
          wolfStrokesForHole(_m(_me, hcp: 12), _hole(2, si: 9),
              mode: 'strokes_off', netPercent: 100, lowPlaying: 4),
          0);
    });

    test('and it scales with the allowance', () {
      // Eight at 50% is four: SI 1..4, so SI 8 no longer strokes.
      expect(
          wolfStrokesForHole(_m(_me, hcp: 12), _hole(1, si: 8),
              mode: 'strokes_off', netPercent: 50, lowPlaying: 4),
          0);
      expect(
          wolfStrokesForHole(_m(_me, hcp: 12), _hole(1, si: 4),
              mode: 'strokes_off', netPercent: 50, lowPlaying: 4),
          1);
    });
  });

  group('**an unscored hole still reports its strokes**', () {
    test('because that is the hole the partner is picked for', () {
      // The allocation is known up front; waiting for a score would blank the
      // dots on exactly the hole the Wolf is standing on.
      expect(
          wolfStrokesForHole(_m(_me, hcp: 18), _hole(1, si: 1),
              mode: 'net', netPercent: 100, lowPlaying: null),
          1);
    });

    test('no hole at all is no strokes, not a crash', () {
      expect(
          wolfStrokesForHole(_m(_me, hcp: 18), null,
              mode: 'net', netPercent: 100, lowPlaying: null),
          0);
    });
  });

  group('**the scorecard marks a SIDE, not a score**', () {
    // The house rule is that a hole is marked when ONE ball wins it — Skins
    // fills the winning cell green, Rabbit greens the outright winner. A Wolf
    // hole is won by the Wolf's side or by the opponents, so pointing at one
    // cell would name a man who may have been carried. The server says as much
    // by sending `winner_id: None` for this game.
    test('the Wolf and his partner are both marked when their side wins', () {
      expect(wolfWonTheHole('wolf', 'wolf'), isTrue);
      expect(wolfWonTheHole('wolf', 'partner'), isTrue);
      expect(wolfWonTheHole('wolf', 'opponent'), isFalse);
    });

    test('and the opponents are, when theirs does', () {
      expect(wolfWonTheHole('opponents', 'opponent'), isTrue);
      expect(wolfWonTheHole('opponents', 'wolf'), isFalse);
      expect(wolfWonTheHole('opponents', 'partner'), isFalse);
    });

    test('**a tie marks nobody**', () {
      // Both sides drew it. Tinting both would say two sides won; tinting
      // neither is the truth.
      for (final r in const ['wolf', 'partner', 'opponent']) {
        expect(wolfWonTheHole('tie', r), isFalse, reason: r);
      }
    });

    test('an undecided hole marks nobody either', () {
      expect(wolfWonTheHole(null, 'wolf'), isFalse);
      expect(wolfWonTheHole('wolf', null), isFalse);
    });
  });
}
