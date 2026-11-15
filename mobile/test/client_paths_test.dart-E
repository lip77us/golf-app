// Every API path in `client.dart` must actually interpolate its ids.
//
// `_delete('/rounds/\$roundId/day-bet/setup/')` compiles, analyses clean and
// passes every existing test — and then asks the server for a round called
// literally `$roundId`, which no route matches. The result is a 404 that
// looks like a missing endpoint rather than a malformed URL, and the method
// beside it works, so the evidence points everywhere except the string.
//
// Reported 10 Oct 2026 as "I still can not Turn it off". It cost two rounds
// of testing to find, and nothing in the toolchain can see it: to Dart, a
// `\$` is a perfectly good character in a perfectly good string.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no API path escapes its interpolation', () {
    final src = File('lib/api/client.dart').readAsStringSync();

    // The path argument of a _get/_post/_patch/_delete call.
    final calls = RegExp(r"_(?:get|post|patch|delete)\(\s*'([^']*)'");
    final offenders = <String>[];
    for (final m in calls.allMatches(src)) {
      final path = m.group(1)!;
      if (path.contains(r'\$')) offenders.add(path);
    }

    expect(offenders, isEmpty,
        reason: 'These paths contain an ESCAPED \$, so the id is sent as '
            'literal text and the server answers 404:\n'
            '  ${offenders.join('\n  ')}');
  });

  test('a path with a brace-less id still interpolates', () {
    // Guards the opposite slip: '/rounds/roundId/' with the $ dropped
    // altogether, which is also a literal and also a 404.
    final src = File('lib/api/client.dart').readAsStringSync();
    final calls = RegExp(r"_(?:get|post|patch|delete)\(\s*'([^']*)'");
    final suspects = <String>[];
    for (final m in calls.allMatches(src)) {
      final path = m.group(1)!;
      // A segment that is camelCase and ends in Id is almost certainly a
      // variable somebody forgot to mark.
      for (final seg in path.split('/')) {
        if (RegExp(r'^[a-z]+[A-Z]\w*Id$').hasMatch(seg)) suspects.add(path);
      }
    }
    expect(suspects, isEmpty,
        reason: 'These look like an id written without its \$:\n'
            '  ${suspects.join('\n  ')}');
  });
}
