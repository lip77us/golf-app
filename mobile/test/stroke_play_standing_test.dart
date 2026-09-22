/// test/stroke_play_standing_test.dart
/// -----------------------------------
/// The standing ribbon's two strings on a Stroke Play round.
///
/// The packet drew this row itself — `2nd of 38 · −1 · thru 4` — so the
/// subject here is the two rules the drawing does not settle: when a place can
/// honestly be reported, and who counts as being in the field.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/stroke_play_standing.dart';

const _me = 11;
const _b = 12;
const _c = 13;

Membership _m(int id, {int hcp = 0, bool phantom = false}) => Membership(
      id: id,
      player: PlayerProfile(
          id: id, name: 'P$id', shortName: 'P$id',
          handicapIndex: '$hcp', isPhantom: phantom, email: ''),
      courseHandicap: hcp,
      playingHandicap: hcp,
    );

/// A card where every hole is a par 4 and [scores] maps player → gross list.
///
/// Stroke index ascends with the hole number, so an 18 handicap gets exactly
/// one a hole — which is what makes the net assertions checkable by eye.
Scorecard _card(Map<int, List<int?>> scores,
                {int holes = 18, int strokes = 0}) {
  final holeList = <ScorecardHole>[];
  for (var h = 1; h <= holes; h++) {
    holeList.add(ScorecardHole(
      holeNumber: h, par: 4, strokeIndex: h, yards: 400,
      scores: [
        for (final e in scores.entries)
          if (e.value.length >= h && e.value[h - 1] != null)
            HoleScoreEntry(
              playerId: e.key, playerName: 'P${e.key}', holeNumber: h,
              grossScore: e.value[h - 1], handicapStrokes: strokes,
              strokeIndex: h, par: 4,
            ),
      ],
    ));
  }
  return Scorecard(
      foursomeId: 1, groupNumber: 1, holes: holeList, totals: const []);
}

StrokePlayStanding? _standing(Scorecard card, List<Membership> players,
        {int? who = _me, bool alone = true}) =>
    strokePlayStanding(
      scorecard: card, players: players, playerId: who,
      handicapMode: 'gross', netPercent: 100,
      holesInPlay: List.generate(18, (i) => i + 1),
      fieldIsThisGroup: alone,
    );

void main() {
  group('the two facts the row reports', () {
    test('the place leads and the score follows', () {
      // Par 4s: me at 3,4 is one under; B at 5,5 is two over.
      final card = _card({_me: [3, 4], _b: [5, 5]});
      final st = _standing(card, [_m(_me), _m(_b)])!;
      expect(st.place, '1st of 2');
      expect(st.score, '−1 thru 2');
    });

    test('level with par reads E, not 0', () {
      final card = _card({_me: [4, 4], _b: [5, 5]});
      expect(_standing(card, [_m(_me), _m(_b)])!.score, 'E thru 2');
    });

    test('over par takes a plus', () {
      final card = _card({_me: [5, 5], _b: [4, 4]});
      expect(_standing(card, [_m(_me), _m(_b)])!.score, '+2 thru 2');
    });

    test('the minus is U+2212, not a hyphen', () {
      // The same minus the money figure uses, and visibly the right length
      // beside a `+`.
      final card = _card({_me: [3, 3]});
      expect(_standing(card, [_m(_me)])!.score.startsWith('−'), isTrue);
    });
  });

  group('the place', () {
    test('it ranks on net to par', () {
      final card = _card({_me: [4, 4], _b: [3, 3], _c: [5, 5]});
      expect(_standing(card, [_m(_me), _m(_b), _m(_c)])!.place, '2nd of 3');
    });

    test('**a tie shows the T** — a net field ties constantly', () {
      final card = _card({_me: [4, 4], _b: [4, 4], _c: [5, 5]});
      expect(_standing(card, [_m(_me), _m(_b), _m(_c)])!.place, 'T1st of 3');
    });

    test('the suffixes are right, including the teens', () {
      expect(placeLabel(1, false), '1st');
      expect(placeLabel(2, false), '2nd');
      expect(placeLabel(3, false), '3rd');
      expect(placeLabel(4, false), '4th');
      expect(placeLabel(11, false), '11th');
      expect(placeLabel(12, false), '12th');
      expect(placeLabel(13, false), '13th');
      expect(placeLabel(21, false), '21st');
      expect(placeLabel(3, true), 'T3rd');
    });

    test('a golfer with no score is not last — he is not on the board', () {
      // Counting him would move everybody else up a place for nothing.
      final card = _card({_me: [4, 4], _b: [5, 5]});
      final st = _standing(card, [_m(_me), _m(_b), _m(_c)])!;
      expect(st.place, '1st of 2');
    });

    test('a phantom is not in the field', () {
      final card = _card({_me: [4, 4], _b: [3, 3]});
      final st = _standing(card, [_m(_me), _m(_b), _m(_c, phantom: true)])!;
      expect(st.place, '2nd of 2');
    });
  });

  group('**the place is withheld when the group is not the field**', () {
    test('a multi-group round reports the score alone', () {
      // Score entry holds ONE foursome's card. A rank computed here would be
      // a place among four golfers wearing the words of a place in the field,
      // and there is no round-level Stroke Play result to ask instead.
      final card = _card({_me: [3, 4], _b: [5, 5]});
      final st = _standing(card, [_m(_me), _m(_b)], alone: false)!;
      expect(st.place, '');
      expect(st.score, '−1 thru 2');
    });

    test('a single-group round reports it, because the group IS the field', () {
      final card = _card({_me: [3, 4], _b: [5, 5]});
      expect(_standing(card, [_m(_me), _m(_b)], alone: true)!.place,
             '1st of 2');
    });
  });

  group('when there is nothing to say', () {
    test('before the reader has a score, nothing', () {
      final card = _card({_b: [4, 4]});
      expect(_standing(card, [_m(_me), _m(_b)]), isNull);
    });

    test('a watcher is not in the field', () {
      final card = _card({_me: [4, 4]});
      expect(_standing(card, [_m(_me)], who: 999), isNull);
    });

    test('no card, no row', () {
      expect(strokePlayStanding(
        scorecard: null, players: const [], playerId: _me,
        handicapMode: 'gross', netPercent: 100,
        holesInPlay: const [], fieldIsThisGroup: true,
      ), isNull);
    });
  });

  group('handicap', () {
    test('gross counts the gross', () {
      final card = _card({_me: [5, 5]});
      expect(_standing(card, [_m(_me, hcp: 18)])!.score, '+2 thru 2');
    });

    test('**at 100% it uses the SERVER\'s strokes, not its own sum**', () {
      // `handicapStrokes` on the score entry is what the calculator actually
      // applied, so the row reports the net the engine settled on rather than
      // re-deriving one that could differ by a stroke. The same rule the
      // stroke dots follow — which is why they come off one helper now.
      final card = _card({_me: [5, 5]}, strokes: 1);
      final st = strokePlayStanding(
        scorecard: card, players: [_m(_me, hcp: 18)], playerId: _me,
        handicapMode: 'net', netPercent: 100,
        holesInPlay: List.generate(18, (i) => i + 1),
        fieldIsThisGroup: true,
      )!;
      expect(st.score, 'E thru 2');
    });

    test('at a partial allowance it allocates by stroke index', () {
      // Below 100% the server's figure is the full-handicap one, so the row
      // has to spread the reduced allowance itself — 18 at 50% is 9 strokes,
      // which fall on the nine hardest holes. These two are SI 1 and 2.
      final card = _card({_me: [5, 5]}, strokes: 1);
      final st = strokePlayStanding(
        scorecard: card, players: [_m(_me, hcp: 18)], playerId: _me,
        handicapMode: 'net', netPercent: 50,
        holesInPlay: List.generate(18, (i) => i + 1),
        fieldIsThisGroup: true,
      )!;
      expect(st.score, 'E thru 2');
    });
  });
}
