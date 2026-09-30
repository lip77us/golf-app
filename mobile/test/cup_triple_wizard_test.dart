/// test/cup_triple_wizard_test.dart
/// -------------------------------
/// **Triple Cup answers the game plan on the format card.**
///
/// Reported from testing, 30 Sep: step 5 of 6 asked which games each round
/// plays on an event whose format had already said — every round, every
/// group, Fourball + Foursomes + two Singles. The only valid answer was the
/// one already given.
///
/// Source-level, like the other wizard guards: booting the whole wizard needs
/// a provider apiece, and what is at risk here is the WIRING — a step dropped
/// from the flow whose STATE nobody writes, which reaches Review with no game
/// on any round and fails at submit.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final wizard =
      File('lib/screens/new_round_wizard.dart').readAsStringSync();

  group('the game-plan step', () {
    test('is in the cup flow only for a MIXED cup', () {
      expect(wizard.contains("if (_cupFormat != 'triple') _StepKind.cupGamePlan"),
          isTrue,
          reason: 'Triple Cup must not be asked which games it plays');
    });

    test('a mixed cup still gets it', () {
      // The step is conditional, not deleted — a mixed cup genuinely has a
      // plan to make, one to several games a day.
      expect(wizard.contains('_StepKind.cupGamePlan'), isTrue);
      expect(wizard.contains('class _Step3CupRoundGames'), isTrue);
    });
  });

  group('the state the dropped step used to write', () {
    test('is written instead by _applyTripleCupPlan', () {
      expect(wizard.contains('void _applyTripleCupPlan()'), isTrue);
      expect(wizard.contains("_roundCupGames[r]  = const ['triple_cup'];"),
          isTrue);
      expect(wizard.contains("_roundCupPoints[r] = const {'triple_cup': 1.0};"),
          isTrue);
    });

    test('is applied when the FORMAT is picked', () {
      expect(wizard.contains("if (f == 'triple') {\n              _applyTripleCupPlan();"),
          isTrue,
          reason: 'picking Triple Cup has to write the plan it implies');
    });

    test('is applied again when the ROUND COUNT changes', () {
      // A round added after the format was picked would otherwise reach
      // Review carrying no game at all.
      expect(
          wizard.contains(
              'void _clampRoundsToCount() {\n    _applyTripleCupPlan();'),
          isTrue);
    });

    test('picking MIXED hands the question back', () {
      // Switching away must not leave every round silently pre-answered with
      // triple_cup — that is a plan the TD never made.
      expect(wizard.contains('_roundCupGames.clear();'), isTrue);
      expect(wizard.contains('_roundCupPoints.clear();'), isTrue);
    });

    test('it drops the stroke-play championship, as the step did', () {
      // Triple Cup spends six holes in alt-shot, where individual net
      // scoring does not apply.
      final i = wizard.indexOf('void _applyTripleCupPlan()');
      final body = wizard.substring(i, i + 1400);
      expect(body.contains('championshipStrokePlay'), isTrue);
    });
  });

  group('the handicap step', () {
    test('asks for no single Net % on a Triple Cup', () {
      // Three formats off three allowances — a slider here could only set
      // one of them, and would set it for all three.
      expect(wizard.contains('showPercent: !isTripleCup'), isTrue);
      expect(
          wizard.contains(
              "isTripleCup: _isCupTournament && _cupFormat == 'triple'"),
          isTrue);
    });

    test('still asks for the MODE, which does apply to the whole cup', () {
      // Net / gross / strokes-off is one choice for the event; only the
      // percentage moved to the round.
      final i = wizard.indexOf('class _StepHandicap');
      final body = wizard.substring(i, i + 3000);
      expect(body.contains('HandicapModeSelector('), isTrue);
      expect(body.contains('onModeChanged:'), isTrue);
    });

    test('says where the allowance moved to', () {
      // A control that vanishes with no explanation reads as a missing
      // feature — the same rule the struck cap card follows.
      expect(wizard.contains('percentNote:'), isTrue);
      final i = wizard.indexOf('percentNote:');
      expect(wizard.substring(i, i + 260).contains('four-ball'), isTrue);
    });
  });
}
