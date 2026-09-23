/// test/team_play_standing_test.dart
/// ---------------------------------
/// The standing ribbon's two strings on a Foursome Play round.
///
/// Stroke Play's shape one level up — a place, a score, how far in — and the
/// difference is that here the place can be SAID: the event is a tournament
/// with a real board behind it, and the server sends the field place down
/// with the card.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/team_play_standing.dart';

TeamPlayCardTeam _team({
  int slot = 1,
  String name = 'Team',
  List<int> playerIds = const [1, 2, 3, 4],
  TeamPlayStanding? standing,
  List<TeamPlayGolferCard> golfers = const [],
}) =>
    TeamPlayCardTeam(
      slot: slot, name: name, colour: '#123456',
      round: const TeamPlayRound(thru: 0, complete: false, par: 72, penalty: 0),
      drive: const TeamPlayDrive(
          rule: 'none', required: 0, perGolfer: 0, holes: 0, free: 0,
          shortfall: 0, penaltyStrokes: 0, pairsSet: false,
          windows: [], rota: []),
      playerIds: playerIds, standing: standing, golfersByHole: golfers,
    );

void main() {
  group('**the place leads, because the place is the money**', () {
    test('a ranked team reads place then score', () {
      final st = teamPlayStanding(_team(
          standing: const TeamPlayStanding(
              rank: 2, field: 6, netToPar: -4, thru: 12)))!;
      expect(st.place, '2nd of 6');
      expect(st.score, '−4 thru 12');
    });

    test('a tie is marked, because a net field ties most weeks', () {
      final st = teamPlayStanding(_team(
          standing: const TeamPlayStanding(
              rank: 2, tied: true, field: 6, netToPar: -4, thru: 12)))!;
      expect(st.place, 'T-2 of 6');
    });

    test('level par is E, never 0', () {
      expect(
          teamPlayStanding(_team(
              standing: const TeamPlayStanding(
                  rank: 1, field: 3, netToPar: 0, thru: 9)))!.score,
          'E thru 9');
    });

    test('the minus is U+2212, the one the money figure uses', () {
      final st = teamPlayStanding(_team(
          standing: const TeamPlayStanding(
              rank: 1, field: 3, netToPar: -2, thru: 9)))!;
      expect(st.score.contains('−'), isTrue);
      expect(st.score.contains('-'), isFalse);
    });
  });

  group('**what the row will not claim**', () {
    test('a team with no score is not on the board', () {
      // Not level par — not ranked. The row draws `Tee off` for this, which
      // is the screen's call and not a string invented here.
      expect(
          teamPlayStanding(_team(
              standing: const TeamPlayStanding(field: 0, thru: 0))),
          isNull);
    });

    test('no standing block at all — an older server', () {
      expect(teamPlayStanding(_team()), isNull);
      expect(teamPlayStanding(null), isNull);
    });

    test('`1st of 1` is true and says nothing, so only the score shows', () {
      // The first group out has nobody to be ahead of. The score carries the
      // row until a second team has a number.
      final st = teamPlayStanding(_team(
          standing: const TeamPlayStanding(
              rank: 1, field: 1, netToPar: -1, thru: 3)))!;
      expect(st.place, isEmpty);
      expect(st.score, '−1 thru 3');
    });
  });

  group('**which team on the card the row reports**', () {
    test('a pairs card reports the reader OWN team', () {
      final a = _team(slot: 1, name: 'B & P', playerIds: const [1, 2]);
      final b = _team(slot: 2, name: 'M & S', playerIds: const [3, 4]);
      expect(readersTeam([a, b], 3)!.name, 'M & S');
      expect(readersTeam([a, b], 1)!.name, 'B & P');
    });

    test('a foursome card has one team and it is his', () {
      final only = _team(playerIds: const [7, 8, 9, 10]);
      expect(readersTeam([only], 9), same(only));
    });

    test('a TD not playing gets the GROUP, not a blank row', () {
      // He opened a screen entirely about this group; a row that went blank
      // would report nothing about the thing on screen.
      final a = _team(slot: 1, name: 'B & P', playerIds: const [1, 2]);
      final b = _team(slot: 2, name: 'M & S', playerIds: const [3, 4]);
      expect(readersTeam([a, b], 999)!.name, 'B & P');
      expect(readersTeam([a, b], null)!.name, 'B & P');
    });

    test('an own-ball card matches on its golfer rows too', () {
      // An older server sends no `player_ids`; a shamble still carries its
      // golfers, so the reader is findable either way.
      final a = _team(slot: 1, name: 'B & P', playerIds: const []);
      final b = _team(slot: 2, name: 'M & S', playerIds: const [], golfers: [
        const TeamPlayGolferCard(
            playerId: 42, name: 'Moran', shortName: 'Moran',
            isPhantom: false, handicap: 9,
            scores: const {}, strokes: const {}, counted: const {}),
      ]);
      expect(readersTeam([a, b], 42)!.name, 'M & S');
    });

    test('a phantom fourth is nobody, so it never claims the row', () {
      final a = _team(slot: 1, name: 'B & P', playerIds: const []);
      final b = _team(slot: 2, name: 'M & S', playerIds: const [], golfers: [
        const TeamPlayGolferCard(
            playerId: 42, name: 'Phantom', shortName: 'PH',
            isPhantom: true, handicap: 0,
            scores: const {}, strokes: const {}, counted: const {}),
      ]);
      expect(readersTeam([a, b], 42)!.name, 'B & P');
    });

    test('an empty card has no team', () {
      expect(readersTeam(const [], 1), isNull);
    });
  });
}
