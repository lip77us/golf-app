// Every place a handicap is typed opens a pad, never the system keyboard.
// On iOS a signed decimal field gets the numbers-and-punctuation keyboard
// (an ABC key, letters one tap away) and a plain number pad has no Done key —
// both can be left on screen with nothing to dismiss them.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/index_sheet.dart';
import 'package:golf_mobile/widgets/index_tap_field.dart';
import 'package:golf_mobile/widgets/playing_hcp_sheet.dart';

void main() {
  group('the playing handicap pad', () {
    test('digits append, two at most, a leading zero is dropped', () {
      expect(playingHcpKey('', '1'), '1');
      expect(playingHcpKey('1', '2'), '12');
      expect(playingHcpKey('12', '3'), '12');
      expect(playingHcpKey('0', '7'), '7');
    });
    test('back removes one and is safe on empty', () {
      expect(playingHcpKey('12', 'back'), '1');
      expect(playingHcpKey('', 'back'), '');
    });

    Future<String?> open(WidgetTester t, String current) async {
      String? result = 'unset';
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showPlayingHcpSheet(c,
                  name: 'Dave Kelly', current: current),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return result;
    }

    testWidgets('typing and Save returns the digits', (t) async {
      await open(t, '');
      await t.tap(find.text('1'));
      await t.tap(find.text('4'));
      await t.pump();
      expect(find.text('14'), findsOneWidget);
      await t.tap(find.byKey(const Key('playing-hcp-save')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('playing-hcp-save')), findsNothing);
    });

    testWidgets('Save is dead until something is typed', (t) async {
      await open(t, '');
      final b = t.widget<FilledButton>(find.byKey(const Key('playing-hcp-save')));
      expect(b.onPressed, isNull);
    });

    testWidgets('Auto hands back an empty string, Cancel hands back null',
        (t) async {
      String? got = 'unset';
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () async => got = await showPlayingHcpSheet(c,
                  name: 'Dave', current: '9'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('playing-hcp-auto')));
      await t.pumpAndSettle();
      expect(got, '');

      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(got, isNull);
    });
  });

  group('the index field', () {
    testWidgets('shows a stored plus handicap the way golfers write it',
        (t) async {
      final c = TextEditingController(text: '-2.1');
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: IndexTapField(
              controller: c, name: 'Dave', owner: IndexOwner.guest),
        ),
      ));
      expect(find.text('+2.1'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing,
          reason: 'it must not be a text field — no system keyboard');
    });

    testWidgets('tapping opens the index pad, and saving writes the stored form',
        (t) async {
      final c = TextEditingController();
      String? changed;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: IndexTapField(
              controller: c,
              name: 'Dave',
              owner: IndexOwner.guest,
              onChanged: (v) => changed = v),
        ),
      ));
      await t.tap(find.byType(IndexTapField));
      await t.pumpAndSettle();
      expect(find.byType(IndexSheet), findsOneWidget);
    });
  });

  group('no screen types a handicap on the system keyboard', () {
    // The six places that did, now converted. A field here that brings the
    // keyboard back fails this, rather than a golfer finding it on a course.
    const files = [
      'lib/screens/player_form_screen.dart',
      'lib/screens/profile_setup_screen.dart',
      'lib/screens/settings_screen.dart',
      'lib/screens/profile_screen.dart',
      'lib/screens/confirm_tees_screen.dart',
      'lib/widgets/new_golfer_sheet.dart',
    ];
    for (final f in files) {
      test(f, () {
        final src = File(f).readAsStringSync();
        final lines = src.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('keyboardType') &&
              !lines[i].contains('keyboard:')) {
            continue;
          }
          final ctx = lines
              .sublist((i - 12).clamp(0, lines.length),
                  (i + 6).clamp(0, lines.length))
              .join('\n')
              .toLowerCase();
          final handicap = ctx.contains('handicap') ||
              ctx.contains('hcp') ||
              ctx.contains('_index');
          final numeric = lines[i].contains('number');
          expect(handicap && numeric, isFalse,
              reason: '$f:${i + 1} types a handicap on the system keyboard');
        }
      });
    }
  });
}
