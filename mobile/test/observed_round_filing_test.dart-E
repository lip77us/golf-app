// Where a watched round is filed, and why the flag could not simply be flipped.
//
// Reported 20 Oct 2026: a watcher found a TOURNAMENT round on the Rounds menu
// rather than under Tournaments. The server hardcoded `is_tournament: false`
// for every round row and the two list screens split on exactly that.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';

SharedRoundSummary row({
  bool isTournament = false,
  int? tournamentId,
  String? tournamentName,
  int? roundNumber,
  String groupLabel = 'Paul Lipkin',
}) =>
    SharedRoundSummary.fromJson({
      'id': 467,
      'date': '2026-10-20',
      'course_name': 'Copper Valley',
      'status': 'complete',
      'active_games': ['forty_balls'],
      'group_label': groupLabel,
      'your_name': null,
      'is_tournament': isTournament,
      'tournament_id': tournamentId,
      'tournament_name': tournamentName,
      'round_number': roundNumber,
    });

void main() {
  group('which list a watched row belongs on', () {
    test('a casual round goes to Casual Rounds', () {
      expect(row().belongsUnderTournaments, isFalse);
    });

    test('a watched TOURNAMENT goes to Tournaments', () {
      expect(row(isTournament: true).belongsUnderTournaments, isTrue);
    });

    test('a round OF a tournament goes to Tournaments', () {
      // The bug: this one used to land on Casual Rounds.
      expect(
        row(tournamentId: 67, tournamentName: 'Copperopolis Fall 26',
            roundNumber: 2).belongsUnderTournaments,
        isTrue,
      );
    });

    test('the two screens are exact complements', () {
      // Each row lands on exactly one list — never twice, never neither.
      final rows = [
        row(),
        row(isTournament: true),
        row(tournamentId: 67, tournamentName: 'Fall Cup', roundNumber: 1),
      ];
      for (final r in rows) {
        expect(r.belongsUnderTournaments == !r.belongsUnderTournaments,
            isFalse);
      }
      expect(rows.where((r) => r.belongsUnderTournaments).length, 2);
      expect(rows.where((r) => !r.belongsUnderTournaments).length, 1);
    });
  });

  group('the flag still means what it meant', () {
    test('a tournament ROUND is not marked isTournament', () {
      // `openWatchedRound` reads `id` as a TOURNAMENT id when this is true.
      // Marking a round with it would send a round id to `joinTournament`.
      final r = row(tournamentId: 67, tournamentName: 'Fall Cup');
      expect(r.isTournament, isFalse);
      expect(r.id, 467, reason: 'still the round, which is what opens');
    });

    test('the opener branches on isTournament, not on the list question', () {
      // Source-level: `utils/shared_round.dart` has no widget to pump, and
      // this is the one line where confusing the two flags would open the
      // wrong thing.
      // Comments stripped first: the file explains at length WHY it does
      // not use the other flag, and a bare word-search would fail on the
      // explanation. (It did.)
      final code = File('lib/utils/shared_round.dart')
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('belongsUnderTournaments'), isFalse,
          reason: 'the opener must branch on what `id` IS');
      expect(code.contains('if (r.isTournament)'), isTrue);
    });
  });

  group('what a row is called in a list', () {
    test('a casual round keeps the creator name', () {
      expect(row().listLabel, 'Paul Lipkin');
    });

    test('a tournament round names the event and the round', () {
      // `Paul Lipkin` under Tournaments names a person where the reader is
      // looking for an event.
      expect(
        row(tournamentId: 67, tournamentName: 'Copperopolis Fall 26',
            roundNumber: 2).listLabel,
        'Copperopolis Fall 26 · Round 2',
      );
    });

    test('a watched tournament already had the event name', () {
      expect(row(isTournament: true, groupLabel: 'Fall Cup').listLabel,
          'Fall Cup');
    });
  });

  test('an older server simply files everything as casual', () {
    // The fields are absent, not false — which is what the shipped behaviour
    // was, so nothing regresses against a server that predates them.
    final r = SharedRoundSummary.fromJson({
      'id': 1, 'date': '', 'course_name': '', 'status': 'complete',
      'active_games': [], 'group_label': 'X', 'your_name': null,
      'is_tournament': false,
    });
    expect(r.tournamentId, isNull);
    expect(r.belongsUnderTournaments, isFalse);
    expect(r.listLabel, 'X');
  });
}
