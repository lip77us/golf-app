import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/banker_strokes.dart';

/// Banker's strokes are pairwise, and the keypad did not know.
///
/// Paul, 10 Nov 2026, with Tyler banking a par 3: *"Why does Tyler Law get 1
/// stroke on this hole?"* He does not. The golfer's row has always used the
/// pairwise rule; the keypad under it had no Banker branch and fell through
/// to the ROUND's full-handicap allocation, so it read `1 stroke · par 3`
/// over a row showing no dot.
///
/// Four golfers: Paul (index 5, the low man), Tyler (12), Larry (16) and
/// Gilbert (20). Hole 4 is the hole in the report.

const _paul = 1, _tyler = 2, _larry = 3, _gil = 4;

BankerSummary _summary({
  required int bankerId,
  Map<String, dynamic> plan = const {},
  bool withHole = true,
}) =>
    BankerSummary.fromJson({
      'status': 'in_progress',
      'handicap_mode': 'strokes_off', 'net_percent': 100,
      'min_bet': 5, 'max_bet': 50, 'rotation_rule': 'low_net',
      'rules': const {'player_double': true, 'counter': true,
                      'par3_triples': true, 'birdie_bonus': true},
      'exposure_ladder': const [], 'hole_cap': null,
      'players': [
        for (final p in const [
          [_paul, 'Paul', 5.0], [_tyler, 'Tyler', 12.0],
          [_larry, 'Larry', 16.0], [_gil, 'Gilbert', 20.0],
        ])
          {'player_id': p[0], 'name': p[1], 'short_name': p[1],
           'handicap_index': p[2], 'banking': 0, 'betting': 0, 'total': 0},
      ],
      'holes': withHole
          ? [
              {'hole': 4, 'par': 3, 'stroke_index': 9, 'is_par_3': true,
               'banker_id': bankerId, 'banker_gross': null,
               'banker_handicap': 0, 'max_bet': 5, 'locked': true,
               'countered': false, 'tie_reason': '', 'hole_capped': false,
               'lines': const [], 'banker_delta': 0, 'resolved': false,
               'exposure': 0, 'exposure_if_max': 0, 'outstanding': const [],
               'cut_off': const [], 'hole_money': const {}},
            ]
          : const [],
      'current_hole': withHole ? 4 : null,
      'current': null, 'awaiting_tie': null, 'tie_candidates': const [],
      'next_banker_id': null, 'next_banker_name': '',
      'biggest_swings': const [], 'bets_settled': 0,
      'stroke_plan': plan, 'grid': const [], 'grid_players': const [],
      'money': const {'transfers': [], 'nets': []},
    });

/// `plan[reference][player][hole]` — what [player] gets against [reference].
Map<String, dynamic> _plan(Map<int, Map<int, int>> byRef) => {
      for (final r in byRef.entries)
        '${r.key}': {
          for (final p in r.value.entries) '${p.key}': {'4': p.value},
        },
    };

void main() {
  group('an opponent strokes against the BANKER', () {
    test('he gets what his own match gives him', () {
      final s = _summary(bankerId: _tyler,
          plan: _plan({_tyler: {_gil: 1, _larry: 0}}));
      expect(bankerStrokesOnHole(s, _gil, 4), 1);
      expect(bankerStrokesOnHole(s, _larry, 4), 0);
    });

    test('a golfer who GIVES the banker a shot gets none', () {
      // Paul is lower than Tyler, so the stroke in that match is Tyler's.
      final s = _summary(bankerId: _tyler,
          plan: _plan({_tyler: {_paul: -1}}));
      expect(bankerStrokesOnHole(s, _paul, 4), 0);
    });
  });

  group('the banker strokes off the LOW golfer', () {
    test('and only off him', () {
      // The reported hole: Tyler banks. Against the low man he gets nothing
      // here — whatever his full handicap would give him on a par 3.
      final s = _summary(bankerId: _tyler, plan: _plan({
        _paul: {_tyler: 0},
        // What he would get against a higher golfer is NOT his figure.
        _gil: {_tyler: 3},
      }));
      expect(bankerStrokesOnHole(s, _tyler, 4), 0);
    });

    test('when the low man does give him one, he has it', () {
      final s = _summary(bankerId: _gil,
          plan: _plan({_paul: {_gil: 1}}));
      expect(bankerStrokesOnHole(s, _gil, 4), 1);
    });

    test('a banker who IS the low man never strokes', () {
      // Nobody gives the low man anything, whatever a plan says.
      final s = _summary(bankerId: _paul,
          plan: _plan({_paul: {_paul: 2}, _tyler: {_paul: 2}}));
      expect(bankerStrokesOnHole(s, _paul, 4), 0);
    });
  });

  group('it says null when it cannot say', () {
    // Null, not zero: the caller falls back rather than drawing a wrong 0.
    test('no summary', () {
      expect(bankerStrokesOnHole(null, _tyler, 4), isNull);
    });

    test('no plan', () {
      expect(bankerStrokesOnHole(_summary(bankerId: _tyler), _gil, 4),
          isNull);
    });

    test('a hole with no banker yet', () {
      final s = _summary(bankerId: _tyler, withHole: false,
          plan: _plan({_tyler: {_gil: 1}}));
      expect(bankerStrokesOnHole(s, _gil, 4), isNull);
    });
  });

  group('one rule, both readers', () {
    final src =
        File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('the keypad reads it', () {
      final at = src.indexOf('int _keypadStrokes(Membership m, Scorecard sc)');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('\n  }\n', at));
      // The call AND its gate AND its return: the first version of this
      // asserted the call's name alone, and `if (false) { …call… }` passed.
      expect(
          RegExp(r'if \(_bankerRound\(rp\)\) \{\s*'
                  r'final b = bankerStrokesOnHole\(\s*'
                  r'rp\.bankerSummary, m\.player\.id, _selectedHole\);\s*'
                  r'if \(b != null\) return b;')
              .hasMatch(body),
          isTrue);
      // BEFORE the fallback to the round's own allocation, which is the
      // figure that was wrong.
      expect(body.indexOf('bankerStrokesOnHole('),
          lessThan(body.indexOf('entry?.handicapStrokes')));
    });

    test('and so does the golfer\'s row', () {
      final at = src.indexOf('int? _bankerStrokes(Membership m, '
          'ScorecardHole? h)');
      expect(at, greaterThan(0));
      expect(src.substring(at, src.indexOf(';', at)),
          contains('bankerStrokesOnHole('));
    });

    test('the screen keeps no copy of its own', () {
      expect(src.contains('_planStrokes('), isFalse);
    });
  });
}
