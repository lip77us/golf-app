/// The generic tray and the tray frame (`handoff-score-entry-template`): what a
/// game with no tray of its own shows once every score is in.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/utils/generic_tray.dart';
import 'package:golf_mobile/widgets/generic_entry.dart';
import 'package:golf_mobile/widgets/tray_frame.dart';

Membership m(int id, String name) => Membership(
      id: id,
      player: PlayerProfile(
          id: id, name: name, shortName: '', handicapIndex: '0',
          isPhantom: false, email: ''),
      courseHandicap: 0,
      playingHandicap: 0,
    );

ScorecardHole hole(int n, int par, Map<int, int?> gross) => ScorecardHole(
      holeNumber: n,
      par: par,
      strokeIndex: n,
      scores: [
        for (final e in gross.entries)
          HoleScoreEntry(
              playerId: e.key,
              playerName: 'P${e.key}',
              holeNumber: n,
              par: par,
              grossScore: e.value,
              handicapStrokes: 0),
      ],
    );

Scorecard card(List<ScorecardHole> holes) =>
    Scorecard(foursomeId: 1, groupNumber: 1, holes: holes, totals: const []);

void main() {
  group('the labels', () {
    test('gross against par, with a true minus', () {
      expect(toParLabel(0), 'E');
      expect(toParLabel(9), '+9');
      expect(toParLabel(-2), '−2');
      expect(toParLabel(-2).codeUnitAt(0), 0x2212, reason: 'U+2212, not a hyphen');
    });

    test('Paul Lipkin is Paul L.; one name is left alone', () {
      expect(trayName('Paul Lipkin'), 'Paul L.');
      expect(trayName('Mary Ann Lee'), 'Mary L.');
      expect(trayName('Jo'), 'Jo');
      expect(trayName('  paul  lipkin '), 'paul L.');
    });
  });

  group('the rows', () {
    final players = [m(1, 'Paul Lipkin'), m(2, 'Dave Chen')];

    test('gross against par through the holes played, this one included', () {
      // Hole 1: Paul 5 (+1), Dave 4 (E). Hole 2 (on screen): Paul 3 (−1),
      // Dave 6 (+2), both typed and not yet in the scorecard.
      final sc = card([
        hole(1, 4, {1: 5, 2: 4}),
        hole(2, 4, {1: null, 2: null}),
      ]);
      final rows = genericTrayRows(
          players: players, scorecard: sc, hole: 2, scores: {1: 3, 2: 6});
      expect(rows[0].toPar, 0, reason: '+1 then −1');
      expect(rows[0].toParText, 'E');
      expect(rows[1].toPar, 2);
      expect(rows[1].toParText, '+2');
      expect(rows[0].hole, 3);
      expect(rows[1].hole, 6);
    });

    test('the hole on screen is read from the typed scores, not the card', () {
      // The scorecard still holds an OLD gross for the hole being edited; the
      // typed value must win, and must not be counted twice.
      final sc = card([hole(1, 4, {1: 9})]);
      final rows = genericTrayRows(
          players: [m(1, 'Paul Lipkin')],
          scorecard: sc,
          hole: 1,
          scores: {1: 4});
      expect(rows.single.toPar, 0);
      expect(rows.single.played, 1);
    });

    test('a golfer with no scores reads a dash, not E', () {
      final rows = genericTrayRows(
          players: [m(1, 'Paul Lipkin')],
          scorecard: card([hole(1, 4, {1: null})]),
          hole: 1,
          scores: const {});
      expect(rows.single.toParText, '–');
      expect(rows.single.hole, isNull);
    });

    test('each golfer is measured against his own par', () {
      final sc = card([
        ScorecardHole(holeNumber: 1, par: 4, strokeIndex: 1, scores: [
          HoleScoreEntry(
              playerId: 1, playerName: 'A', holeNumber: 1, par: 5,
              grossScore: 5, handicapStrokes: 0),
          HoleScoreEntry(
              playerId: 2, playerName: 'B', holeNumber: 1, par: 4,
              grossScore: 5, handicapStrokes: 0),
        ]),
      ]);
      final rows = genericTrayRows(
          players: players, scorecard: sc, hole: 9, scores: const {});
      expect(rows[0].toPar, 0, reason: 'a par on his own forward-tee five');
      expect(rows[1].toPar, 1);
    });

    test('there is no net and no money here — only what no game can dispute',
        () {
      final src = File('lib/utils/generic_tray.dart').readAsStringSync();
      expect(src, isNot(contains('netScore')));
      expect(src, isNot(contains('handicapStrokes')));
    });
  });

  group('the frame', () {
    Future<void> pump(WidgetTester t,
        {bool picking = false,
        VoidCallback? onPrev,
        VoidCallback? onNext,
        String next = 'Hole 8'}) async {
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TrayFrame(
              label: 'Hole 7 · Irish Rumble',
              picking: picking,
              onEdit: () {},
              onPrev: onPrev,
              onNext: onNext,
              nextLabel: next,
              blocks: const [TrayBlock(child: Text('block one')), TrayBlock(child: Text('block two'))],
            ),
          ),
        ),
      ));
    }

    testWidgets('the label line is caps, with Edit scores on the right',
        (t) async {
      await pump(t);
      expect(find.text('HOLE 7 · IRISH RUMBLE'), findsOneWidget);
      expect(find.text('Edit scores'), findsOneWidget);
      expect(t.getCenter(find.text('Edit scores')).dx,
          greaterThan(t.getCenter(find.text('HOLE 7 · IRISH RUMBLE')).dx));
    });

    testWidgets('there is no "All N scores in" line', (t) async {
      await pump(t);
      expect(find.textContaining('scores in'), findsNothing);
    });

    testWidgets('while picking it says Done and where to tap', (t) async {
      await pump(t, picking: true);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Edit scores'), findsNothing);
      expect(find.text('Tap a score above to change it'), findsOneWidget);
    });

    testWidgets('the blocks are translucent cards on deep pine', (t) async {
      await pump(t);
      final blocks = t.widgetList<Container>(find.descendant(
          of: find.byType(TrayBlock), matching: find.byType(Container)));
      expect((blocks.first.decoration as BoxDecoration).color,
          Colors.white.withValues(alpha: 0.07));
      final frame = t.widget<Container>(find
          .descendant(of: find.byType(TrayFrame), matching: find.byType(Container))
          .first);
      expect((frame.decoration as BoxDecoration).color, Halved.deepPine);
    });

    testWidgets('a round ‹ and a white pill that names the next hole',
        (t) async {
      var back = 0, next = 0;
      await pump(t, onPrev: () => back++, onNext: () => next++);
      expect(find.text('Hole 8 ›'), findsOneWidget);
      await t.tap(find.text('‹'));
      await t.tap(find.text('Hole 8 ›'));
      expect(back, 1);
      expect(next, 1);
    });

    testWidgets('on the 18th the pill is Finish round', (t) async {
      await pump(t, next: 'Finish round', onNext: () {});
      expect(find.text('Finish round ›'), findsOneWidget);
    });

    testWidgets('it is at most 78% of the screen tall', (t) async {
      await pump(t);
      expect(t.getSize(find.byType(TrayFrame)).height,
          lessThanOrEqualTo(844 * 0.78 + 0.5));
    });
  });

  group('the generic tray', () {
    testWidgets('one row per golfer under HOLE and GROSS', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: GenericHoleTray(
              label: 'Hole 12 · Irish Rumble',
              rows: const [
                GenericTrayRow(
                    playerId: 1, name: 'Paul L.', side: null, hole: 3,
                    toPar: 9, played: 11),
                GenericTrayRow(
                    playerId: 2, name: 'Tom R.', side: null, hole: 2,
                    toPar: 0, played: 11),
                GenericTrayRow(
                    playerId: 3, name: 'New G.', side: null, hole: null,
                    toPar: 0, played: 0),
              ],
              onEdit: () {},
              nextLabel: 'Hole 13',
              onNext: () {},
            ),
          ),
        ),
      ));
      expect(find.text('HOLE'), findsOneWidget);
      expect(find.text('GROSS'), findsOneWidget);
      expect(find.text('Paul L.'), findsOneWidget);
      expect(find.text('+9'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
      expect(find.text('–'), findsNWidgets(2), reason: 'no hole and no holes');
    });
  });

  group('the screen uses it', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('every round is a keypad round: a specific tray, or the generic one',
        () {
      expect(src, contains('_hasSpecificTray(rp) || _genericTrayRound(rp)'));
      expect(src, contains('!_hasSpecificTray(rp) && rp.round != null'));
    });

    test('the generic tray raises, so the hole posts itself', () {
      final at = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      final body = src.substring(at, src.indexOf(';', at));
      expect(body, contains('_genericTrayRound(rp)'));
    });

    test('it rises when every score is in, and the pager hides under it', () {
      expect(src, contains('final genTray = _genericTrayRound(rp) &&'));
      expect(src, contains('&& !genTray)'));
      expect(src, contains('else if (genTray)'));
    });

    test('its forward button finishes the round on the last hole', () {
      final at = src.indexOf('else if (genTray)');
      final body = src.substring(at, src.indexOf('else if (fbMember != null)', at));
      expect(body, contains("'Finish round'"));
      expect(body, contains('_completeRound(ctx, players, par)'));
    });
  });
}
