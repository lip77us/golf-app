import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/skins_board_model.dart';

/// A skins summary in the server's own shape, so the conversion is exercised
/// rather than the model being hand-built.
SkinsSummary _skins({
  required List<Map<String, dynamic>> players,
  required List<Map<String, dynamic>> holes,
  bool carryover = true,
  String mode = 'net',
  double betUnit = 1.0,
  String rules = '',
  String payoutStyle = 'per_point',
  double pool = 4.0,
  double? rate,
  String perPointMode = 'first',
}) =>
    SkinsSummary.fromJson({
      'status': 'in_progress',
      // The real shape is NESTED — `handicap: {mode, net_percent}`.  The API
      // block in CLAUDE.md shows it flat, which is stale; the parser has
      // always read the nested one.
      'handicap': {'mode': mode, 'net_percent': 100},
      'carryover': carryover,
      'allow_junk': true,
      'skin_rules': rules,
      'per_point_rate': rate ?? betUnit,
      // Top level, as the server sends it. This helper had it inside `money`,
      // so every summary here was silently parsed as a pool.
      'payout_style': payoutStyle,
      'per_point_mode': perPointMode,
      'players': players,
      'holes': holes,
      'money': {'bet_unit': betUnit, 'pool': pool, 'total_skins': 0},
    });

/// `payout` defaults to `net`, which is what the server sends PER SKIN. In a
/// pool they differ — payout is the share, net is share minus ante — and a
/// helper that always made them equal is how the board came to show the
/// wrong one for a pool with no test noticing.
Map<String, dynamic> _p(int id, String name,
        {int won = 0, int junk = 0, double net = 0, double? payout}) =>
    {
      'player_id': id, 'name': name, 'short_name': name,
      'skins_won': won, 'junk_skins': junk, 'total_skins': won + junk,
      'payout': payout ?? net, 'net': net,
    };

/// `value` follows the engine: a carried hole stores the pot INCLUDING itself.
Map<String, dynamic> _won(int hole, int winner, {int value = 1, int par = 4}) =>
    {'hole': hole, 'par': par, 'winner_id': winner, 'skins_value': value,
     'is_carry': false};
Map<String, dynamic> _carried(int hole, int pot, {int par = 4}) =>
    {'hole': hole, 'par': par, 'winner_id': null, 'skins_value': pot,
     'is_carry': true};
Map<String, dynamic> _unplayed(int hole, {int par = 4}) =>
    {'hole': hole, 'par': par, 'winner_id': null, 'skins_value': 0,
     'is_carry': false};

void main() {
  group('the walk', () {
    test('nothing played yet: one skin rides on the first hole', () {
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      ));
      expect(d.holesPlayed, 0);
      expect(d.nextHole!.hole, 1);
      expect(d.skinsRiding, 1);
      expect(d.carriedInHoles, isEmpty);
      expect(d.roundOver, isFalse);
    });

    test('after a won hole the next one rides for one', () {
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 1, net: 1), _p(2, 'Dave', net: -1)],
        holes: [_won(1, 1), for (var h = 2; h <= 18; h++) _unplayed(h)],
      ));
      expect(d.nextHole!.hole, 2);
      expect(d.skinsRiding, 1);
      expect(d.carriedInHoles, isEmpty);
    });

    test('two carried holes ride as THREE on the next', () {
      // The design's thru-12 state: 11 and 12 carried in, 3 riding on 13.
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [
          for (var h = 1; h <= 10; h++) _won(h, 1),
          _carried(11, 1),
          _carried(12, 2),      // the pot INCLUDING itself
          for (var h = 13; h <= 18; h++) _unplayed(h),
        ],
      ));
      expect(d.nextHole!.hole, 13);
      expect(d.skinsRiding, 3);
      expect(d.carriedInHoles, [11, 12]);
    });

    test('the carried run stops at the last won hole', () {
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [
          _carried(1, 1), _won(2, 1, value: 2), _carried(3, 1),
          for (var h = 4; h <= 18; h++) _unplayed(h),
        ],
      ));
      expect(d.carriedInHoles, [3]);
      expect(d.skinsRiding, 2);
    });

    test('carry OFF never reports a carried run', () {
      final d = SkinsBoardData.fromSkins(_skins(
        carryover: false,
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [_carried(1, 1), for (var h = 2; h <= 18; h++) _unplayed(h)],
      ));
      expect(d.carriedInHoles, isEmpty);
    });
  });

  group('play order, not hole number', () {
    test('a shotgun round starts on the hole the group starts on', () {
      // Off the 7th: the server sends the holes in PLAY order.
      final order = [for (var h = 7; h <= 18; h++) h, for (var h = 1; h <= 6; h++) h];
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [
          _won(order.first, 1),
          for (final h in order.skip(1)) _unplayed(h),
        ],
      ));
      expect(d.holesPlayed, 1);
      // The next hole is the 8th, NOT hole 1.
      expect(d.nextHole!.hole, 8);
    });

    test('the last hole played can have the smallest number', () {
      final order = [for (var h = 7; h <= 18; h++) h, for (var h = 1; h <= 6; h++) h];
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [
          for (final h in order.take(17)) _won(h, 1),
          _unplayed(order.last),   // hole 6, played last
        ],
      ));
      expect(d.nextHole!.hole, 6);
      expect(d.holesLeft, 1);
    });
  });

  group('the end of the round', () {
    test('every hole played is round over', () {
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 18, net: 18)],
        holes: [for (var h = 1; h <= 18; h++) _won(h, 1)],
      ));
      expect(d.roundOver, isTrue);
      expect(d.nextHole, isNull);
      expect(d.skinsRiding, 0);
      expect(d.holesLeft, 0);
      expect(d.unclaimedAtEnd, 0);
    });

    test('skins left riding on the last hole are unclaimed', () {
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul')],
        holes: [
          for (var h = 1; h <= 16; h++) _won(h, 1),
          _carried(17, 1),
          _carried(18, 2),
        ],
      ));
      expect(d.roundOver, isTrue);
      expect(d.unclaimedAtEnd, 2);
    });
  });

  group('the ledger', () {
    test('junk counts toward the ticks, because it is paid on', () {
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 2, junk: 1, net: 9)],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      ));
      expect(d.golfers.single.skinsWon, 2);
      expect(d.golfers.single.junkSkins, 1);
      expect(d.golfers.single.totalSkins, 3);
      expect(d.totalSkinsWon, 3);
    });

    test('sorted by skins, high first, with a stable name tiebreak', () {
      final d = SkinsBoardData.fromSkins(_skins(
        players: [
          _p(1, 'Zoe',  won: 1),
          _p(2, 'Adam', won: 3),
          _p(3, 'Bea',  won: 1),
        ],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      ));
      expect([for (final g in d.ledger) g.name], ['Adam', 'Bea', 'Zoe']);
    });

    test('a colour follows the ROSTER, not the standings', () {
      // Otherwise a golfer changes colour the moment he wins a skin, and the
      // hole tiles stop matching the ledger swatches.
      final d = SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Zoe'), _p(2, 'Adam', won: 3)],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      ));
      expect(d.ledger.first.name, 'Adam');
      expect(d.ledger.first.colourIndex, 1);   // still second in the roster
      expect(d.golfers.first.colourIndex, 0);
    });

    test('in a pool the column is each share, and adds up to the pool', () {
      // The round from Paul's screenshot, 29 Oct 2026: six golfers ante $10,
      // three skins won, one each. Each winner is paid $20 of the $60; the
      // board showed his NET (+$10) and the losers' −$10, under "$60 pool".
      final d = SkinsBoardData.fromSkins(_skins(
        betUnit: 10, payoutStyle: 'pool', pool: 60,
        players: [
          _p(1, 'Larry', won: 1, payout: 20, net: 10),
          _p(2, 'Paul',  won: 1, payout: 20, net: 10),
          _p(3, 'Sean',  won: 1, payout: 20, net: 10),
          _p(4, 'Jim',   payout: 0, net: -10),
          _p(5, 'Ryan',  payout: 0, net: -10),
          _p(6, 'Tyler', payout: 0, net: -10),
        ],
        holes: [
          _unplayed(1), _won(2, 1), _won(3, 2), _won(4, 3),
          for (var h = 5; h <= 18; h++) _unplayed(h),
        ],
      ));
      expect(d.isPool, isTrue);
      expect(d.ledger.map((g) => g.money), [20, 20, 20, 0, 0, 0]);
      expect(d.ledger.fold<double>(0, (a, g) => a + g.money), d.pool);
    });

    test('per skin the column is the signed net, and adds up to zero', () {
      final d = SkinsBoardData.fromSkins(_skins(
        betUnit: 1, payoutStyle: 'per_point',
        players: [_p(1, 'Paul', won: 2, net: 2), _p(2, 'Dave', net: -2)],
        holes: [_won(1, 1), _won(2, 1),
                for (var h = 3; h <= 18; h++) _unplayed(h)],
      ));
      expect(d.ledger.map((g) => g.money), [2, -2]);
    });

    test('the money is the SERVER\'s net, not the design\'s formula', () {
      // stake 1, 2 golfers, Paul 3 of 3 skins: the reference formula would
      // say +$3.  Pool mode (or junk, or a withdrawal) makes it something
      // else, and the server is the one that knows.
      final d = SkinsBoardData.fromSkins(_skins(
        betUnit: 1.0,
        players: [_p(1, 'Paul', won: 3, net: 1.5),
                  _p(2, 'Dave', net: -1.5)],
        holes: [for (var h = 1; h <= 3; h++) _won(h, 1)],
      ));
      expect(d.ledger.first.money, 1.5);
      expect(d.ledger.last.money, -1.5);
    });
  });

  group('the cross-round pool', () {
    MultiSkinsSummary pool() => MultiSkinsSummary.fromJson({
          'status': 'in_progress',
          'handicap': {'mode': 'gross', 'net_percent': 100},
          'skin_rules': '',
          'players': [
            {'player_id': 1, 'name': 'Paul', 'short_name': 'Paul',
             'foursome_id': 1, 'group_number': 1, 'skins_won': 2,
             'payout': 6.0, 'thru': 9},
            {'player_id': 2, 'name': 'Dave', 'short_name': 'Dave',
             'foursome_id': 2, 'group_number': 2, 'skins_won': 0,
             'payout': -2.0, 'thru': 9},
          ],
          'holes': [
            {'hole': 1, 'par': 4, 'winner_id': 1, 'is_dead': false},
            {'hole': 2, 'par': 4, 'winner_id': null, 'is_dead': true},
            {'hole': 3, 'par': 4, 'winner_id': 1, 'is_dead': false},
          ],
          'money': {'bet_unit': 2.0, 'pool': 4.0, 'total_skins': 2},
        });

    test('it never carries, so the Up-next card is suppressed', () {
      final d = SkinsBoardData.fromPool(pool());
      expect(d.carry, isFalse);
      expect(d.showNext, isFalse);
      expect(d.carriedInHoles, isEmpty);
    });

    test('a dead hole counts as played but pays nothing', () {
      final d = SkinsBoardData.fromPool(pool());
      expect(d.holesPlayed, 3);
      expect(d.holes[1].played, isTrue);
      expect(d.holes[1].isWon, isFalse);
      expect(d.holes[1].value, 0);
    });

    test('every won hole in a pool is worth exactly one', () {
      final d = SkinsBoardData.fromPool(pool());
      expect(d.holes[0].value, 1);
      expect(d.holes[2].value, 1);
    });

    test('a pool has no junk', () {
      final d = SkinsBoardData.fromPool(pool());
      expect(d.golfers.every((g) => g.junkSkins == 0), isTrue);
      expect(d.totalSkinsWon, 2);
    });
  });

  group('the basis label', () {
    test('it is a label, never a calculation', () {
      for (final (mode, label) in [
        ('net', 'Net'), ('gross', 'Gross'), ('strokes_off', 'Strokes off'),
      ]) {
        final d = SkinsBoardData.fromSkins(_skins(
          mode: mode, players: [_p(1, 'Paul')],
          holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
        ));
        expect(d.basis, label);
      }
    });
  });

  group('a per-skin price is the game\'s own, not the round\'s', () {
    // Reported from Annandale Friday: $5 skins beside a $10 Nassau read
    // `$10 a skin` and `2 skins · $80`, while the money was rightly -$15 for
    // three skins. `betUnit` is the round's stake; a skin has its own rate.
    final five = [
      for (final (i, n) in ['Gil', 'Glenn', 'Jack', 'Jean', 'Paul'].indexed)
        _p(i + 1, n),
    ];
    final holes = [for (var h = 1; h <= 18; h++) _unplayed(h)];

    test('the stake is the rate, whatever the round is playing for', () {
      final d = SkinsBoardData.fromSkins(_skins(
          players: five, holes: holes, betUnit: 10, rate: 5));
      expect(d.stake, 5);
    });

    test('one skin pays the rate from each of the other four', () {
      final d = SkinsBoardData.fromSkins(_skins(
          players: five, holes: holes, betUnit: 10, rate: 5));
      expect(d.skinWorth, 20);
      expect(2 * d.skinWorth, 40, reason: 'the screenshot read \$80');
    });

    test('pay everyone above you is worth the same', () {
      final d = SkinsBoardData.fromSkins(_skins(
          players: five, holes: holes, rate: 5, perPointMode: 'all'));
      expect(d.skinWorth, 20);
    });

    test('against the average a skin is worth four fifths of that', () {
      final d = SkinsBoardData.fromSkins(_skins(
          players: five, holes: holes, rate: 5, perPointMode: 'average'));
      expect(d.skinWorth, 4);
    });

    test('a pool still reads the round stake, which is its ante', () {
      final d = SkinsBoardData.fromSkins(_skins(
          players: five, holes: holes, betUnit: 10, rate: 0,
          payoutStyle: 'pool'));
      expect(d.stake, 10);
    });
  });
}
