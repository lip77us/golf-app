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
        // Anything that can turn it ON — Rabbit's Edit toggles it, so a
        // pattern looking only for `= true` would silently find nothing and
        // pass about a file it had stopped checking.
        final starts = <int>[];
        for (final m in RegExp(r'_trayEditing\s*=\s*(?:true|!_trayEditing)')
            .allMatches(src)) {
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

          // **And it picks nobody.** Opening on `players.first` put the
          // keypad on a golfer you did not ask for, so a quick tap changed
          // the wrong man's score. Checked at every Edit button in the app
          // rather than the one that was reported — Rabbit was fixed first
          // and Sixes and Annandale kept guessing for an hour.
          final end = src.indexOf('}),', at);
          final body = src.substring(at, end > at ? end : at);
          expect(body.contains('players.first'), isFalse,
              reason: 'Edit must not guess a golfer: $body');
          expect(body, contains('= null'),
              reason: 'Edit must clear the cursor: $body');
        }
      });
    }

    test('one header for all three trays', () {
      // Rabbit, Sixes and Annandale Friday each drew `All N scores in` and
      // its Edit button themselves, so the change had to be made three
      // times — and the first pass made it once.
      const trays = [
        'lib/widgets/rabbit_entry.dart',
        'lib/widgets/sixes_entry.dart',
        'lib/widgets/annandale_friday.dart',
      ];
      for (final f in trays) {
        final src = File(f).readAsStringSync();
        expect(src, contains('TrayEditHeader('), reason: '$f draws its own');
        expect(src.contains("'Edit scores'"), isFalse,
            reason: '$f still spells the button itself');
      }
      expect(File('lib/widgets/tray_edit_header.dart').readAsStringSync(),
          contains("'Edit scores'"));
    });

    test('the Rabbit tray gate asks only about the cursor', () {
      // A session always has a golfer under the keypad, so asking about the
      // flag here was redundant — and an edit inside a session used to clear
      // the cursor while leaving the flag set, which neither the tray nor the
      // keypad would draw on a fully scored hole. The bottom bar fell through
      // to the bare pager: "a blank bottom, not the hole summary".
      final src = File(files['rabbit']!).readAsStringSync();
      final at = src.indexOf('if (allDone &&');
      expect(at, greaterThan(0), reason: 'the tray gate moved');
      final line = src.substring(at, src.indexOf('\n', at));
      expect(line, contains('_editingPlayerId == null'));
      expect(line.contains('_trayEditing'), isFalse,
          reason: 'the cursor is the only question: $line');
    });

    test('an edit inside a session keeps its cursor', () {
      final src = File(files['rabbit']!).readAsStringSync();
      final at = src.indexOf('void _handleScore(');
      expect(at, greaterThan(0));
      // Bounded by the function's own end, not a character count.
      final body = src.substring(at, src.indexOf('\n  }', at));
      for (final m in RegExp(r'[^\n]*_editingPlayerId = null[^\n]*')
          .allMatches(body)) {
        expect(m.group(0), contains('!_trayEditing'),
            reason: 'only a one-shot ends on the score: ${m.group(0)}');
      }
    });

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
