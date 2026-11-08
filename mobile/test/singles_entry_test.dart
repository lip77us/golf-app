import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/fourball_entry.dart';

/// Singles Match score entry —
/// `~/Downloads/handoff-singles-match-score-entry`.
///
/// Its first instruction is "build it as the Fourball score entry with one
/// golfer a side", so these are about the handful of things that DIFFER:
/// the wording, the sub line, and the side headers coming off.

FourballHoleCard _card({
  int scored = 2,
  String? result1 = 'won',
  String? result2 = 'lost',
  Map<String, dynamic>? match,
  double stake = 20,
  int? nextHole = 6,
}) =>
    FourballHoleCard.fromJson(<String, dynamic>{
      'hole': 5, 'par': 4, 'stroke_index': 3, 'thru': 5,
      'stake': stake, 'kind': 'net',
      'players': [
        {'player_id': 1, 'name': 'Paul Lipkin', 'first': 'Paul',
         'course_handicap': 12, 'strokes': 1, 'gross': 5, 'net': 4,
         'side': 1, 'counted': false},
        {'player_id': 2, 'name': 'Jim Diederich', 'first': 'Jim',
         'course_handicap': 8, 'strokes': 0,
         'gross': scored == 2 ? 5 : null, 'net': scored == 2 ? 5 : null,
         'side': 2, 'counted': false},
      ],
      'sides': [
        {'side': 1, 'label': 'Paul', 'player_ids': [1], 'best': 4,
         'sub': 'CH 12 · 1 stroke', 'result': result1},
        {'side': 2, 'label': 'Jim', 'player_ids': [2],
         'best': scored == 2 ? 5 : null,
         'sub': 'CH 8 · no stroke', 'result': result2},
      ],
      'scored': scored, 'hole_complete': scored == 2,
      'counts_for_card': false, 'closed_out': false,
      'match': match ??
          const {'leader': 1, 'margin': 1, 'headline': 'Paul',
                 'figure': '1 UP', 'line': 'thru 5 · 13 to play',
                 'state': 'Paul 1 UP', 'is_final': false},
      'strip': [
        for (var h = 1; h <= 9; h++)
          {'hole': h, 'played': h <= 5,
           'result': h == 5 ? 'T1' : (h <= 4 ? 'Halved' : null),
           'dead': false},
      ],
      'money': stake > 0
          ? [
              {'side': 1, 'label': 'Paul', 'amount': stake},
              {'side': 2, 'label': 'Jim', 'amount': -stake},
            ]
          : <Map<String, dynamic>>[],
      'round_over': nextHole == null, 'next_hole': nextHole,
    });

Future<void> _pump(WidgetTester t, FourballHoleCard card) async {
  await t.binding.setSurfaceSize(const Size(390, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: FourballHoleTray(
        card: card, onEdit: () {}, onNext: () {}, onPrev: () {}),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the same tray, different words', () {
    testWidgets('the label reads NET, not BEST BALL', (t) async {
      await _pump(t, _card());
      expect(find.text('HOLE 5 · NET'), findsOneWidget);
      expect(find.textContaining('BEST BALL'), findsNothing);
    });

    testWidgets('the sub line is the golfer\'s own strokes', (t) async {
      // Fourball says whose ball counted; with one golfer a side there is
      // nothing to choose between, so it says what he gets.
      await _pump(t, _card());
      expect(find.text('CH 12 · 1 stroke'), findsOneWidget);
      expect(find.text('CH 8 · no stroke'), findsOneWidget);
      expect(find.textContaining('counts:'), findsNothing);
    });

    testWidgets('two golfers read Both scores in', (t) async {
      // `All 2 scores in` is not a sentence.
      await _pump(t, _card());
      expect(find.text('Both scores in'), findsOneWidget);
      expect(find.textContaining('All 2'), findsNothing);
    });

    testWidgets('…and 1 of 2 scored after a pick-up', (t) async {
      await _pump(t, _card(scored: 1, result1: null, result2: null));
      expect(find.text('1 of 2 scored'), findsOneWidget);
    });

    testWidgets('the match card uses singular verbs', (t) async {
      await _pump(t, _card(
        nextHole: null,
        match: const {'leader': 1, 'margin': 1, 'headline': 'Paul wins',
                      'figure': '1 UP', 'line': 'Final after 18',
                      'state': 'Paul 1 UP', 'is_final': true},
      ));
      // The server composes it, so this is about the card carrying it.
      expect(find.text('Paul wins'), findsOneWidget);
      expect(find.text('Finish round ›'), findsOneWidget);
    });

    testWidgets('one money row a golfer', (t) async {
      await _pump(t, _card());
      expect(find.text('+\$20'), findsOneWidget);
      expect(find.text('−\$20'), findsOneWidget);
    });

    testWidgets('no stakes draws no money', (t) async {
      await _pump(t, _card(stake: 0));
      expect(find.text('NO STAKES'), findsOneWidget);
      expect(find.text('MONEY'), findsNothing);
    });

    testWidgets('it survives a narrow phone', (t) async {
      await _pump(t, _card());
      await t.binding.setSurfaceSize(const Size(320, 900));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('the model knows which it is', () {
    test('one golfer a side is a Singles Match', () {
      expect(_card().isSingles, isTrue);
    });

    test('and two is not', () {
      final fourball = FourballHoleCard.fromJson(<String, dynamic>{
        'sides': [
          {'side': 1, 'label': 'Paul + Larry', 'player_ids': [1, 2]},
          {'side': 2, 'label': 'Jim + Ryan', 'player_ids': [3, 4]},
        ],
      });
      expect(fourball.isSingles, isFalse);
      // …and an older server that sends no `kind` still says best ball.
      expect(fourball.kind, 'best ball');
    });
  });

  group('the shared screen keeps doing its job', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('Singles Match enters on the keypad', () {
      expect(src, contains('primary == GameIds.match18'));
    });

    test('a tray game posts and STAYS', () {
      final at = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      final body = src.substring(at, src.indexOf(';', at));
      expect(body, contains('_singlesCard(rp)'));
    });

    test('a SIDE-BET Singles Match does not take over the screen', () {
      // It can ride alongside a Sixes or Nassau primary
      // (`docs/parallel-games.md`), and a side bet must not change entry.
      final at = src.indexOf('FourballHoleCard? _singlesCard(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('\n  }', at));
      expect(body, contains('resolvePrimary'));
      expect(body, contains('!= GameIds.match18'));
    });

    test('one tray draws both, because they are one card', () {
      expect(src, contains('_fourballCard(rp) ?? _singlesCard(rp)'));
    });

    test('the side headers stay Fourball\'s', () {
      // One golfer a side would make a header a label for the name under it.
      final at = src.indexOf('fourballHole: (_fourballCard(rp)');
      expect(at, greaterThan(0));
      expect(src.substring(at, at + 160), isNot(contains('_singlesCard')));
    });

    test('the card is fetched for the hole on screen', () {
      expect(src, contains('_ensureSinglesCard(rp);'));
      expect(src, contains('loadSinglesHole(widget.foursomeId, _selectedHole)'));
    });
  });
}
