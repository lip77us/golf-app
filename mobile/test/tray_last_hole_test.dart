import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A tray that covers the pager has to carry the way off the last hole.
///
/// Both the Rabbit and Sixes trays replace the bottom bar entirely while they
/// are up — deliberately, because their forward button can name the next
/// RABBIT or the next MATCH, which a generic pager cannot. What that covers
/// on the eighteenth is **Complete Round**, and both screens were passing
/// `onNext: null` there: the group scored the last hole and the black bar was
/// a dead end, with the tray's own button reading `Done` and doing nothing
/// (Paul, 31 Oct 2026).
///
/// Checked at the source on both screens, because the trays are the only two
/// controls in the app that take the pager away.
void main() {
  const trays = <String, String>{
    'rabbit': 'lib/screens/rabbit_screen.dart',
    'sixes (score entry)': 'lib/screens/score_entry_screen.dart',
    'survivor': 'lib/screens/survivor_screen.dart',
  };
  const finisher = <String, String>{
    'rabbit': '_finishRound(',
    'sixes (score entry)': '_completeRound(',
    'survivor': '_finishRound(',
  };

  group('a tray that covers the pager finishes the round', () {
    for (final e in trays.entries) {
      test('${e.key} wires its last-hole button', () {
        final src = File(e.value).readAsStringSync();
        // Bounded by the next argument, not a character count.
        final at = src.indexOf('onNext:');
        expect(at, greaterThan(0), reason: 'the tray lost its forward button');
        final end = src.indexOf('\n              on', at + 8);
        final body = src.substring(at, end > at ? end : at + 400);

        expect(body, contains(finisher[e.key]!),
            reason: 'nothing finishes the round from the tray: $body');
        expect(
            RegExp(r'==\s*null\s*\?\s*null').hasMatch(body), isFalse,
            reason: 'the last hole must not disable the only button there');
      });
    }
  });
}
