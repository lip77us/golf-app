/// test/spots_types_test.dart
/// -------------------------
/// Spots' named types on the client: what the button says, what the sheet
/// offers, and the three facts the greenie card has to get right.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/spots_earned.dart';
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
const _greenie2 = {'type': 'greenie', 'label': 'Greenie', 'worth': 2};

/// The EXACT payload `GET /foursomes/855/spots/` returned for Paul's local
/// Tilden Park round on 15 Oct 2026, when he reported that the greenie could
/// not be selected on hole 7. Captured rather than hand-written, so this
/// tests the real shape and not my idea of it.
const _tildenPayload = r'''
{
    "status": "in_progress",
    "in_play": [
        {
            "type": "greenie",
            "label": "Greenie",
            "worth": 1
        },
        {
            "type": "sandy",
            "label": "Sandy",
            "worth": 1
        },
        {
            "type": "birdie",
            "label": "Birdie",
            "worth": 1
        },
        {
            "type": "eagle",
            "label": "Eagle or better",
            "worth": 2
        },
        {
            "type": "chippy",
            "label": "Chippy",
            "worth": 1
        }
    ],
    "sheet_types": [
        {
            "type": "sandy",
            "label": "Sandy",
            "worth": 1
        },
        {
            "type": "chippy",
            "label": "Chippy",
            "worth": 1
        }
    ],
    "greenie": {
        "carry": true,
        "needs_par": true,
        "holes": [
            {
                "hole": 4,
                "worth": 1,
                "carried_from": null,
                "winner_id": null,
                "decided": false,
                "missed": false,
                "pending_score": false,
                "winner_short": null
            },
            {
                "hole": 7,
                "worth": 1,
                "carried_from": null,
                "winner_id": null,
                "decided": false,
                "missed": false,
                "pending_score": false,
                "winner_short": null
            },
            {
                "hole": 11,
                "worth": 1,
                "carried_from": null,
                "winner_id": null,
                "decided": false,
                "missed": false,
                "pending_score": false,
                "winner_short": null
            },
            {
                "hole": 16,
                "worth": 1,
                "carried_from": null,
                "winner_id": null,
                "decided": false,
                "missed": false,
                "pending_score": false,
                "winner_short": null
            }
        ],
        "next": {
            "hole": 4,
            "worth": 1,
            "carried_from": null,
            "winner_id": null,
            "decided": false,
            "missed": false,
            "pending_score": false
        }
    },
    "birdie_basis": "net_so",
    "players": [
        {
            "player_id": 89,
            "name": "Paul Lipkin",
            "short_name": "Paul",
            "spots": 2,
            "payout": 5.0
        },
        {
            "player_id": 103,
            "name": "Ryan Lipkin",
            "short_name": "RyanL",
            "spots": 1,
            "payout": 1.0
        }
    ],
    "holes": [
        {
            "hole": 2,
            "spots": [
                {
                    "player_id": 89,
                    "short_name": "Paul",
                    "count": 2,
                    "types": [
                        {
                            "type": "birdie",
                            "label": "Birdie",
                            "worth": 1
                        },
                        {
                            "type": "chippy",
                            "label": "Chippy",
                            "worth": 1
                        }
                    ]
                }
            ]
        },
        {
            "hole": 6,
            "spots": [
                {
                    "player_id": 103,
                    "short_name": "RyanL",
                    "count": 1,
                    "types": [
                        {
                            "type": "birdie",
                            "label": "Birdie",
                            "worth": 1
                        }
                    ]
                }
            ]
        }
    ],
    "money": {
        "bet_unit": 1.0,
        "total_spots": 3
    }
}
''';

void main() {
  group('the payload from the round that could not select a greenie', () {
    // The server was right and so was the widget; what this pins is the
    // PARSE, which is the only link between them that a stale build hides.
    final s = SpotsSummary.fromJson(
        jsonDecode(_tildenPayload) as Map<String, dynamic>);

    test('greenie is in play', () {
      expect(s.greenieInPlay, isTrue);
      expect(s.inPlay.map((t) => t.type),
             ['greenie', 'sandy', 'birdie', 'eagle', 'chippy']);
    });

    test('every par 3 has a row, hole 7 among them', () {
      expect(s.greenie.holes.map((h) => h.hole), [4, 7, 11, 16]);
      expect(s.greenie.forHole(7), isNotNull);
      expect(s.greenie.forHole(7)!.worth, 1);
      // A par 4 has none, which is what keeps the card off every other hole.
      expect(s.greenie.forHole(5), isNull);
    });

    test('the carry is on and nothing is decided yet', () {
      expect(s.greenie.carry, isTrue);
      expect(s.greenie.holes.every((h) => !h.decided), isTrue);
      expect(s.greenie.next?.hole, 4);
    });

    test('the sheet offers the ticks and not the greenie', () {
      expect(s.sheetTypes.map((t) => t.type), ['sandy', 'chippy']);
    });
  });

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

  group('the button reads as a button', () {
    // Reported: "I am afraid people don't see the button and think they
    // have to press on the + key exactly."
    //
    // **The hit area was never the problem** — the whole pill has always
    // been inside the InkWell, and the first test below passed before any
    // of this changed. It is kept as the guard against somebody later
    // shrinking the target onto the glyph, which is the thing being feared.
    // What was actually wrong is everything that made it LOOK untappable:
    // 32pt tall, no fill, the faintest border token, muted grey text, and a
    // filled state that swallowed its own ripple.

    Future<Size> pumpButton(WidgetTester t, {required List<SpotTypeInfo> types,
                                             VoidCallback? onTap}) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SpotsButton(types: types, onTap: onTap ?? () {}),
          ),
        ),
      ));
      return t.getSize(find.byType(SpotsButton));
    }

    testWidgets('the WHOLE pill answers, not just the + glyph',
        (tester) async {
      var taps = 0;
      await pumpButton(tester, types: const [], onTap: () => taps++);
      final box = tester.getRect(find.byType(SpotsButton));
      // The far right edge, as far from the `+` as the control goes.
      await tester.tapAt(Offset(box.right - 4, box.center.dy));
      await tester.pump();
      expect(taps, 1, reason: 'the label end of the pill did not answer');
      // ...and the bottom edge, which a thumb finds before the glyph does.
      await tester.tapAt(Offset(box.center.dx, box.bottom - 3));
      await tester.pump();
      expect(taps, 2, reason: 'the bottom of the pill did not answer');
    });

    testWidgets('it is at least 38 tall, empty or filled', (tester) async {
      // Measured rather than asserted in a comment: it was 32, which is
      // under every touch-target guideline there is and reads as a chip.
      final emptySize = await pumpButton(tester, types: const []);
      expect(emptySize.height, greaterThanOrEqualTo(38));
      final filledSize = await pumpButton(tester, types: [
        SpotTypeInfo.fromJson(_sandy),
      ]);
      expect(filledSize.height, greaterThanOrEqualTo(38));
    });

    testWidgets('empty is drawn in the ACTION colour, not the muted one',
        (tester) async {
      // The old empty state used the three faintest tokens in the theme, on
      // a row carrying a bold name and a big score box.
      await pumpButton(tester, types: const []);
      final ctx = tester.element(find.byType(SpotsButton));
      final scheme = Theme.of(ctx).colorScheme;
      final label = tester.widget<Text>(find.text('Spots'));
      expect(label.style?.color, scheme.primary);
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, scheme.primary);
    });

    testWidgets('a tap leaves a ripple, in BOTH states', (tester) async {
      // A decoration painted by the InkWell's child paints over the splash,
      // which is what the filled state used to do to its own feedback. A
      // control that does not flinch when touched is one people decide is
      // not a control.
      for (final types in [<SpotTypeInfo>[],
                           [SpotTypeInfo.fromJson(_sandy)]]) {
        await pumpButton(tester, types: types);
        final gesture =
            await tester.startGesture(tester.getCenter(find.byType(SpotsButton)));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(InkWell), findsOneWidget);
        final material = tester.widget<Material>(
            find.ancestor(of: find.byType(InkWell),
                          matching: find.byType(Material)).first);
        expect(material.color, Colors.transparent,
            reason: 'the ink has no transparent Material to paint into');
        await gesture.up();
        await tester.pumpAndSettle();
      }
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

  group('where a man looks for the greenie', () {
    // Reported from a par 3: "did not see Greeny on the list", with the
    // sheet open showing Sandy and Chippy. The greenie is a pick at the
    // foot of the card because only one golfer can win it — but a list that
    // silently omits the type he came looking for reads as the type being
    // missing, not as it living somewhere better.
    Future<void> pumpSheet(WidgetTester t, {required bool onThisHole}) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (ctx) => TextButton(
            onPressed: () => showModalBottomSheet<List<String>>(
              context: ctx,
              builder: (_) => spotsSheetForTest(
                title: 'Ryan · hole 7',
                offered: [
                  SpotTypeInfo.fromJson(_sandy),
                  SpotTypeInfo.fromJson(_chippy),
                ],
                initial: const {},
                greenieOnThisHole: onThisHole,
              ),
            ),
            child: const Text('open'),
          )),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('on a par 3 the sheet says where it is', (tester) async {
      await pumpSheet(tester, onThisHole: true);
      expect(find.textContaining('greenie is picked below'), findsOneWidget);
      // ...and it is still not a tick, which is the whole reason for the note.
      expect(find.text('Greenie'), findsNothing);
    });

    testWidgets('on any other hole it says nothing', (tester) async {
      await pumpSheet(tester, onThisHole: false);
      expect(find.textContaining('greenie is picked below'), findsNothing);
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

    testWidgets('it states the rule, because half of it is unenforceable',
        (tester) async {
      await pump(tester, SpotsGreenieHole.fromJson(
          const {'hole': 3, 'worth': 1}));
      expect(find.textContaining('On the green in one'), findsOneWidget);
      expect(find.textContaining('a par to keep it'), findsOneWidget);
    });

    testWidgets('a missed par says who was closest and that nobody keeps it',
        (tester) async {
      // Otherwise a bogey that pays nobody reads as a bug.
      await pump(tester, SpotsGreenieHole.fromJson(const {
        'hole': 3, 'worth': 1, 'winner_id': 1, 'winner_short': 'Paul',
        'decided': true, 'missed': true,
      }));
      expect(find.textContaining('Paul was closest'), findsOneWidget);
      expect(find.textContaining('nobody keeps this one'), findsOneWidget);
    });

    testWidgets('a pick with no score yet says it is waiting', (tester) async {
      await pump(tester, SpotsGreenieHole.fromJson(const {
        'hole': 3, 'worth': 1, 'winner_id': 1, 'pending_score': true,
      }));
      expect(find.textContaining('Waiting on the score'), findsOneWidget);
    });

    testWidgets('a played hole with nobody named says it carried',
        (tester) async {
      // Otherwise the next par 3's bigger number looks like a bug. The chips
      // stay live: the group may simply not have got round to naming him.
      await pump(tester, SpotsGreenieHole.fromJson(const {
        'hole': 4, 'worth': 1, 'decided': true, 'unclaimed': true,
      }));
      expect(find.textContaining('Nobody recorded'), findsOneWidget);
      expect(find.textContaining('it carried'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(3));   // 2 + Nobody
    });

    testWidgets('and the hole it carried TO names where it came from',
        (tester) async {
      await pump(tester, SpotsGreenieHole.fromJson(const {
        'hole': 7, 'worth': 2, 'carried_from': 4,
      }));
      expect(find.text('Greenie · worth 2'), findsOneWidget);
      expect(find.text('Carried from the 4th'), findsOneWidget);
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
                          'chippy', 'barky', 'hogan', 'snake', 'other']) {
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

  group('the names come from the server', () {
    test('the checklist is the catalogue, not a list typed on the phone', () {
      // A configured game's `in_play` holds only the group's picks, so the
      // screen used to fill the gaps from a hardcoded label map — which made
      // it a second place every type is named. Adding Hogan proved the cost.
      final s = _summary({
        'catalogue': const [
          {'type': 'greenie', 'label': 'Greenie', 'worth': 1,
           'entry': 'pick', 'default': true},
          {'type': 'hogan', 'label': 'Hogan', 'worth': 1,
           'entry': 'sheet', 'default': false},
        ],
        'in_play': const [_greenie],
      });
      expect(s.catalogue.map((t) => t.type), ['greenie', 'hogan']);
      // Hogan is in the catalogue and NOT in play — which is exactly the row
      // the old merge could not produce.
      expect(s.inPlay.map((t) => t.type), ['greenie']);
    });

    test('no type name is typed into the setup screen', () {
      final src =
          File('lib/screens/spots_setup_screen.dart').readAsStringSync();
      for (final label in ['Eagle or better', 'Greenie', 'Barky', 'Hogan']) {
        // Unescaped on purpose: `"'\$label'"` would look for the literal
        // text and pass against anything, which is a test that agrees with
        // the bug.
        expect(src.contains("'" + label + "'"), isFalse,
            reason: 'spots_setup_screen names $label itself');
      }
    });
  });

  group('what he was paid FOR, on the board', () {
    // The capture is only worth the taps if it reaches the leaderboard, and
    // a total on its own answers the wrong question: `5 spots +\$10` is not
    // checkable, `Chippy on 2 · Birdie on 2` is.
    final holes = [
      {'hole': 7, 'spots': [
        {'player_id': 1, 'short_name': 'A', 'count': 3,
         'types': [_greenie2, _birdie]},
        {'player_id': 2, 'short_name': 'B', 'count': 1, 'types': [_sandy]},
      ]},
      {'hole': 2, 'spots': [
        {'player_id': 1, 'short_name': 'A', 'count': 1, 'types': [_chippy]},
      ]},
      {'hole': 11, 'spots': [
        {'player_id': 1, 'short_name': 'A', 'count': -1, 'types': [_snake]},
      ]},
    ];

    test('it is one golfer\'s own spots, in the order they happened', () {
      // The summary groups by hole, because that is how the money settles. A
      // board ranks golfers, so it needs the other grouping — and hole order
      // is asserted rather than inherited from whatever order the server
      // happened to send.
      final got = spotsEarnedFor(holes, 1);
      expect(got.map((e) => '${e.label}@${e.hole}'),
             ['Chippy@2', 'Greenie@7', 'Birdie@7', 'Snake@11']);
      expect(spotsEarnedFor(holes, 2).map((e) => e.label), ['Sandy']);
    });

    test('nobody else\'s spots leak in', () {
      expect(spotsEarnedFor(holes, 3), isEmpty);
      expect(spotsEarnedFor(holes, null), isEmpty);
    });

    test('a worth over one is NAMED, because it is different money', () {
      final got = spotsEarnedFor(holes, 1);
      expect(earnedSpotLabel(got[0]), 'Chippy on 2');
      // The carry is the whole reason a greenie can be worth two.
      expect(earnedSpotLabel(got[1]), 'Greenie on 7 \u00d72');
      // A snake costs him one; the sign lives in the colour, not the text.
      expect(earnedSpotLabel(got[3]), 'Snake on 11');
    });

    test('`on` is in the text, because `Chippy 2` reads as two chippies', () {
      expect(earnedSpotLabel(spotsEarnedFor(holes, 2).first), 'Sandy on 7');
    });

    test('an older server with no types draws nothing, not a blank bubble',
        () {
      final old = [
        {'hole': 4, 'spots': [
          {'player_id': 1, 'short_name': 'A', 'count': 2},
        ]},
      ];
      expect(spotsEarnedFor(old, 1), isEmpty);
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
