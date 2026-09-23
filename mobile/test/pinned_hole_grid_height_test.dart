/// test/pinned_hole_grid_height_test.dart
/// --------------------------------------
/// **A band's two halves are the same height, or the names stop naming the
/// rows they sit beside.**
///
/// `PinnedHoleGrid` takes the label out of the horizontal scroller so it stays
/// visible, which means the grid is two Columns rendered side by side. They
/// only look like one table while every band is the same height on both sides.
///
/// Length and order had no way to go wrong — the widget builds both halves
/// from one list. Height did: the label came straight from the caller. The
/// Survivor by-hole grid handed in a bare `Text` per golfer and an empty
/// `SizedBox` for the header, so the pinned column ran at the text's line
/// height while the scrolling half ran at 32, and the drift compounded until
/// the three names sat stacked ABOVE the grid. Reported from the course,
/// 22 Sep 2026.
///
/// `HoleGridBand.height` closes it. These are the claims that keep it closed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/pinned_hole_grid.dart';

const _label = 56.0;
const _cell = 34.0;

Widget _host(List<HoleGridBand> bands) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: PinnedHoleGrid(
            bands: bands, labelWidth: _label, cellWidth: _cell,
            holeCount: 9, currentIndex: -1,
          ),
        ),
      ),
    );

double _height(WidgetTester t, Finder f) => t.getSize(f).height;

void main() {
  testWidgets('**a declared height reaches BOTH halves**', (t) async {
    await t.pumpWidget(_host([
      HoleGridBand(const Text('Hole'), [for (var i = 0; i < 9; i++)
        SizedBox(width: _cell, height: 26, child: Text('h$i'))], height: 26),
      HoleGridBand(const Text('Paul'), [for (var i = 0; i < 9; i++)
        SizedBox(width: _cell, height: 32, child: Text('p$i'))], height: 32),
    ]));

    // The labels are bare `Text`s — the exact thing that broke — and the band
    // sizes them anyway, so each one lands on its own row's centre line.
    expect(t.getCenter(find.text('Hole')).dy,
           closeTo(t.getCenter(find.text('h0')).dy, 0.5));
    expect(t.getCenter(find.text('Paul')).dy,
           closeTo(t.getCenter(find.text('p0')).dy, 0.5));
  });

  testWidgets('**the row a name sits beside is its own**', (t) async {
    // The failure was not that a row was the wrong height; it was that the
    // pinned column drifted UP relative to the scrolling one, so `Larry` came
    // to sit beside Jim's scores. That is what this measures.
    await t.pumpWidget(_host([
      HoleGridBand(const Text('Hole'), [
        for (var i = 0; i < 9; i++)
          SizedBox(width: _cell, height: 26, child: Text('h$i'))
      ], height: 26),
      for (final n in const ['Paul', 'Jim', 'Larry'])
        HoleGridBand(Text(n), [
          for (var i = 0; i < 9; i++)
            SizedBox(width: _cell, height: 32, child: Text('$n$i'))
        ], height: 32),
    ]));

    for (final n in const ['Paul', 'Jim', 'Larry']) {
      // Vertical centres, because the name is centred in its band and a score
      // is centred in its cell.
      final name = t.getCenter(find.text(n)).dy;
      final score = t.getCenter(find.text('${n}0')).dy;
      expect((name - score).abs(), lessThan(0.5),
          reason: '$n is not beside $n\'s own scores');
    }
  });

  testWidgets('a rule keeps both halves in step too', (t) async {
    // A hairline is a row like any other: present on one side only, it is a
    // one-pixel drift that every band below inherits.
    await t.pumpWidget(_host([
      HoleGridBand(const Text('A'),
          [const SizedBox(width: _cell, height: 20)], height: 20),
      const HoleGridBand.rule(),
      HoleGridBand(const Text('B'),
          [const SizedBox(key: Key('b0'), width: _cell, height: 20)],
          height: 20),
    ]));
    expect(t.getCenter(find.text('B')).dy,
           closeTo(t.getCenter(find.byKey(const Key('b0'))).dy, 0.5));
  });

  testWidgets('bands without a height are left exactly as they were', (t) async {
    // Every grid predates the parameter and sizes its own label. The addition
    // has to be inert for them, or it is eighteen regressions rather than one
    // fix.
    await t.pumpWidget(_host([
      HoleGridBand(
        const SizedBox(
            key: Key('lbl'), width: _label, height: 40, child: Text('Sized')),
        [const SizedBox(width: _cell, height: 40)],
      ),
    ]));
    expect(_height(t, find.byKey(const Key('lbl'))), 40);
  });
}
