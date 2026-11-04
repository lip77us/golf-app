/// test/stroke_with_skins_test.dart
/// -------------------------------
/// **A round-wide pool never owns score entry.**
///
/// A tournament called "Stroke With Skins" stored `active_games =
/// ['multi_skins']` — because an individual-play tournament sets its scoring
/// method once, on the tournament — and score entry read that list for every
/// gate it has. So the round resolved to the POOL: the skins standings card
/// on the entry screen, no stroke-play keypad, no hole tray, no ribbon.
///
/// Two halves. `primaryGameOf` must not hand entry to a round-wide pool, and
/// the screen has to know what the round is actually scored on.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/game_catalog.dart';

String _src(String p) => File(p).readAsStringSync();

Round _round({List<String> games = const [], String? scoringGame,
    String? primary}) =>
    Round.fromJson({
      'id': 1,
      'round_number': 1,
      'date': '2026-11-04',
      'course': {'id': 1, 'name': 'Tilden', 'hole_count': 18},
      'status': 'in_progress',
      'bet_unit': 1,
      'active_games': games,
      if (primary != null) 'primary_game': primary,
      if (scoringGame != null) 'scoring_game': scoringGame,
      'foursomes': const [],
    });

void main() {
  group('a round-wide pool never owns entry', () {
    test('stroke play with a skins pool resolves to stroke play', () {
      expect(primaryGameOf([GameIds.multiSkins, GameIds.strokePlay]),
          GameIds.strokePlay);
    });

    test('and the order of the list cannot change the answer', () {
      // `active_games` is a set on the wire; an answer that depended on which
      // game happened to be first is the defect the stored primary was
      // introduced for.
      expect(primaryGameOf([GameIds.strokePlay, GameIds.multiSkins]),
          GameIds.strokePlay);
    });

    test('a pool-ONLY round still lands on the pool', () {
      // The one case where it really is all there is — and the reason
      // `_kSidePrimaryPriority` has listed it since it was written.
      expect(primaryGameOf([GameIds.multiSkins]), GameIds.multiSkins);
    });

    test('a game that owns entry beats the pool', () {
      // A casual pool round running Sixes inside each group: Sixes owns the
      // teams and the segments, the pool only reads the scores.
      expect(primaryGameOf([GameIds.multiSkins, GameIds.sixes]),
          GameIds.sixes);
    });

    test('a stored pick still wins, so nothing made through the picker moves',
        () {
      expect(
          resolvePrimary(GameIds.multiSkins,
              [GameIds.multiSkins, GameIds.strokePlay]),
          GameIds.multiSkins);
    });

    test('the pool is still offered as a primary in its own right', () {
      // `canBeSideGame` was deliberately NOT flipped: that would start
      // offering the pool as a side game in the casual picker, which needs
      // the deferred cross-round linkage. The fix is narrower than that.
      expect(canBeSideGame(GameIds.multiSkins), isFalse);
      expect(gameMeta(GameIds.multiSkins)!.acrossGroups, isTrue);
    });
  });

  group('the round says what it is scored on', () {
    test('null by default, so an older server is unchanged', () {
      expect(_round(games: ['multi_skins']).scoringGame, isNull);
    });

    test('and the server can name it', () {
      expect(_round(games: ['multi_skins'], scoringGame: 'low_net_round')
          .scoringGame, 'low_net_round');
    });

    test('it does not touch the games the round is PLAYING', () {
      // A different question from what somebody chose — which is why it is
      // its own field rather than being folded into `activeGames`, where the
      // hub would start offering a Configure button for it.
      final r = _round(games: ['multi_skins'], scoringGame: 'low_net_round');
      expect(r.activeGames, ['multi_skins']);
    });
  });

  group('score entry reads it', () {
    test('_activeGames folds the scoring game in', () {
      final src = _src('lib/screens/score_entry_screen.dart');
      final i = src.indexOf('List<String> _activeGames(Round? round) {');
      expect(i, greaterThan(0));
      final body = src.substring(
          i, src.indexOf('List<String> _configuredGames(', i));
      expect(body, contains('round.scoringGame'));
      // And it is the UNION, not a replacement: the pool is still playing.
      expect(body, contains('...rdGames'));
      expect(body, contains('...fsGames'));
    });

    test('the skins standings card is gated on the PRIMARY, not membership',
        () {
      // Which is what takes it off a stroke round's entry screen: the pool
      // has a leaderboard tab, and a board crushed under the keypad is a
      // second drawing of it.
      final src = _src('lib/screens/score_entry_screen.dart');
      expect(src, contains("if (primaryGame == 'multi_skins')"));
      expect(src.contains("games.contains('multi_skins')\n"
          "            && _MultiSkinsStandingsCard"), isFalse);
    });

    test('a stroke round with a pool reaches the keypad', () {
      // The composition the user is actually after: the fast entry.
      final games = ['multi_skins', 'low_net_round'];
      expect(resolvePrimary(null, games), GameIds.strokePlay);
      final src = _src('lib/screens/score_entry_screen.dart');
      final i = src.indexOf('bool _keypadRound(RoundProvider rp) {');
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('GameIds.strokePlay'));
    });
  });
}
