import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/round_complete.dart';

/// Reported from TPSGC Fall Scramble 2026 (30 Oct 2026): *"I can not close
/// the Fall scramble. It stays in my active tab no matter what."*
///
/// Ten of its fourteen groups never entered a score, so the server was right
/// to hold the round open — and the TD's force, built for exactly this, lived
/// in `score_entry_screen` alone. A Foursome Play round never opens that
/// screen; its only Complete Round button is the hub's, which posted no
/// `force` and then navigated to the leaderboard anyway, so the tap looked
/// like it had worked.

/// The ten groups that actually held round 493 open.
List<Map<String, dynamic>> _fallScramble() => [
      {'group_number': 1, 'name': 'Group 1', 'holes_scored': 0, 'holes_expected': 18},
      {'group_number': 4, 'name': 'Group 4', 'holes_scored': 13, 'holes_expected': 18},
      {'group_number': 5, 'name': 'Group 5', 'holes_scored': 0, 'holes_expected': 18},
      {'group_number': 8, 'name': 'Group 8', 'holes_scored': 0, 'holes_expected': 18},
      {'group_number': 9, 'name': 'Group 9', 'holes_scored': 1, 'holes_expected': 18},
      {'group_number': 10, 'name': 'Group 10', 'holes_scored': 0, 'holes_expected': 18},
      {'group_number': 11, 'name': 'Group 11', 'holes_scored': 1, 'holes_expected': 18},
      {'group_number': 12, 'name': 'Group 12', 'holes_scored': 1, 'holes_expected': 18},
      {'group_number': 13, 'name': 'Group 13', 'holes_scored': 0, 'holes_expected': 18},
      {'group_number': 14, 'name': 'Group 14', 'holes_scored': 0, 'holes_expected': 18},
    ];

Future<bool?> _open(
  WidgetTester t,
  List<Map<String, dynamic>> outstanding, {
  Size size = const Size(400, 800),
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  bool? result;
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async =>
              result = await confirmForceComplete(ctx, outstanding),
          child: const Text('go'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
  return result;
}

String _content(WidgetTester t) => t
    .widgetList<Text>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(Text)))
    .map((w) => w.data ?? '')
    .join('\n');

void main() {
  group('the dialog names the groups', () {
    testWidgets('every outstanding group, with its hole count', (t) async {
      await _open(t, _fallScramble());
      final body = _content(t);
      expect(body, contains('10 groups have not finished:'));
      // The two facts a TD acts on: which group, and how far it got.
      expect(body, contains('Group 1 — 0 of 18 holes'));
      expect(body, contains('Group 4 — 13 of 18 holes'));
      expect(body, contains('Group 9 — 1 of 18 holes'));
    });

    testWidgets('one group is singular', (t) async {
      await _open(t, [
        {'group_number': 7, 'name': 'Group 7', 'holes_scored': 0, 'holes_expected': 18}
      ]);
      expect(_content(t), contains('One group has not finished:'));
    });

    testWidgets('a group with no name falls back to its number', (t) async {
      await _open(t, [
        {'group_number': 7, 'holes_scored': 2, 'holes_expected': 18}
      ]);
      expect(_content(t), contains('Group 7 — 2 of 18 holes'));
    });

    testWidgets('it says what closing costs and that it can be reopened',
        (t) async {
      await _open(t, _fallScramble());
      final body = _content(t);
      expect(body, contains('counts for nothing'));
      expect(body, contains('reopen'));
    });

    testWidgets('ten groups fit on a phone without overflowing', (t) async {
      // The real case. A dialog that overflows is one the TD cannot read to
      // the Close button.
      await _open(t, _fallScramble(), size: const Size(375, 667));
      expect(t.takeException(), isNull);
      expect(find.text('Close the round'), findsOneWidget);
    });
  });

  group('the answer', () {
    testWidgets('Keep it open leaves the round alone', (t) async {
      final r = await _open(t, _fallScramble());
      await t.tap(find.text('Keep it open'));
      await t.pumpAndSettle();
      expect(r ?? false, isFalse);
    });

    testWidgets('Close the round confirms', (t) async {
      await _open(t, _fallScramble());
      await t.tap(find.text('Close the round'));
      await t.pumpAndSettle();
      // The dialog closed on the affirmative action.
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('one place owns the flow', () {
    // The bug was a second answer: the force in one screen, a plain complete
    // in the other. Anything that can host a FIELD must come through the
    // shared helper — the nine single-foursome play screens are exempt and
    // say so in `round_complete.dart`.
    const hosts = [
      'lib/screens/round_screen.dart',
      'lib/screens/score_entry_screen.dart',
    ];

    for (final f in hosts) {
      test('$f completes through the shared helper', () {
        final src = File(f).readAsStringSync();
        expect(src, contains('completeRoundOrOfferForce('),
            reason: '$f must offer the TD the force');
        expect(src.contains('rp.completeRound('), isFalse,
            reason: '$f posts a plain complete, so no force is ever offered');
      });
    }

    test('the provider reports the status the SERVER returned', () {
      // Writing 'complete' locally made the hub swap to Final Results over a
      // round the server had left open.
      final src = File('lib/providers/round_provider.dart').readAsStringSync();
      final i = src.indexOf('Future<Leaderboard?> completeRound(');
      expect(i, greaterThan(0));
      final body = src.substring(i, i + 1600);
      expect(body.contains("status:      'complete'"), isFalse,
          reason: 'the local round must take lb.status, not assume complete');
      expect(body, contains('status:      lb.status'));
    });
  });
}
