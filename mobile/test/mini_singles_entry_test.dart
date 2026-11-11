import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/mini_singles_entry.dart';
import 'package:golf_mobile/widgets/tray_result_row.dart';

/// Mini Singles Bracket score entry —
/// `~/Downloads/handoff-mini-singles-score-entry` (11 Nov 2026).
///
/// The engine is covered in `scoring/tests/test_mini_singles_hole_card.py`,
/// which also WRITES the fixtures these draw (`REGEN_MS_FIXTURES=1`): the
/// handoff's worked example played through the real bracket.

MiniSinglesHoleCard _card(String name) => MiniSinglesHoleCard.fromJson(
    jsonDecode(File('test/fixtures/mini_singles_$name.json')
        .readAsStringSync()) as Map<String, dynamic>);

Future<void> _pump(WidgetTester t, MiniSinglesHoleCard card, {
  Size size = const Size(390, 1300),
  int? nextHole = 9,
  bool gettingResult = false,
  VoidCallback? onNext,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MediaQuery(
          data: MediaQueryData(size: Size(size.width, size.height + 400)),
          child: MiniSinglesHoleTray(
            card: card,
            onEdit: () {},
            onPrev: () {},
            onNext: onNext ?? () {},
            nextHole: nextHole,
            gettingResult: gettingResult,
          ),
        ),
      ),
    ),
  ));
}

void main() {
  group('the tray', () {
    testWidgets('the semis: a block a match, and nothing about the back nine',
        (t) async {
      await _pump(t, _card('hole4_semis'), nextHole: 5);
      expect(find.text('All 4 scores in'), findsOneWidget);
      expect(find.text('HOLE 4 · SEMIS'), findsOneWidget);
      expect(find.text('\$40 POT'), findsOneWidget);
      expect(find.text('SEMI 1'), findsOneWidget);
      expect(find.text('SEMI 2'), findsOneWidget);
      expect(find.byType(TrayResultRow), findsNWidgets(2));
      expect(find.text('2 UP'), findsOneWidget);
      expect(find.text('thru 4 of 9 · 5 to play'), findsNWidgets(2));
      // No Finals / 3rd card under the semis: it read the same on every
      // front-nine hole and added nothing (Paul, 11 Nov 2026).
      expect(find.text('FINALS'), findsNothing);
      expect(find.textContaining('from 10'), findsNothing);
      expect(find.text('Hole 5 ›'), findsOneWidget);
    });

    testWidgets('a semi closes: who goes through, and what the 9th is',
        (t) async {
      await _pump(t, _card('hole8_semi_closes'));
      expect(find.text('Paul wins'), findsOneWidget);
      expect(find.text('2&1'), findsOneWidget);
      expect(find.text('Paul goes to the finals · hole 9 stroke play only'),
          findsOneWidget);
    });

    testWidgets('a match already over is ONE line, not a block', (t) async {
      await _pump(t, _card('hole9_semi_halved'), nextHole: 10);
      expect(find.text('Paul won 2&1 · hole 9 is stroke play only'),
          findsOneWidget);
      // Semi 1 draws no hole line: only Semi 2 is live.
      expect(find.byType(TrayResultRow), findsOneWidget);
    });

    testWidgets('a semi level after nine goes to extra holes, and the button says so',
        (t) async {
      await _pump(t, _card('hole9_semi_halved'), nextHole: 10);
      // A semi is never `halved` — it is all square and goes on.
      expect(find.text('All square after 9'), findsOneWidget);
      expect(find.text('Semi 2 goes to extra holes from the 10th'),
          findsOneWidget);
      expect(find.textContaining('halved'), findsNothing);
      expect(find.text('NEXT · THE BACK NINE'), findsOneWidget);
      expect(find.text('Dave and Sam go to extra holes from 10'),
          findsOneWidget);
      expect(find.text('Back nine · hole 10 ›'), findsOneWidget);
    });

    testWidgets('the extra hole: nobody waits, the finals is v TBD',
        (t) async {
      await _pump(t, _card('hole10_extra_hole'), nextHole: 11);
      expect(find.text('HOLE 10 · BACK NINE'), findsOneWidget);
      expect(find.text('Still level'), findsOneWidget);
      expect(find.text('FINALS'), findsOneWidget);
      expect(find.text('3RD PLACE'), findsOneWidget);
      // Both back-nine matches are scored against an unnamed opponent…
      expect(find.byType(CustomPaint).evaluate().where((e) =>
          (e.widget as CustomPaint).painter.runtimeType.toString() ==
              'DashedRRect').length, 2);
      expect(find.text('1 UP'), findsNWidgets(2));
    });

    testWidgets('the semi is settled: only the real pairing is left',
        (t) async {
      await _pump(t, _card('hole11_semi_settled'), nextHole: 12);
      expect(find.text('Sam wins the semi'), findsOneWidget);
      expect(find.text('11th'), findsOneWidget);
      expect(find.text('Level after 9, won on the 11th.'), findsOneWidget);
      expect(find.byType(CustomPaint).evaluate().where((e) =>
          (e.widget as CustomPaint).painter.runtimeType.toString() ==
              'DashedRRect'), isEmpty);
      expect(find.textContaining('TBD'), findsNothing);
    });

    testWidgets('the back nine has no semi at all', (t) async {
      await _pump(t, _card('hole12_back_nine'), nextHole: 13);
      expect(find.textContaining('SEMI'), findsNothing);
      expect(find.text('2 UP'), findsOneWidget);
      expect(find.text('thru 3 of 9 · 6 to play'), findsNWidgets(2));
    });

    testWidgets('the group is over: the winner, and a Result table',
        (t) async {
      await _pump(t, _card('hole18_group_over'), nextHole: null);
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('GROUP WINNER'), findsOneWidget);
      expect(find.text('Paul Lipkin'), findsNWidgets(2));
      // Headed Result, never Final — that read as a final score.
      expect(find.text('RESULT'), findsOneWidget);
      expect(find.textContaining('FINAL,'), findsNothing);
      expect(find.text('1st'), findsOneWidget);
      expect(find.text('T3'), findsNWidgets(2));
      expect(find.text('+\$14'), findsOneWidget);
      expect(find.text('−\$7'), findsNWidgets(2));
      expect(find.textContaining('Net of the \$10 entry.'), findsOneWidget);
      expect(find.text('Finish round ›'), findsOneWidget);
      // On 18 the tiles are left out to keep the tray short.
      expect(find.text('13'), findsNothing);
    });

    testWidgets('the money columns share one right edge', (t) async {
      await _pump(t, _card('hole18_group_over'), nextHole: null);
      final head = t.getTopRight(find.text('MONEY')).dx;
      for (final amount in ['\$0', '−\$7']) {
        expect(t.getTopRight(find.text(amount).first).dx, head,
            reason: amount);
      }
      final place = t.getTopLeft(find.text('PLACE')).dx;
      for (final p in ['1st', '2nd', 'T3']) {
        expect(t.getTopLeft(find.text(p).first).dx, place, reason: p);
      }
    });

    testWidgets('a bracket played for nothing draws no table', (t) async {
      final j = jsonDecode(File(
              'test/fixtures/mini_singles_hole18_group_over.json')
          .readAsStringSync()) as Map<String, dynamic>;
      j['result'] = null;
      j['trailing'] = '';
      await _pump(t, MiniSinglesHoleCard.fromJson(j), nextHole: null);
      expect(find.text('RESULT'), findsNothing);
      expect(find.text('GROUP WINNER'), findsOneWidget);
    });

    testWidgets('it holds its figures back while the result is on its way',
        (t) async {
      await _pump(t, _card('hole8_semi_closes'), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('SEMI 1'), findsNothing);
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    });

    testWidgets('it survives a narrow, short phone', (t) async {
      await t.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MiniSinglesHoleTray(
                card: _card('hole18_group_over'),
                onEdit: () {}, onNext: () {}, nextHole: null),
          ),
        ),
      ));
      expect(t.takeException(), isNull);
      expect(find.text('Finish round ›').hitTestable(), findsOneWidget);
    });
  });

  group('the matches in play, under the hole', () {
    Future<void> pump(WidgetTester t, String name,
        {double width = 390}) async {
      await t.binding.setSurfaceSize(Size(width, 400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(home: Scaffold(
          body: MiniSinglesMatches(card: _card(name)))));
    }

    testWidgets('each semi names its two golfers and where it stands',
        (t) async {
      await pump(t, 'hole4_semis');
      expect(find.text('SEMI 1'), findsOneWidget);
      expect(find.text('SEMI 2'), findsOneWidget);
      expect(find.text('Paul v Lee', findRichText: true), findsOneWidget);
      expect(find.text('Dave v Sam', findRichText: true), findsOneWidget);
      expect(find.text('Paul 2 UP'), findsOneWidget);
      expect(find.text('Dave 1 UP'), findsOneWidget);
    });

    testWidgets('a match that is over still says who won it', (t) async {
      await pump(t, 'hole9_semi_halved');
      expect(find.text('Paul wins 2&1'), findsOneWidget);
      expect(find.text('AS'), findsOneWidget);
    });

    testWidgets('the opponents change at the turn', (t) async {
      await pump(t, 'hole12_back_nine');
      expect(find.text('FINALS'), findsOneWidget);
      expect(find.text('3RD PLACE'), findsOneWidget);
      expect(find.text('Paul v Sam', findRichText: true), findsOneWidget);
      expect(find.text('Lee v Dave', findRichText: true), findsOneWidget);
      expect(find.textContaining('SEMI'), findsNothing);
    });

    testWidgets('an unnamed opponent reads TBD', (t) async {
      await pump(t, 'hole10_extra_hole');
      expect(find.text('Paul v TBD', findRichText: true), findsOneWidget);
      expect(find.text('Dave v Sam', findRichText: true), findsOneWidget);
    });

    testWidgets('it survives a narrow phone', (t) async {
      await pump(t, 'hole10_extra_hole', width: 300);
      expect(t.takeException(), isNull);
    });

    test('the screen draws it between the hole and the golfers', () {
      final src =
          File('lib/screens/score_entry_screen.dart').readAsStringSync();
      expect(
          RegExp(r'aboveRows: _miniSinglesCard\(rp\) != null\s*'
                  r'\? MiniSinglesMatches\(card: _miniSinglesCard\(rp\)!\)')
              .hasMatch(src),
          isTrue);
    });
  });

  group('the card', () {
    test('a golfer\'s strokes are read off the card', () {
      final c = _card('hole4_semis');
      expect(c.players.length, 4);
      expect(c.strokesFor(c.players.first.playerId), isNotNull);
      expect(c.strokesFor(-1), isNull);
    });
  });

  group('the shared screen keeps doing its job', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    String body(String signature) {
      final at = src.indexOf(signature);
      expect(at, greaterThan(0), reason: signature);
      return src.substring(at, src.indexOf('\n  }\n', at));
    }

    test('a Mini Singles group enters on the keypad', () {
      expect(body('bool _keypadRound(RoundProvider rp)'),
          contains('_miniSinglesRound(rp)'));
    });

    test('four golfers: a threesome plays a different game', () {
      expect(body('bool _miniSinglesRound(RoundProvider rp)'),
          contains('fs.realPlayers.length != 4'));
    });

    test('it never takes the tray from a game that has one', () {
      final b = body('bool _miniSinglesRound(RoundProvider rp)');
      for (final g in ['sixes', 'nassau', 'skins', 'banker', 'tripleCup',
                       'fourball', 'vegas']) {
        expect(b, contains('GameIds.$g'), reason: g);
      }
      // Stroke Play is NOT among them: the bracket's tray wins there.
      expect(b, isNot(contains('GameIds.strokePlay')));
    });

    test('and the Stroke Play tray stands down for it', () {
      expect(body('StrokePlayHoleCard? _strokePlayCard(RoundProvider rp)'),
          contains('if (_miniSinglesRound(rp)) return null;'));
    });

    test('its hole ends in a tray, so it posts itself and stays', () {
      final at = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      expect(src.substring(at, src.indexOf(';', at)),
          contains('_miniSinglesCard(rp) != null'));
    });

    test('the keypad takes its strokes from the card', () {
      expect(
          RegExp(r'final ms = _miniSinglesCard\(rp\);\s*'
                  r'if \(ms != null\) \{\s*'
                  r'final s = ms\.strokesFor\(m\.player\.id\);\s*'
                  r'if \(s != null\) return s;')
              .hasMatch(body('int _keypadStrokes(Membership m, Scorecard sc)')),
          isTrue);
    });

    test('the pager hides under the tray', () {
      final at = src.indexOf('if (!sixTray');
      expect(src.substring(at, src.indexOf(')', at)), contains('!msTray'));
    });

    test('the last hole finishes the round from the tray', () {
      final at = src.indexOf('MiniSinglesHoleTray(');
      final call = src.substring(at, src.indexOf('else if (tcTray)', at));
      expect(call, contains('_completeRound(ctx, players, par)'));
    });

    test('the old bracket card leaves the screen for these groups', () {
      expect(src, contains('!_miniSinglesRound(rp))\n'
          '                    ? rp.matchPlayData : null,'));
    });
  });
}
