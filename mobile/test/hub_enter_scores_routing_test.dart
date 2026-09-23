/// test/hub_enter_scores_routing_test.dart
/// --------------------------------------
/// **Every branch of the hub's Enter Scores routing goes out the same door.**
///
/// The chain picks a route from fifteen-odd branches and then pushes ONCE, at
/// the bottom, with a `.then` that reloads the round. That reload is the only
/// thing keeping the hub honest on the way back: `hasAnyScore` decides whether
/// the button reads `Start Match` or `Continue Match`, and it is a server
/// field, so a hub that does not ask again keeps whatever it had before
/// scoring started.
///
/// Foursome Play used to push and `return` from inside the chain, skipping
/// that tail. The button read `Start Match` on the 2nd hole of a two-man
/// scramble, and on every hole after it — reported 23 Sep 2026.
///
/// This is a source-level check because the defect is structural: the code was
/// individually correct on every line and wrong in its shape. A widget test
/// would have to drive a whole round hub to see it, and would still only catch
/// the ONE branch it exercised. The rule is about all of them.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The body of the `onEnterScores:` closure, which is where the rule applies.
String _onEnterScoresBody() {
  final src = File('lib/screens/round_screen.dart').readAsStringSync();
  final start = src.indexOf('onEnterScores:');
  expect(start, greaterThan(0), reason: 'onEnterScores has been renamed');
  // Bounded by MATCHING the closure's own braces. Scanning forward for a
  // closing delimiter ran straight past it into the hub's other buttons,
  // which push setup screens of their own and legitimately do not reload.
  final open = src.indexOf('{', start);
  expect(open, greaterThan(start));
  var depth = 0;
  var end = -1;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  expect(end, greaterThan(open), reason: 'the closure could not be bounded');
  return src.substring(open, end);
}

void main() {
  group('**one push, one reload, every game**', () {
    test('the chain pushes exactly once', () {
      final body = _onEnterScoresBody();
      final pushes = 'pushNamed('.allMatches(body).length;
      expect(pushes, 1,
          reason: 'A branch that pushes on its own skips the shared reload '
              'below and leaves the hub on stale state. Set `route` (and '
              '`teamPlayArgs` if the screen wants a map) and fall through.');
    });

    test('that push reloads the round on the way back', () {
      final body = _onEnterScoresBody();
      final push = body.indexOf('pushNamed(');
      final then = body.indexOf('.then(', push);
      expect(then, greaterThan(push),
          reason: 'Without the reload, `hasAnyScore` never refreshes and the '
              'button keeps saying Start Match.');
      expect(body.substring(then), contains('loadRound'));
    });

    test('no branch returns early out of the chain', () {
      final body = _onEnterScoresBody();
      // A bare `return;` inside the chain is how the tail gets skipped. The
      // closure returns void, so there is no legitimate one.
      expect(body.contains('return;'), isFalse,
          reason: 'An early return skips the push and the reload with it.');
    });

    test('Foursome Play routes by setting the route, like the rest', () {
      final body = _onEnterScoresBody();
      expect(body, contains("route = '/team-play-score'"));
      expect(body.contains("pushNamed('/team-play-score'"), isFalse);
    });
  });
}
