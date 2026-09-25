/// test/stroke_play_progress_grid_test.dart
/// ---------------------------------------
/// The gross card a tournament round draws under the hole being entered.
///
/// It was private to `score_entry_screen.dart` until Pink Ball needed it, and
/// the risk in a move is precisely that: a widget that only ever built inside
/// one file, lifted out, and nobody renders it again until somebody reports a
/// blank card from a course. So it is rendered here.
///
/// The second group is the sweep rule. `score_entry_screen` is not the only
/// place a tournament round is scored, and every sweep this app has run — the
/// combo-tee chip, OUT/IN/TOT, the pinned label column, the standing row — was
/// found to have stopped there while the games with their OWN play screen went
/// without. Pink Ball is one of those screens.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/stroke_play_progress_grid.dart';

const _me = 11;
const _b = 12;

Membership _m(int id, {int hcp = 0}) => Membership(
      id: id,
      player: PlayerProfile(
          id: id, name: 'Player $id', shortName: 'P$id',
          handicapIndex: '$hcp', isPhantom: false, email: ''),
      courseHandicap: hcp,
      playingHandicap: hcp,
    );

/// Every hole a par 4, stroke index ascending with the hole number.
Scorecard _card(Map<int, List<int?>> scores) {
  final holes = <ScorecardHole>[];
  for (var h = 1; h <= 18; h++) {
    holes.add(ScorecardHole(
      holeNumber: h, par: 4, strokeIndex: h, yards: 400,
      scores: [
        for (final e in scores.entries)
          if (e.value.length >= h && e.value[h - 1] != null)
            HoleScoreEntry(
              playerId: e.key, playerName: 'Player ${e.key}', holeNumber: h,
              grossScore: e.value[h - 1], handicapStrokes: 0,
              strokeIndex: h, par: 4,
            ),
      ],
    ));
  }
  return Scorecard(
      foursomeId: 1, groupNumber: 1, holes: holes, totals: const []);
}

Future<void> _pump(WidgetTester tester, Scorecard card,
    {int currentHole = 3,
    String mode = 'net',
    int pct = 100,
    void Function(int)? onTapHole}) async {
  // Wide and tall: the grid scrolls horizontally, and a phone-width viewport
  // would put the back nine off screen where `find.text` cannot see it. The
  // scroll itself is `PinnedHoleGrid`'s and has its own test.
  tester.view.physicalSize = const Size(3000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: StrokePlayProgressGrid(
        players: [_m(_me), _m(_b)],
        scorecard: card,
        currentHole: currentHole,
        onTapHole: onTapHole,
        handicapMode: mode,
        netPercent: pct,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('the card renders outside the screen it came from', () {
    testWidgets('it draws the header, both golfers and their scores',
        (tester) async {
      await _pump(tester, _card({_me: [4, 5], _b: [3, 4]}));
      expect(find.text('Stroke play progress'), findsOneWidget);
      expect(find.text('P11'), findsOneWidget);
      expect(find.text('P12'), findsOneWidget);
      expect(find.text('Hole'), findsOneWidget);
      expect(find.text('Par'), findsOneWidget);
      // **Twice each, and that is the correct answer.** The hole row numbers
      // 1..18, so a gross of 5 shares its glyph with hole 5 — there is no
      // score a hole number cannot collide with. The count is the probe: one
      // header cell plus one score cell. (4 is a par as well and appears
      // eighteen more times, which is why it is not used here.)
      expect(find.text('5'), findsNWidgets(2));   // hole 5 + P11 on the 2nd
      expect(find.text('3'), findsNWidgets(2));   // hole 3 + P12 on the 1st
    });

    testWidgets('an unscored hole is a dash, not a blank or a zero',
        (tester) async {
      await _pump(tester, _card({_me: [4], _b: [4]}));
      // Seventeen holes unscored for each of two golfers.
      expect(find.text('–'), findsNWidgets(34));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('the mode chip states the handicap the field is scored on',
        (tester) async {
      await _pump(tester, _card({_me: [4]}), mode: 'gross');
      expect(find.text('Gross'), findsOneWidget);

      await _pump(tester, _card({_me: [4]}), mode: 'net', pct: 90);
      expect(find.text('Net 90%'), findsOneWidget);

      await _pump(tester, _card({_me: [4]}), mode: 'strokes_off', pct: 100);
      expect(find.text('SO 100%'), findsOneWidget);
    });

    testWidgets('a nine subtotal appears only once that nine is whole',
        (tester) async {
      // Eight holes of the front nine — OUT is still an em dash, per the rule
      // the leaderboard uses. A partial subtotal is a misleading number.
      final eight = _card({_me: List.filled(8, 4), _b: List.filled(8, 4)});
      await _pump(tester, eight);
      expect(find.text('OUT'), findsOneWidget);
      // Six em dashes: OUT, IN and TOT, for each of two golfers. Only OUT is
      // the hole-8 case under test; IN and TOT are empty because the back nine
      // has not been played at all, which is the same rule one nine along.
      // (An unscored GROSS cell is an en dash, a different glyph — see above.)
      expect(find.text('—'), findsNWidgets(6));

      // Fives and sixes, not fours: the par row's own OUT is 36, so a golfer
      // round in level par shares his subtotal with it and the probe would be
      // reading the par row.
      final nine = _card({_me: List.filled(9, 5), _b: List.filled(9, 6)});
      await _pump(tester, nine);
      expect(find.text('45'), findsOneWidget);   // P11's nine 5s
      expect(find.text('54'), findsOneWidget);   // P12's nine 6s
      expect(find.text('—'), findsNWidgets(4));  // IN and TOT, still to come
    });

    testWidgets('tapping a hole reports that hole, not its position',
        (tester) async {
      final taps = <int>[];
      await _pump(tester, _card({_me: List.filled(18, 4)}),
          onTapHole: taps.add);
      // The par cell of hole 12 — the label column is pinned and takes no
      // taps, so any cell in the column will do.
      await tester.tap(find.text('12'));
      expect(taps, [12]);
    });
  });

  group('every screen that scores a tournament round draws it', () {
    // Source-level, because the alternative is booting two full screens with a
    // provider apiece. What it guards is the sweep, not the rendering: a third
    // screen added here without the card is the failure this catches.
    const screens = [
      'lib/screens/score_entry_screen.dart',
      'lib/screens/pink_ball_screen.dart',
    ];

    for (final path in screens) {
      test('$path draws StrokePlayProgressGrid', () {
        final src = File(path).readAsStringSync();
        expect(src.contains('StrokePlayProgressGrid('), isTrue,
            reason: '$path enters scores on a tournament round and has to show '
                'the group its card. Do not copy the grid — import it.');
      });
    }

    test('the grid is defined once', () {
      // A second definition is how one card becomes two that disagree about a
      // stroke. `git grep` over lib/, so a screen re-declaring it fails here.
      final hits = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => f
              .readAsStringSync()
              .contains('class StrokePlayProgressGrid extends'))
          .map((f) => f.path)
          .toList();
      expect(hits, ['lib/widgets/stroke_play_progress_grid.dart']);
    });
  });
}
