import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/points_board_model.dart';

/// `~/Downloads/handoff-points-leaderboard` — one widget for every Points
/// 5-3-1 leaderboard. The engine decides the points and the money; this
/// reads them.

const _paul = 89, _roger = 95, _will = 232;

Map<String, dynamic> _entry(int id, String short, int net, double pts) => {
      'player_id': id,
      'name': {_paul: 'Paul Lipkin', _roger: 'Roger Bird', _will: 'Will Glennon'}[id],
      'short_name': short,
      'net_score': net,
      'gross': net,
      'strokes': 0,
      'points': pts,
    };

Map<String, dynamic> _hole(int h, {int par = 4, required List entries}) =>
    {'hole': h, 'par': par, 'entries': entries};

Map<String, dynamic> _summary({
  required List<Map<String, dynamic>> holes,
  required List<Map<String, dynamic>> players,
  List<int>? holesInPlay,
  int? currentHole,
  String status = 'in_progress',
  double betUnit = 1,
  double? lossCap,
  String payoutStyle = 'per_point',
  String perPointMode = 'average',
  List<Map<String, dynamic>>? roster,
}) {
  final order = holesInPlay ?? [for (var i = 1; i <= 18; i++) i];
  return {
    'status': status,
    'handicap': {'mode': 'strokes_off', 'net_percent': 100},
    'players': players,
    'holes': holes,
    'holes_in_play': order,
    'current_hole': currentHole ?? (holes.isEmpty ? 0 : holes.last['hole']),
    'scorecard': {
      'players': roster ??
          [
            {'player_id': _paul, 'name': 'Paul Lipkin', 'short_name': 'Paul'},
            {'player_id': _roger, 'name': 'Roger Bird', 'short_name': 'Roger'},
            {'player_id': _will, 'name': 'Will Glennon', 'short_name': 'Will'},
          ],
      'holes': [
        for (final h in order) {'hole': h, 'par': h % 3 == 0 ? 3 : 4},
      ],
      'holes_in_play': order,
    },
    'money': {
      'bet_unit': betUnit,
      'par_per_hole': 3,
      'loss_cap': lossCap,
      'payout_style': payoutStyle,
      'per_point_mode': perPointMode,
    },
  };
}

Map<String, dynamic> _player(int id, String short, String name, double pts,
        int holes, double money) =>
    {
      'player_id': id,
      'name': name,
      'short_name': short,
      'points': pts,
      'holes_played': holes,
      'money': money,
    };

PointsBoardData _of(Map<String, dynamic> j) =>
    PointsBoardData.fromSummary(Points531Summary.fromJson(j));

void main() {
  group('the money is the server\'s', () {
    // Foursome 257 in the local database: 58 · 57 · 47 over 18 holes against
    // a target of 54, with a $6 loss cap.
    final capped = _of(_summary(
      status: 'complete',
      lossCap: 6,
      holes: [
        for (var h = 1; h <= 18; h++)
          _hole(h, entries: [
            _entry(_will, 'Will', 4, 58 / 18),
            _entry(_paul, 'Paul', 4, 57 / 18),
            _entry(_roger, 'Roger', 5, 47 / 18),
          ]),
      ],
      players: [
        _player(_will, 'Will', 'Will Glennon', 58, 18, 3.43),
        _player(_paul, 'Paul', 'Paul Lipkin', 57, 18, 2.57),
        _player(_roger, 'Roger', 'Roger Bird', 47, 18, -6),
      ],
    ));

    test('a loss cap is honoured, which the packet\'s formula cannot be', () {
      // `(points − 3 × holes) × stake` says +4 / +3 / −7. The cap clips the
      // loser at −6 and rescales the winners, which is what was actually
      // paid — so a board doing its own arithmetic shows a figure nobody got.
      final byId = {for (final g in capped.golfers) g.playerId: g.money};
      expect(byId[_will], 3.43);
      expect(byId[_paul], 2.57);
      expect(byId[_roger], -6.0);
    });

    test('and the uncapped formula would have disagreed', () {
      for (final g in capped.golfers) {
        expect(g.money, isNot((g.points - capped.target) * capped.stake));
      }
    });

    test('the ledger still totals to zero', () {
      final sum = capped.golfers.fold<double>(0, (a, g) => a + g.money);
      expect(sum.abs() < 0.005, isTrue, reason: 'nets to $sum');
    });
  });

  group('target', () {
    test('is three a hole over the holes PLAYED', () {
      final d = _of(_summary(
        holes: [
          for (var h = 1; h <= 7; h++)
            _hole(h, entries: [
              _entry(_paul, 'Paul', 4, 5),
              _entry(_roger, 'Roger', 5, 3),
              _entry(_will, 'Will', 6, 1),
            ]),
        ],
        players: [
          _player(_paul, 'Paul', 'Paul Lipkin', 35, 7, 14),
          _player(_roger, 'Roger', 'Roger Bird', 21, 7, 0),
          _player(_will, 'Will', 'Will Glennon', 7, 7, -14),
        ],
      ));
      expect(d.target, 21);
      expect(d.holesLeft, 11);
    });

    test('and the FULL target follows the holes in play, not 54', () {
      // The reference hardcodes 54. A nine-hole round plays to 27.
      final d = _of(_summary(
        holesInPlay: [for (var h = 1; h <= 9; h++) h],
        holes: const [],
        players: [
          _player(_paul, 'Paul', 'Paul Lipkin', 0, 0, 0),
        ],
      ));
      expect(d.fullTarget, 27);
    });
  });

  group('order', () {
    test('colour follows the ROSTER, not the standings', () {
      // The server sorts `players` by money. Taking the colour from there
      // would repaint a golfer the moment he went ahead, and the hole tiles
      // would stop matching the ledger swatches.
      final d = _of(_summary(
        holes: const [],
        players: [
          _player(_will, 'Will', 'Will Glennon', 58, 18, 3.43),
          _player(_paul, 'Paul', 'Paul Lipkin', 57, 18, 2.57),
          _player(_roger, 'Roger', 'Roger Bird', 47, 18, -6),
        ],
      ));
      expect([for (final g in d.golfers) g.shortName],
          ['Paul', 'Roger', 'Will']);
      expect([for (final g in d.golfers) g.colourIndex], [0, 1, 2]);
    });

    test('the ledger sorts by points, high first', () {
      final d = _of(_summary(
        holes: const [],
        players: [
          _player(_paul, 'Paul', 'Paul Lipkin', 47, 18, -6),
          _player(_roger, 'Roger', 'Roger Bird', 58, 18, 3.43),
          _player(_will, 'Will', 'Will Glennon', 57, 18, 2.57),
        ],
      ));
      expect([for (final g in d.ledger) g.shortName],
          ['Roger', 'Will', 'Paul']);
    });

    test('falls back to the player list when no scorecard came with it', () {
      final j = _summary(holes: const [], players: [
        _player(_will, 'Will', 'Will Glennon', 1, 1, 0),
        _player(_paul, 'Paul', 'Paul Lipkin', 0, 1, 0),
      ]);
      j.remove('scorecard');
      final d = _of(j);
      expect([for (final g in d.golfers) g.shortName], ['Will', 'Paul']);
    });
  });

  group('the next hole', () {
    test('is the next in PLAY order, not the next number', () {
      // A shotgun from the 7th: the hole after the 18th is the 1st.
      final order = [
        for (var h = 7; h <= 18; h++) h,
        for (var h = 1; h <= 6; h++) h,
      ];
      final d = _of(_summary(
        holesInPlay: order,
        currentHole: 18,
        holes: [
          for (final h in order.take(12))
            _hole(h, entries: [
              _entry(_paul, 'Paul', 4, 5),
              _entry(_roger, 'Roger', 5, 3),
              _entry(_will, 'Will', 6, 1),
            ]),
        ],
        players: [_player(_paul, 'Paul', 'Paul Lipkin', 60, 12, 24)],
      ));
      expect(d.nextHole, 1);
    });

    test('is the first hole before anybody tees off', () {
      final d = _of(_summary(
        holesInPlay: [for (var h = 7; h <= 18; h++) h],
        currentHole: 0,
        holes: const [],
        players: [_player(_paul, 'Paul', 'Paul Lipkin', 0, 0, 0)],
      ));
      expect(d.nextHole, 7);
      expect(d.lastHole, isNull);
    });

    test('is null once the round is over', () {
      final d = _of(_summary(
        status: 'complete',
        currentHole: 18,
        holes: [
          _hole(18, entries: [_entry(_paul, 'Paul', 4, 5)]),
        ],
        players: [_player(_paul, 'Paul', 'Paul Lipkin', 54, 18, 0)],
      ));
      expect(d.nextHole, isNull);
    });
  });

  group('a tie on the hole', () {
    final d = _of(_summary(
      currentHole: 13,
      holes: [
        _hole(13, entries: [
          _entry(_roger, 'Sam', 4, 4),
          _entry(_will, 'Dave', 4, 4),
          _entry(_paul, 'Paul', 5, 1),
        ]),
      ],
      players: [_player(_paul, 'Paul', 'Paul Lipkin', 49, 13, 10)],
    ));

    test('is read off equal NET, never equal points', () {
      // A 4 can be a share of low (5 and 3 split) OR a share of second
      // (3 and 1), so reading the points back would call an outright second
      // a tie. The net is the actual rule.
      final hole = d.holes[13]!;
      final byId = {for (final e in hole.entries) e.shortName: e.tied};
      expect(byId['Sam'], isTrue);
      expect(byId['Dave'], isTrue);
      expect(byId['Paul'], isFalse);
    });

    test('and the hero card reads low net first, keeping the pair adjacent',
        () {
      expect([for (final e in d.holes[13]!.byNet) e.shortName],
          ['Dave', 'Sam', 'Paul']);
    });
  });

  group('the finish', () {
    test('names one winner, and says so when two share it', () {
      final outright = _of(_summary(
        status: 'complete',
        holes: const [],
        players: [
          _player(_paul, 'Paul', 'Paul Lipkin', 69, 18, 15),
          _player(_roger, 'Sam', 'Sam Reid', 49, 18, -5),
          _player(_will, 'Dave', 'Dave Moran', 44, 18, -10),
        ],
      ));
      expect(outright.winner!.shortName, 'Paul');
      expect(outright.winnerIsTied, isFalse);

      final shared = _of(_summary(
        status: 'complete',
        holes: const [],
        players: [
          _player(_paul, 'Paul', 'Paul Lipkin', 60, 18, 3),
          _player(_roger, 'Sam', 'Sam Reid', 60, 18, 3),
          _player(_will, 'Dave', 'Dave Moran', 42, 18, -6),
        ],
      ));
      expect(shared.winnerIsTied, isTrue);
    });
  });

  test('the surname is dropped when the short name already carries it', () {
    final d = _of(_summary(holes: const [], players: const [], roster: [
      {'player_id': 1, 'name': 'Paul Lipkin', 'short_name': 'Paul'},
      {'player_id': 2, 'name': 'Tyler Law', 'short_name': 'TYLaw'},
      {'player_id': 3, 'name': 'Cher', 'short_name': 'Cher'},
    ]));
    expect(d.golfers[0].surname, 'Lipkin');
    expect(d.golfers[1].surname, '', reason: 'TYLaw Law');
    expect(d.golfers[2].surname, '');
  });

  test('points format drops a whole number\'s decimal and keeps a half', () {
    expect(formatPoints(5), '5');
    expect(formatPoints(4.5), '4.5');
    expect(formatPoints(0), '0');
  });
}
