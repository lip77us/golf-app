// Create makes ONE tournament, however it is tapped or retried.
//
// Reported 13 Nov 2026: two "Pink Test" tournaments forty seconds apart, the
// first with a round and no groups. Create is several requests; when one
// failed the button came back and a retry started over.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/screens/new_round_wizard.dart').readAsStringSync();

  test('a second tap while one is in flight does nothing', () {
    final i = src.indexOf('Future<void> _createRound() async {');
    final body = src.substring(i, src.indexOf('try {', i));
    expect(body.contains('if (_creating) return;'), isTrue);
    expect(body.indexOf('if (_creating) return;'),
        lessThan(body.indexOf('setState(() {')));
  });

  test('both paths reuse a tournament this visit already made', () {
    expect('_madeTournamentId ??'.allMatches(src).length, 1); // cup
    expect(src.contains('_createNewTournament && _madeTournamentId != null'),
        isTrue); // standard
    expect('_madeTournamentId = '.allMatches(src).length, 2);
  });

  test('both paths reuse round 1 and resume the extra rounds', () {
    expect('_madeRound1 ??'.allMatches(src).length, 2);
    expect('i = _madeExtraRounds'.allMatches(src).length, 2);
    expect('_madeExtraRounds = i + 1'.allMatches(src).length, 2);
  });
}
