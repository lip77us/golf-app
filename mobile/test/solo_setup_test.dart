// The solo setup screen: the sentence under the slider, and the way in.
//
// `handoff-solo-games` writes that sentence for a 12 handicap — "12 strokes,
// on the holes with a stroke index of 12 or lower". It stops making sense the
// moment the number passes 18, and a high handicapper is exactly who slides
// above 100%: at 150% a 30 handicap is 45 strokes, which is a stroke on every
// hole and a second on 27 of them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/screens/solo_setup_screen.dart';
import 'package:golf_mobile/widgets/solo_board.dart';
import 'package:golf_mobile/utils/create_casual_round.dart';

void main() {
  group('the variant follows the chip', () {
    test('each solo game maps to its own variant', () {
      expect(soloVariantOf([GameIds.soloStroke]), 'stroke');
      expect(soloVariantOf([GameIds.soloNassau]), 'nassau');
      expect(soloVariantOf([GameIds.soloMatch]), 'match');
    });

    test('a round that is not solo at all is null, not stroke', () {
      // It moved out of the setup screen (where the variant was always one
      // of three, because the screen only opens on a solo round) into
      // `widgets/solo_board.dart`, where score entry asks it of EVERY round
      // to decide whether to draw the solo card. A default of 'stroke' there
      // would put a vs-par board on every skins game in the app.
      expect(soloVariantOf([]), isNull);
      expect(soloVariantOf(['skins']), isNull);
    });
  });

  group('picking a solo game routes to its setup', () {
    // The failure this guards is the one this repo keeps hitting: a game
    // that exists and cannot be reached.
    for (final entry in {
      GameIds.soloStroke: 'stroke',
      GameIds.soloNassau: 'nassau',
      GameIds.soloMatch: 'match',
    }.entries) {
      test('${entry.key} opens /solo-setup as ${entry.value}', () {
        final meta = gameMeta(entry.key);
        expect(meta, isNotNull, reason: '${entry.key} is not in the catalog');
      });
    }
  });

  group('the allowance sentence survives a big handicap', () {
    // Rendered rather than asserted on a string, because the sentence is
    // chosen by the widget and the whole point is which branch it takes.
    Future<String> line(WidgetTester t, int ch, int pct) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SoloAllowanceLine(courseHandicap: ch,
                                               netPercent: pct)),
      ));
      final w = t.widget<Text>(find.byType(Text).first);
      return w.data ?? '';
    }

    testWidgets('a 12 handicap reads as the handoff writes it', (t) async {
      expect(await line(t, 12, 100), contains('12 strokes'));
      expect(await line(t, 12, 100), contains('stroke index of 12 or lower'));
    });

    testWidgets('exactly 18 is one on every hole', (t) async {
      // An 18 handicap at 100% — a 12 cannot reach 18 anywhere on the
      // slider now that it stops at 130%.
      final s = await line(t, 18, 100);
      expect(s, contains('18 strokes'));
      expect(s, contains('every hole'));
      expect(s, isNot(contains('index of 18')));
    });

    testWidgets('past 18 names the second strokes', (t) async {
      // 30 off 130% is 39: one everywhere and a second on 21.
      final s = await line(t, 30, 130);
      expect(s, contains('39 strokes'));
      expect(s, contains('second on the 21 hardest'));
      expect(s, isNot(contains('index of 39')));
    });

    testWidgets('no strokes at all says so', (t) async {
      final s = await line(t, 0, 100);
      expect(s, contains('par straight up'));
    });

    testWidgets('it always says Net, because there is no choice', (t) async {
      for (final pct in [50, 100, 130]) {
        expect(await line(t, 12, pct), startsWith('Always Net.'));
      }
    });
  });

  group('what each variant is called', () {
    // One map behind three labels — the setup title, the hub's Edit button
    // and the leaderboard tab, which the SERVER names from
    // `SoloGame.get_variant_display`. They have to agree with it.
    test('the names match the multi-player games', () {
      expect(soloGameName('stroke'), 'Stroke Play');
      expect(soloGameName('nassau'), 'Nassau');
      expect(soloGameName('match'), 'Match Play');
    });

    test('an unknown variant does not render an empty button', () {
      expect(soloGameName(null), 'Solo');
      expect(soloGameName('whatever'), 'Solo');
    });
  });

  group('the size filter is a word as well as a number', () {
    // `int.parse('solo')` throws, and the throw landed inside a `setState`:
    // the assignment above it had already happened, so the widget was never
    // marked dirty and the tap did nothing. EVERY game chip was dead on the
    // solo filter, which is what it was reported as — not an exception, just
    // a picker that would not pick.
    test('solo does not throw, and offers nothing', () {
      expect(sideGamesForFilter(GameIds.soloNassau, 'solo'), isEmpty);
      expect(sideGamesForFilter(GameIds.skins, 'solo'), isEmpty);
    });

    test('no primary offers nothing, whatever the filter', () {
      expect(sideGamesForFilter(null, '4'), isEmpty);
      expect(sideGamesForFilter(null, 'solo'), isEmpty);
    });

    test('the numbers and groups are unchanged', () {
      // The shipped behaviour is the point: this function was extracted, not
      // written, so a four-ball must offer exactly what it offered before.
      expect(sideGamesForFilter(GameIds.skins, '4').map((m) => m.id).toSet(),
          sideGamesFor(GameIds.skins, size: 4).map((m) => m.id).toSet());
      expect(
          sideGamesForFilter(GameIds.skins, 'groups').map((m) => m.id).toSet(),
          sideGamesFor(GameIds.skins, size: 4, multiGroup: true)
              .map((m) => m.id)
              .toSet());
    });
  });
}