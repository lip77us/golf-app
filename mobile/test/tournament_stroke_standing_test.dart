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

  // ── The reader is usually NOT in the field ──────────────────────────────
  //
  // Reported from a live tournament: the row said `Tee off` while the group
  // was thru 1. Every golfer in that field was a login-less roster entry, so
  // the one person holding the phone was in none of them — which in a
  // tournament is the ordinary case, not an edge. The screen he is looking at
  // is entirely about that group, and a row reporting nothing reported
  // nothing about the thing in front of him.
  group('**a TD not playing gets the card, not a blank row**', () {
    const card = [
      (id: 21, shortName: 'AW'),
      (id: 22, shortName: 'AM'),
      (id: 23, shortName: 'AB'),
    ];
    const standings = {
      21: FieldPlace(rank: 1, field: 8, netToPar: -1, thru: 1),
      22: FieldPlace(rank: 2, tied: true, field: 8, netToPar: 0, thru: 1),
      23: FieldPlace(rank: 7, tied: true, field: 8, netToPar: 1, thru: 1),
    };

    test('it names the best-placed golfer on the card', () {
      final st = tournamentStrokeStanding(standings, 999, card: card)!;
      expect(st.place, 'AW 1st of 8');
      expect(st.score, '−1 thru 1');
    });

    test('a tie takes the first in CARD order, which is how rows are drawn',
        () {
      const tiedCard = [(id: 22, shortName: 'AM'), (id: 24, shortName: 'BL')];
      const tied = {
        22: FieldPlace(rank: 2, tied: true, field: 8, netToPar: 0, thru: 1),
        24: FieldPlace(rank: 2, tied: true, field: 8, netToPar: 0, thru: 1),
      };
      expect(tournamentStrokeStanding(tied, 999, card: tiedCard)!.place,
          'AM T-2 of 8');
    });

    test('a reader who IS in the field still gets his own, unnamed', () {
      // The two cases are kept apart: the name marks a row that is about
      // somebody else.
      final st = tournamentStrokeStanding(standings, 23, card: card)!;
      expect(st.place, 'T-7 of 8');
    });

    test('a reader in the field who has not teed off still gets Tee off', () {
      // True of him, and not the same question as not being in the field.
      expect(
          tournamentStrokeStanding(
              const {21: FieldPlace(field: 8, thru: 0)}, 21,
              card: const [(id: 21, shortName: 'AW')]),
          isNull);
    });

    test('nobody on the card has started — no row', () {
      expect(
          tournamentStrokeStanding(
              const {21: FieldPlace(field: 8, thru: 0)}, 999,
              card: const [(id: 21, shortName: 'AW')]),
          isNull);
    });

    test('no card passed — the casual callers are unaffected', () {
      expect(tournamentStrokeStanding(standings, 999), isNull);
    });
  });
}
