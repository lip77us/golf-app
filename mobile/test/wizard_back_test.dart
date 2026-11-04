// The way out of a setup wizard.
//
// Reported from a 60-golfer Multi-Group Skins round (3 Nov 2026): "I got
// stuck in a dialog without an esc and the only option was back arrow which
// ended the wizard and I lost all of the players that I had added."
//
// Two things, and the second is this file. The casual wizard's app bar arrow
// POPPED THE ROUTE, where the tournament wizard's and the round-setup
// screen's have always stepped back through the wizard — so this screen was
// the one with two back affordances that meant different things, and the
// bigger one threw the draft away. It steps now, and leaving from the first
// step asks first.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/discard_draft.dart';

/// The body of a method, from its signature to the first line that closes it
/// at method indent. Anchored on the code rather than a character count: five
/// source guards in this repo have broken for a reworded comment above the
/// claim, which is how a guard comes to be deleted.
String _methodBody(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, greaterThan(-1), reason: 'no $signature');
  final end = src.indexOf('\n  }\n', start);
  expect(end, greaterThan(start), reason: '$signature never closes');
  return src.substring(start, end);
}

void main() {
  final casual = File('lib/screens/casual_round_screen.dart').readAsStringSync();

  group('the discard prompt', () {
    Future<bool?> ask(WidgetTester t, {bool added = false}) async {
      bool? answer;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  answer = await confirmDiscardDraft(ctx, addedGolfers: added),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      return answer;
    }

    testWidgets('keeps the draft unless the answer is Discard', (t) async {
      await ask(t);
      expect(find.text('Leave without creating the round?'), findsOneWidget);
      await t.tap(find.text('Keep setting up'));
      await t.pumpAndSettle();
      // Nothing is thrown away on a dismissal, and that includes the
      // dismissal Flutter gives you for free (barrier, system back).
      expect(find.text('go'), findsOneWidget);
    });

    testWidgets('says so when it means it', (t) async {
      await ask(t);
      await t.tap(find.text('Discard'));
      await t.pumpAndSettle();
      expect(find.text('Leave without creating the round?'), findsNothing);
    });

    testWidgets('reassures about added golfers ONLY when there are some',
        (t) async {
      // A golfer created inline is written to the roster as he is created, so
      // he survives the draft — which is the exact worry Paul reported. Said
      // on every back-out it would be noise.
      await ask(t, added: true);
      expect(find.textContaining('saved to My Golfers'), findsOneWidget);
      await t.tap(find.text('Keep setting up'));
      await t.pumpAndSettle();

      await ask(t);
      expect(find.textContaining('saved to My Golfers'), findsNothing);
    });
  });

  group('the casual wizard', () {
    test('the app bar arrow steps back instead of leaving', () {
      expect(casual.contains('leading: BackButton(onPressed: _back),'), isTrue,
          reason: 'the arrow is the affordance that ended the wizard');
    });

    test('and so does the system back', () {
      expect(casual.contains('canPop: false'), isTrue);
      expect(
          casual.contains('onPopInvokedWithResult: (didPop, _) '
              '{ if (!didPop) _back(); }'),
          isTrue,
          reason: 'a swipe-back must not drop the draft either');
    });

    test('_back is the only thing that steps', () {
      // Two back affordances with their own copies of the rule is how they
      // came to mean different things in the first place.
      expect(casual.split('_step - 1').length - 1, 1,
          reason: 'something other than _back() is stepping');
      final body = _methodBody(casual, 'Future<void> _back() async {');
      expect(body.contains('_step - 1'), isTrue);
      expect(body.contains('confirmDiscardDraft'), isTrue,
          reason: 'leaving step 0 with work in hand has to ask');
      expect(body.contains('Navigator.of(context).pop()'), isTrue);
    });

    test('leaving an untouched wizard asks nothing', () {
      // The logged-in golfer is ticked on load by the screen itself, so the
      // seeded selection is not work.
      final body = _methodBody(casual, 'bool get _hasWork =>');
      expect(body.contains('_seeded'), isTrue);
      expect(casual.contains('_seeded = _playerTees.keys.toSet();'), isTrue);
    });

    test('and nothing else pops this screen', () {
      // One way out, so there is one place the prompt has to be.
      expect(casual.split('Navigator.of(context).pop()').length - 1, 1);
    });
  });

  group('every setup wizard', () {
    // The failure this file is about is "reachable from one screen and not the
    // other" — so the family is checked, not just the screen that was
    // reported. The onboarding wizard is exempt by construction: it draws no
    // arrow at all (`automaticallyImplyLeading: false`) and offers Skip.
    const stepping = [
      'lib/screens/casual_round_screen.dart',
      'lib/screens/new_round_wizard.dart',
      'lib/screens/setup_round_players_screen.dart',
    ];

    for (final f in stepping) {
      test('$f: its arrow steps', () {
        expect(File(f).readAsStringSync().contains('BackButton(onPressed: _back)'),
            isTrue);
      });
    }

    test('the onboarding wizard draws no arrow', () {
      final src = File('lib/screens/onboarding_wizard.dart').readAsStringSync();
      expect(src.contains('automaticallyImplyLeading: false'), isTrue);
    });
  });
}
