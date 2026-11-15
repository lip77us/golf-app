import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/effective_scores.dart';

/// Reported from the course (26 Oct 2026). Paul's own words settled it:
/// *"You can't get by the hole without completing all four scores, so it
/// should never be a problem."* The per-hole gate is sound — the round-level
/// check was the one blind to the sync queue.

Scorecard _sc(Map<int, Map<int, int>> holes) => Scorecard.fromJson({
      'foursome_id': 1,
      'group_number': 1,
      'holes': [
        for (final e in holes.entries)
          {
            'hole_number': e.key,
            'par': 4,
            'scores': [
              for (final s in e.value.entries)
                {'player_id': s.key, 'gross_score': s.value},
            ],
          },
      ],
    });

void main() {
  group('the three places a score lives', () {
    test('the server copy', () {
      final sc = _sc({1: {10: 4, 11: 5}});
      expect(effectiveScores(sc, 1), {10: 4, 11: 5});
    });

    test('the SYNC QUEUE — saved locally, not yet delivered', () {
      // `submitHole` writes locally and only refreshes the scorecard once
      // the queue drains, so on a bad signal this is the only copy there is.
      expect(
        effectiveScores(_sc({}), 7, queued: {
          7: {10: 4, 11: 5, 12: 6, 13: 4}
        }),
        {10: 4, 11: 5, 12: 6, 13: 4},
      );
    });

    test('the screen\'s own unsaved taps', () {
      expect(effectiveScores(_sc({}), 3, pending: {3: {10: 3}}), {10: 3});
    });

    test('precedence is chronological — later edits win', () {
      final sc = _sc({5: {10: 6}});
      expect(effectiveScores(sc, 5, queued: {5: {10: 5}}), {10: 5});
      expect(
        effectiveScores(sc, 5, queued: {5: {10: 5}}, pending: {5: {10: 4}}),
        {10: 4},
      );
    });

    test('a queued hole is NOT empty, which was the whole bug', () {
      // Every hole finished and advanced past read as empty to the round's
      // completion check while the grid drew it and the hole gate let you on.
      final queued = {for (var h = 1; h <= 18; h++) h: {10: 4, 11: 4}};
      for (var h = 1; h <= 18; h++) {
        expect(effectiveScores(_sc({}), h, queued: queued).isEmpty, isFalse,
            reason: 'hole $h');
      }
    });

    test('a cleared score stays blank wherever it came from', () {
      expect(
        effectiveScores(_sc({2: {10: 4}}), 2,
            pending: {2: {10: -1}}, clearedSentinel: -1),
        isEmpty,
      );
    });

    test('a null scorecard is not a crash', () {
      expect(effectiveScores(null, 1, queued: {1: {10: 4}}), {10: 4});
      expect(effectiveScores(null, 1), isEmpty);
    });
  });

  group('one merge, not ten', () {
    test('no screen keeps its own copy', () {
      // Ten screens each had one and every one skipped the queue. A
      // re-grown copy would skip it again.
      final dir = Directory('lib/screens');
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        expect(src.contains('return {...saved, ...(_pending[hole]'), isFalse,
            reason: '${f.path} has grown its own merge back');
      }
    });

    test('every screen that merges reads the QUEUE', () {
      final dir = Directory('lib/screens');
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        if (!src.contains('_effectiveScores(Scorecard sc, int hole)')) continue;
        expect(src.contains('queued: context.read<RoundProvider>()'), isTrue,
            reason: '${f.path} merges without the sync queue');
      }
    });
  });
}
