/// test/quota_nassau_standing_test.dart
/// -----------------------------------
/// The standing row on a cup's Four Ball Quota.
///
/// **The margin is POINTS, not holes.** `3 UP` is the Nassau form and it is
/// wrong here: every golfer plays a quota (36 − course handicap) and the match
/// is the gap between how far each is beating it, so a golfer three quota
/// points clear may be level on holes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/quota_nassau_standing.dart';

const _me = 11, _them = 12, _other = 21;

QuotaNassauPlayerInfo _p(int id, String short) => QuotaNassauPlayerInfo(
    playerId: id, name: 'Player $id', shortName: short, quota: 36);

QuotaNassauHoleResult _hole(int n, {double? p1}) => QuotaNassauHoleResult(
      hole: n, p1Stableford: 2, p2Stableford: 2,
      p1VsQuota: p1, p2VsQuota: p1 == null ? null : 0,
      front9Margin: null, back9Margin: null, overallMargin: null,
    );

QuotaNassauMatchSummary _match({
  int a = _me, int b = _them,
  String aShort = 'Yau', String bShort = 'Lee',
  double front = 0, double back = 0, double overall = 0,
  List<QuotaNassauHoleResult> holes = const [],
}) =>
    QuotaNassauMatchSummary(
      player1: _p(a, aShort), player2: _p(b, bShort),
      front9 : QuotaNassauSegment(result: null, margin: front),
      back9  : QuotaNassauSegment(result: null, margin: back),
      overall: QuotaNassauSegment(result: null, margin: overall),
      holes  : holes,
    );

QuotaNassauSummary _summary(List<QuotaNassauMatchSummary> matches) =>
    QuotaNassauSummary(
      status: 'in_progress', matches: matches, phantom: null,
      team1Colour: 'Red', team2Colour: 'Blue');

void main() {
  group('**the margin is points, and it says so**', () {
    test('it names the leader and counts points, never holes', () {
      final s = _summary([
        _match(front: 3, overall: 3, holes: [_hole(1, p1: 1)]),
      ]);
      final st = quotaNassauStanding(s, _me, hole: 1)!;
      expect(st.main.label, 'F9');
      expect(st.main.value, 'Yau +3 pts');
      expect(st.main.value.contains('UP'), isFalse);
    });

    test('a half is real and is written as one', () {
      // A hole shared on Stableford points leaves a margin of 2.5. Rounding
      // it away would report a match that is not the one being played.
      final s = _summary([
        _match(front: 2.5, overall: 2.5, holes: [_hole(1, p1: 1)]),
      ]);
      expect(quotaNassauStanding(s, _me, hole: 1)!.main.value, 'Yau +2½ pts');
    });

    test('the LEADER is named, so two readers see one row', () {
      // `+3` from one side is `−3` from the other, and both golfers are
      // looking at the same bar. RULINGS §3.
      final s = _summary([
        _match(front: -3, overall: -3, holes: [_hole(1, p1: 1)]),
      ]);
      final mine  = quotaNassauStanding(s, _me, hole: 1)!;
      final yours = quotaNassauStanding(s, _them, hole: 1)!;
      expect(mine.main.value, 'Lee +3 pts');
      expect(mine.main.value, yours.main.value);
      expect(mine.main.side, 2);
    });

    test('level says All Square, not zero points', () {
      final s = _summary([_match(holes: [_hole(1, p1: 0)])]);
      expect(quotaNassauStanding(s, _me, hole: 1)!.main.value, 'All Square');
    });
  });

  group('**which bet, and when**', () {
    test('the nine on screen leads, with the eighteen beside it', () {
      final s = _summary([
        _match(front: 3, back: -1, overall: 2,
            holes: [_hole(1, p1: 1), _hole(10, p1: 1)]),
      ]);
      expect(quotaNassauStanding(s, _me, hole: 4)!.main.label, 'F9');
      expect(quotaNassauStanding(s, _me, hole: 12)!.main.label, 'B9');
      expect(quotaNassauStanding(s, _me, hole: 12)!.second!.label, 'Overall');
    });

    test('a bet with no holes in it says Tee off, not All Square', () {
      // Level on nothing is not level.
      final s = _summary([_match(holes: [_hole(1, p1: 0)])]);
      expect(quotaNassauStanding(s, _me, hole: 12)!.main.value, 'Tee off');
    });
  });

  group('**whose match**', () {
    test('a foursome runs two, and the row reports the reader own', () {
      final s = _summary([
        _match(front: 3, overall: 3, holes: [_hole(1, p1: 1)]),
        _match(a: _other, b: 22, aShort: 'Gun', bShort: 'Mai',
            front: -5, overall: -5, holes: [_hole(1, p1: 1)]),
      ]);
      expect(quotaNassauStanding(s, _me, hole: 1)!.main.value, 'Yau +3 pts');
      expect(quotaNassauStanding(s, _other, hole: 1)!.main.value, 'Mai +5 pts');
    });

    test('a reader in NEITHER match still gets the group match', () {
      // **The ordinary case on a cup screen, not an edge.** Every golfer in
      // the field can be a login-less roster entry, so the TD entering the
      // scores is frequently in neither match — and the row said `Tee off`
      // over a match that had been played. Third time this gate has been
      // found: the tournament stroke row, cup Nassau, and this.
      final s = _summary([
        _match(front: 3, overall: 3, holes: [_hole(1, p1: 1)]),
      ]);
      final st = quotaNassauStanding(s, 999, hole: 1);
      expect(st, isNotNull);
      expect(st!.main.value, 'Yau +3 pts');
      // A phone with no linked golfer at all reads the same.
      expect(quotaNassauStanding(s, null, hole: 1)!.main.value, 'Yau +3 pts');
    });

    test('no match and no summary are still nothing', () {
      expect(quotaNassauStanding(null, _me, hole: 1), isNull);
      expect(quotaNassauStanding(_summary(const []), _me, hole: 1), isNull);
    });
  });
}
