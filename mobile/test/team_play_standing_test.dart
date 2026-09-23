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
  String shortName = 'Team',
  List<int> playerIds = const [1, 2, 3, 4],
  TeamPlayStanding? standing,
  List<TeamPlayGolferCard> golfers = const [],
}) =>
    TeamPlayCardTeam(
      slot: slot, name: name, shortName: shortName,
      colour: '#123456',
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

  // ── A pairs card reports BOTH twosomes ──────────────────────────────────
  //
  // One person enters for both teams on the card — that is what the card is
  // for — so reporting one of them picks a favourite between two teams the
  // same thumb is scoring. Reported from a two-man scramble, 23 Sep 2026:
  // *it should have both places for the 2 twosomes.*
  group('**both twosomes, and the whole field**', () {
    TeamPlayCardTeam pair(String short, int? rank, int thru,
            {int field = 4, int ntp = 0, bool tied = false}) =>
        _team(
            name: short, shortName: short,
            standing: TeamPlayStanding(
                rank: rank, tied: tied, field: field,
                netToPar: rank == null ? null : ntp, thru: thru));

    test('two places, tagged, over one field', () {
      final st = teamPlayCardStanding([
        pair('B & P', 1, 1, ntp: -1),
        pair('D & D', 2, 1, ntp: 0),
      ])!;
      expect(st.place, 'B&P 1st · D&D 2nd of 4');
      // Both are on the same hole, so `thru` is one fact and is said once.
      expect(st.score, 'thru 1');
    });

    test('the field is every team ENTERED, not the ones that have started',
        () {
      // Four twosomes are four twosomes from the first tee, and that is how
      // many rows the board draws all day.
      final st = teamPlayCardStanding([
        pair('B & P', 1, 1, ntp: -1),
        pair('D & D', 2, 1, ntp: 0),
      ])!;
      expect(st.place, endsWith('of 4'));
    });

    test('a twosome that has not started is marked, not dropped', () {
      // It is on the card and on the board; leaving it out would read as one
      // twosome in a pairs event.
      final st = teamPlayCardStanding([
        pair('B & P', 1, 1, ntp: -1),
        pair('D & D', null, 0),
      ])!;
      expect(st.place, 'B&P 1st · D&D — of 4');
      // Their hole counts differ for the moment between the two entries, so
      // there is no one `thru` to state.
      expect(st.score, isEmpty);
    });

    test('a tie is marked on a pairs row too', () {
      final st = teamPlayCardStanding([
        pair('B & P', 1, 2, ntp: -1, tied: true),
        pair('D & D', 1, 2, ntp: -1, tied: true),
      ])!;
      expect(st.place, 'B&P T-1 · D&D T-1 of 4');
    });

    test('neither has started — the row says Tee off, which is the screen\'s',
        () {
      expect(
          teamPlayCardStanding([pair('B & P', null, 0), pair('D & D', null, 0)]),
          isNull);
    });

    test('a foursome card is unchanged — one team, and it keeps its score',
        () {
      final st = teamPlayCardStanding([
        _team(standing: const TeamPlayStanding(
            rank: 2, field: 6, netToPar: -4, thru: 12)),
      ])!;
      expect(st.place, '2nd of 6');
      expect(st.score, '−4 thru 12');
    });

    test('an empty card has no row', () {
      expect(teamPlayCardStanding(const []), isNull);
    });
  });
}

