/// The golfer rows from `handoff-score-entry-template`: the score box (shapes
/// coded to NET par, stroke dots inside it), the team header band, the keypad's
/// progress dots, and the row's own layout.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/forty_balls_keypad.dart';
import 'package:golf_mobile/widgets/score_box.dart';
import 'package:golf_mobile/widgets/side_header_band.dart';

Future<void> pumpBox(WidgetTester t, ScoreBox box) => t.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: box))));

BoxDecoration faceOf(WidgetTester t) {
  // The face is the 40pt container that carries the border.
  final c = t.widgetList<Container>(find.descendant(
      of: find.byType(ScoreBox), matching: find.byType(Container)));
  return c.map((e) => e.decoration).whereType<BoxDecoration>().firstWhere(
      (d) => d.border != null && d.color != null);
}

int dotCount(WidgetTester t) => t
    .widgetList<Container>(find.descendant(
        of: find.byType(ScoreBox), matching: find.byType(Container)))
    .where((c) {
      final d = c.decoration;
      return d is BoxDecoration &&
          d.shape == BoxShape.circle &&
          (d.color == Halved.deepPine || d.color == Halved.brightMint) &&
          c.constraints?.maxWidth == 5;
    }).length;

void main() {
  group('the score box is drawn as the score it holds, to NET par', () {
    testWidgets('empty: white, pine border, radius 10', (t) async {
      await pumpBox(t, const ScoreBox(score: null, par: 4));
      final d = faceOf(t);
      expect(d.color, Colors.white);
      expect(d.borderRadius, BorderRadius.circular(10));
      expect(t.getSize(find.byType(ScoreBox)), const Size(40, 40));
    });

    testWidgets('par is a #BFDCC6 square with a pine border', (t) async {
      await pumpBox(t, const ScoreBox(score: 4, par: 4));
      expect(faceOf(t).color, const Color(0xFFBFDCC6));
      expect(faceOf(t).borderRadius, BorderRadius.circular(10));
    });

    testWidgets('birdie is a pine circle with a white figure', (t) async {
      await pumpBox(t, const ScoreBox(score: 3, par: 4));
      expect(faceOf(t).color, Halved.pine);
      expect(faceOf(t).borderRadius, BorderRadius.circular(20));
    });

    testWidgets('eagle is a deep pine circle', (t) async {
      await pumpBox(t, const ScoreBox(score: 2, par: 4));
      expect(faceOf(t).color, Halved.deepPine);
      expect(faceOf(t).borderRadius, BorderRadius.circular(20));
    });

    testWidgets('bogey is a #FDF6EF square, radius 5', (t) async {
      await pumpBox(t, const ScoreBox(score: 5, par: 4));
      expect(faceOf(t).color, const Color(0xFFFDF6EF));
      expect(faceOf(t).borderRadius, BorderRadius.circular(5));
    });

    testWidgets('double bogey or worse is #FAEBDD', (t) async {
      await pumpBox(t, const ScoreBox(score: 7, par: 4));
      expect(faceOf(t).color, const Color(0xFFFAEBDD));
    });

    testWidgets('a stroke moves the baseline: a 5 on a par 4 off one is par',
        (t) async {
      await pumpBox(t, const ScoreBox(score: 5, par: 4, strokes: 1));
      expect(faceOf(t).color, const Color(0xFFBFDCC6));
    });

    testWidgets('with Net Style Entry off the dots stay and the baseline goes',
        (t) async {
      await pumpBox(
          t, const ScoreBox(score: 5, par: 4, strokes: 1, shapeStrokes: 0));
      expect(faceOf(t).color, const Color(0xFFFDF6EF), reason: 'a bogey');
      expect(dotCount(t), 1, reason: 'the stroke is still shown');
    });

    testWidgets('the figure is the gross score', (t) async {
      await pumpBox(t, const ScoreBox(score: 6, par: 4));
      expect(find.text('6'), findsOneWidget);
    });
  });

  group('the stroke dots are INSIDE the box', () {
    testWidgets('one dot per stroke', (t) async {
      for (final n in [1, 2, 3]) {
        await pumpBox(t, ScoreBox(score: null, par: 4, strokes: n));
        expect(dotCount(t), n, reason: '$n strokes');
      }
      await pumpBox(t, const ScoreBox(score: null, par: 4));
      expect(dotCount(t), 0);
    });

    testWidgets('they sit in the top right corner, inside the 40pt box',
        (t) async {
      await pumpBox(t, const ScoreBox(score: null, par: 4, strokes: 1));
      final box = t.getRect(find.byType(ScoreBox));
      final dot = t.getRect(find.descendant(
          of: find.byType(ScoreBox),
          matching: find.byWidgetPredicate((w) =>
              w is Container &&
              w.constraints?.maxWidth == 5 &&
              (w.decoration as BoxDecoration?)?.shape == BoxShape.circle)));
      expect(dot.right, lessThanOrEqualTo(box.right));
      expect(dot.top, greaterThanOrEqualTo(box.top));
      expect(dot.right, closeTo(box.right - 4, 0.5));
      expect(dot.top, closeTo(box.top + 4, 0.5));
    });

    testWidgets('on a dark circle they are mint, and set in further',
        (t) async {
      await pumpBox(t, const ScoreBox(score: 3, par: 4, strokes: 1));
      final dot = t.widgetList<Container>(find.descendant(
              of: find.byType(ScoreBox), matching: find.byType(Container)))
          .where((c) => c.constraints?.maxWidth == 5)
          .single;
      expect((dot.decoration as BoxDecoration).color, Halved.brightMint);
    });

    testWidgets('on a light box they are deep pine', (t) async {
      await pumpBox(t, const ScoreBox(score: 5, par: 4, strokes: 1));
      final dot = t.widgetList<Container>(find.descendant(
              of: find.byType(ScoreBox), matching: find.byType(Container)))
          .where((c) => c.constraints?.maxWidth == 5)
          .single;
      expect((dot.decoration as BoxDecoration).color, Halved.deepPine);
    });
  });

  group('the active box', () {
    testWidgets('gets a ring drawn OUTSIDE it, so the row never moves',
        (t) async {
      await pumpBox(t, const ScoreBox(score: null, par: 4, active: true));
      expect(t.getSize(find.byType(ScoreBox)), const Size(40, 40),
          reason: 'the ring is an outline, not layout');
      final rings = t.widgetList<Container>(find.descendant(
          of: find.byType(ScoreBox), matching: find.byType(Container)))
          .where((c) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.color == null &&
            d.border != null &&
            (d.border as Border).top.width == 2.5;
      });
      expect(rings.length, 1);
      // Outside the box by 2pt of offset plus its own 2.5 of line.
      final ring = t.widget<Positioned>(find.byWidgetPredicate(
          (w) => w is Positioned && w.left == -4.5));
      expect(ring.top, -4.5);
      expect(ring.right, -4.5);
      expect(ring.bottom, -4.5);
    });

    testWidgets('an inactive box has no ring', (t) async {
      await pumpBox(t, const ScoreBox(score: null, par: 4));
      final rings = t.widgetList<Container>(find.descendant(
          of: find.byType(ScoreBox), matching: find.byType(Container)))
          .where((c) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.border != null &&
            (d.border as Border).top.width == 2.5;
      });
      expect(rings, isEmpty);
    });
  });

  group('the team header band', () {
    testWidgets('is the caps label and nothing else', (t) async {
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: SideHeaderBand(label: 'Paul + Dave'))));
      expect(find.text('PAUL + DAVE'), findsOneWidget);
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('is a pale band across the card', (t) async {
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: SideHeaderBand(label: 'A'))));
      final box = t.widget<Container>(find.byType(Container).first);
      expect((box.decoration as BoxDecoration).color,
          const Color(0xFFF4F7F4));
    });

    test('Fourball, Las Vegas and Annandale all draw it', () {
      for (final f in [
        'lib/widgets/fourball_entry.dart',
        'lib/widgets/vegas_entry.dart',
        'lib/widgets/annandale_friday.dart',
      ]) {
        expect(File(f).readAsStringSync(), contains('SideHeaderBand('),
            reason: f);
      }
    });
  });

  group('the keypad progress dots', () {
    Future<void> pump(WidgetTester t,
        {List<bool>? progress, int? active}) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FortyBallsKeypad(
            playerName: 'Dave',
            par: 4,
            strokes: 0,
            progress: progress,
            activeIndex: active,
            onScore: (_) {},
            onClear: () {},
          ),
        ),
      ));
    }

    List<AnimatedContainer> dots(WidgetTester t) =>
        t.widgetList<AnimatedContainer>(find.byType(AnimatedContainer)).toList();

    testWidgets('one dot per golfer', (t) async {
      await pump(t, progress: [true, false, false, false], active: 1);
      expect(dots(t).length, 4);
    });

    testWidgets('entered is pine, active is a 20pt deep pill, the rest grey',
        (t) async {
      await pump(t, progress: [true, false, false, false], active: 1);
      await t.pumpAndSettle();
      final ds = dots(t);
      Color? colour(AnimatedContainer c) =>
          (c.decoration as BoxDecoration).color;
      expect(colour(ds[0]), Halved.pine);
      expect(colour(ds[1]), Halved.deepPine);
      expect(colour(ds[2]), Halved.cardBorder);
      expect(ds[1].constraints!.maxWidth, 20);
      expect(ds[0].constraints!.maxWidth, 8);
    });

    testWidgets('no progress draws nothing, which is every other game',
        (t) async {
      await pump(t);
      expect(dots(t), isEmpty);
    });

    testWidgets('the 10+ field hides them', (t) async {
      await pump(t, progress: [false, false], active: 0);
      await t.tap(find.text('10+'));
      await t.pump();
      expect(dots(t), isEmpty);
    });
  });

  group('the row', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();
    final row = src.substring(src.indexOf('class _PlayerRow'));

    test('it is 50pt with the side bar on the left edge', () {
      expect(row, contains('BoxConstraints(minHeight: 50)'));
      expect(row, contains('BorderSide(color: teamTint, width: 4)'));
    });

    test('the active row is a mint wash, not a frame', () {
      expect(row, contains('0x1F3BD89A'));
      // The old "entry section" box is gone.
      expect(src, isNot(contains('Square-cornered team-colour frame')));
    });

    test('it carries CH, the net pill and the score box', () {
      expect(row, contains("'CH \${member.courseHandicap}'"));
      expect(row, contains("const TextSpan(text: 'net ')"));
      // The figure is NET: the gross less the strokes on this hole.
      expect(row, contains("'\${gross! - strokesOnThisHole}'"));
      expect(row, contains('ScoreBox('));
    });

    test('the other rows are not dimmed', () {
      expect(row, isNot(contains('Opacity(opacity: 0.78')));
    });

    test('the keypad is given its progress dots', () {
      expect(src, contains('progress  : ['));
      expect(src, contains('activeIndex: fbIdx'));
    });
  });
}
