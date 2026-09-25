/// test/hole_header_test.dart
/// -------------------------
/// The grey header at the top of a score-entry card, and the line under the
/// hole number that states the hole's facts.
///
/// **The meta line is the reason the header is shared at all.** It collapses
/// par, yardage and index across the tees ACTUALLY IN PLAY and slashes only
/// what they disagree on. Pink Ball's own header read three pill chips off the
/// first golfer's tee, which in a mixed group is not the group's index — and a
/// stroke falls where the index says. So the collapse is what is pinned here,
/// case by case; it moved out of `score_entry_screen.dart` untested.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/hole_header.dart';

const _course = CourseInfo(id: 1, name: 'Ranch Solano');

TeeInfo _tee(int id, String name) => TeeInfo(
      id: id, course: _course, teeName: name,
      slope: 113, courseRating: 70.0, par: 72,
    );

Membership _m(int id, {TeeInfo? tee}) => Membership(
      id: id,
      player: PlayerProfile(
          id: id, name: 'Player $id', shortName: 'P$id',
          handicapIndex: '0', isPhantom: false, email: ''),
      courseHandicap: 0,
      playingHandicap: 0,
      tee: tee,
    );

/// One hole, with a per-golfer entry for each of [perPlayer].
ScorecardHole _hole({
  int par = 4,
  int? yards = 400,
  int si = 7,
  Map<int, ({int par, int? yards, int si})> perPlayer = const {},
}) =>
    ScorecardHole(
      holeNumber: 7, par: par, strokeIndex: si, yards: yards,
      scores: [
        for (final e in perPlayer.entries)
          HoleScoreEntry(
            playerId: e.key, playerName: 'Player ${e.key}', holeNumber: 7,
            handicapStrokes: 0,
            par: e.value.par, yards: e.value.yards, strokeIndex: e.value.si,
          ),
      ],
    );

void main() {
  group('the line collapses across the tees in play', () {
    test('one tee states each fact once', () {
      final line = holeHeaderLine(_hole(), [_m(1, tee: _tee(9, 'White'))]);
      expect(line, 'Par 4  |  400 yds.  |  SI: 7');
    });

    test('four golfers off ONE tee still state it once', () {
      // Keyed by tee, not by golfer — otherwise a foursome off the white tees
      // would read `Par 4/4/4/4`.
      final tee = _tee(9, 'White');
      final line = holeHeaderLine(
          _hole(perPlayer: {
            for (var i = 1; i <= 4; i++) i: (par: 4, yards: 400, si: 7),
          }),
          [for (var i = 1; i <= 4; i++) _m(i, tee: tee)]);
      expect(line, 'Par 4  |  400 yds.  |  SI: 7');
    });

    test('two tees slash only the facts that differ', () {
      // The forward tee plays the 7th as a five, 60 yards shorter, and indexes
      // it differently. All three disagree, so all three slash.
      final line = holeHeaderLine(
          _hole(perPlayer: {
            1: (par: 4, yards: 400, si: 7),
            2: (par: 5, yards: 340, si: 3),
          }),
          [_m(1, tee: _tee(9, 'White')), _m(2, tee: _tee(10, 'Red'))]);
      expect(line, 'Par 4/5  |  400/340 yds.  |  SI: 7/3');
    });

    test('a shared par is not slashed just because the yardage is', () {
      // The case that makes this a collapse rather than a join: two tees, one
      // par. `Par 4/4` would be noise on a line read on a tee box.
      final line = holeHeaderLine(
          _hole(perPlayer: {
            1: (par: 4, yards: 400, si: 7),
            2: (par: 4, yards: 340, si: 7),
          }),
          [_m(1, tee: _tee(9, 'White')), _m(2, tee: _tee(10, 'Red'))]);
      expect(line, 'Par 4  |  400/340 yds.  |  SI: 7');
    });

    test('a golfer with no tee counts as his own', () {
      // He keys off his own id, so he cannot collapse into somebody else's row
      // — which is what stops an unassigned golfer borrowing a par he is not
      // playing.
      final line = holeHeaderLine(
          _hole(perPlayer: {
            1: (par: 4, yards: 400, si: 7),
            2: (par: 5, yards: 340, si: 3),
          }),
          [_m(1), _m(2)]);
      expect(line, 'Par 4/5  |  400/340 yds.  |  SI: 7/3');
    });

    test('no yardage on the card drops the middle field, not the line',
        () {
      final line = holeHeaderLine(
          _hole(yards: null), [_m(1, tee: _tee(9, 'White'))]);
      expect(line, 'Par 4  |  SI: 7');
    });

    test('no golfers falls back to the hole\'s own shared figures', () {
      // Empty is legal — the header draws before a foursome is resolved.
      expect(holeHeaderLine(_hole(), const []), 'Par   |  SI: ');
    });
  });

  group('the header', () {
    Future<void> pump(WidgetTester tester,
        {ScorecardHole? hole,
        String courseName = '',
        Widget? trailing,
        int holeNumber = 7}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HoleHeader(
            holeData: hole,
            holeNumber: holeNumber,
            players: [_m(1, tee: _tee(9, 'White'))],
            courseName: courseName,
            trailing: trailing,
          ),
        ),
      ));
    }

    testWidgets('names the hole by NUMBER and states its facts',
        (tester) async {
      // Seven, not "the first hole played" — a shotgun group starting on the
      // 7th is on the 7th.
      await pump(tester, hole: _hole());
      expect(find.text('Hole 7'), findsOneWidget);
      expect(find.text('Par 4  |  400 yds.  |  SI: 7'), findsOneWidget);
    });

    testWidgets('a hole with no data drops the line rather than inventing a par',
        (tester) async {
      await pump(tester);
      expect(find.text('Hole 7'), findsOneWidget);
      expect(find.textContaining('Par'), findsNothing);
    });

    testWidgets('the course name sits above the hole when there is one',
        (tester) async {
      await pump(tester, hole: _hole(), courseName: 'Ranch Solano');
      final course = tester.getCenter(find.text('Ranch Solano'));
      final hole = tester.getCenter(find.text('Hole 7'));
      expect(course.dy, lessThan(hole.dy));
    });

    testWidgets('no trailing widget leaves the hole number centred',
        (tester) async {
      // The 44px padding is symmetrical, so a screen with no legend is not
      // paying for one — and `Hole 7` is centred either way.
      await pump(tester, hole: _hole());
      final header = tester.getRect(find.byType(HoleHeader));
      final label = tester.getCenter(find.text('Hole 7'));
      expect(label.dx, closeTo(header.center.dx, 0.5));
    });

    testWidgets('a trailing widget sits top-right and does not move the label',
        (tester) async {
      await pump(tester,
          hole: _hole(),
          trailing: const Icon(Icons.help_outline, key: Key('legend')));
      final header = tester.getRect(find.byType(HoleHeader));
      final legend = tester.getRect(find.byKey(const Key('legend')));
      expect(legend.right, lessThanOrEqualTo(header.right));
      expect(legend.left, greaterThan(header.center.dx));
      expect(legend.top, lessThan(header.center.dy));
      // Still centred — the whole reason it is a Stack.
      expect(tester.getCenter(find.text('Hole 7')).dx,
          closeTo(header.center.dx, 0.5));
    });
  });

  group('one header, every score-entry screen', () {
    // Source-level: the point is the sweep, not the rendering. Every screen
    // that enters a score draws the same header, and the ones with their own
    // play screen are exactly the ones a sweep misses.
    const screens = [
      'lib/screens/score_entry_screen.dart',
      'lib/screens/pink_ball_screen.dart',
    ];

    for (final path in screens) {
      test('$path draws HoleHeader', () {
        expect(File(path).readAsStringSync().contains('HoleHeader('), isTrue,
            reason: '$path shows a golfer the hole he is entering. Use the '
                'shared header — do not draw another one.');
      });
    }

    test('it is defined once, and so is the line', () {
      for (final decl in [
        'class HoleHeader extends',
        'String holeHeaderLine(',
      ]) {
        final hits = Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => f.readAsStringSync().contains(decl))
            .map((f) => f.path)
            .toList();
        expect(hits, ['lib/widgets/hole_header.dart'], reason: decl);
      }
    });
  });
}
