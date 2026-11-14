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

    test('the golfers\' own tees win over the card\'s shared values', () {
      // **This is the bug the sweep fixed.** `ScorecardHole.par` and
      // `.strokeIndex` are the SHARED first-player values; Rabbit, Survivor,
      // Wolf, Sequoya 3s and Triple Nassau all read them, so a mixed group was
      // shown one golfer's par and one golfer's index — and the index is what
      // decides where a stroke falls.
      //
      // The card here says par 4 / SI 7 while NEITHER golfer plays it that way.
      final line = holeHeaderLine(
          _hole(par: 4, yards: 400, si: 7, perPlayer: {
            1: (par: 5, yards: 520, si: 1),
            2: (par: 5, yards: 455, si: 2),
          }),
          [_m(1, tee: _tee(9, 'Blue')), _m(2, tee: _tee(10, 'White'))]);
      expect(line, 'Par 5  |  520/455 yds.  |  SI: 1/2');
      // Said explicitly, because the equality above is what would have read
      // `Par 4 | 400 yds. | SI: 7` on five screens: the card's own numbers
      // appear NOWHERE. (`isNot(contains('4'))` would be the obvious probe and
      // is wrong — `455` contains a 4.)
      expect(line, isNot(contains('Par 4')));
      expect(line, isNot(contains('SI: 7')));
      expect(line, isNot(contains('400')));
    });

    test('a golfer with no entry on the hole falls back to the card', () {
      // The fallback is per FIELD, not all-or-nothing: a golfer the card has no
      // row for still counts, off the hole's shared figures.
      final line = holeHeaderLine(
          _hole(par: 4, yards: 400, si: 7,
              perPlayer: {1: (par: 5, yards: 520, si: 1)}),
          [_m(1, tee: _tee(9, 'Blue')), _m(2, tee: _tee(10, 'White'))]);
      expect(line, 'Par 5/4  |  520/400 yds.  |  SI: 1/7');
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

  group('holeFacts', () {
    test('states each fact once for one tee, in pieces', () {
      final f = holeFacts(_hole(), [_m(1, tee: _tee(9, 'White'))]);
      expect(f.par, '4');
      expect(f.yards, '400');
      expect(f.si, '7');
    });

    test('slashes only what the tees disagree on', () {
      final f = holeFacts(
          _hole(perPlayer: {
            1: (par: 4, yards: 400, si: 7),
            2: (par: 4, yards: 340, si: 7),
          }),
          [_m(1, tee: _tee(9, 'White')), _m(2, tee: _tee(10, 'Red'))]);
      expect(f.par, '4');
      expect(f.yards, '400/340');
      expect(f.si, '7');
    });

    test('no yardage on any tee is null, not a dash', () {
      expect(holeFacts(_hole(yards: null), [_m(1, tee: _tee(9, 'W'))]).yards,
          isNull);
    });
  });

  group('the hole card', () {
    Future<void> pump(WidgetTester tester,
        {ScorecardHole? hole,
        String courseName = '',
        Widget? trailing,
        Widget? badge,
        int holeNumber = 7}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HoleHeader(
            holeData: hole,
            holeNumber: holeNumber,
            players: [_m(1, tee: _tee(9, 'White'))],
            courseName: courseName,
            trailing: trailing,
            badge: badge,
          ),
        ),
      ));
    }

    testWidgets('the tile names the hole by NUMBER, over its par',
        (tester) async {
      // Seven, not "the first hole played" — a shotgun group starting on the
      // 7th is on the 7th.
      await pump(tester, hole: _hole());
      expect(find.text('7'), findsOneWidget);
      expect(find.text('Par 4'), findsOneWidget);
    });

    testWidgets('beside it the yardage, and the index with the nine',
        (tester) async {
      await pump(tester, hole: _hole());
      expect(find.text('400 yds'), findsOneWidget);
      expect(find.text('SI 7 · front nine'), findsOneWidget);
    });

    testWidgets('a hole past the ninth is on the back nine', (tester) async {
      await pump(tester, hole: _hole(), holeNumber: 12);
      expect(find.text('SI 7 · back nine'), findsOneWidget);
    });

    testWidgets('a hole with no data draws the tile and no invented par',
        (tester) async {
      await pump(tester);
      expect(find.text('7'), findsOneWidget);
      expect(find.textContaining('Par'), findsNothing);
      expect(find.text('back nine'.replaceAll('back', 'front')), findsOneWidget);
    });

    testWidgets('it is its own white card, not the top of another',
        (tester) async {
      await pump(tester, hole: _hole());
      final box = tester.widget<Container>(find
          .descendant(
              of: find.byType(HoleHeader), matching: find.byType(Container))
          .first);
      final deco = box.decoration as BoxDecoration;
      expect(deco.color, Colors.white);
      expect(deco.borderRadius, BorderRadius.circular(16),
          reason: 'all four corners — it has no card above it to join');
    });

    testWidgets('the tile is a 48pt deep pine square', (tester) async {
      await pump(tester, hole: _hole());
      final tile = find.ancestor(
          of: find.text('7'), matching: find.byType(Container)).first;
      expect(tester.getSize(tile), const Size(48, 48));
    });

    testWidgets('the course is a caption only for a screen that passes it',
        (tester) async {
      await pump(tester, hole: _hole(), courseName: 'Ranch Solano');
      expect(find.text('Ranch Solano'), findsOneWidget);
      await pump(tester, hole: _hole());
      expect(find.text('Ranch Solano'), findsNothing);
    });

    testWidgets('the game\'s pill and the legend sit on the right',
        (tester) async {
      await pump(tester,
          hole: _hole(),
          badge: const Text('Carry 2', key: Key('pill')),
          trailing: const Icon(Icons.help_outline, key: Key('legend')));
      final card = tester.getRect(find.byType(HoleHeader));
      final pill = tester.getRect(find.byKey(const Key('pill')));
      final legend = tester.getRect(find.byKey(const Key('legend')));
      expect(pill.left, greaterThan(card.center.dx));
      expect(legend.left, greaterThan(pill.left));
      expect(legend.right, lessThanOrEqualTo(card.right));
    });
  });

  group('the shotgun position marker', () {
    // The confusion it exists for: a group teeing off on the 9th does not know
    // whether that is their first hole or their ninth.
    List<int> order(int start, {int n = 18, int universe = 18}) =>
        [for (var i = 0; i < n; i++) ((start - 1 + i) % universe) + 1];

    test('a round starting on the 1st gets nothing', () {
      // The hole number IS the position, so the marker would only restate it.
      for (final h in [1, 9, 18]) {
        expect(holePositionLine(order(1), h), '');
      }
    });

    test('an unknown play order gets nothing', () {
      expect(holePositionLine(const [], 7), '');
    });

    test('a shotgun counts from the group\'s own first tee', () {
      // fs=517 in the local database: a skins round starting on the 13th.
      final o = order(13);
      expect(holePositionLine(o, 13), '1 of 18');
      expect(holePositionLine(o, 18), '6 of 18');
      expect(holePositionLine(o, 1), '7 of 18');   // wraps
      expect(holePositionLine(o, 12), '18 of 18');
    });

    test('a back nine counts within its own nine', () {
      final o = order(10, n: 9);
      expect(holePositionLine(o, 10), '1 of 9');
      expect(holePositionLine(o, 14), '5 of 9');
      expect(holePositionLine(o, 18), '9 of 9');
    });

    test('a hole outside the order gets nothing, not `0 of 9`', () {
      // `indexOf` returns −1 and the obvious `indexOf + 1` renders `0 of 9`,
      // which was reachable in the team-play copy this rule replaced.
      expect(holePositionLine(order(10, n: 9), 3), '');
    });

    testWidgets('the card draws it on the sub line, after the nine',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HoleHeader(
            holeData: _hole(),
            holeNumber: 14,
            players: [_m(1, tee: _tee(9, 'White'))],
            holesInPlay: order(13),
          ),
        ),
      ));
      // Off the 13th, hole 14 is the group's second.
      // Beside the nine, on the card's sub line: `SI 7 · front nine · 2 of 18`.
      expect(find.text('SI 7 · back nine · 2 of 18'), findsOneWidget);
    });

    testWidgets('a round off the 1st says nothing about position',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HoleHeader(
            holeData: _hole(),
            holeNumber: 7,
            players: [_m(1, tee: _tee(9, 'White'))],
            holesInPlay: [for (var i = 1; i <= 18; i++) i],
          ),
        ),
      ));
      expect(find.textContaining(' of 18'), findsNothing);
    });
  });

  group('one header, every score-entry screen', () {
    // Source-level: the point is the sweep, not the rendering. Every screen
    // that enters a score draws the same header, and the ones with their own
    // play screen are exactly the ones a sweep misses.
    // Every screen that names the hole a golfer is entering. The four that
    // already collapsed correctly (Nassau, Points 5-3-1, Quota Nassau, Skins)
    // each carried their own copy of the function; the five that did not
    // (Rabbit, Survivor, Wolf, Sequoya 3s, Triple Nassau) were reading the
    // card's shared first-player par and index.
    const screens = [
      'lib/screens/score_entry_screen.dart',
      'lib/screens/pink_ball_screen.dart',
      'lib/screens/nassau_screen.dart',
      'lib/screens/points_531_screen.dart',
      'lib/screens/quota_nassau_screen.dart',
      'lib/screens/skins_screen.dart',
      'lib/screens/rabbit_screen.dart',
      'lib/screens/survivor_screen.dart',
      'lib/screens/wolf_screen.dart',
      'lib/screens/sequoya_threes_screen.dart',
      'lib/screens/triple_nassau_screen.dart',
    ];

    // **Two screens are deliberately NOT on that list**, and neither is an
    // oversight:
    //
    //  * `banker_screen` states hole, par and index on ONE line with a
    //    `triples, not doubles` note under it, and reads them from the SERVER's
    //    `BankerHoleState` rather than from the group's card. Its single par is
    //    the same latent problem, but fixing it means changing a payload, not
    //    swapping a widget.
    //  * `team_play_score_entry_screen` is a TEAM game — one ball, so there is
    //    no per-golfer par to collapse — and its line carries a shotgun
    //    position marker (`3 of 9`) the others lack.

    test('every screen that names a hole passes its play order', () {
      // No exceptions left. Pink Ball was one for a day: it navigated by hole
      // NUMBER, so an order it did not follow would have marked `1 of 18` with
      // the group on their first tee. It navigates by POSITION now — the ball's
      // rotation was ruled to follow position on 25 Sep 2026 — so it hands over
      // the order it actually walks.
      for (final path in screens) {
        expect(File(path).readAsStringSync().contains('holesInPlay'), isTrue,
            reason: '$path draws HoleHeader but hands it no play order, so a '
                'shotgun group gets no position marker.');
      }
    });

    test('the marker rule is stated once', () {
      // Team play wrote its own and it drifted: it could render `0 of 9`.
      final hits = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) =>
              f.readAsStringSync().contains('String holePositionLine('))
          .map((f) => f.path)
          .toList();
      expect(hits, ['lib/widgets/hole_header.dart']);
    });

    test('team play states the position the same way', () {
      // It is not a HoleHeader (a team game has one ball, so no per-golfer par
      // to collapse) but the marker has to read identically on both.
      final src = File('lib/screens/team_play_score_entry_screen.dart')
          .readAsStringSync();
      expect(src.contains('holePositionLine('), isTrue);
      expect(src.contains('positionOf(hole)'), isFalse,
          reason: 'the old copy, which could render `0 of 9`');
    });

    test('no screen keeps a private hole header any more', () {
      final rogue = Directory('lib/screens')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) =>
              f.readAsStringSync().contains('class _HoleHeader extends'))
          .map((f) => f.path)
          .toList();
      // Team play's is its own thing — see the note above.
      expect(rogue, ['lib/screens/team_play_score_entry_screen.dart']);
    });

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
