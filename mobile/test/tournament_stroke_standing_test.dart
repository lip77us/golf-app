/// test/tournament_stroke_standing_test.dart
/// ----------------------------------------
/// The standing row on an individual-play STROKE tournament — `T-2 of 8`,
/// `−1 thru 4`.
///
/// The same shape as the casual Stroke Play row, and the place leads for the
/// same reason: the place is the money. What differs is where it comes from.
/// A casual round's field is the foursome, so the card holds it; a tournament
/// card is one group of a real field, and a rank taken off four golfers would
/// be a place among four wearing the words of a place in the field.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/stroke_play_standing.dart';

const _me = 11;

void main() {
  group('**the place comes down with the card**', () {
    test('rank, tie marker and field', () {
      final st = tournamentStrokeStanding(const {
        _me: FieldPlace(rank: 2, tied: true, field: 8, netToPar: -1, thru: 4),
      }, _me)!;
      expect(st.place, 'T-2 of 8');
      expect(st.score, '−1 thru 4');
    });

    test('an untied place keeps its ordinal', () {
      final st = tournamentStrokeStanding(const {
        _me: FieldPlace(rank: 1, field: 8, netToPar: -3, thru: 9),
      }, _me)!;
      expect(st.place, '1st of 8');
    });

    test('level par is E, and the minus is U+2212', () {
      expect(
          tournamentStrokeStanding(const {
            _me: FieldPlace(rank: 3, field: 8, netToPar: 0, thru: 5),
          }, _me)!.score,
          'E thru 5');
      expect(
          tournamentStrokeStanding(const {
            _me: FieldPlace(rank: 3, field: 8, netToPar: -2, thru: 5),
          }, _me)!.score.contains('−'),
          isTrue);
    });

    test('the field is every golfer entered, not the ones who have started',
        () {
      // Eight golfers are eight from the first tee — the number of rows the
      // board draws all day.
      final st = tournamentStrokeStanding(const {
        _me: FieldPlace(rank: 1, field: 8, netToPar: -1, thru: 1),
      }, _me)!;
      expect(st.place, endsWith('of 8'));
    });
  });

  group('**what it will not claim**', () {
    test('a golfer who has not teed off has no row', () {
      // Not level par — not on the board. The screen draws `Tee off`.
      expect(
          tournamentStrokeStanding(
              const {_me: FieldPlace(field: 8, thru: 0)}, _me),
          isNull);
    });

    test('no block for this golfer, or no reader at all', () {
      expect(tournamentStrokeStanding(const {}, _me), isNull);
      expect(
          tournamentStrokeStanding(const {
            _me: FieldPlace(rank: 1, field: 8, netToPar: 0, thru: 1),
          }, null),
          isNull);
    });

    test('`1st of 1` says nothing, so only the score shows', () {
      final st = tournamentStrokeStanding(const {
        _me: FieldPlace(rank: 1, field: 1, netToPar: -1, thru: 3),
      }, _me)!;
      expect(st.place, isEmpty);
      expect(st.score, '−1 thru 3');
    });
  });

  group('**the scorecard carries it**', () {
    test('parsed off the wire, keyed by player id', () {
      final sc = Scorecard.fromJson(const {
        'foursome_id': 1,
        'group_number': 1,
        'holes': [],
        'totals': [],
        'field_standing': {
          '11': {'rank': 2, 'tied': true, 'field': 8, 'net_to_par': -1,
                 'thru': 4},
        },
      });
      expect(sc.fieldStanding[11]!.rank, 2);
      expect(sc.fieldStanding[11]!.tied, isTrue);
      expect(sc.fieldStanding[11]!.netToPar, -1);
    });

    test('absent on a casual round — which is what gates the row', () {
      // The presence of the block IS the signal that this is an individual
      // stroke tournament; a client re-deriving that would be a second copy
      // of a rule it does not own.
      final sc = Scorecard.fromJson(const {
        'foursome_id': 1, 'group_number': 1, 'holes': [], 'totals': [],
      });
      expect(sc.fieldStanding, isEmpty);
    });
  });
}
