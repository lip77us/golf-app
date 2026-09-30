/// test/tee_sheet_reachable_test.dart
/// ---------------------------------
/// **The tee sheet is reachable from the round hub.**
///
/// `TeeTimesScreen` has had fill-forward, the collision warning and play-order
/// sorting since it was written, and its own docstring said it was "reached
/// from the round hub". It was not: the only push was on the tournament card,
/// which is not where a TD stands when he is looking at the groups. Asked on
/// 30 Sep whether the feature existed at all — which is what an unreachable
/// feature looks like from outside.
///
/// Source-level, like the other entry-point guards: nothing pumps the hub
/// (it needs a provider apiece) and what is at risk is the WIRING.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final hub = File('lib/screens/round_screen.dart').readAsStringSync();
  final sheet = File('lib/screens/tee_times_screen.dart').readAsStringSync();

  group('the hub offers it', () {
    test('it imports and pushes the screen', () {
      expect(hub.contains("import 'tee_times_screen.dart';"), isTrue);
      expect(hub.contains('TeeTimesScreen('), isTrue,
          reason: 'the hub must be able to open the tee sheet');
    });

    test('it is named, not a bare glyph', () {
      expect(hub.contains("const Text('Tee times')"), isTrue);
    });

    test('it is gated on the TD and a live round', () {
      final i = hub.indexOf("const Text('Tee times')");
      // The gate sits just above the tile.
      final before = hub.substring(i - 900, i);
      expect(before.contains('canManage'), isTrue,
          reason: 'a tee sheet is the TD’s to set');
      expect(before.contains('!isComplete'), isTrue,
          reason: 'there is nothing to schedule once the round is over');
      expect(before.contains('round.foursomes.length > 1'), isTrue,
          reason: 'one group has no sheet to lay out');
    });

    test('it reloads the hub on the way back', () {
      // The cards below it are ordered BY tee time, so a change has to be
      // reflected or the list argues with the sheet that just set it.
      final i = hub.indexOf('TeeTimesScreen(');
      expect(hub.substring(i, i + 400).contains('_reloadRound()'), isTrue);
    });
  });

  group('the behaviour it was asked for already exists', () {
    test('setting one group fills the ones BELOW it forward', () {
      // Not first-group-only: any group, and the groups after it.
      expect(sheet.contains('f.groupNumber > fs.groupNumber'), isTrue);
      expect(sheet.contains('_offerFill('), isTrue);
    });

    test('groups that already have times SHIFT by the same delta', () {
      // Preserves a spacing the TD chose rather than flattening it back to
      // the constant.
      expect(sheet.contains('deltaMin'), isTrue);
    });
  });

  test('the docstring no longer claims a door that does not exist', () {
    // It said "reached from the round hub" while the only push was on the
    // tournament card — a comment that reads as a wiring check and is not one.
    expect(sheet.contains('Reached from the round hub'), isTrue);
    expect(sheet.contains('tournament card'), isTrue);
  });
}
