import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/auto_post.dart';

/// A tray game's hole posts itself — `utils/auto_post.dart`.
///
/// The decision is a pure function so the RACE it closes can be tested. The
/// post used to be fired by the last keystroke, and its gate depends on a
/// hole card the screen fetches asynchronously: a group that typed four
/// scores before the card arrived passed the gate while it was still false,
/// and nothing came back to try again.

const _sig = '6:1=5,2=5,3=5,4=5';

bool _ask({
  bool traysHere = true,
  bool fortyBalls = false,
  bool submitting = false,
  bool holeReady = true,
  String pendingSig = _sig,
  String? lastPosted,
}) =>
    shouldAutoPost(
      traysHere: traysHere, fortyBalls: fortyBalls, submitting: submitting,
      holeReady: holeReady, pendingSig: pendingSig, lastPosted: lastPosted,
    );

void main() {
  group('the race it closes', () {
    test('a complete hole posts even though the keystroke is long gone', () {
      // The card arrived AFTER the last score, so `traysHere` was false when
      // the keystroke fired and is true now. Asked on every build, the
      // answer changes the moment the card lands.
      expect(_ask(traysHere: false), isFalse);
      expect(_ask(traysHere: true), isTrue);
    });

    test('and it is asked again after each score, not only the last', () {
      expect(_ask(holeReady: false), isFalse,
          reason: 'a part-scored hole has nothing to report');
    });
  });

  group('it does not ask twice', () {
    test('the same scores are posted once', () {
      expect(_ask(lastPosted: _sig), isFalse);
    });

    test('a FAILED save is not retried in a loop', () {
      // The scores are still pending and the signature has not changed, so
      // this stays quiet — the snackbar carries the Retry.
      expect(_ask(lastPosted: _sig), isFalse);
    });

    test('…but a correction after one is posted', () {
      expect(_ask(pendingSig: '6:1=5,2=5,3=5,4=6', lastPosted: _sig), isTrue);
    });

    test('nothing pending, nothing to post', () {
      expect(_ask(pendingSig: ''), isFalse);
    });

    test('never while a save is in flight', () {
      expect(_ask(submitting: true), isFalse);
    });

    test('40 Balls posts with its count, not with a score', () {
      expect(_ask(fortyBalls: true), isFalse);
    });
  });

  group('the signature', () {
    test('is empty when nothing is waiting', () {
      expect(pendingSignature(6, null), '');
      expect(pendingSignature(6, const {}), '');
    });

    test('does not change with the ORDER the scores were entered', () {
      // Otherwise a scorer who corrected two rows back to the same numbers
      // would post the identical hole twice.
      expect(pendingSignature(6, {1: 5, 2: 4}),
             pendingSignature(6, {2: 4, 1: 5}));
    });

    test('changes with the hole', () {
      expect(pendingSignature(6, {1: 5}),
             isNot(pendingSignature(7, {1: 5})));
    });

    test('changes with a score', () {
      expect(pendingSignature(6, {1: 5}),
             isNot(pendingSignature(6, {1: 6})));
    });
  });

  group('the screen asks on every build', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('the keypad no longer fires the post itself', () {
      final at = src.indexOf('onScore   : (n) {');
      final body = src.substring(at, src.indexOf('onClear   :', at));
      expect(body, isNot(contains('_saveCurrentHole')));
    });

    test('and the bottom bar asks instead', () {
      expect(src, contains('_ensureHolePosted(rp, players, sc, par, fourCard)'));
      final at = src.indexOf('void _ensureHolePosted(');
      final body = src.substring(at, src.indexOf('\n  }', at));
      expect(body, contains('shouldAutoPost('));
      expect(body, contains('_raisesTray(rp)'));
      expect(body, contains('_saveCurrentHole('));
      // **It remembers what it posted.** Without this the question is asked
      // on every build with the same answer, and a save that fails is
      // retried for ever.
      expect(body, contains('lastPosted: _autoPosted'));
      expect(body, contains('_autoPosted = sig'));
      // …and it checks again on the other side of the frame, because the
      // scorer can have changed a score in between.
      expect(body, contains('pendingSignature(hole, _pending[hole]) != sig'));
    });
  });
}
