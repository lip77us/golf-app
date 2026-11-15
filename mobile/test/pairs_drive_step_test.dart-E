/// test/pairs_drive_step_test.dart
/// -------------------------------
/// The drive step's quota ceiling, and the three jobs the tee-shot control
/// does (docs/design-review/handoff-team-pairs/SPEC.md §5).
///
/// **The ceiling scales with the team size**, and the shipped 2-and-4 was four
/// men's answer hardcoded. Four golfers sharing nine holes top out at two drives
/// each; two golfers sharing the same nine top out at four each, and nine each
/// across eighteen — every hole spoken for and nothing left over.
///
/// This is mirrored from `TeamPlayConfig.max_drives_per_golfer`, because the
/// wizard sets it before the config row exists and cannot ask the server. That
/// is exactly the kind of duplicate rule that drifts, so it is pinned here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/team_allowance.dart';
import 'package:golf_mobile/widgets/team_play/team_drive_step.dart';

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  Future<void> pumpTall(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(child);
    await tester.pump();
  }

  int? lastDrives;

  Widget harness({
    int teamSize = 2,
    String format = 'scramble',
    String rule = 'per_nine',
    int drives = 1,
    List<String> rules = const ['none', 'per_nine', 'per_eighteen'],
  }) =>
      MaterialApp(
        home: Scaffold(
          body: TeamDriveStep(
            teamSize        : teamSize,
            format          : format,
            rulesAllowed    : rules,
            rule            : rule,
            drivesRequired  : drives,
            penalty         : 'warn',
            hasShortTeam    : false,
            onRule          : (_) {},
            onDrivesRequired: (n) => lastDrives = n,
            onPenalty       : (_) {},
          ),
        ),
      );

  /// Tap the stepper's `+` until it stops moving, and report where it stopped.
  Future<int> ceiling(WidgetTester tester,
      {required int teamSize, required String rule}) async {
    var value = 1;
    for (var i = 0; i < 24; i++) {
      lastDrives = null;
      await pumpTall(tester,
          harness(teamSize: teamSize, rule: rule, drives: value));
      await tester.tap(find.byIcon(Icons.add).first, warnIfMissed: false);
      await tester.pump();
      if (lastDrives == null) break;      // the + went dead: this is the cap
      value = lastDrives!;
    }
    return value;
  }

  group('the quota ceiling scales with the team size', () {
    testWidgets('a pair tops out at four drives each per nine',
        (tester) async {
      expect(await ceiling(tester, teamSize: 2, rule: 'per_nine'), 4);
    });

    testWidgets('a pair tops out at nine each across eighteen',
        (tester) async {
      expect(await ceiling(tester, teamSize: 2, rule: 'per_eighteen'), 9);
    });

    testWidgets('a foursome is unchanged — two per nine', (tester) async {
      expect(await ceiling(tester, teamSize: 4, rule: 'per_nine'), 2);
    });

    testWidgets('a foursome is unchanged — four across eighteen',
        (tester) async {
      expect(await ceiling(tester, teamSize: 4, rule: 'per_eighteen'), 4);
    });
  });

  group('what the quota reads as it fills', () {
    testWidgets('four each per nine is eight of nine, one free',
        (tester) async {
      await pumpTall(tester, harness(drives: 4));
      expect(find.text('8'), findsOneWidget);     // REQUIRED / NINE
      expect(find.text('9'), findsOneWidget);     // HOLES
      expect(find.text('1'), findsOneWidget);     // FREE / NINE
    });

    testWidgets('at the ceiling the slack note gives way to the warning',
        (tester) async {
      // The note argues from the room a pair has; at nine each across eighteen
      // there is none, and saying "a lot of room — 0 holes are free" would be
      // the screen contradicting itself.
      await pumpTall(tester,
          harness(rule: 'per_eighteen', drives: 9));
      expect(find.textContaining('a lot of room'), findsNothing);
      expect(find.textContaining('No slack at all'), findsOneWidget);
    });

    testWidgets('below the ceiling the note counts the free holes',
        (tester) async {
      await pumpTall(tester, harness(drives: 1));
      expect(find.textContaining('7 holes are free'), findsOneWidget);
    });
  });

  group('the format decides which rules exist', () {
    testWidgets('best ball has no drive control at all', (tester) async {
      await pumpTall(tester,
          harness(format: 'best_ball', rule: 'none', rules: const ['none']));
      expect(find.textContaining('Nothing to set'), findsOneWidget);
      expect(find.text('Per nine'), findsNothing);
    });

    testWidgets('alternate shot is a rota, not a quota', (tester) async {
      await pumpTall(tester, harness(
          format: 'alternate_shot', rule: 'alternating',
          rules: const ['alternating']));
      expect(find.textContaining('nothing to fall short of'), findsOneWidget);
      expect(find.text('Per nine'), findsNothing);
    });

    testWidgets('scotch keeps the tap whichever rule is picked',
        (tester) async {
      await pumpTall(tester, harness(format: 'scotch', rule: 'none'));
      expect(find.textContaining('happens on every hole in Scotch'),
             findsOneWidget);
    });
  });

  group('a step with nothing to set is not a step', () {
    // In best ball and Chapman both golfers drive every hole: no drive to choose,
    // no quota to count, no penalty to apply. The wizard drops the step rather
    // than showing a page whose only content says there is nothing on it.
    test('best ball and chapman have no drive step', () {
      expect(hasDriveStep(2, 'best_ball'), isFalse);
      expect(hasDriveStep(2, 'chapman'), isFalse);
    });

    test('alternate shot keeps its step despite having no control', () {
      // The rota is a real thing that happens on the course, and the step is
      // the only place the TD is told it is coming.
      expect(hasDriveStep(2, 'alternate_shot'), isTrue);
      expect(driveRulesFor(2, 'alternate_shot'), ['alternating']);
    });

    test('the formats with a choice keep theirs', () {
      expect(hasDriveStep(2, 'scramble'), isTrue);
      expect(hasDriveStep(2, 'scotch'), isTrue);
      expect(hasDriveStep(4, 'scramble'), isTrue);
      expect(hasDriveStep(4, 'shamble'), isTrue);
    });

    test('alternating pairs stays a fours rule', () {
      // Two golfers have no pairs to alternate; their rota IS alternate shot.
      expect(driveRulesFor(2, 'scramble'), isNot(contains('alternating')));
      expect(driveRulesFor(4, 'scramble'), contains('alternating'));
    });

    test('the ceiling helper agrees with the widget', () {
      expect(maxDrivesPerGolfer(2, 'per_nine'), 4);
      expect(maxDrivesPerGolfer(2, 'per_eighteen'), 9);
      expect(maxDrivesPerGolfer(4, 'per_nine'), 2);
      expect(maxDrivesPerGolfer(4, 'per_eighteen'), 4);
    });
  });
}
