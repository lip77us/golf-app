import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/result_hold.dart';

void main() {
  const wait = Duration(seconds: 5);

  group('ResultHold', () {
    test('holds a posted hole until it is answered', () {
      fakeAsync((t) {
        final h = ResultHold(wait: wait, onChanged: () {});
        expect(h.pending(7), isFalse);
        h.hold(7);
        expect(h.pending(7), isTrue);
        expect(h.pending(8), isFalse);
        h.answer(7);
        expect(h.pending(7), isFalse);
        expect(h.answered(7), isTrue);
      });
    });

    test('lets go after the wait, so a bad signal cannot strand a group', () {
      fakeAsync((t) {
        var changes = 0;
        final h = ResultHold(wait: wait, onChanged: () => changes++);
        h.hold(7);
        t.elapse(const Duration(seconds: 4));
        expect(h.pending(7), isTrue);
        t.elapse(const Duration(seconds: 2));
        expect(h.pending(7), isFalse);
        expect(h.answered(7), isFalse, reason: 'nothing came back');
        expect(changes, 1);
      });
    });

    test('an edit in flight keeps the hold through the earlier answer', () {
      fakeAsync((t) {
        final h = ResultHold(wait: wait, onChanged: () {});
        h.hold(7);
        h.hold(7);
        h.answer(7);
        expect(h.pending(7), isTrue);
        h.answer(7);
        expect(h.pending(7), isFalse);
      });
    });

    test('an edit after an answer needs a new answer', () {
      fakeAsync((t) {
        final h = ResultHold(wait: wait, onChanged: () {});
        h.hold(7);
        h.answer(7);
        h.hold(7);
        expect(h.answered(7), isFalse);
        expect(h.pending(7), isTrue);
      });
    });

    test('an answer cancels the timer', () {
      fakeAsync((t) {
        var changes = 0;
        final h = ResultHold(wait: wait, onChanged: () => changes++);
        h.hold(7);
        h.answer(7);
        t.elapse(const Duration(seconds: 10));
        expect(changes, 0);
      });
    });
  });

  group('wiring', () {
    final screen =
        File('lib/screens/score_entry_screen.dart').readAsStringSync();
    final provider =
        File('lib/providers/round_provider.dart').readAsStringSync();

    test('the button is held ahead of every next-hole branch', () {
      final gate = screen.indexOf('rp.annandaleResultPending(_selectedHole)) {');
      final next = screen.indexOf(
          'final nextHole = _nextHoleInOrder(rp);\n    if (nextHole != null)');
      expect(gate, greaterThan(0));
      expect(next, greaterThan(gate));
    });

    test('the hold is taken before the enqueue starts the drain', () {
      final hold = provider.indexOf('_annandaleResults.hold(holeNumber)');
      final enqueue = provider.indexOf('await _sync.enqueue(');
      expect(hold, greaterThan(0));
      expect(enqueue, greaterThan(hold));
    });

    test('offline never holds', () {
      expect(provider, contains('_annandaleResults.pending(hole) && _sync.isOnline'));
    });
  });
}
