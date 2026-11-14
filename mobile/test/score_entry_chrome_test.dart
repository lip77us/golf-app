/// The score entry chrome from `handoff-score-entry-template`: the app bar's
/// title, the leaderboard line on every game, and the hole as its own card.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/score_entry_title.dart';

void main() {
  group('the title', () {
    testWidgets('the course is the title and the game sits under it',
        (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ScoreEntryTitle(
              course: 'Claremont Country Club', subtitle: 'Fourball · Thru 6'),
        ),
      ));
      expect(find.text('Claremont Country Club'), findsOneWidget);
      expect(find.text('Fourball · Thru 6'), findsOneWidget);
      expect(t.getCenter(find.text('Claremont Country Club')).dy,
          lessThan(t.getCenter(find.text('Fourball · Thru 6')).dy));
    });

    testWidgets('a long course is cut off, not wrapped', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: ScoreEntryTitle(
                course: 'The Very Long Name Of A Country Club And Golf Resort',
                subtitle: 'Skins'),
          ),
        ),
      ));
      final text = t.widget<Text>(
          find.text('The Very Long Name Of A Country Club And Golf Resort'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('with no course the subtitle is the title', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ScoreEntryTitle(course: '', subtitle: 'Stroke Play · Thru 3'),
        ),
      ));
      expect(find.text('Stroke Play · Thru 3'), findsOneWidget);
    });

    test('the subtitle says Thru only once something is played', () {
      expect(ScoreEntryTitle.subtitleFor('Fourball', 6), 'Fourball · Thru 6');
      expect(ScoreEntryTitle.subtitleFor('Fourball', 0), 'Fourball');
    });
  });

  group('the main screen wears it', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('the course is the title, with the game and Thru under it', () {
      expect(src, contains('ScoreEntryTitle('));
      expect(src, contains('course: rp.round?.course.name'));
      expect(src, contains('ScoreEntryTitle.subtitleFor('));
      expect(src, contains('_holesThru(rp)'));
    });

    test('the bar is the sage surface with dark ink', () {
      final at = src.indexOf('appBar: AppBar(');
      final head = src.substring(at, at + 700);
      expect(head, contains('backgroundColor: Halved.surface'));
      expect(head, contains('foregroundColor: Halved.deepPine'));
    });

    test('every game gets the leaderboard line', () {
      // A game with no standing of its own falls back to a bare trophy and the
      // pill, so the way to the leaderboard is on every game.
      expect(src, contains('_standingRibbon(rp, games) ??'));
    });

    test('the leaderboard icon is gone — the pill is the way in', () {
      expect(src, isNot(contains("tooltip: 'Leaderboard',\n              icon: const Icon(Icons.leaderboard_outlined)")));
    });

    test("the hole is its own card, above the golfers' card", () {
      final at = src.indexOf('class _HoleScoreCard');
      final body = src.substring(at);
      final header = body.indexOf('HoleHeader(');
      final card = body.indexOf('Card(\n      elevation: 0,\n      clipBehavior');
      expect(header, greaterThan(-1));
      expect(card, greaterThan(header),
          reason: "the header comes BEFORE the golfers' card, not inside it");
    });

    test('the course is not repeated in the hole card', () {
      final at = src.indexOf('class _HoleScoreCard');
      expect(src.substring(at), contains("courseName:  ''"));
    });
  });
}
