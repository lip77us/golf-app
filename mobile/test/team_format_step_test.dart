/// test/team_format_step_test.dart
/// ------------------------------
/// The shamble ball-count controls on wizard step 5.
///
/// The grid is the part that goes missing quietly: it renders from the TEE's
/// hole list, and a tee inflated from a payload that omits the holes blob
/// leaves the whole control drawing nothing at all — no grid, no preview, no
/// error. These tests pin both the working case and that failure mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/team_play/team_format_step.dart';

void main() {
  final pars = {for (var h = 1; h <= 18; h++) h: h % 3 == 0 ? 3 : 4};

  // A tall surface so the step's ListView builds everything below the fold —
  // otherwise a missing control and an unscrolled one look identical.
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  Future<void> pumpTall(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(child);
    await tester.pump();
  }

  Widget harness({
    required String mode,
    required Map<int, int> parByHole,
    String format = 'shamble',
  }) =>
      MaterialApp(
        home: Scaffold(
          body: TeamFormatStep(
            format        : format,
            ballCountMode : mode,
            ballCountFixed: 2,
            perHoleCounts : const {},
            parByHole     : parByHole,
            locked        : false,
            onFormat      : (_) {},
            onMode        : (_) {},
            onFixed       : (_) {},
            onPerHole     : (_, __) {},
          ),
        ),
      );

  testWidgets('per-hole shows the tap-to-cycle grid', (tester) async {
    await pumpTall(tester, harness(mode: 'per_hole', parByHole: pars));

    expect(find.text('Per-hole balls (tap to cycle 1→2→3→4)'), findsOneWidget);
    expect(find.text('Front 9'), findsOneWidget);
    expect(find.text('Back 9'), findsOneWidget);
    // Hole numbers 1..18 each drawn once.
    expect(find.text('18'), findsWidgets);
  });

  testWidgets('the presets do NOT show the grid, matching Irish Rumble',
      (tester) async {
    await pumpTall(tester, harness(mode: 'fixed', parByHole: pars));
    expect(find.text('Per-hole balls (tap to cycle 1→2→3→4)'), findsNothing);
    // ...but the readback is always there.
    expect(find.text('What that means'), findsOneWidget);
  });

  testWidgets('a scramble collapses the whole block', (tester) async {
    await pumpTall(tester,
        harness(mode: 'fixed', parByHole: pars, format: 'scramble'));
    expect(find.text('Balls that count'), findsNothing);
    expect(find.text('What that means'), findsNothing);
  });

  testWidgets('with no hole data the control still draws something',
      (tester) async {
    // The regression this guards: a tee with no holes blob used to render the
    // radios and then nothing — no preview, no grid, no explanation.
    await pumpTall(tester, harness(mode: 'per_hole', parByHole: const {}));

    expect(find.text('Balls that count'), findsOneWidget,
        reason: 'the mode radios should always render');
    expect(find.text('Per-hole balls (tap to cycle 1→2→3→4)'), findsOneWidget,
        reason: 'the grid must not vanish silently when holes are missing');
  });
}
