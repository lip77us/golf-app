import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';

/// `RoundHandicapBasis` — what the Tees & Handicaps card draws.
///
/// The sentence under the picker is the whole of the logic: "why is this the
/// basis" is what a TD asks when the number surprises him.
void main() {
  BasisTeeOption white() => const BasisTeeOption(
        teeId: 2, teeName: 'White', sex: 'M', par: 70,
        courseRating: 69.0, slope: 122,
      );

  group('the label', () {
    test('names the tee, the sex and the rating it contributes', () {
      expect(white().label, 'White (M) · par 70 · 69.0');
    });

    test('a unisex tee carries no sex marker', () {
      const combo = BasisTeeOption(
        teeId: 9, teeName: 'Combo', sex: '', par: 70,
        courseRating: 69.4, slope: 120);
      expect(combo.label, 'Combo · par 70 · 69.4');
    });
  });

  group('where it came from', () {
    RoundHandicapBasis b(String? source) => RoundHandicapBasis(
          basis: white(), source: source, courseName: 'Tilden Park');

    test('set on this round', () {
      expect(b('round').explanation, 'Set for this round.');
    });

    test('inherited from the tournament', () {
      expect(b('tournament').explanation, 'From the tournament.');
    });

    test('remembered on the course, which NAMES the course', () {
      expect(b('course').explanation, 'Remembered for Tilden Park.');
    });

    test('nothing set says what happens instead, rather than going blank', () {
      // "No basis" has to read as a choice with a consequence, not as an
      // empty field.
      final e = const RoundHandicapBasis().explanation;
      expect(e, contains('lowest par in each group'));
      expect(e, contains('depending on the draw'));
    });
  });

  group('parsing', () {
    test('a full payload', () {
      final b = RoundHandicapBasis.fromJson({
        'basis': {'tee_id': 2, 'tee_name': 'White', 'sex': 'M',
                  'par': 70, 'course_rating': 69.0, 'slope': 122},
        'source': 'course',
        'course_name': 'Tilden Park',
        'candidates': [
          {'tee_id': 2, 'tee_name': 'White', 'sex': 'M', 'par': 70,
           'course_rating': 69.0, 'slope': 122},
          {'tee_id': 4, 'tee_name': 'RED', 'sex': 'W', 'par': 71,
           'course_rating': 71.5, 'slope': 125},
        ],
        'locked': true,
      });
      expect(b.basis!.teeName, 'White');
      expect(b.candidates.length, 2);
      expect(b.locked, isTrue);
      expect(b.source, 'course');
    });

    test('an unset round parses to nothing set and unlocked', () {
      final b = RoundHandicapBasis.fromJson({
        'basis': null, 'source': null, 'course_name': 'Tilden Park',
        'candidates': const [], 'locked': false,
      });
      expect(b.basis, isNull);
      expect(b.source, isNull);
      expect(b.locked, isFalse);
    });

    test('a course rating sent as a string still parses', () {
      final o = BasisTeeOption.fromJson({
        'tee_id': 2, 'tee_name': 'White', 'sex': 'M',
        'par': 70, 'course_rating': '69.0', 'slope': 122,
      });
      expect(o.courseRating, 69.0);
    });
  });
}
