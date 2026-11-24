import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/game_catalog.dart';

Map<String, dynamic> _json({String fmt = 'alternate_shot'}) => {
      'status': 'in_progress',
      'result_label': '—',
      'handicap': {'mode': 'net', 'net_percent': 100},
      'overall': {'holes_up': 0, 'leader': null},
      'team1': {'players': ['A', 'B'], 'short_names': ['A', 'B'],
                'player_ids': [1, 2], 'is_winner': false},
      'team2': {'players': ['C', 'D'], 'short_names': ['C', 'D'],
                'player_ids': [3, 4], 'is_winner': false},
      'holes': [],
      'money': {'bet_amount': 0, 'by_player': []},
      'ball_format': fmt,
      'allowance_pct': 40,
      'scorers_by_hole': {'1': [2, 3], '2': [1, 4]},
      'first_tee': {'1': 2, '2': 3},
    };

void main() {
  test('a pair match parses its format, allowance and tee rota', () {
    final s = FourballSummary.fromJson(_json());
    expect(s.isOneBall, isTrue);
    expect(s.allowancePct, 40);
    expect(s.firstTee[1], 2);
    expect(s.scorersByHole[2], [1, 4]);
  });

  test('the partner is whoever does not hold the side\'s score that hole', () {
    final s = FourballSummary.fromJson(_json());
    expect(s.isPartnerOnHole(1, 1), isTrue);   // B tees hole 1
    expect(s.isPartnerOnHole(2, 1), isFalse);
    expect(s.isPartnerOnHole(2, 2), isTrue);   // A tees hole 2
    expect(s.isPartnerOnHole(3, 1), isFalse);
    expect(s.isPartnerOnHole(3, 2), isTrue);
  });

  test('a plain Fourball dims nobody', () {
    final j = _json(fmt: 'best_ball')..remove('scorers_by_hole');
    final s = FourballSummary.fromJson(j);
    expect(s.isOneBall, isFalse);
    expect(s.isPartnerOnHole(1, 1), isFalse);
  });

  test('both games are in the catalog and exclude Fourball', () {
    for (final id in [GameIds.scrambleMatch, GameIds.alternateShotMatch]) {
      expect(gameMeta(id), isNotNull);
      expect(gamesCompatible(id, GameIds.fourball), isFalse);
    }
  });

  test('the drive card parses the server\'s sentence and the pick', () {
    final j = {
      'hole': 3, 'ball_format': 'scramble',
      'drive': {
        'rule': 'per_nine',
        'sides': [
          {'side': 1, 'picked': 2, 'line': 'A 0 · B 1 — 1 owed, 8 free',
           'warn': false, 'player_ids': [1, 2]},
          {'side': 2, 'picked': null, 'line': 'C 0 · D 0 — every hole left is owed',
           'warn': true, 'player_ids': [3, 4]},
        ],
      },
    };
    final c = FourballHoleCard.fromJson(j);
    expect(c.drive!.sides[0].picked, 2);
    expect(c.drive!.sides[1].warn, isTrue);
    expect(c.drive!.sides[0].line, contains('owed'));
  });

  test('a card with no quota has no drive', () {
    expect(FourballHoleCard.fromJson({'hole': 1, 'drive': {}}).drive, isNull);
  });
}
