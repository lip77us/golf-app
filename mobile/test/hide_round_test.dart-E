import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Reported 30 Oct 2026: *"I have a round I was invited to and it never
/// happened and it is stuck on my open rounds list. Can I have a remove
/// myself from a round option?"*
///
/// Neither cross-account list ages a live follow off, so an abandoned round
/// sits on the Active tab for good. These pin the two halves of the answer:
/// the action is offered on the rounds that need it, and it is never the
/// destructive reading of "remove myself".

void main() {
  final list =
      File('lib/screens/casual_rounds_list_screen.dart').readAsStringSync();
  final client = File('lib/api/client.dart').readAsStringSync();

  group('it is offered where it is needed', () {
    test('on a round I play in, and on one I only watch', () {
      // Both are cross-account and neither ages off.
      for (final builder in ['_sharedItem', '_watchedItem']) {
        final at = list.indexOf('_RoundItem $builder');
        expect(at, greaterThan(0), reason: '$builder moved');
        final body = list.substring(at, list.indexOf('\n  }', at));
        expect(body, contains('onRemove:'),
            reason: '$builder must offer the way out');
      }
    });

    test('and NOT on my own rounds, which the server refuses', () {
      // Hiding your own round makes it unreachable rather than tidy.
      final at = list.indexOf('_RoundItem _ownItem');
      if (at > 0) {
        expect(list.substring(at, list.indexOf('\n  }', at)),
            isNot(contains('onRemove:')));
      }
    });
  });

  group('it is not a delete', () {
    test('the icon is not the bin and not the danger colour', () {
      final at = list.indexOf('if (item.onRemove != null)');
      expect(at, greaterThan(0));
      final body = list.substring(at, at + 600);
      expect(body, contains('visibility_off_outlined'));
      expect(body.contains('delete_outline'), isFalse);
      expect(body.contains('_danger'), isFalse);
    });

    test('an Undo is offered instead of a confirmation', () {
      final at = list.indexOf('Future<void> _removeFromMyList(');
      expect(at, greaterThan(0));
      final body = list.substring(at, list.indexOf('\n  }\n', at));
      expect(body, contains("label: 'Undo'"));
      expect(body, contains('setRoundHidden(roundId, false)'));
      // A dialog would be asking permission for something that cannot go
      // wrong — it is reversible and their round is untouched.
      expect(body.contains('showDialog'), isFalse);
    });

    test('the client sends a hide, never a round delete', () {
      final at = client.indexOf('Future<void> setRoundHidden(');
      expect(at, greaterThan(0));
      final body = client.substring(at, client.indexOf('\n  }', at));
      expect(body, contains("/rounds/\$roundId/hide/"));
      expect(body.contains('deleteRound'), isFalse);
    });
  });
}
