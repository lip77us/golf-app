/// test/cup_setup_start_guard_test.dart
/// -----------------------------------
/// "Start Round" must not be a one-tap way to lose a part-built draw.
///
/// Reported from a 12-group cup build: the bottom bar shows ONE primary
/// button, and the screen flips to review after every group — so "Add Group",
/// tapped eleven times, becomes "Start Round" in the same place. `_submit`
/// posts the foursomes built so far and `setup_round` deletes the round's
/// existing foursomes first, so an early tap is destructive, not a no-op.
///
/// Source-level, like the other setup guards: the risk is the WIRING — a
/// confirmation that exists but is never awaited, or one that blocks a
/// legitimate short start.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src =
      File('lib/screens/cup_round_setup_screen.dart').readAsStringSync();

  group('starting an incomplete round asks first', () {
    test('_submit awaits the confirmation before doing anything', () {
      final i = src.indexOf('Future<void> _submit() async {');
      expect(i, greaterThan(-1));
      final head = src.substring(i, i + 200);
      expect(head.contains('if (!await _confirmIncompleteStart()) return;'),
          isTrue,
          reason: 'a guard that is not awaited first is decoration');
      // It must come BEFORE the submitting flag, or a cancelled dialog
      // leaves the button spinning.
      expect(head.indexOf('_confirmIncompleteStart'),
             lessThan(head.indexOf('_submitting = true')));
    });

    test('a complete draw is not interrupted', () {
      // Every group built and nobody sitting out must go straight through —
      // otherwise the guard trains people to tap past it.
      final i = src.indexOf('Future<bool> _confirmIncompleteStart() async {');
      final body = src.substring(i, i + 400);
      expect(body.contains('if (missing == 0 && short <= 0) return true;'),
          isTrue);
    });

    test('it names the numbers rather than warning vaguely', () {
      // "Some golfers are unassigned" is the kind of line people learn to
      // dismiss; a count is checkable against what they expected.
      expect(src.contains(r'$short more '), isTrue);
      expect(src.contains(r'$missing '), isTrue);
    });

    test('it asks rather than blocks', () {
      // Uneven singles legitimately leave golfers out, so a hard block would
      // be wrong — the TD must be able to proceed.
      expect(src.contains("Text('Start anyway')"), isTrue);
      expect(src.contains("Text('Keep building')"), isTrue);
    });

    test('dismissing the dialog does NOT start the round', () {
      final i = src.indexOf('Future<bool> _confirmIncompleteStart() async {');
      final body = src.substring(i, src.indexOf('Future<void> _submit()'));
      expect(body.contains('return ok ?? false;'), isTrue,
          reason: 'a barrier tap returns null and must mean "no"');
    });

    test('it says the groups are REPLACED, not merged', () {
      // `setup_round` deletes the round's foursomes before writing the new
      // ones, which is the part that makes an early tap costly.
      expect(src.contains('replaces this round'), isTrue);
    });
  });
}
