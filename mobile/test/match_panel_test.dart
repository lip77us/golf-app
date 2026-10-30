// The box round the board a match picker drives (widgets/match_panel.dart).
//
// The two cards that use it are private to leaderboard_screen.dart, so the
// wiring is checked at the source: what the box has to hold, and what it must
// NOT — a ledger totalling every match inside a box that changes with the pick
// would look as though it should change too.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/match_panel.dart';

String _card(String src, String cls, String next) {
  final a = src.indexOf('class $cls ');
  final b = src.indexOf('class $next ', a);
  if (a < 0 || b < a) throw StateError('$cls / $next not found');
  return src.substring(a, b);
}

void main() {
  testWidgets('names the match it holds, in the pills\' order', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: MatchPanel(
      side1: MatchPanelSide('Paul & Jim', Colors.green),
      side2: MatchPanelSide('Larry & RyanL', Colors.orange),
      child: SizedBox(height: 40, child: Text('BOARD')),
    ))));
    expect(find.text('Paul & Jim'), findsOneWidget);
    expect(find.text('Larry & RyanL'), findsOneWidget);
    expect(find.text('BOARD'), findsOneWidget);
    // Header above the board, so the board is read under its match.
    expect(t.getTopLeft(find.text('Paul & Jim')).dy,
        lessThan(t.getTopLeft(find.text('BOARD')).dy));
  });

  testWidgets('wears the selected pill\'s border', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: MatchPanel(
      side1: MatchPanelSide('A', Colors.green),
      side2: MatchPanelSide('B', Colors.orange),
      child: SizedBox(height: 10),
    ))));
    final box = t.widget<Container>(find.byType(Container).first);
    final border = (box.decoration as BoxDecoration).border as Border;
    expect(border.top.color, MatchPanel.accent);
    expect(border.top.width, MatchPanel.accentWidth);
  });

  group('both pickers', () {
    final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
    final cards = {
      'Annandale Friday': (_card(src, '_AnnandaleFridayGroupCardState',
          '_AfMatchPill'), 'MatchPanel(', '_AfNetPosition('),
      'Triple Nassau': (_card(src, '_TripleNassauGroupCardState',
          '_MatchPicker'), 'MatchPanel(', '_TripleNetPosition('),
    };
    cards.forEach((name, c) {
      final (body, panel, ledger) = c;
      test('$name puts the board inside the panel', () {
        final p = body.indexOf(panel);
        expect(p, greaterThan(0));
        expect(body.indexOf('NassauBoard(', p), greaterThan(p));
        // Exactly one board, and it is the panel's child.
        expect('NassauBoard('.allMatches(body).length, 1);
      });
      test('$name keeps the net position OUTSIDE the panel', () {
        final p = body.indexOf(panel);
        final board = body.indexOf('NassauBoard(', p);
        final close = body.indexOf('\n      ),', board);
        expect(body.indexOf(ledger), greaterThan(close),
            reason: 'the ledger totals every match; it must not sit in the box');
      });
    });

    test('the selected pill takes the panel\'s own colour', () {
      expect('selected ? MatchPanel.accent :'.allMatches(src).length, 2);
    });
  });
}
