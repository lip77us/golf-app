/// test/skins_junk_test.dart
/// ------------------------
/// Skins junk, set up like Spots — and built on the same widgets.
///
/// What is worth pinning here is NOT the tick sheet or the greenie card:
/// those are `spots_types_test.dart`'s, and the whole point of the handoff
/// is that there is one of each. What is pinned is that junk reaches them,
/// that the stepper is gone from both screens that had it, and the two
/// places junk legitimately differs from spots.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/spots_capture.dart';

SkinsSummary _summary(Map<String, dynamic> over) => SkinsSummary.fromJson({
      'status': 'in_progress',
      'allow_junk': true,
      'players': const [],
      'holes': const [],
      'money': const {'bet_unit': 1.0, 'pool': 4.0, 'total_skins': 0},
      ...over,
    });

const _sandy   = {'type': 'sandy',   'label': 'Sandy',   'worth': 1};
const _chippy  = {'type': 'chippy',  'label': 'Chippy',  'worth': 1};
const _greenie = {'type': 'greenie', 'label': 'Greenie', 'worth': 1};
const _birdie  = {'type': 'birdie',  'label': 'Birdie',  'worth': 1};

void main() {
  group('junk reads like spots', () {
    test('the sheet offers ticks, never the greenie or a birdie', () {
      final s = _summary({
        'junk_in_play': const [_greenie, _sandy, _birdie],
        'junk_sheet_types': const [_sandy],
      });
      expect(s.junkSheetTypes.map((t) => t.type), ['sandy']);
      expect(s.junkInPlay.length, 3);
      expect(s.junkGreenieInPlay, isTrue);
    });

    test("a golfer's button shows only his SHEET types", () {
      final s = _summary({
        'junk_sheet_types': const [_sandy],
        'junk_in_play': const [_sandy, _birdie],
        'holes': [
          {'hole': 7, 'winner_id': null, 'skins_value': 1, 'is_carry': false,
           'junk': [
             {'player_id': 1, 'short_name': 'A', 'count': 2,
              'types': [_sandy, _birdie]},
           ]},
        ],
      });
      expect(s.junkSheetTypesFor(1, 7).map((t) => t.type), ['sandy']);
      // ...while the hole's own line reports the birdie, which is the only
      // place a derived junk is visible.
      expect(s.junkTypesFor(1, 7).map((t) => t.type), ['sandy', 'birdie']);
    });

    testWidgets('the button is the SAME one, with a different noun',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Column(children: [
          SpotsButton(types: const [], onTap: () {}, noun: 'Junk'),
          SpotsButton(types: [
            SpotTypeInfo.fromJson(_sandy),
            SpotTypeInfo.fromJson(_chippy),
          ], onTap: () {}, noun: 'Junk'),
        ])),
      ));
      expect(find.text('Junk'), findsOneWidget);       // + Junk
      expect(find.text('Sandy, Chippy'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('junk has no plural — "3 junk", never "3 junks"',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (ctx) => TextButton(
          onPressed: () => showModalBottomSheet<List<String>>(
            context: ctx,
            builder: (_) => buildExtrasSheet(
              title: 'A · hole 7',
              offered: [SpotTypeInfo.fromJson(_sandy)],
              initial: const {},
              noun: 'junk',
              nounPlural: 'junk',
            ),
          ),
          child: const Text('open'),
        ))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Done · 0 junk'), findsOneWidget);
      expect(find.textContaining('Tick each junk he made'), findsOneWidget);
    });
  });

  group('where junk legitimately differs', () {
    test('a round played BEFORE junk had names keeps its count, unnamed', () {
      // Sixteen such rows exist in four completed rounds. They are read and
      // never rewritten, so the board shows the number without inventing a
      // label for it.
      final s = _summary({
        'junk_sheet_types': const [_sandy],
        'holes': [
          {'hole': 5, 'winner_id': null, 'skins_value': 1, 'is_carry': false,
           'junk': [{'player_id': 1, 'short_name': 'A', 'count': 2}]},
        ],
      });
      expect(s.junkTypesFor(1, 5), isEmpty);
      expect(s.holes.first.junk.first.count, 2);
    });

    test('junk OFF reports nothing in play', () {
      final s = _summary({'allow_junk': false});
      expect(s.junkInPlay, isEmpty);
      expect(s.junkSheetTypes, isEmpty);
    });
  });

  group('the stepper is gone', () {
    test('neither screen that had it still threads a junk COUNT', () {
      // Both batched edits into a pending map and flushed them on the way to
      // the next hole. The sheet posts on Done, so there is nothing to
      // flush — and a screen left on the old shape would compile and then
      // post a body the server refuses.
      for (final name in ['score_entry', 'skins']) {
        final src = File('lib/screens/${name}_screen.dart').readAsStringSync();
        expect(src.contains('_JunkDots'), isFalse, reason: '$name: _JunkDots');
        expect(src.contains('onJunkAdd'), isFalse, reason: '$name: onJunkAdd');
        expect(src.contains('junk_count'), isFalse,
            reason: '$name: posts the old shape');
        expect(src.contains('_pendingJunk'), isFalse,
            reason: '$name: still batching');
        expect(src.contains('openJunkSheet'), isTrue,
            reason: '$name: no tick sheet');
      }
    });

    test('the par-3 greenie reaches both screens too', () {
      // The games with their own play screen are the ones that get missed.
      for (final name in ['score_entry', 'skins']) {
        final src = File('lib/screens/${name}_screen.dart').readAsStringSync();
        expect(src.contains('junkFooter(') || src.contains('junkFooters('),
            isTrue, reason: '$name: no greenie / this-hole footer');
      }
    });

    test('the setup screen does not name a type itself', () {
      final src =
          File('lib/screens/skins_setup_screen.dart').readAsStringSync();
      for (final label in ['Eagle or better', 'Greenie', 'Barky', 'Hogan']) {
        expect(src.contains("'" + label + "'"), isFalse,
            reason: 'skins_setup_screen names $label itself');
      }
    });
  });
}
