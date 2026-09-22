/// test/sixes_standing_test.dart
/// -----------------------------
/// The standing ribbon's two strings on a casual Sixes round.
///
/// The rotation is the whole subject. Sixes repairs the teams every six holes,
/// so the reader is on team 1 in one segment and team 2 in the next — and
/// `margin` is written from team 1's side throughout. A standing that forgot
/// to flip would read correctly a third of the time and be a screenshot away
/// from looking fine.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/sixes_standing.dart';

const _me = 11;
const _partner = 12;
const _themA = 21;
const _themB = 22;

SixesHoleResult _hole(int n, int margin, {String? winner = 'T1'}) =>
    SixesHoleResult(hole: n, margin: margin, winner: winner,
                    t1Points: 0, t2Points: 0, counts: true);

/// Short names, keyed the way the server sends them — the fixture names the
/// pairs so the assertions read like the row a golfer sees.
const _short = {_me: 'Paul', _partner: 'Jim', _themA: 'Larry', _themB: 'GL'};

SixesTeamInfo _team(List<int> ids) => SixesTeamInfo(
      players: [for (final i in ids) '${_short[i]} Surname'],
      playersShort: [for (final i in ids) _short[i]!],
      playerIds: ids,
      method: 'draw',
    );

SixesSegment _seg({
  required List<int> team1,
  required List<int> team2,
  required List<SixesHoleResult> holes,
  String status = 'in_progress',
  String winner = '—',
  int startHole = 1,
  int endHole = 6,
}) =>
    SixesSegment(
      label: 'Segment', startHole: startHole, endHole: endHole,
      isExtra: false, status: status, winner: winner,
      team1: _team(team1),
      team2: _team(team2),
      holes: holes,
    );

SixesSummary _summary(List<SixesSegment> segments,
                      {Map<int, double> money = const {}}) =>
    SixesSummary(
      segments: segments, team1Wins: 0, team2Wins: 0, halves: 0,
      handicapMode: 'net', netPercent: 100, moneyByPlayer: money,
    );

void main() {
  group('the standing is read from the READER\'s side', () {
    test('a reader on team 1 takes the margin as written', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1), _hole(2, 2)]),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim 2 up thru 2');
    });

    test('a reader on team 2 takes it flipped — the rotation case', () {
      // The identical segment, read by a golfer on the other side. `margin`
      // has not changed; whose number it is has.
      final s = _summary([
        _seg(team1: [_themA, _themB], team2: [_me, _partner],
             holes: [_hole(1, 1), _hole(2, 2)]),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim 2 down thru 2');
    });

    test('the same round reads opposite ways to the two sides', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)]),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim 1 up thru 1');
      expect(sixesStanding(s, _themA)!.standing, 'Larry, GL 1 down thru 1');
    });

    test('a reader who changed sides between segments follows his own', () {
      // Segment 1: he played with _partner as team 1 and went 2 up.
      // Segment 2: the draw repaired him with _themA — and put that pair on
      // TEAM 2, so the same +1 margin is now against him. The live segment is
      // the one he wants, read from the side he is on NOW.
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 2)], status: 'complete', winner: 'Team 1'),
        _seg(team1: [_partner, _themB], team2: [_me, _themA],
             startHole: 7, endHole: 12, holes: [_hole(7, 1)]),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Larry 1 down thru 1');
    });

    test('all square says so rather than showing a nought', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 0, winner: 'Halved')]),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim all square thru 1');
    });

    test('a decided segment reports the result, not a running margin', () {
      // `2 UP` on a match that is over reads as a match still to play.
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 2)], status: 'complete', winner: 'Team 1'),
      ]);
      // One hole played of six, so five were conceded — golf's own
      // notation, not `2 UP thru 1` about a match that is over.
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim won 2 and 5');
      expect(sixesStanding(s, _themA)!.standing, 'Larry, GL lost 2 and 5');
    });
  });

  group('the money is settled, never forecast', () {
    test('it reads the engine\'s own per-segment settlement', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)]),
      ], money: {_me: 10.0, _themA: -10.0});
      expect(sixesStanding(s, _me)!.figure, '+\$10 so far');
      expect(sixesStanding(s, _themA)!.figure, '−\$10 so far');
    });

    test('nothing settled says nothing at all', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)]),
      ]);
      // **Nothing settled says nothing.** It read `Even so far`, which is
      // true and reads as a contradiction beside a live margin: the row said
      // `1 UP · Even so far` on the second hole, and a golfer who is one up
      // does not think of himself as even.
      expect(sixesStanding(s, _me)!.figure, '');
    });

    test('the minus is U+2212, not a hyphen', () {
      // Beside a `+` at 12px the hyphen is visibly the wrong length, and the
      // two appear within a few characters of each other on this row.
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)]),
      ], money: {_me: -5.0});
      expect(sixesStanding(s, _me)!.figure.startsWith('−'), isTrue);
    });
  });

  group('thru counts the MATCH, not the course', () {
    test('it counts holes played in this segment', () {
      // The golfer is on the 9th hole of the course and the 3rd of his
      // match. `1 UP` alone leaves him counting backwards to work out how
      // many he has left to play it in.
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)], status: 'complete', winner: 'Team 1'),
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             startHole: 7, endHole: 12,
             holes: [_hole(7, 1), _hole(8, 1), _hole(9, 1)]),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim 1 up thru 3');
    });

    test('a segment that does not start at hole 1 still counts from 1', () {
      // The case that prompted this: with an extra segment in the round the
      // hole number and the match position stop agreeing, and the header can
      // only tell you the first.
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             startHole: 13, endHole: 18, holes: [_hole(13, 0, winner: 'Halved')]),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim all square thru 1');
    });

    test('a match played out to the end says UP, not AND 0', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [for (var h = 1; h <= 6; h++) _hole(h, 1)],
             status: 'complete', winner: 'Team 1'),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim won 1 up');
    });

    test('a halved match says so rather than counting to nothing', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [for (var h = 1; h <= 6; h++) _hole(h, 0, winner: 'Halved')],
             status: 'halved', winner: 'Halved'),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim halved');
    });
  });

  group('the colour is a second signal, never the only one', () {
    test('it reports his side when that match is the one on screen', () {
      final seg = _seg(team1: [_me, _partner], team2: [_themA, _themB],
                       holes: [_hole(1, 1)]);
      final s = _summary([seg]);
      expect(sixesStanding(s, _me, onScreen: seg)!.team, 1);
      expect(sixesStanding(s, _themA, onScreen: seg)!.team, 2);
    });

    test('it follows him across the re-draw', () {
      final seg2 = _seg(team1: [_partner, _themB], team2: [_me, _themA],
                        startHole: 7, endHole: 12, holes: [_hole(7, 1)]);
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)], status: 'complete', winner: 'Team 1'),
        seg2,
      ]);
      expect(sixesStanding(s, _me, onScreen: seg2)!.team, 2);
    });

    test('**it is withheld between segments**', () {
      // Reported from the course on the 7th: the row said `WON 1 UP` in blue
      // while the player rows had already repaired, so blue was no longer the
      // pair that won it. The standing is about match 1; the screen is showing
      // match 2. No colour — the names carry it.
      final seg1 = _seg(team1: [_me, _partner], team2: [_themA, _themB],
                        holes: [_hole(1, 1)], status: 'complete',
                        winner: 'Team 1');
      final seg2 = _seg(team1: [_partner, _themB], team2: [_me, _themA],
                        startHole: 7, endHole: 12, holes: const [],
                        status: 'pending');
      final s = _summary([seg1, seg2]);
      final standing = sixesStanding(s, _me, onScreen: seg2)!;
      expect(standing.team, isNull);
      expect(standing.standing, 'Paul, Jim won 1 and 5');
    });

    test('it is withheld when nothing says what is on screen', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)]),
      ]);
      expect(sixesStanding(s, _me)!.team, isNull);
    });
  });

  group('the row names his pairing on every state', () {
    test('**colour cannot carry identity when the teams repair**', () {
      // Blue is a different pair of golfers in match two than it was in match
      // one, so a golfer reading a colour has to remember which draw he is
      // looking at. Names never need that.
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)], status: 'complete', winner: 'Team 1'),
        _seg(team1: [_partner, _themB], team2: [_me, _themA],
             startHole: 7, endHole: 12, holes: [_hole(7, 1)]),
      ]);
      // His pair changed; so does the name on the row.
      expect(sixesStanding(s, _me)!.standing, startsWith('Paul, Larry '));
    });

    test('it uses the short-name field, not first names', () {
      final s = _summary([
        _seg(team1: [_me, _themB], team2: [_partner, _themA],
             holes: [_hole(1, 1)]),
      ]);
      // `GL` is a set short name; a first-name split would say `Gilbert`.
      expect(sixesStanding(s, _me)!.standing, startsWith('Paul, GL '));
    });

    test('an older payload without short names falls back to first names', () {
      final seg = SixesSegment(
        label: 'Segment', startHole: 1, endHole: 6, isExtra: false,
        status: 'in_progress', winner: '—',
        team1: SixesTeamInfo(players: const ['Paul Lipkin', 'Jim Diederich'],
                             playerIds: const [_me, _partner], method: 'draw'),
        team2: SixesTeamInfo(players: const ['Larry Sanders', 'Gilbert Lee'],
                             playerIds: const [_themA, _themB], method: 'draw'),
        holes: [_hole(1, 1)],
      );
      expect(sixesStanding(_summary([seg]), _me)!.standing,
             startsWith('Paul, Jim '));
    });
  });

  group('which segment the row is about', () {
    test('the one being played, not the tally', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 3)], status: 'complete', winner: 'Team 1'),
        _seg(team1: [_me, _themA], team2: [_partner, _themB],
             startHole: 7, endHole: 12, holes: [_hole(7, 1)]),
      ]);
      // Segment 1 finished 3 up; the row reports the ONE being played.
      expect(sixesStanding(s, _me)!.standing, 'Paul, Larry 1 up thru 1');
    });

    test('between segments it holds the match just finished', () {
      // The draw is up and nobody has teed off. Reporting the new segment
      // would say ALL SQUARE about golf nobody has played.
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 2)], status: 'complete', winner: 'Team 1'),
        _seg(team1: [_me, _themA], team2: [_partner, _themB],
             startHole: 7, endHole: 12, holes: const [], status: 'pending'),
      ]);
      expect(sixesStanding(s, _me)!.standing, 'Paul, Jim won 2 and 5');
    });

    test('an extra segment is not the live one', () {
      expect(liveSegment(_summary(const [])), isNull);
    });
  });

  group('when there is nothing to say', () {
    test('no summary, no row', () {
      expect(sixesStanding(null, _me), isNull);
    });

    test('a watcher gets no standing — he is on neither side', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: [_hole(1, 1)]),
      ]);
      expect(sixesStanding(s, 999), isNull);
    });

    test('before the first hole, no standing', () {
      final s = _summary([
        _seg(team1: [_me, _partner], team2: [_themA, _themB],
             holes: const [], status: 'pending'),
      ]);
      expect(sixesStanding(s, _me), isNull);
    });
  });

  group('the money block parses off the wire', () {
    test('it reads money.by_player, which the server always sent', () {
      final s = SixesSummary.fromJson({
        'segments': [],
        'overall': {'team1_wins': 1, 'team2_wins': 0, 'halves': 0},
        'handicap': {'mode': 'net', 'net_percent': 100},
        'money': {
          'bet_unit': 5.0,
          'by_player': [
            {'player_id': _me, 'name': 'Me', 'amount': 5.0},
            {'player_id': _themA, 'name': 'Them', 'amount': -5.0},
          ],
        },
      });
      expect(s.moneyByPlayer[_me], 5.0);
      expect(s.moneyByPlayer[_themA], -5.0);
    });

    test('an older payload without money is empty, not a crash', () {
      final s = SixesSummary.fromJson({
        'segments': [],
        'overall': {'team1_wins': 0, 'team2_wins': 0, 'halves': 0},
        'handicap': {'mode': 'net', 'net_percent': 100},
      });
      expect(s.moneyByPlayer, isEmpty);
    });
  });
}
