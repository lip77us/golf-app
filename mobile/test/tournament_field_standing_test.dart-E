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
      final st = tournamentFieldStanding(const {
        _me: FieldPlace(rank: 2, tied: true, field: 8, netToPar: -1, thru: 4),
      }, _me)!;
      expect(st.place, 'T-2 of 8');
      expect(st.score, '−1 thru 4');
    });

    test('an untied place keeps its ordinal', () {
      final st = tournamentFieldStanding(const {
        _me: FieldPlace(rank: 1, field: 8, netToPar: -3, thru: 9),
      }, _me)!;
      expect(st.place, '1st of 8');
    });

    test('level par is E, and the minus is U+2212', () {
      expect(
          tournamentFieldStanding(const {
            _me: FieldPlace(rank: 3, field: 8, netToPar: 0, thru: 5),
          }, _me)!.score,
          'E thru 5');
      expect(
          tournamentFieldStanding(const {
            _me: FieldPlace(rank: 3, field: 8, netToPar: -2, thru: 5),
          }, _me)!.score.contains('−'),
          isTrue);
    });

    test('the field is every golfer entered, not the ones who have started',
        () {
      // Eight golfers are eight from the first tee — the number of rows the
      // board draws all day.
      final st = tournamentFieldStanding(const {
        _me: FieldPlace(rank: 1, field: 8, netToPar: -1, thru: 1),
      }, _me)!;
      expect(st.place, endsWith('of 8'));
    });
  });

  group('**the row says whose standing it is**', () {
    // It used to name a golfer only when the reader was not in the field, on
    // the reasoning that a man reading his own standing knows whose it is.
    // On a tournament screen he frequently is not looking at his own group:
    // `T-1 of 8 · E thru 2` over four golfers who are thru 6 describes a man
    // who is not on the screen at all.
    test('the reader is named too', () {
      final st = tournamentFieldStanding(
        const {_me: FieldPlace(rank: 1, tied: true, field: 8,
                               netToPar: 0, thru: 3)},
        _me,
        nameOf: (id) => id == _me ? 'AP' : '',
      )!;
      expect(st.place, 'AP T-1 of 8');
      expect(st.score, 'E thru 3');
    });

    test('no resolver, no name — every older caller is unchanged', () {
      final st = tournamentFieldStanding(const {
        _me: FieldPlace(rank: 1, tied: true, field: 8, netToPar: 0, thru: 3),
      }, _me)!;
      expect(st.place, 'T-1 of 8');
    });

    test('with no card there is nothing to follow, so the reader stands',
        () {
      // Every casual caller passes none, and on a casual round his foursome
      // IS the screen.
      final st = tournamentFieldStanding(const {
        _me: FieldPlace(rank: 4, field: 8, netToPar: 2, thru: 9),
      }, _me, nameOf: (_) => 'AP')!;
      expect(st.place, 'AP 4th of 8');
    });

    test('a one-golfer event still reports the score alone', () {
      // There is no place to attach a name to, and `AP` over a bare score
      // would read as a place.
      final st = tournamentFieldStanding(
        const {_me: FieldPlace(rank: 1, field: 1, netToPar: -1, thru: 3)},
        _me,
        nameOf: (_) => 'AP',
      )!;
      expect(st.place, 'AP');
      expect(st.score, '−1 thru 3');
    });
  });

  group('**what it will not claim**', () {
    test('a golfer who has not teed off has no row', () {
      // Not level par — not on the board. The screen draws `Tee off`.
      expect(
          tournamentFieldStanding(
              const {_me: FieldPlace(field: 8, thru: 0)}, _me),
          isNull);
    });

    test('no block for this golfer, or no reader at all', () {
      expect(tournamentFieldStanding(const {}, _me), isNull);
      expect(
          tournamentFieldStanding(const {
            _me: FieldPlace(rank: 1, field: 8, netToPar: 0, thru: 1),
          }, null),
          isNull);
    });

    test('`1st of 1` says nothing, so only the score shows', () {
      final st = tournamentFieldStanding(const {
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
      final st = tournamentFieldStanding(standings, 999, card: card)!;
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
      expect(tournamentFieldStanding(tied, 999, card: tiedCard)!.place,
          'AM T-2 of 8');
    });

    test('a reader ON this card gets his own standing', () {
      final st = tournamentFieldStanding(standings, 23, card: card,
          nameOf: (_) => 'AB')!;
      expect(st.place, 'AB T-7 of 8');
    });

    test('a reader in the field but in ANOTHER group follows the screen', () {
      // The case that sent this back: the reader was in group 1 and scoring
      // group 2, so the row reported HIS place and HIS thru over four
      // golfers who were three holes further on. Everything else on the
      // screen is about the group being scored.
      const elsewhere = {
        ...standings,
        99: FieldPlace(rank: 1, field: 8, netToPar: 0, thru: 2),
      };
      final st = tournamentFieldStanding(elsewhere, 99, card: card,
          nameOf: (id) => id == 99 ? 'AP' : 'AW')!;
      expect(st.place, 'AW 1st of 8');
      expect(st.score, '−1 thru 1');
    });

    test('a group that has not started reads Tee off, whoever is reading', () {
      // Not the reader's own thru from another group — the screen has not
      // started, and that is what the row reports.
      expect(
          tournamentFieldStanding(
              const {21: FieldPlace(field: 8, thru: 0),
                     99: FieldPlace(rank: 1, field: 8, netToPar: 0, thru: 2)},
              99,
              card: const [(id: 21, shortName: 'AW')]),
          isNull);
    });

    test('a reader in the field who has not teed off still gets Tee off', () {
      // True of him, and not the same question as not being in the field.
      expect(
          tournamentFieldStanding(
              const {21: FieldPlace(field: 8, thru: 0)}, 21,
              card: const [(id: 21, shortName: 'AW')]),
          isNull);
    });

    test('nobody on the card has started — no row', () {
      expect(
          tournamentFieldStanding(
              const {21: FieldPlace(field: 8, thru: 0)}, 999,
              card: const [(id: 21, shortName: 'AW')]),
          isNull);
    });

    test('no card passed — the casual callers are unaffected', () {
      expect(tournamentFieldStanding(standings, 999), isNull);
    });
  });

  // ── Stableford counts the other way up ──────────────────────────────────
  //
  // Reported 23 Sep 2026: *I don't see the stableford points anywhere.* A
  // Stableford tournament round carries no `active_games` of its own — the
  // game is the tournament's — so the round board drew a stroke-play tab and
  // no points at all, on the one competition being played.
  group('**a Stableford tournament reports points**', () {
    test('the figure is points, in its own unit', () {
      final st = tournamentFieldStanding(const {
        _me: FieldPlace(rank: 2, tied: true, field: 8, metric: 'points',
                        points: 27, thru: 4),
      }, _me)!;
      expect(st.place, 'T-2 of 8');
      // `+27` beside a stroke row's `+3` would be the same glyph meaning a
      // good round and a bad one, so the unit is said.
      expect(st.score, '27 pts thru 4');
    });

    test('zero points is a figure, not a silence', () {
      // A golfer can genuinely be on 0 after a hole, and that is news.
      final st = tournamentFieldStanding(const {
        _me: FieldPlace(rank: 8, field: 8, metric: 'points', points: 0,
                        thru: 1),
      }, _me)!;
      expect(st.score, '0 pts thru 1');
    });

    test('no points yet — the row says Tee off', () {
      expect(
          tournamentFieldStanding(
              const {_me: FieldPlace(field: 8, metric: 'points', thru: 0)},
              _me),
          isNull);
    });

    test('a TD not playing gets the card, in points', () {
      const card = [(id: 21, shortName: 'AW'), (id: 22, shortName: 'AM')];
      final st = tournamentFieldStanding(const {
        21: FieldPlace(rank: 1, field: 8, metric: 'points', points: 4,
                       thru: 1),
        22: FieldPlace(rank: 5, field: 8, metric: 'points', points: 2,
                       thru: 1),
      }, 999, card: card)!;
      expect(st.place, 'AW 1st of 8');
      expect(st.score, '4 pts thru 1');
    });

    test('the metric is read off the row, never guessed', () {
      // One payload key must never mean two shapes: a points total read as a
      // score against par is roughly its opposite.
      final sc = Scorecard.fromJson(const {
        'foursome_id': 1, 'group_number': 1, 'holes': [], 'totals': [],
        'field_standing': {
          '11': {'metric': 'points', 'rank': 1, 'field': 8, 'points': 4,
                 'thru': 1},
        },
      });
      final p = sc.fieldStanding[11]!;
      expect(p.metric, 'points');
      expect(p.netToPar, isNull);
      expect(p.hasFigure, isTrue);
    });

    test('an older payload with no metric reads as stroke', () {
      final sc = Scorecard.fromJson(const {
        'foursome_id': 1, 'group_number': 1, 'holes': [], 'totals': [],
        'field_standing': {
          '11': {'rank': 1, 'field': 8, 'net_to_par': -1, 'thru': 1},
        },
      });
      expect(sc.fieldStanding[11]!.metric, 'stroke');
      expect(tournamentFieldStanding(sc.fieldStanding, 11)!.score,
          '−1 thru 1');
    });
  });
}

