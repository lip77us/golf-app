/// test/match_play_standing_test.dart
/// -----------------------------------
/// The standing ribbon on a Mini Singles Bracket round, and the phase rule
/// three surfaces share.
///
/// The row writes no notation of its own — it renders the engine's `line`,
/// which is already neutral and already handles the halved semi, the
/// unresolved opponent and the close-out's `&M`. So what is pinned here is
/// which MATCH it picks and which PHASE is live.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/match_play_standing.dart';

const _me = 11;
const _opp = 12;

Map<String, dynamic> _m({
  int round = 1,
  String label = 'Semi 1',
  String status = 'in_progress',
  String line = 'Gunst 1 UP thru 4',
  int p1 = _me,
  int p2 = _opp,
}) =>
    {
      'round': round, 'label': label, 'status': status, 'line': line,
      'player1_id': p1, 'player2_id': p2,
    };

Map<String, dynamic> _data(List<Map<String, dynamic>> matches) =>
    {'matches': matches};

void main() {
  group('**the live phase is round 2 only when every semi is done**', () {
    test('one semi finished is not enough', () {
      // The other is still the live match for two of the four golfers.
      final d = _data([
        _m(status: 'complete'),
        _m(label: 'Semi 2', p1: 13, p2: 14),
        _m(round: 2, label: 'Final', p1: 13, p2: _me),
      ]);
      expect(bracketLiveMatches(d).every((m) => m['round'] == 1), isTrue);
    });

    test('both finished hands over to the back nine', () {
      final d = _data([
        _m(status: 'complete'),
        _m(label: 'Semi 2', status: 'halved', p1: 13, p2: 14),
        _m(round: 2, label: 'Final', p1: 13, p2: _me),
        _m(round: 2, label: '3rd Place', p1: 14, p2: _opp),
      ]);
      final live = bracketLiveMatches(d);
      expect(live.length, 2);
      expect(live.every((m) => m['round'] == 2), isTrue);
    });

    test('**a HALVED semi counts as finished**', () {
      // A halved semi plays on and then resolves; it is not still running.
      final d = _data([
        _m(status: 'halved'),
        _m(label: 'Semi 2', status: 'halved', p1: 13, p2: 14),
        _m(round: 2, label: 'Final', p1: _me, p2: 13),
      ]);
      expect(bracketLiveMatches(d).first['round'], 2);
    });

    test('with no round 2 drawn it stays on the semis', () {
      final d = _data([_m(status: 'complete')]);
      expect(bracketLiveMatches(d).first['round'], 1);
    });
  });

  group('**the row reports the READER\'s match**', () {
    test('his own, not the other semi', () {
      final d = _data([
        _m(label: 'Semi 1', line: 'Gunst 2 UP thru 6'),
        _m(label: 'Semi 2', line: 'Bird 3&2', p1: 13, p2: 14),
      ]);
      final st = matchPlayStanding(d, _me)!;
      expect(st.label, 'Semi 1');
      expect(st.standing, 'Gunst 2 UP thru 6');
    });

    test('and it follows him into the final', () {
      final d = _data([
        _m(status: 'complete'),
        _m(label: 'Semi 2', status: 'complete', p1: 13, p2: 14),
        _m(round: 2, label: 'Final', line: 'All square thru 3',
           p1: _me, p2: 13),
        _m(round: 2, label: '3rd Place', line: 'Bird 1 UP thru 3',
           p1: 14, p2: _opp),
      ]);
      final st = matchPlayStanding(d, _me)!;
      expect(st.label, 'Final');
      expect(st.standing, 'All square thru 3');
    });

    test('**it writes nothing of its own** — the engine\'s line, verbatim', () {
      // `_match_line` handles the halved semi that played on, the back-nine
      // match against an unresolved semi, and the `&M` counted along the
      // match's own nine. Re-deriving any of it here would gain nothing.
      for (final line in const [
        'Gunst 4&2',
        'Halved — Bird won the last hole',
        '1 UP thru 11',
        'All square thru 11',
      ]) {
        final d = _data([_m(line: line)]);
        expect(matchPlayStanding(d, _me)!.standing, line);
      }
    });

    test('an empty line still draws a row', () {
      // The pill is the way in; a match with nothing to say must not take it
      // away.
      final d = _data([_m(line: '')]);
      expect(matchPlayStanding(d, _me)!.standing, 'Not started');
    });
  });

  group('when the reader is not in the live phase', () {
    test('a semi loser gets no row while the final runs', () {
      final d = _data([
        _m(status: 'complete'),
        _m(label: 'Semi 2', status: 'complete', p1: 13, p2: 14),
        _m(round: 2, label: 'Final', p1: 13, p2: 14),
      ]);
      expect(matchPlayStanding(d, _me), isNull);
    });

    test('a watcher is not in the bracket', () {
      expect(matchPlayStanding(_data([_m()]), 999), isNull);
    });

    test('no data, no row', () {
      expect(matchPlayStanding(null, _me), isNull);
    });
  });
}
