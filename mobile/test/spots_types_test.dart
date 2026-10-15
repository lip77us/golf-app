/// test/spots_types_test.dart
/// -------------------------
/// Spots' named types on the client: what the button says, what the sheet
/// offers, and the three facts the greenie card has to get right.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/spots_capture.dart';

SpotsSummary _summary(Map<String, dynamic> over) => SpotsSummary.fromJson({
      'status': 'in_progress',
      'payout_style': 'per_point',
      'players': const [],
      'holes': const [],
      'money': const {'bet_unit': 1.0, 'total_spots': 0},
      ...over,
    });

const _sandy  = {'type': 'sandy',  'label': 'Sandy',  'worth': 1};
const _chippy = {'type': 'chippy', 'label': 'Chippy', 'worth': 1};
const _snake  = {'type': 'snake',  'label': 'Snake',  'worth': -1};
const _greenie = {'type': 'greenie', 'label': 'Greenie', 'worth': 1};
const _birdie  = {'type': 'birdie',  'label': 'Birdie',  'worth': 1};

void main() {
  group('the button says what was ticked', () {
    testWidgets('empty it offers, filled it reports', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Column(children: [
          SpotsButton(types: const [], onTap: () {}),
          SpotsButton(types: [
            SpotTypeInfo.fromJson(_sandy),
            SpotTypeInfo.fromJson(_chippy),
          ], onTap: () {}),
        ])),
      ));
      expect(find.text('Spots'), findsOneWidget);          // + Spots
      expect(find.text('Sandy, Chippy'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);              // the badge
    });

    testWidgets('a snake takes the count DOWN', (tester) async {
      // The badge is a sum of WORTHS, not a count of ticks — a sandy and a
      // snake is zero, and the row has to be able to say so.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SpotsButton(types: [
          SpotTypeInfo.fromJson(_sandy),
          SpotTypeInfo.fromJson(_snake),
        ], onTap: () {})),
      ));
      expect(find.text('0'), findsOneWidget);
      expect(find.text('Sandy, Snake'), findsOneWidget);
    });
  });

  group('what the sheet may offer', () {
    test('never the greenie, never a birdie', () {
      // Greenie has its own pick and birdies come off the card, so a tick of
      // either would be a second, contradictory record of one fact. The
      // server decides this; these assert the client reads it.
      final s = _summary({
        'in_play': const [_greenie, _sandy, _birdie, _snake],
        'sheet_types': const [_sandy, _snake],
      });
      expect(s.sheetTypes.map((t) => t.type), ['sandy', 'snake']);
      expect(s.inPlay.length, 4);
      expect(s.greenieInPlay, isTrue);
    });

    test('a golfer\'s button shows only his SHEET types', () {
      // His birdie is real and counts; it just is not something he can
      // untick, so it must not appear on a control that unticks things.
      final s = _summary({
        'sheet_types': const [_sandy],
        'in_play': const [_sandy, _birdie],
        'holes': [
          {'hole': 7, 'spots': [
            {'player_id': 1, 'short_name': 'A', 'count': 2,
             'types': [_sandy, _birdie]},
          ]},
        ],
      });
      expect(s.sheetTypesFor(1, 7).map((t) => t.type), ['sandy']);
      // ...while the hole's own line reports everything, which is the only
      // place a derived spot is visible.
      expect(s.allTypesFor(1, 7).map((t) => t.type), ['sandy', 'birdie']);
      expect(s.countFor(1, 7), 2);
    });

    test('an unknown slug from a later server is ignored, not drawn', () {
      final s = _summary({
        'sheet_types': const [_sandy],
        'holes': [
          {'hole': 1, 'spots': [
            {'player_id': 1, 'short_name': 'A', 'count': 2,
             'types': [_sandy, {'type': 'ferret', 'label': 'Ferret'}]},
          ]},
        ],
      });
      expect(s.sheetTypesFor(1, 1).map((t) => t.type), ['sandy']);
    });
  });

  group('the greenie card', () {
    Future<void> pump(WidgetTester t, SpotsGreenieHole hole,
        {void Function(int?)? onPick}) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: GreenieCard(
          hole: hole,
          players: const [(id: 1, short: 'Paul'), (id: 2, short: 'Dave')],
          onPick: onPick ?? (_) {},
        )),
      ));
    }

    testWidgets('it names its worth and where a carry came from',
        (tester) async {
      await pump(tester, SpotsGreenieHole.fromJson(const {
        'hole': 7, 'worth': 2, 'carried_from': 4, 'decided': false,
      }));
      expect(find.text('Greenie · worth 2'), findsOneWidget);
      expect(find.text('Carried from the 4th'), findsOneWidget);
    });

    testWidgets('no chip when nothing carried', (tester) async {
      await pump(tester, SpotsGreenieHole.fromJson(
          const {'hole': 3, 'worth': 1}));
      expect(find.text('Greenie · worth 1'), findsOneWidget);
      expect(find.textContaining('Carried from'), findsNothing);
    });

    testWidgets('NOBODY is a choice in the row, not an absence',
        (tester) async {
      // It is what rolls the carry, so it has to be pickable — an undecided
      // hole and a Nobody hole are different states.
      int? picked;
      var called = false;
      await pump(tester, SpotsGreenieHole.fromJson(const {'hole': 3, 'worth': 1}),
          onPick: (p) { picked = p; called = true; });
      expect(find.text('Nobody'), findsOneWidget);
      await tester.tap(find.text('Nobody'));
      expect(called, isTrue);
      expect(picked, isNull);
    });

    testWidgets('the winner reads as selected', (tester) async {
      await pump(tester, SpotsGreenieHole.fromJson(const {
        'hole': 3, 'worth': 1, 'winner_id': 2, 'decided': true,
      }));
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
      final selected = [
        for (final c in chips)
          if (c.selected) ((c.label as Text).data ?? ''),
      ];
      expect(selected, ['Dave']);
    });
  });

  group('every type can explain itself', () {
    test('each one has a blurb', () {
      // A checklist row with no description is a slug with a tick box.
      for (final slug in ['greenie', 'sandy', 'poley', 'birdie', 'eagle',
                          'chippy', 'barky', 'snake', 'other']) {
        expect(spotTypeBlurb(slug), isNotEmpty, reason: '$slug has no blurb');
      }
    });

    test('the snake says it pays the other way', () {
      // The one type whose direction is the whole point of it.
      expect(spotTypeBlurb('snake').toLowerCase(),
          contains('pays everyone else'));
    });

    test('an unknown slug degrades to empty, not to a crash', () {
      expect(spotTypeBlurb('ferret'), '');
    });
  });

  group('the stepper is gone', () {
    test('no screen still threads a spots COUNT', () {
      // Spots are ticks of named types now. A screen left on the old
      // stepper would compile — `spotsCount` was an int and so is a lot of
      // things — and would silently post nothing the server accepts.
      for (final name in ['score_entry', 'wolf', 'points_531',
                          'sequoya_threes', 'quota_nassau', 'rabbit',
                          'survivor', 'nassau']) {
        final src = File('lib/screens/${name}_screen.dart').readAsStringSync();
        expect(src.contains('SpotsDots'), isFalse, reason: '$name: SpotsDots');
        expect(src.contains('onSpotsAdd'), isFalse, reason: '$name: onSpotsAdd');
        expect(src.contains('spotsCountFor'), isFalse,
            reason: '$name: spotsCountFor');
        // ...and each one offers the sheet AND the par-3 footer, because the
        // games with their own play screen are the ones that get missed.
        expect(src.contains('openSpotsSheet'), isTrue,
            reason: '$name: no tick sheet');
        expect(
            src.contains('greenieCards(') || src.contains('spotsFooter('),
            isTrue,
            reason: '$name: no greenie / this-hole footer');
      }
    });
  });
}
