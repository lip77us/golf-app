import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/skin_validation_card.dart';

void main() {
  group('SkinValidationCard', () {
    Future<void> pump(WidgetTester t, {
      String minimum = 'none',
      bool steal = false,
      ValueChanged<String>? onMin,
      ValueChanged<bool>? onSteal,
    }) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SkinValidationCard(
                minimum: minimum,
                birdieSteal: steal,
                onMinimumChanged: onMin ?? (_) {},
                onBirdieStealChanged: onSteal ?? (_) {},
              ),
            ),
          ),
        ));

    testWidgets('offers all three minimums', (t) async {
      await pump(t);
      expect(find.text('No minimum'), findsOneWidget);
      expect(find.text('Net par or better'), findsOneWidget);
      expect(find.text('Gross par or better'), findsOneWidget);
    });

    testWidgets('names gross par as the stricter rule', (t) async {
      await pump(t);
      // The distinction is the whole reason both exist — a net par made off a
      // stroke is a gross bogey.
      expect(
        find.textContaining('net par made off a stroke is a gross bogey'),
        findsOneWidget,
      );
    });

    testWidgets('plain skins is stated when nothing is on', (t) async {
      await pump(t);
      expect(find.textContaining('Plain skins'), findsOneWidget);
    });

    testWidgets('the effect line names the unwon hole', (t) async {
      await pump(t, minimum: 'gross_par');
      // The interesting consequence: a hole can now go unwon, which plain
      // skins never does unless somebody ties.
      expect(find.textContaining('goes unwon'), findsOneWidget);
    });

    testWidgets('both rules on are described together', (t) async {
      await pump(t, minimum: 'net_par', steal: true);
      expect(find.textContaining('and a gross birdie beats any net score'),
          findsOneWidget);
    });

    testWidgets('picking a minimum reports the server slug', (t) async {
      String? got;
      await pump(t, onMin: (v) => got = v);
      await t.tap(find.text('Gross par or better'));
      expect(got, 'gross_par');
    });

    testWidgets('the steal switch toggles', (t) async {
      bool? got;
      await pump(t, onSteal: (v) => got = v);
      await t.tap(find.byType(SwitchListTile));
      expect(got, isTrue);
    });

    testWidgets('disabled makes every control inert', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SkinValidationCard(
            minimum: 'none',
            birdieSteal: false,
            onMinimumChanged: _never,
            onBirdieStealChanged: _neverBool,
            enabled: false,
          ),
        ),
      ));
      final sw = t.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.onChanged, isNull);
    });
  });

  group('the summaries carry the rules', () {
    test('SkinsSummary reads all three keys', () {
      final s = SkinsSummary.fromJson({
        'status': 'in_progress',
        'handicap_mode': 'net',
        'net_percent': 100,
        'carryover': true,
        'allow_junk': false,
        'skin_minimum': 'gross_par',
        'birdie_steal': true,
        'skin_rules': 'gross par or better to win · gross birdies steal',
        'players': [],
        'holes': [],
        'money': {'bet_unit': 1.0, 'pool': 0.0, 'total_skins': 0},
      });
      expect(s.skinMinimum, 'gross_par');
      expect(s.birdieSteal, isTrue);
      expect(s.skinRules, contains('steal'));
    });

    test('an older server without the keys means plain skins', () {
      final s = SkinsSummary.fromJson({
        'status': 'pending',
        'handicap_mode': 'net',
        'net_percent': 100,
        'carryover': true,
        'allow_junk': false,
        'players': [],
        'holes': [],
        'money': {'bet_unit': 1.0, 'pool': 0.0, 'total_skins': 0},
      });
      expect(s.skinMinimum, 'none');
      expect(s.birdieSteal, isFalse);
      expect(s.skinRules, '');
    });

    test('MultiSkinsSummary reads the same three keys', () {
      final s = MultiSkinsSummary.fromJson({
        'status': 'in_progress',
        'handicap': {'mode': 'net', 'net_percent': 100},
        'skin_minimum': 'net_par',
        'birdie_steal': true,
        'skin_rules': 'net par or better to win · gross birdies steal',
        'players': [],
        'holes': [],
        'money': {'bet_unit': 1.0, 'pool': 0.0, 'total_skins': 0},
      });
      expect(s.skinMinimum, 'net_par');
      expect(s.birdieSteal, isTrue);
      expect(s.skinRules, contains('net par'));
    });
  });

  group('both setup screens are wired', () {
    // Paul asked for these on BOTH round skins and the cross-group pool, and
    // this repo's recurring failure is shipping a rule reachable from one
    // screen and not the other (the day bet, Hot Seat on the Road Trip
    // sheet).  Checked at the source: a screen that renders the card but
    // never posts the values looks identical until somebody plays a round.
    const screens = {
      'lib/screens/skins_setup_screen.dart',
      'lib/screens/multi_skins_setup_screen.dart',
    };

    for (final path in screens) {
      test('$path renders the card AND posts both values', () {
        final src = File(path).readAsStringSync();
        expect(src.contains('SkinValidationCard'), isTrue,
            reason: '$path does not render the control');
        expect(src.contains('skinMinimum'), isTrue,
            reason: '$path never sends skin_minimum');
        expect(src.contains('birdieSteal'), isTrue,
            reason: '$path never sends birdie_steal');
      });
    }

    test('the client sends them on both endpoints', () {
      final src = File('lib/api/client.dart').readAsStringSync();
      for (final call in ['postSkinsSetup', 'postMultiSkinsSetup']) {
        final i = src.indexOf(call);
        expect(i, greaterThan(-1), reason: '$call missing');
        // Slice to the NEXT method rather than a fixed length: these two
        // carry long doc comments, and a window that falls short reads as a
        // missing field.
        final next = src.indexOf('\n  Future<', i + 1);
        final body = src.substring(i, next > i ? next : src.length);
        expect(body.contains('skin_minimum'), isTrue,
            reason: '$call does not send skin_minimum');
        expect(body.contains('birdie_steal'), isTrue,
            reason: '$call does not send birdie_steal');
      }
    });
  });
}

void _never(String _) {}
void _neverBool(bool _) {}
