import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One keypad, one Clear.
///
/// `FortyBallsKeypad` is shared by score entry (40 Balls, Sixes, Annandale
/// Friday) and by the Rabbit screen, and each caller wires `onClear` to its
/// own `_selectScore`. That function reads **−1** as "take this golfer out of
/// pending" and treats every other value as a score — so Rabbit passing `0`
/// wrote a gross of zero: the row read as scored, the keypad moved to the
/// next golfer, and the hole counted as complete (Paul, 30 Oct 2026, off the
/// 7th with nothing entered). The save then posted it and `gross_score` has
/// `min_value=1`, so the server refused the whole hole and the sync queue
/// dropped it as a permanent 4xx — the scores were lost silently.
///
/// Anchored on the keypad's own call, bounded by the end of its argument
/// list, so a line inserted above the claim cannot push it out of range.
void main() {
  final files = <String, String>{
    'score entry': 'lib/screens/score_entry_screen.dart',
    'rabbit': 'lib/screens/rabbit_screen.dart',
  };

  final cleared = <String, String>{};

  group('every keypad clears with the same value', () {
    for (final e in files.entries) {
      test('${e.key} passes the clear sentinel, not a score', () {
        final src = File(e.value).readAsStringSync();
        final at = src.indexOf('FortyBallsKeypad(');
        expect(at, greaterThan(0), reason: 'the keypad call moved');
        // `onClear` is the last argument on both call sites; bound the slice
        // at the end of the argument list rather than by a character count.
        final onClear = src.indexOf('onClear', at);
        expect(onClear, greaterThan(at));
        final end = src.indexOf('\n          ),', onClear);
        expect(end, greaterThan(onClear), reason: 'the argument list moved');
        final body = src.substring(onClear, end);

        // Either handler is fine — Rabbit routes its clear through
        // `_handleScore` so a complete hole posts the deletion — and the
        // value may be a named constant, which is resolved from the file's
        // own declaration rather than assumed.
        // `_selectScore` takes the score second, `_handleScore` third.
        final m = RegExp(
                r'_(?:select|handle)Score\((?:[^,()]+,\s*){1,2}(-?\d+|_k\w+)\s*,')
            .firstMatch(body);
        expect(m, isNotNull,
            reason: 'onClear must pass the clear value to a score handler');
        var value = m!.group(1)!;
        if (value.startsWith('_k')) {
          final decl = RegExp('const int $value = (-?\\d+);').firstMatch(src);
          expect(decl, isNotNull, reason: '$value is not declared here');
          value = decl!.group(1)!;
        }
        cleared[e.key] = value;

        expect(cleared[e.key], '-1',
            reason: 'a clear must not be written as a score');
      });
    }

    test('and they agree with each other', () {
      expect(cleared.length, files.length);
      expect(cleared.values.toSet().length, 1,
          reason: 'one keypad cannot mean two things by Clear: $cleared');
    });
  });
}
