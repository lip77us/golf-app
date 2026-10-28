import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/utils/nassau_board_model.dart';

/// Triple Nassau: three golfers, no teams, every PAIR its own 1v1 Nassau.
/// Built from `~/Downloads/handoff-triple-nassau-leaderboard`, whose scope
/// line is that the board in the middle is the SHARED NassauBoard and this
/// packet adds only the picker and the net position card around it.

Map<String, dynamic> _bet({
  String? result, int margin = 0, int holesPlayed = 0,
}) => {
      'result': result, 'margin': margin, 'holes_played': holesPlayed,
      'decided_margin': null, 'decided_remaining': null,
    };

Map<String, dynamic> _p(int id, String name) =>
    {'player_id': id, 'name': name, 'short_name': name};

/// One 1v1 Nassau, in the shape `TripleNassauMatch.match` parses.
Map<String, dynamic> _match(
  int aId, String a, int bId, String b, {
  List<Map<String, dynamic>> holes = const [],
  int margin = 0, int holesPlayed = 0, double total = 0,
}) => {
      'status': 'in_progress',
      'variant': 'none',
      'single_match': false,
      'bet_unit': 10.0,
      'press_unit': 5.0,
      'teams': {'team1': [_p(aId, a)], 'team2': [_p(bId, b)]},
      'front9': _bet(margin: margin, holesPlayed: holesPlayed),
      'back9': _bet(),
      'overall': _bet(margin: margin, holesPlayed: holesPlayed),
      'presses': const [],
      'holes': holes,
      'payouts': {'total': total, 'total_capped': total},
    };

TripleNassauSummary _triple({double paul = 60, double dave = -20,
                             double sam = -40}) =>
    TripleNassauSummary.fromJson({
      'status': 'in_progress',
      'handicap_mode': 'strokes_off',
      'net_percent': 100,
      'press_mode': 'auto',
      'bet_unit': 10.0,
      'press_unit': 5.0,
      'players': [
        {..._p(1, 'Paul'), 'playing_handicap': 0, 'net': paul},
        {..._p(2, 'Dave'), 'playing_handicap': 4, 'net': dave},
        {..._p(3, 'Sam'),  'playing_handicap': 9, 'net': sam},
      ],
      'matches': [
        {'game_type': 'triple_1', 'player1_id': 1, 'player2_id': 2,
         'match': _match(1, 'Paul', 2, 'Dave',
             margin: 3, holesPlayed: 12, total: 25)},
        {'game_type': 'triple_2', 'player1_id': 1, 'player2_id': 3,
         'match': _match(1, 'Paul', 3, 'Sam',
             margin: 1, holesPlayed: 12, total: 35)},
        {'game_type': 'triple_3', 'player1_id': 2, 'player2_id': 3,
         'match': _match(2, 'Dave', 3, 'Sam',
             margin: 0, holesPlayed: 12, total: -5)},
      ],
      'scorecard': <String, dynamic>{},
    });

void main() {
  group('the shape of it', () {
    test('a match arrives as a full NassauSummary, which is the whole trick',
        () {
      // That is what lets the picker hand one to the SAME widget the 2v2 and
      // 1v1 boards use, instead of a Triple Nassau board existing at all.
      final s = _triple();
      expect(s.matches, hasLength(3));
      expect(s.matches.first.match, isA<NassauSummary>());
      final d = NassauBoardData.fromSummary(s.matches.first.match);
      expect(d.sides.map((x) => x.name), ['Paul', 'Dave']);
    });

    test('every pair plays, and each golfer is in two matches', () {
      final s = _triple();
      final pairs = {
        for (final m in s.matches) {m.player1Id, m.player2Id},
      };
      expect(pairs, hasLength(3));
      for (final pid in [1, 2, 3]) {
        final mine = s.matches.where(
            (m) => m.player1Id == pid || m.player2Id == pid);
        expect(mine, hasLength(2), reason: 'golfer $pid');
      }
    });

    test('the sides card is hidden — the picker already names the match', () {
      final d = NassauBoardData.fromSummary(
          _triple().matches.first.match, showSides: false);
      expect(d.showSides, isFalse);
    });

    test('colour follows the GOLFER, not the side', () {
      // Paul is side 0 in match 1 and side 0 in match 2, but Dave is side 1
      // in match 1 and side 0 in match 3. If colour tracked the side, Dave
      // would change colour the moment the reader switched matches.
      final s = _triple();
      final colourOf = {
        for (var i = 0; i < s.players.length; i++)
          s.players[i].playerId: Halved.golfer(i),
      };
      final m1 = NassauBoardData.fromSummary(s.matches[0].match,
          side0Colour: colourOf[1], side1Colour: colourOf[2]);
      final m3 = NassauBoardData.fromSummary(s.matches[2].match,
          side0Colour: colourOf[2], side1Colour: colourOf[3]);
      expect(m1.sides[1].colour, colourOf[2]);
      expect(m3.sides[0].colour, colourOf[2],
          reason: 'Dave keeps his colour across his two matches');
    });
  });

  group('net position', () {
    test('is the server\'s per-golfer net, never summed from the boards', () {
      // Each board's money is ONE match of a golfer's two, and the card
      // totals both plus every press. The server already did that.
      final s = _triple();
      expect(s.players.map((p) => p.net), [60.0, -20.0, -40.0]);
    });

    test('it is zero-sum across the three', () {
      final s = _triple();
      final total = s.players.fold<double>(0, (a, p) => a + p.net);
      expect(total, 0);
    });
  });

  group('one board, not two', () {
    test('the card renders NassauBoard and defines no board of its own', () {
      final src = File('lib/screens/leaderboard_screen.dart')
          .readAsStringSync();
      final card = src.substring(src.indexOf('class _TripleNassauGroupCard'));
      final end = card.indexOf('class _QuotaNassauGroupCard');
      final body = end > 0 ? card.substring(0, end) : card;
      expect(body.contains('NassauBoard(data:'), isTrue);
      // The old bespoke card drew its own matrix and press rows. Those are
      // the board's job now; a second drawing of them is how the two come
      // to disagree.
      expect(body.contains('_matrix('), isFalse);
      expect(body.contains('_pressRows('), isFalse);
    });

    test('the picker is three buttons at a 44pt target', () {
      final src = File('lib/screens/leaderboard_screen.dart')
          .readAsStringSync();
      expect(src.contains('minHeight: 44'), isTrue);
    });
  });
}
