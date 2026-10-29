import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/rabbit_board_model.dart';
import 'package:golf_mobile/widgets/rabbit_board.dart';

/// `~/Downloads/handoff-rabbit-leaderboard` — one widget for every Rabbit
/// leaderboard. The engine decides holders, leads, ranges after rolling and
/// money; this reads them.

Map<String, dynamic> _seg(int i, int a, int b, {
  int? holder, String? short, int lead = 0, bool complete = true,
  int? decidedOn, double value = 5, double payout = 0, bool extra = false,
  double carriedIn = 0,
}) => {
      'index': i, 'is_extra': extra, 'start_hole': a, 'end_hole': b,
      'holes': b - a + 1, 'holder_id': holder, 'holder_short': short,
      'lead': lead, 'complete': complete, 'decided_on': decidedOn,
      'value': value, 'carried_in': carriedIn, 'payout': payout,
    };

Map<String, dynamic> _hole(int h, int seg, {
  int? holder, int lead = 0, bool played = true, int par = 4,
}) => {
      'hole': h, 'segment': seg, 'par': par,
      'winner_id': null, 'winner_short': null,
      'holder_id': holder, 'holder_short': null, 'lead': lead,
      'event': null,
      'entries': [
        {'player_id': 1, 'short_name': 'Paul', 'name': 'Paul Lipkin',
         'net_score': played ? 4 : null, 'gross': played ? 4 : null,
         'strokes': 0, 'is_winner': false, 'is_holder': false},
      ],
    };

RabbitSummary _rabbit({
  required List<Map<String, dynamic>> segments,
  required List<Map<String, dynamic>> holes,
  String status = 'in_progress',
  bool accumulate = true,
  bool carry = false,
  List<Map<String, dynamic>>? players,
  int? currentHolder,
  int currentLead = 0,
}) =>
    RabbitSummary.fromJson({
      'status': status,
      'handicap': {'mode': 'net', 'net_percent': 100,
                   'allocation': 'full_round'},
      'accumulate': accumulate,
      'num_segments': 3,
      'extra_rabbits': false,
      'carry': carry,
      'segments': segments,
      'players': players ?? [
        {'player_id': 1, 'name': 'Paul Lipkin', 'short_name': 'Paul',
         'money': 20.0, 'segments_won': 2, 'phcp_in_play': 0},
        {'player_id': 2, 'name': 'Sam Reid', 'short_name': 'Sam',
         'money': -5.0, 'segments_won': 1, 'phcp_in_play': 0},
        {'player_id': 3, 'name': 'Dave Moran', 'short_name': 'Dave',
         'money': -15.0, 'segments_won': 0, 'phcp_in_play': 0},
      ],
      'holes': holes,
      'scorecard': const <String, dynamic>{},
      'current': {'holder_id': currentHolder, 'holder_short': null,
                  'lead': currentLead, 'segment': 2},
      'money': {'bet_unit': 5.0, 'entry': 5.0, 'seg_value': 5.0,
                'pot': 15.0, 'max_liability': 15.0},
    });

Future<void> _pump(WidgetTester t, RabbitBoardData d) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: RabbitBoard(data: d))),
      ),
    );

void main() {
  group('the rabbit in play', () {
    testWidgets('names the holder, the lead and what is riding', (t) async {
      await _pump(t, RabbitBoardData.fromSummary(_rabbit(
        segments: [
          _seg(1, 1, 6, holder: 1, short: 'Paul', decidedOn: 6, payout: 10),
          _seg(2, 7, 12, holder: 2, short: 'Sam', lead: 2, complete: false),
          _seg(3, 13, 18, complete: false),
        ],
        holes: [
          for (var h = 1; h <= 9; h++) _hole(h, h <= 6 ? 1 : 2, holder: 2),
          for (var h = 10; h <= 18; h++)
            _hole(h, h <= 12 ? 2 : 3, played: false),
        ],
        currentHolder: 2, currentLead: 2,
      )));
      expect(find.textContaining('LIVE'), findsOneWidget);
      expect(find.text('Sam'), findsWidgets);
      expect(find.text('holds the rabbit'), findsOneWidget);
      expect(find.text('+2'), findsWidgets);
      expect(find.textContaining('\$5 riding'), findsOneWidget);
    });

    testWidgets('a loose rabbit says so rather than naming nobody', (t) async {
      await _pump(t, RabbitBoardData.fromSummary(_rabbit(
        segments: [
          _seg(1, 1, 6, complete: false),
          _seg(2, 7, 12, complete: false),
          _seg(3, 13, 18, complete: false),
        ],
        holes: [
          for (var h = 1; h <= 3; h++) _hole(h, 1),
          for (var h = 4; h <= 18; h++)
            _hole(h, h <= 6 ? 1 : (h <= 12 ? 2 : 3), played: false),
        ],
      )));
      expect(find.text('Loose'), findsWidgets);
      expect(find.text('holds the rabbit'), findsNothing);
    });

    testWidgets('a one-hole extra says it is half stake', (t) async {
      await _pump(t, RabbitBoardData.fromSummary(_rabbit(
        segments: [
          _seg(1, 1, 17, holder: 1, short: 'Paul', decidedOn: 17, payout: 10),
          _seg(2, 18, 18, extra: true, complete: false, value: 2.5),
        ],
        holes: [
          for (var h = 1; h <= 17; h++) _hole(h, 1, holder: 1),
          _hole(18, 2, played: false),
        ],
      )));
      expect(find.textContaining('half stake, one hole'), findsOneWidget);
    });
  });

  group('round over', () {
    RabbitBoardData finished() => RabbitBoardData.fromSummary(_rabbit(
          status: 'complete',
          segments: [
            _seg(1, 1, 6, payout: 0),
            _seg(2, 7, 11, holder: 1, short: 'Paul', decidedOn: 11,
                payout: 20),
            _seg(3, 12, 16, holder: 2, short: 'Sam', decidedOn: 16,
                payout: 10),
            _seg(4, 17, 18, holder: 1, short: 'Paul', decidedOn: 18,
                payout: 10, extra: true),
          ],
          holes: [for (var h = 1; h <= 18; h++) _hole(h, 1, holder: 1)],
        ));

    testWidgets('one line per rabbit, with what it paid', (t) async {
      await _pump(t, finished());
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('Rabbit 1'), findsOneWidget);
      expect(find.text('Extra'), findsWidgets);
      // Twice over, legitimately: the leg's own win and Paul's ledger
      // total happen to be the same figure in this fixture.
      expect(find.text('+\$20'), findsWidgets);
      expect(find.text('won on 11'), findsOneWidget);
      expect(find.text('won on 16'), findsOneWidget);
    });

    testWidgets('a loose rabbit pays nothing and says why', (t) async {
      await _pump(t, finished());
      expect(find.text('no winner'), findsOneWidget);
      expect(find.text('—'), findsWidgets);
    });

    testWidgets('the ledger reads Final and settles every rabbit', (t) async {
      await _pump(t, finished());
      expect(find.text('Final, each'), findsOneWidget);
      expect(find.text('Settled 4 of 4'), findsOneWidget);
      expect(find.text('Final'), findsOneWidget);
    });
  });

  group('the model reads, it does not replay', () {
    test('a leg\'s win is the engine\'s payout, not stake x golfers', () {
      // A withdrawal changes who pays, and the engine knows. Multiplying
      // out here would be a second opinion about money.
      final d = RabbitBoardData.fromSummary(_rabbit(
        segments: [_seg(1, 1, 6, holder: 1, short: 'Paul', payout: 7.5)],
        holes: [for (var h = 1; h <= 6; h++) _hole(h, 1, holder: 1)],
      ));
      expect(d.legWin(d.rabbits.first), 7.5);
    });

    test('ranges come from the engine, already rolled', () {
      // 3 x 6 nominally, but rabbit 1 was decided on 4 — so the engine
      // reports 1-4, 5-9, 10-15 and the board draws those.
      final d = RabbitBoardData.fromSummary(_rabbit(
        segments: [
          _seg(1, 1, 4, holder: 1, short: 'Paul', decidedOn: 4),
          _seg(2, 5, 9, holder: 2, short: 'Sam', decidedOn: 9),
          _seg(3, 10, 15),
        ],
        holes: [for (var h = 1; h <= 15; h++) _hole(h, 1)],
      ));
      expect(d.rabbits.map((r) => r.range), ['1–4', '5–9', '10–15']);
    });

    test('colour is identity, in roster order', () {
      final d = RabbitBoardData.fromSummary(_rabbit(
        segments: [_seg(1, 1, 6)],
        holes: [for (var h = 1; h <= 6; h++) _hole(h, 1)],
      ));
      expect(d.colourOf(1), 0);
      expect(d.colourOf(3), 2);
      expect(d.colourOf(999), -1, reason: 'not in this round');
    });

    test('the live leg is the first incomplete one', () {
      final d = RabbitBoardData.fromSummary(_rabbit(
        segments: [
          _seg(1, 1, 6, holder: 1, short: 'Paul'),
          _seg(2, 7, 12, complete: false),
          _seg(3, 13, 18, complete: false),
        ],
        holes: [for (var h = 1; h <= 18; h++) _hole(h, 1)],
      ));
      expect(d.liveLeg?.index, 2);
      expect(d.settled, 1);
    });
  });

  group('one board, not two', () {
    test('the leaderboard renders RabbitBoard and keeps no table', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect(src.contains('RabbitBoard(data:'), isTrue);
      final card = src.substring(src.indexOf('class _RabbitGroupCard'));
      final end = card.indexOf('\nclass ');
      final body = end > 0 ? card.substring(0, end) : card;
      // The old card drew its own standings table and segment strip.
      expect(body.contains('_segStrip'), isFalse);
      expect(body.contains('DataTable'), isFalse);
    });

    test('the board writes no money of its own', () {
      final src = File('lib/widgets/rabbit_board.dart').readAsStringSync();
      for (final banned in ['payout *', 'money =', '..sort(']) {
        expect(src.contains(banned), isFalse, reason: banned);
      }
    });
  });

  group('carry', () {
    // A loose rabbit rolls its stake into the next. Off by default — it
    // changes what every later rabbit is worth (Paul, 28 Oct 2026).
    testWidgets('a live rabbit says what rolled into it', (t) async {
      await _pump(t, RabbitBoardData.fromSummary(_rabbit(
        carry: true,
        segments: [
          _seg(1, 1, 6, payout: 0),
          _seg(2, 7, 12, holder: 1, short: 'Paul', lead: 1,
              complete: false, value: 10, carriedIn: 5),
          _seg(3, 13, 18, complete: false),
        ],
        holes: [
          for (var h = 1; h <= 8; h++) _hole(h, h <= 6 ? 1 : 2, holder: 1),
          for (var h = 9; h <= 18; h++)
            _hole(h, h <= 12 ? 2 : 3, played: false),
        ],
        currentHolder: 1, currentLead: 1,
      )));
      expect(find.textContaining('\$10 riding'), findsOneWidget);
      expect(find.textContaining('\$5 carried'), findsOneWidget);
    });

    testWidgets('a loose rabbit that CARRIED says so, not "no winner"',
        (t) async {
      await _pump(t, RabbitBoardData.fromSummary(_rabbit(
        status: 'complete',
        carry: true,
        segments: [
          _seg(1, 1, 6, payout: 0),
          _seg(2, 7, 12, holder: 1, short: 'Paul', decidedOn: 12,
              payout: 20, value: 10, carriedIn: 5),
          _seg(3, 13, 18, holder: 2, short: 'Sam', decidedOn: 18, payout: 10),
        ],
        holes: [for (var h = 1; h <= 18; h++) _hole(h, 1, holder: 1)],
      )));
      expect(find.text('carried'), findsOneWidget);
      expect(find.text('no winner'), findsNothing);
    });

    testWidgets('a loose LAST rabbit has nowhere to carry to', (t) async {
      await _pump(t, RabbitBoardData.fromSummary(_rabbit(
        status: 'complete',
        carry: true,
        segments: [
          _seg(1, 1, 9, holder: 1, short: 'Paul', decidedOn: 9, payout: 10),
          _seg(2, 10, 18, payout: 0),
        ],
        holes: [for (var h = 1; h <= 18; h++) _hole(h, 1, holder: 1)],
      )));
      expect(find.text('no winner'), findsOneWidget,
          reason: 'that stake is never won by anybody');
      expect(find.text('carried'), findsNothing);
    });

    testWidgets('without carry the card says nothing about it', (t) async {
      await _pump(t, RabbitBoardData.fromSummary(_rabbit(
        status: 'complete',
        segments: [
          _seg(1, 1, 9, payout: 0),
          _seg(2, 10, 18, holder: 1, short: 'Paul', decidedOn: 18, payout: 10),
        ],
        holes: [for (var h = 1; h <= 18; h++) _hole(h, 1, holder: 1)],
      )));
      expect(find.text('no winner'), findsOneWidget);
      expect(find.text('CARRY'), findsNothing);
      expect(find.textContaining('carried'), findsNothing);
    });

    test('the setup screen offers it, and posts it', () {
      final screen =
          File('lib/screens/rabbit_setup_screen.dart').readAsStringSync();
      expect(screen.contains('_carry'), isTrue);
      expect(screen.contains('carry: _carry'), isTrue);
      final client = File('lib/api/client.dart').readAsStringSync();
      expect(client.contains("'carry'        : carry,"), isTrue);
    });
  });
}
