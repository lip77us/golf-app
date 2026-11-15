import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/game_switcher.dart';

/// Pumps the switcher over a real TabController + TabBarView, because the
/// thumb's whole job is to follow that controller.
Future<TabController> _pump(WidgetTester t, List<String> labels,
    {double width = 390}) async {
  late TabController controller;
  // The SURFACE has to shrink, not just the MediaQuery: the default test
  // window is 800 wide, so a phone-width assertion made against it means
  // nothing.
  await t.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: DefaultTabController(
        length: labels.length,
        child: Builder(builder: (context) {
          controller = DefaultTabController.of(context);
          return Scaffold(
            body: Column(children: [
              GameSwitcher(controller: controller, labels: labels),
              Expanded(
                child: TabBarView(
                  controller: controller,
                  children: [for (final l in labels) Center(child: Text(l))],
                ),
              ),
            ]),
          );
        }),
      ),
    ),
  ));
  await t.pumpAndSettle();
  return controller;
}

/// Scoped to the switcher: the TabBarView pages carry the same words, and an
/// unscoped finder picks whichever comes first in the tree — which may be
/// off-screen, so the tap silently misses.
Finder _inSwitcher(String label) => find.descendant(
      of: find.byType(GameSwitcher),
      matching: find.text(label),
    );

void main() {
  group('it draws every game', () {
    testWidgets('one label each', (t) async {
      await _pump(t, ['Stroke Play', 'Skins', 'Settlement']);
      for (final l in ['Stroke Play', 'Skins', 'Settlement']) {
        expect(find.text(l), findsWidgets);
      }
    });

    testWidgets('nothing at all when there are no games', (t) async {
      await t.pumpWidget(MaterialApp(
        home: DefaultTabController(
          length: 0,
          child: Builder(builder: (c) => Scaffold(
                body: GameSwitcher(
                    controller: DefaultTabController.of(c),
                    labels: const []),
              )),
        ),
      ));
      expect(find.byType(SingleChildScrollView), findsNothing);
    });
  });

  group('tapping moves the controller, not just the thumb', () {
    testWidgets('a tap selects that game', (t) async {
      final c = await _pump(t, ['Stroke Play', 'Skins', 'Settlement']);
      expect(c.index, 0);
      // The test font is square-per-glyph, so these labels are far wider
      // here than on a device and the last one starts off-screen. Scroll it
      // in first — which is what the strip is FOR, and what a user does.
      await t.ensureVisible(_inSwitcher('Settlement'));
      await t.pumpAndSettle();
      await t.tap(_inSwitcher('Settlement'));
      await t.pumpAndSettle();
      expect(c.index, 2);
    });

    testWidgets('the body follows, because they share one controller',
        (t) async {
      final c = await _pump(t, ['Stroke Play', 'Skins']);
      await t.tap(_inSwitcher('Skins'));
      await t.pumpAndSettle();
      expect(c.index, 1);
      // The page it swapped to carries the same word, outside the switcher.
      expect(find.text('Skins'), findsNWidgets(2));
    });
  });

  group('the thumb tracks the swipe', () {
    testWidgets('a half-finished drag leaves it between two games',
        (t) async {
      final c = await _pump(t, ['Stroke Play', 'Skins', 'Settlement']);
      // Drag the PAGE half a width — the controller's animation is then a
      // fractional index, which is the thing an index cannot describe.
      await t.drag(find.byType(TabBarView), const Offset(-195, 0));
      await t.pump();
      final v = c.animation!.value;
      expect(v, greaterThan(0.0));
      expect(v, lessThan(1.0));
      await t.pumpAndSettle();
    });

    testWidgets('the active label is deep pine, the others muted', (t) async {
      await _pump(t, ['Stroke Play', 'Skins']);
      final active = t.widget<Text>(_inSwitcher('Stroke Play'));
      final other  = t.widget<Text>(_inSwitcher('Skins'));
      expect(active.style?.color, Halved.deepPine);
      expect(other.style?.color, Halved.muted);
    });
  });

  group('it scrolls rather than squeezing', () {
    testWidgets('a long game list stays scrollable', (t) async {
      await _pump(t, [
        'Stroke Play', 'Skins', 'Nassau', 'Stableford', 'Sixes',
        'Spots', 'Honors', 'Settlement',
      ], width: 390);
      final sv = t.widget<SingleChildScrollView>(
          find.byType(SingleChildScrollView));
      expect(sv.scrollDirection, Axis.horizontal);
      // Eight games cannot fit 390pt — the strip is wider than the viewport.
      final box = t.getSize(find.byType(GameSwitcher));
      expect(box.width, lessThanOrEqualTo(390));
    });

    testWidgets('a label is never truncated to make it fit', (t) async {
      // The thumb is sized to the LABEL, so a squeezed label would leave the
      // thumb describing a word nobody can read.
      await _pump(t, ['Stroke Play', 'Multi-Group Skins', 'Settlement']);
      final txt = t.widget<Text>(_inSwitcher('Multi-Group Skins'));
      expect(txt.maxLines, 1);
      expect(txt.overflow, isNot(TextOverflow.ellipsis));
    });
  });

  group('the leaderboard uses it', () {
    test('and no longer draws a TabBar', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect(src.contains('GameSwitcher('), isTrue);
      // Four packets: "Do not use pill or underline tabs."
      expect(RegExp(r'\bTabBar\(').hasMatch(src), isFalse,
          reason: 'the leaderboard is drawing underline tabs again');
    });
  });
}
