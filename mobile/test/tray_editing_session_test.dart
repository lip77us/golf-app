import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A session starts from `Edit scores`, and from nothing else.
///
/// `_trayEditing` began life meaning only "do not draw the tray", which
/// `_editingPlayerId` / `_editHotPid` already did on their own — so Rabbit's
/// tap-a-golfer handler set both and nothing was wrong. When `Edit scores`
/// became a SESSION (30 Oct 2026) the flag gained a second meaning, "keep the
/// keypad on this golfer until Done", and that tap handler silently inherited
/// it: tapping any box pinned the keypad for the rest of the hole, so nothing
/// ever advanced to the next golfer.
///
/// So the rule is checked where it can actually be got wrong — at every
/// assignment — rather than at the one handler that got it wrong.
void main() {
  const files = <String, String>{
    'score entry': 'lib/screens/score_entry_screen.dart',
    'rabbit': 'lib/screens/rabbit_screen.dart',
  };

  group('only Edit scores starts an edit session', () {
    for (final e in files.entries) {
      test('every _trayEditing = true in ${e.key} sits under onEdit', () {
        final src = File(e.value).readAsStringSync();
        final starts = <int>[];
        for (final m in RegExp(r'_trayEditing\s*=\s*true').allMatches(src)) {
          starts.add(m.start);
        }
        expect(starts, isNotEmpty, reason: 'the session flag moved');

        for (final at in starts) {
          // The nearest handler named ABOVE the assignment is the one that
          // owns it. `onEdit` is the tray's button; a tap handler is not.
          final before = src.substring(0, at);
          final owner = RegExp(r'on(Edit|EditTap|TapPlayer|ScoreSelected)\b')
              .allMatches(before)
              .last
              .group(0);
          expect(owner, 'onEdit',
              reason: 'a $owner handler must not start a session');
        }
      });
    }

    test('the Rabbit tap handler sets the cursor and nothing else', () {
      final src = File(files['rabbit']!).readAsStringSync();
      final at = src.indexOf('onTapPlayer:');
      expect(at, greaterThan(0));
      // Bounded by the next argument, not a character count.
      final end = src.indexOf('rowExtras:', at);
      expect(end, greaterThan(at), reason: 'the argument list moved');
      final body = src.substring(at, end);
      expect(body, contains('_editingPlayerId = pid'));
      expect(body.contains('_trayEditing'), isFalse);
    });
  });
}
