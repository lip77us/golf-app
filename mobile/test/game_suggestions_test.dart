/// The rules in `handoff-game-selection-more-games`, as the handoff's own
/// worked cases (r1–r5) plus the edges the page implies.
///
/// `fits` here is the casual screen's own filter, rebuilt from the catalog, so
/// these run against the real player ranges rather than the prototype's table.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/utils/game_suggestions.dart';
import 'package:golf_mobile/widgets/all_games_sheet.dart';

bool Function(String) fitsFor(String size) => (id) {
      final m = gameMeta(id);
      if (m == null || !m.enabled || m.sideGameOnly) return false;
      if (size == 'groups') return m.acrossGroups;
      if (m.acrossGroups) return false;
      if (size == 'solo') return m.supportsSize(1);
      if (size == kFiveOrSix) return fitsFiveOrSix(m);
      return m.supportsSize(int.parse(size));
    };

GameSuggestion guess(String size, List<String> history) =>
    suggestGames(sizeKey: size, history: history, fits: fitsFor(size));

void main() {
  // A regular: Wolf last, Nassau most.
  final regular = [
    'wolf', 'nassau', 'skins', 'nassau', 'triple_nassau', 'nassau', 'skins',
    'nassau', 'wolf', 'nassau', 'skins', 'nassau', 'sixes', 'nassau',
    'triple_nassau', 'skins', 'nassau', 'wolf', 'nassau', 'skins',
  ];

  group('the handoff cases', () {
    test('r1 — no history, four: the default list, first selected', () {
      final s = guess('4', const []);
      expect(s.chips, ['skins', 'nassau', 'fourball', 'sixes']);
      expect(s.selected, 'skins');
    });

    test('r2 — last game fits: it is first and selected, then most played', () {
      final s = guess('4', regular);
      expect(s.chips.first, 'wolf');
      expect(s.selected, 'wolf');
      // Nassau ×9 then Skins ×5; Triple Nassau is ×2 but is not a game for
      // four, so Sixes (×1) takes the slot ahead of any default.
      expect(s.chips, ['wolf', 'nassau', 'skins', 'sixes']);
    });

    test("r3 — last game doesn't fit four: not shown, first chip selected", () {
      final s = guess('4', ['triple_nassau', 'skins', 'banker', 'skins', 'skins',
        'banker', 'skins']);
      expect(s.chips, isNot(contains('triple_nassau')));
      expect(s.chips, ['skins', 'banker', 'nassau', 'fourball']);
      expect(s.selected, 'skins');
    });

    test('r4 — one round only: that game, then the defaults', () {
      final s = guess('4', ['sixes']);
      expect(s.chips, ['sixes', 'skins', 'nassau', 'fourball']);
      expect(s.selected, 'sixes');
    });

    test('r5 — the same golfer in a threesome', () {
      final s = guess('3', regular);
      // Wolf plays three, so it is still the last game and first. Nassau is
      // the most played and does not play three, so it is skipped; the
      // history that DOES fit comes next, then the threesome defaults.
      expect(s.chips, ['wolf', 'skins', 'triple_nassau', 'points_531']);
      expect(s.selected, 'wolf');
    });
  });

  group('the rules', () {
    test('a tie in games played goes to the more recent', () {
      // Skins and Nassau twice each; Skins was played more recently.
      final s = guess('4', ['wolf', 'skins', 'nassau', 'skins', 'nassau']);
      expect(s.chips.sublist(0, 3), ['wolf', 'skins', 'nassau']);
    });

    test('a game counts toward most played whatever size it was played at', () {
      // Nassau at two is the same game as Nassau at four.
      final s = guess('4', ['sixes', 'nassau', 'nassau', 'nassau', 'skins']);
      expect(s.chips, ['sixes', 'nassau', 'skins', 'fourball']);
    });

    test('no game appears twice', () {
      for (final size in ['solo', '2', '3', '4', kFiveOrSix, 'groups']) {
        for (final h in [const <String>[], regular, ['skins', 'skins']]) {
          final chips = guess(size, h).chips;
          expect(chips.toSet().length, chips.length, reason: '$size $h');
        }
      }
    });

    test('four chips, three across groups, never more', () {
      for (final size in ['solo', '2', '3', '4', kFiveOrSix, 'groups']) {
        expect(guess(size, regular).chips.length,
            lessThanOrEqualTo(chipCountFor(size)),
            reason: size);
      }
      expect(chipCountFor('groups'), 3);
      expect(chipCountFor('4'), 4);
    });

    test('every chip fits, and the selection is one of the chips', () {
      for (final size in ['solo', '2', '3', '4', kFiveOrSix, 'groups']) {
        final s = guess(size, regular);
        final fits = fitsFor(size);
        for (final c in s.chips) {
          expect(fits(c), isTrue, reason: '$size offers $c');
        }
        if (s.selected != null) expect(s.chips, contains(s.selected));
      }
    });

    test('a primary is always chosen when anything fits', () {
      for (final size in ['solo', '2', '3', '4', kFiveOrSix, 'groups']) {
        expect(guess(size, const []).selected, isNotNull, reason: size);
      }
    });

    test('a history game nothing can play is ignored, not shown', () {
      final s = guess('4', ['not_a_real_game', 'nassau']);
      expect(s.chips, isNot(contains('not_a_real_game')));
      expect(s.chips.first, 'nassau');
    });

    test('solo starts on a solo game', () {
      final s = guess('solo', const []);
      expect(s.selected, 'solo_stroke');
      expect(s.chips.first, 'solo_stroke');
    });

    test('across groups offers the pool, and only what the catalog allows', () {
      final s = guess('groups', const []);
      expect(s.chips.first, 'multi_skins');
      for (final c in s.chips) {
        expect(gameMeta(c)!.acrossGroups, isTrue);
      }
    });

    test('a default the catalog says does not fit is skipped, not shown', () {
      // The handoff lists Skins first for five or six; the catalog seats
      // Skins at two to four. The registry wins.
      final s = guess(kFiveOrSix, const []);
      expect(s.chips, isNot(contains('skins')));
      expect(s.chips, contains('annandale_friday'));
    });
  });

  group("Paul's list of the best-known games", () {
    test('the order for each size is the one he gave', () {
      expect(kGameOrder['2'], ['skins', 'nassau', 'nassau_nine', 'match_18',
        'low_net_round', 'stableford']);
      expect(kGameOrder['3'], ['points_531', 'skins', 'rabbit', 'survivor',
        'wolf', 'triple_nassau', 'banker', 'match_play', 'match_18',
        'low_net_round', 'stableford']);
      expect(kGameOrder['4'], ['skins', 'nassau', 'fourball', 'sixes', 'wolf',
        'sequoya_threes', 'vegas', 'banker', 'triple_cup', 'match_play',
        'low_net_round', 'stableford', 'match_18', 'nassau_nine']);
      expect(kGameOrder['solo'], ['solo_stroke', 'solo_nassau', 'solo_match']);
      expect(kGameOrder[kFiveOrSix], ['annandale_friday']);
      expect(kGameOrder['groups'], ['multi_skins']);
    });

    test('every game he named exists, and plays at the size he named it for',
        () {
      kGameOrder.forEach((size, ids) {
        final fits = fitsFor(size);
        for (final id in ids) {
          expect(gameMeta(id), isNotNull, reason: '$size names $id');
          // Nothing on his list is silently skipped by the catalog's ranges —
          // if one is, the list or the registry is wrong and one must move.
          expect(fits(id), isTrue, reason: '$size: $id does not fit');
        }
      });
    });

    test('solo, five or six and across groups each have fewer than four', () {
      for (final size in ['solo', kFiveOrSix, 'groups']) {
        expect(guess(size, const []).chips.length, lessThan(4), reason: size);
      }
      expect(guess('solo', const []).chips,
          ['solo_stroke', 'solo_nassau', 'solo_match']);
      expect(guess(kFiveOrSix, const []).chips, ['annandale_friday']);
      expect(guess('groups', const []).chips, ['multi_skins']);
    });
  });

  group('a pick from the sheet', () {
    test('takes the fourth slot, never a fifth chip', () {
      final out = chipsWithPick(['nassau', 'skins', 'wolf', 'sixes'], 'banker', 4);
      expect(out, ['nassau', 'skins', 'wolf', 'banker']);
      expect(out.length, 4);
    });

    test('a game that is already a chip leaves the chips alone', () {
      final chips = ['nassau', 'skins', 'wolf', 'sixes'];
      expect(chipsWithPick(chips, 'wolf', 4), chips);
    });

    test('a second sheet pick replaces the first rather than stacking', () {
      final first = chipsWithPick(['nassau', 'skins', 'wolf', 'sixes'], 'banker', 4);
      // The screen re-derives the chips and folds the NEW pick in.
      final again = chipsWithPick(['nassau', 'skins', 'wolf', 'sixes'], 'vegas', 4);
      expect(first.last, 'banker');
      expect(again.last, 'vegas');
      expect(again.length, 4);
    });

    test('three chips across groups: the pick takes the third', () {
      final out = chipsWithPick(['multi_skins', 'a'], 'b', 3);
      expect(out.length, lessThanOrEqualTo(3));
      expect(out.last, 'b');
    });

    test('Las Vegas is Vegas on the chip and Las Vegas on the sheet', () {
      expect(gameChipLabel('vegas'), 'Vegas');
      expect(gameDisplayName('vegas'), 'Las Vegas');
    });
  });

  group('the screen uses it', () {
    final src = File('lib/screens/casual_round_screen.dart').readAsStringSync();

    test('the chips come from the suggestion, not a filtered catalog', () {
      expect(src, contains('suggestGames('));
      expect(src, contains('for (final id in _chips)'));
      expect(src, contains('_MoreGamesChip('));
      expect(src, contains('onTap: _openAllGames'));
    });

    test('the chip says All games when nothing more is left to find', () {
      expect(src, contains("'All games'"));
      expect(src, contains('_allGamesFit <= _chips.length'));
    });

    test('the history is loaded, and a failure is not an error', () {
      expect(src, contains('getGameHistory()'));
      final at = src.indexOf('Future<void> _loadGameHistory()');
      final body = src.substring(at, src.indexOf('bool _fitsGame'));
      expect(body, contains('catch (_)'));
    });

    test('a group-size change and a short round both re-guess', () {
      final size = src.indexOf('_sizeFilter = v;');
      expect(src.substring(size, size + 1400), contains('_recomputeGames();'));
      final holes = src.indexOf('void _setHoles(');
      expect(src.substring(holes, holes + 700), contains('_recomputeGames();'));
    });

    test('only a golfer\'s own pick makes the form worth guarding', () {
      // The guess always selects something, so "a game is selected" is no
      // longer work; backing out of an untouched form must stay silent.
      final at = src.indexOf('bool get _hasWork');
      final body = src.substring(at, src.indexOf('static bool _setEq'));
      expect(body, contains('_tapped != null'));
      expect(body, isNot(contains('_primaryGame != null')));
    });

    test('a sheet pick leaves side games', () {
      final at = src.indexOf('Future<void> _openAllGames()');
      final body = src.substring(at, at + 1200);
      expect(body, contains('_sideGames.remove(picked)'));
    });
  });
}
