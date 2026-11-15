import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';

/// `RosterLastImport` — when the roster last came from Golf Genius.
///
/// The parsing and the sentence are the whole of it; the screen just draws
/// the sentence or draws nothing.
void main() {
  group('parsing', () {
    test('a never-imported roster is an answer, not an error', () {
      final r = RosterLastImport.fromJson({'synced': false});
      expect(r.synced, isFalse);
      expect(r.when, isNull);
    });

    test('it reads the run and converts the time to local', () {
      final r = RosterLastImport.fromJson({
        'synced': true,
        'when': '2026-10-15T14:15:00Z',
        'run_number': 6,
        'filename': 'tilden-roster.xlsx',
        'created': 2,
        'updated': 72,
        'by': 'Paul Lipkin',
      });
      expect(r.synced, isTrue);
      expect(r.runNumber, 6);
      expect(r.created, 2);
      expect(r.updated, 72);
      expect(r.by, 'Paul Lipkin');
      expect(r.when!.isUtc, isFalse, reason: 'shown in the reader\'s own time');
      expect(r.when!.toUtc(), DateTime.utc(2026, 10, 15, 14, 15));
    });

    test('a malformed date does not take the whole object down', () {
      final r = RosterLastImport.fromJson({'synced': true, 'when': 'not a date'});
      expect(r.synced, isTrue);
      expect(r.when, isNull);
    });

    test('missing keys fall back rather than throwing', () {
      final r = RosterLastImport.fromJson({'synced': true});
      expect(r.created, 0);
      expect(r.updated, 0);
      expect(r.by, '');
      expect(r.filename, '');
    });
  });

  group('the sentence', () {
    RosterLastImport imp(int created, int updated) =>
        RosterLastImport(synced: true, created: created, updated: updated);

    test('both halves', () {
      expect(imp(2, 72).changeSummary, '2 added, 72 updated');
    });

    test('a zero is omitted rather than printed', () {
      expect(imp(0, 72).changeSummary, '72 updated');
      expect(imp(2, 0).changeSummary, '2 added');
    });

    test('a run that moved nobody says so', () {
      // A file matching everybody with no changes is a real outcome. Silence
      // there reads as a failed import.
      expect(imp(0, 0).changeSummary, 'nothing changed');
    });
  });
}
