import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/wolf_entry.dart';

/// Wolf score entry — `~/Downloads/handoff-wolf-score-entry`.
///
/// The engine is covered in `scoring/tests/test_wolf_hole_card.py`; these are
/// about what the call chips and the tray DRAW, and the source guards are
/// about what a dedicated play screen loses when a keypad is bolted onto it.

WolfHoleCard _card({
  String decision = 'partner',
  int? partnerId = 1,
  bool needsCall = false,
  bool roundOver = false,
  bool canPartner = true,
  bool partnerLocked = false,
  int? nextHole = 8,
  String nextWolf = 'Lee',
  List<List<dynamic>> sides = const [
    ['wolf', 'Sam + Paul', 4, 'won'],
    ['field', 'Dave + Lee', 5, 'lost'],
  ],
  List<List<dynamic>> standing = const [
    // id, first, side, isWolf, hole, points, money
    [1, 'Paul', 'wolf', false, 1.0, 8.0, 8.0],
    [2, 'Dave', 'field', false, -1.0, 1.0, 1.0],
    [3, 'Sam', 'wolf', true, 1.0, -3.0, -3.0],
    [4, 'Lee', 'field', false, -1.0, -6.0, -6.0],
  ],
}) =>
    WolfHoleCard.fromJson(_cardJson(
      decision: decision, partnerId: partnerId, needsCall: needsCall,
      roundOver: roundOver, canPartner: canPartner,
      partnerLocked: partnerLocked, nextHole: nextHole, nextWolf: nextWolf,
      sides: sides, standing: standing,
    ));

Map<String, dynamic> _cardJson({
  String decision = 'partner',
  int? partnerId = 1,
  bool needsCall = false,
  bool roundOver = false,
  bool canPartner = true,
  bool partnerLocked = false,
  int? nextHole = 8,
  String nextWolf = 'Lee',
  List<List<dynamic>> sides = const [
    ['wolf', 'Sam + Paul', 4, 'won'],
    ['field', 'Dave + Lee', 5, 'lost'],
  ],
  List<List<dynamic>> standing = const [
    [1, 'Paul', 'wolf', false, 1.0, 8.0, 8.0],
    [2, 'Dave', 'field', false, -1.0, 1.0, 1.0],
    [3, 'Sam', 'wolf', true, 1.0, -3.0, -3.0],
    [4, 'Lee', 'field', false, -1.0, -6.0, -6.0],
  ],
}) =>
    <String, dynamic>{
      'hole': 7, 'par': 4, 'stroke_index': 5, 'yards': 376,
      'nine': 'front nine', 'thru': 7, 'stake': 1.0,
      'wolf_id': 3, 'wolf_short': 'SR', 'wolf_first': 'Sam',
      'last_place_wolf': false,
      'decision': decision,
      'partner_id': decision == 'partner' ? partnerId : null,
      'partner_locked': partnerLocked,
      'can_partner': canPartner,
      'values': {'team': 1, 'lone': 3, 'blind': 6},
      'call_label': decision == 'partner'
          ? 'partner'
          : (decision == 'lone'
              ? 'Lone Wolf'
              : (decision == 'blind' ? 'Blind Wolf' : '')),
      'call_value': decision == 'partner'
          ? '1 pt each'
          : (decision == 'lone' ? '3 pts' : (decision == 'blind' ? '6 pts' : '')),
      'players': [
        for (final p in const [
          [1, 'Paul Lipkin', 'PL', 'Paul', 8, 0, 4, 4],
          [2, 'Dave Kim', 'DK', 'Dave', 12, 0, 5, 5],
          [3, 'Sam Reid', 'SR', 'Sam', 15, 1, 5, 4],
          [4, 'Lee Nash', 'LN', 'Lee', 18, 1, 6, 5],
        ])
          {'player_id': p[0], 'name': p[1], 'short': p[2], 'first': p[3],
           'course_handicap': p[4], 'strokes': p[5], 'gross': p[6],
           'net': p[7], 'side': null, 'is_wolf': p[0] == 3,
           'is_partner': p[0] == 1 && decision == 'partner',
           'hole_points': null},
      ],
      'sides': needsCall
          ? const []
          : [
              for (final s in sides)
                {'side': s[0], 'label': s[1], 'best': s[2], 'result': s[3]},
            ],
      'standing': [
        for (final s in standing)
          {'player_id': s[0], 'first': s[1], 'short': s[1], 'side': s[2],
           'is_wolf': s[3], 'hole_points': s[4], 'points': s[5],
           'money': s[6]},
      ],
      'hole_complete': true,
      'needs_call': needsCall,
      'round_over': roundOver,
      'winner': roundOver
          ? {'player_id': 1, 'short': 'PL', 'first': 'Paul',
             'points': 9.0, 'money': 9.0, 'stake': 1.0}
          : null,
      'next_hole': nextHole,
      'next_wolf_first': nextWolf,
    };

Future<void> _pumpTray(WidgetTester t, WolfHoleCard card,
    {List<String>? calls}) async {
  await t.binding.setSurfaceSize(const Size(390, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: WolfHoleTray(
        card: card,
        onEdit: () {},
        onCall: (d, {int? partnerId}) =>
            calls?.add(partnerId == null ? d : '$d:$partnerId'),
        onNext: () {},
        onPrev: () {},
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _pumpChips(WidgetTester t, WolfHoleCard card,
    List<String> calls) async {
  await t.binding.setSurfaceSize(const Size(390, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: WolfCallCard(
          card: card,
          onCall: (d, {int? partnerId}) =>
              calls.add(partnerId == null ? d : '$d:$partnerId'),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the call chips', () {
    testWidgets('they name the Wolf and what each call is worth',
        (t) async {
      await _pumpChips(t, _card(decision: 'pending'), []);
      expect(find.text('Sam’s call'), findsOneWidget);
      expect(find.text('partner 1 · Lone 3 · Blind 6'),
          findsOneWidget);
      // The three other golfers, plus Lone and Blind.
      for (final n in ['Paul', 'Dave', 'Lee', 'Lone', 'Blind']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      expect(find.text('Sam'), findsNothing,
          reason: 'the Wolf cannot take himself');
    });

    testWidgets('a partner chip sends the partner', (t) async {
      final calls = <String>[];
      await _pumpChips(t, _card(decision: 'pending'), calls);
      await t.tap(find.text('Dave'));
      expect(calls, ['partner:2']);
    });

    testWidgets('tapping the selected chip clears the call', (t) async {
      final calls = <String>[];
      await _pumpChips(t, _card(decision: 'lone'), calls);
      await t.tap(find.text('Lone'));
      expect(calls, ['pending']);
    });

    testWidgets('…and the selected PARTNER clears only on his own chip',
        (t) async {
      final calls = <String>[];
      await _pumpChips(t, _card(partnerId: 1), calls);
      await t.tap(find.text('Dave'));
      expect(calls, ['partner:2']);
      await t.tap(find.text('Paul'));
      expect(calls.last, 'pending');
    });

    testWidgets('a forced solo turn offers no partner, and says so',
        (t) async {
      await _pumpChips(
          t,
          _card(decision: 'pending', canPartner: false, partnerLocked: true),
          []);
      expect(find.text('Dave'), findsNothing);
      expect(find.text('Lone'), findsOneWidget);
      expect(find.textContaining('Lone or Blind only'), findsOneWidget);
    });

    testWidgets('the header fits a long first name', (t) async {
      // The name yields and the prices stay: a `Expanded` on the left and a
      // plain `Text` on the right pushed `partner 1 · Lone 3 · Blind 6` off
      // the card, which a golden pass caught before a device did.
      await t.binding.setSurfaceSize(const Size(320, 400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WolfCallCard(
            card: WolfHoleCard.fromJson(<String, dynamic>{
              ..._cardJson(decision: 'pending'),
              'wolf_first': 'Bartholomew',
            }),
            onCall: (d, {int? partnerId}) {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('partner 1 · Lone 3 · Blind 6'),
          findsOneWidget);
    });

    testWidgets('a 3-player game offers no partner and no explanation',
        (t) async {
      // There is no partner in 3-player Wolf; nothing has been taken away.
      await _pumpChips(
          t, _card(decision: 'pending', canPartner: false), []);
      expect(find.text('Dave'), findsNothing);
      expect(find.textContaining('Lone or Blind only'), findsNothing);
    });
  });

  group('the tray asks for the call', () {
    testWidgets('it names the Wolf and prices every option', (t) async {
      await _pumpTray(t, _card(decision: 'pending', needsCall: true));
      expect(find.text('HOLE 7 · SAM’S CALL'), findsOneWidget);
      expect(find.text('WHO DID SAM TAKE?'), findsOneWidget);
      expect(find.text('partner · 1 pt'), findsNWidgets(3));
      expect(find.text('3 pts'), findsOneWidget);
      expect(find.text('6 pts'), findsOneWidget);
      expect(find.textContaining('settles once the call is set'),
          findsOneWidget);
    });

    testWidgets('nothing moves on until it is answered', (t) async {
      await _pumpTray(t, _card(decision: 'pending', needsCall: true));
      expect(find.text('Pick Sam’s call'), findsOneWidget);
      final b = t.widget<FilledButton>(find.ancestor(
          of: find.text('Pick Sam’s call'),
          matching: find.byType(FilledButton)));
      expect(b.onPressed, isNull,
          reason: 'a scored hole with no call counts for nobody');
    });

    testWidgets('answering it sends the call', (t) async {
      final calls = <String>[];
      await _pumpTray(t, _card(decision: 'pending', needsCall: true),
          calls: calls);
      await t.tap(find.text('Lone'));
      expect(calls, ['lone']);
    });

    testWidgets('no sides are drawn while it is unanswered', (t) async {
      await _pumpTray(t, _card(decision: 'pending', needsCall: true));
      expect(find.text('won'), findsNothing);
      expect(find.text('EACH · NOW'), findsNothing);
    });
  });

  group('the tray settles the hole', () {
    testWidgets('the Wolf side is first, with its best net and result',
        (t) async {
      await _pumpTray(t, _card());
      expect(find.text('HOLE 7 · PARTNER'), findsOneWidget);
      expect(find.text('1 PT EACH'), findsOneWidget);
      expect(find.text('Sam + Paul'), findsOneWidget);
      expect(find.text('won'), findsOneWidget);
      expect(find.text('lost'), findsOneWidget);
      final a = t.getTopLeft(find.text('Sam + Paul')).dy;
      final b = t.getTopLeft(find.text('Dave + Lee')).dy;
      expect(a, lessThan(b));
    });

    testWidgets('the standing carries the hole, the total and the money',
        (t) async {
      await _pumpTray(t, _card());
      expect(find.text('EACH · NOW'), findsOneWidget);
      // Paul and Sam took +1 on the hole, and Dave's running total is
      // +1 as well.
      expect(find.text('+1'), findsNWidgets(3));
      expect(find.text('−1'), findsNWidgets(2));
      expect(find.text('+\$8'), findsOneWidget);
      expect(find.text('−\$6'), findsOneWidget);
      expect(find.text('WOLF'), findsOneWidget);
    });

    testWidgets('a halved hole reads 0, not +0', (t) async {
      await _pumpTray(t, _card(
        sides: const [
          ['wolf', 'Sam + Paul', 4, 'halved'],
          ['field', 'Dave + Lee', 4, 'halved'],
        ],
        standing: const [
          [1, 'Paul', 'wolf', false, 0.0, 7.0, 7.0],
          [2, 'Dave', 'field', false, 0.0, 2.0, 2.0],
          [3, 'Sam', 'wolf', true, 0.0, -4.0, -4.0],
          [4, 'Lee', 'field', false, 0.0, -5.0, -5.0],
        ],
      ));
      expect(find.text('halved'), findsNWidgets(2));
      expect(find.text('0'), findsNWidgets(4));
      expect(find.text('+0'), findsNothing);
    });

    testWidgets('the forward button names the next hole’s Wolf',
        (t) async {
      await _pumpTray(t, _card());
      expect(find.text('Hole 8 · Lee is Wolf ›'), findsOneWidget);
    });

    testWidgets('…and falls back to the hole alone when it cannot',
        (t) async {
      await _pumpTray(t, _card(nextWolf: ''));
      expect(find.text('Hole 8 ›'), findsOneWidget);
    });

    testWidgets('the last hole finishes the round', (t) async {
      // The tray covers the screen's pager, so a forward button that only
      // advanced would leave the 18th a dead end (reported on Rabbit).
      await _pumpTray(t, _card(roundOver: true, nextHole: null));
      expect(find.text('Finish round ›'), findsOneWidget);
      // The label says it; the header above keeps saying what it always
      // says, so the corner does not carry the same fact twice.
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('All 4 scores in'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('Paul wins with +9 pts'), findsOneWidget);
      expect(find.textContaining('every hole sums to zero'), findsOneWidget);
    });

    testWidgets('a no-stake round says so rather than naming \$0 a point',
        (t) async {
      await _pumpTray(t, WolfHoleCard.fromJson(<String, dynamic>{
        'hole': 18, 'stake': 0, 'wolf_first': 'Lee', 'decision': 'partner',
        'call_label': 'partner', 'call_value': '1 pt each',
        'hole_complete': true, 'round_over': true,
        'values': {'team': 1, 'lone': 3, 'blind': 6},
        'sides': [
          {'side': 'wolf', 'label': 'Lee + Dave', 'best': 4,
           'result': 'halved'},
          {'side': 'field', 'label': 'Paul + Sam', 'best': 4,
           'result': 'halved'},
        ],
        'standing': [
          {'player_id': 1, 'first': 'Paul', 'short': 'PL', 'side': 'field',
           'is_wolf': false, 'hole_points': 0.0, 'points': 9.0,
           'money': 0.0},
        ],
        'winner': {'player_id': 1, 'short': 'PL', 'first': 'Paul',
                   'points': 9.0, 'money': 0.0, 'stake': 0},
      }));
      expect(find.text('No stake · every hole sums to zero'),
          findsOneWidget);
    });

    testWidgets('it holds its figures back while the result is on its way',
        (t) async {
      await t.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: WolfHoleTray(
            card: _card(),
            onEdit: () {},
            onCall: (d, {int? partnerId}) {},
            gettingResult: true,
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('Sam + Paul'), findsNothing);
      expect(find.text('+\$8'), findsNothing);
    });

    testWidgets('it survives a narrow phone', (t) async {
      await _pumpTray(t, _card());
      await t.binding.setSurfaceSize(const Size(320, 900));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('the sides are one colour everywhere', () {
    test('wolf is pine on a card and mint on the tray', () {
      expect(sideColour('wolf'), Halved.pine);
      expect(sideColour('wolf', onDark: true), Halved.onDark1);
      expect(sideColour('field'), Halved.teamClay);
      expect(sideColour('field', onDark: true), Halved.onDark2);
    });

    test('no call means no side colour', () {
      // Before the Wolf has decided, nobody is on a side — a row tinted
      // pine would be claiming one.
      expect(sideColour(null), Halved.muted);
      expect(sideColour(null, onDark: true), isNot(Halved.onDark1));
    });
  });

  group('the screen keeps what a dedicated play screen loses', () {
    final src = File('lib/screens/wolf_screen.dart').readAsStringSync();

    test('the call is no longer a gate', () {
      // `effHot` was forced to -1 until the Wolf had decided, so not one
      // score could be entered before a modal sheet was answered.
      expect(src, isNot(contains('decided ? hotSpotIdx : -1')));
      expect(src, isNot(contains('dimmed:    !decided')));
      expect(src, contains('WolfCallCard('));
    });

    test('the keypad posts the hole on its last score', () {
      // A hole left unsent raises a tray with nothing in it — the bug
      // Annandale hit, and then Sixes.
      final onScore = src.substring(src.indexOf('onScore: (n) {'));
      final body = onScore.substring(0, onScore.indexOf('onClear:'));
      expect(body, contains('_saveHole'));
    });

    test('the keypad reads the strokes off the CARD', () {
      // Not the round's stored full-net allocation, which is a different
      // number whenever the game is strokes-off — and Wolf's default IS
      // strokes-off.
      expect(src, contains('card.playerById(m.player.id)?.strokes'));
    });

    test('Clear passes the sentinel, never a zero', () {
      // `_selectScore` reads anything but −1 as a score, so 0 writes a gross
      // of zero: the row reads as scored and the hole counts as complete.
      final c = src.substring(src.indexOf('onClear:'));
      expect(c.substring(0, c.indexOf('\n')), contains('-1'));
    });

    test('the pager walks PLAY ORDER, not hole numbers', () {
      expect(src, contains('nextInOrder('));
      expect(src, contains('prevInOrder('));
    });

    test('it still carries the combo chip and Spots', () {
      expect(src, contains('ComboTeeChip'));
      expect(src, contains('SpotsCaptureMixin'));
    });

    test('the keypad is the only picker while it is up', () {
      // Two full-width score pickers on one screen is one too many; the
      // inline one stays as the fallback for a hole with no card.
      expect(src, contains('showPicker: card == null'));
      expect(src, contains('(isHot || isEditing) && showPicker'));
    });

    test('the decision sheet picks nothing any more', () {
      // One control for the call. The sheet is what is left of the old
      // overlay: the tee order, which nothing else shows.
      // The tombstone comment names it; nothing CONSTRUCTS one.
      expect(src, isNot(contains('_WolfChoice(')));
      expect(src, isNot(contains('class _WolfChoice')));
      expect(src, isNot(contains("'Take as partner'")));
      expect(src, contains('_openTeeOrderSheet'));
      // A sheet that picks returns a value; this one returns nothing.
      expect(src, contains('showModalBottomSheet<void>'));
    });
  });
}
