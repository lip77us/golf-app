import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Triple Nassau's leaderboard draws a two-golfer scorecard per match
/// (Paul, 11 Nov 2026), through the shared progress card.
void main() {
  final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
  final at = src.indexOf('class _TripleNassauGroupCardState');
  final end = src.indexOf('\nclass ', at + 1);
  final card = src.substring(at, end);

  test('the PICKED match\'s card sits behind its tab, one card only', () {
    expect('NassauProgressCard('.allMatches(card).length, 1);
    expect(card, contains('_cardOf(raw, picked)'));
    expect(card, contains("title: '\${nameOf[s.matches[picked].player1Id]"));
    // Inside the match panel, with its board — not under the net position.
    expect(card.indexOf('NassauProgressCard('),
        lessThan(card.indexOf('_TripleNetPosition(')));
  });

  test('each card reads that match\'s OWN scorecard', () {
    expect(card, contains("(ms[i] as Map?)?['match']"));
    expect(card, contains("m?['scorecard']"));
  });

  test('colours follow the roster, as the picker does', () {
    expect(card, contains('colourOf[s.matches[picked].player1Id]'));
    expect(card, contains('colourOf[s.matches[picked].player2Id]'));
  });

  test('the shared card takes a title and falls back to its own', () {
    final w =
        File('lib/widgets/nassau_progress_card.dart').readAsStringSync();
    expect(w, contains('title ??'));
  });
}
