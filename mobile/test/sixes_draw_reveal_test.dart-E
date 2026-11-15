import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/sixes_draw.dart';

/// Match 2's teams are the GROUP's pick (`handoff-solo-games` §3), so the
/// question these answer is "which match still needs teams, and is this the
/// moment to ask" — not "has this reveal been shown", which is what the
/// deleted per-device flag was standing in for.
Map<String, dynamic> _seg({
  required int start,
  String status = 'pending',
  bool assigned = true,
  List<int> played = const [],
}) => {
      'label': 'Holes $start–${start + 5}',
      'start_hole': start,
      'end_hole': start + 5,
      'is_extra': false,
      'status': status,
      'winner': '—',
      'team1': {'players': assigned ? ['Al', 'Bo'] : <String>[]},
      'team2': {'players': assigned ? ['Cy', 'Di'] : <String>[]},
      'holes': [
        for (final h in played)
          {'hole': h, 't1_net': 4, 't2_net': 5, 'winner': 'T1', 'margin': 1},
      ],
    };

SixesSummary _summary(List<Map<String, dynamic>> segs) =>
    SixesSummary.fromJson({'segments': segs});

/// How a round now looks after setup: match 1 has teams, 2 and 3 do not.
final _freshRound = _summary([
  _seg(start: 1),
  _seg(start: 7, assigned: false),
  _seg(start: 13, assigned: false),
]);

/// Match 1 decided, nothing played since — the moment to ask.
final _theMoment = _summary([
  _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
  _seg(start: 7, assigned: false),
  _seg(start: 13, assigned: false),
]);

void main() {
  group('which match needs teams', () {
    test('match 2, on a round that has just been set up', () {
      expect(sixesMatchNeedingTeams(_freshRound), 2);
    });

    test('none once every match has them', () {
      expect(
          sixesMatchNeedingTeams(_summary([
            _seg(start: 1),
            _seg(start: 7),
            _seg(start: 13),
          ])),
          isNull);
    });

    test('nothing to say about a round with no sixes', () {
      expect(sixesMatchNeedingTeams(null), isNull);
      expect(sixesMatchNeedingTeams(_summary(const [])), isNull);
    });

    test('an extra match is not one of these', () {
      // Extras have their own picker — a free drag of all four golfers,
      // because an extra is not part of the three-match rotation.
      final withExtra = _summary([
        _seg(start: 1),
        _seg(start: 7),
        _seg(start: 13),
        {..._seg(start: 17, assigned: false), 'is_extra': true},
      ]);
      expect(sixesMatchNeedingTeams(withExtra), isNull);
    });
  });

  group('when the picker opens itself', () {
    test('when match 1 is decided and match 2 has not begun', () {
      expect(shouldOpenSixesTeamPicker(_theMoment), isTrue);
    });

    test('not while match 1 is still being played', () {
      expect(shouldOpenSixesTeamPicker(_freshRound), isFalse);
    });

    test('not once the group has played on', () {
      // Still pickable — the banner says so — but a screen of its own would
      // interrupt a match to ask a question the group answered with its feet.
      final playedOn = _summary([
        _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4, 5, 6]),
        _seg(start: 7, assigned: false, played: const [7]),
        _seg(start: 13, assigned: false),
      ]);
      expect(shouldOpenSixesTeamPicker(playedOn), isFalse);
    });

    test('an early close-out is still the moment', () {
      // Match 1 can finish on the 4th. That is exactly when the group is
      // standing on the next tee asking whose side they are on.
      final closedEarly = _summary([
        _seg(start: 1, status: 'complete', played: const [1, 2, 3, 4]),
        _seg(start: 5, assigned: false),
        _seg(start: 11, assigned: false),
      ]);
      expect(shouldOpenSixesTeamPicker(closedEarly), isTrue);
    });

    test('never for match 1 — that one is picked at setup', () {
      final noTeamsAtAll = _summary([
        _seg(start: 1, assigned: false),
        _seg(start: 7, assigned: false),
        _seg(start: 13, assigned: false),
      ]);
      expect(sixesMatchNeedingTeams(noTeamsAtAll), 1);
      expect(shouldOpenSixesTeamPicker(noTeamsAtAll), isFalse);
    });
  });
}
