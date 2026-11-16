import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/course_handicap.dart';

/// A nine-hole course: the rating and par describe nine holes, so the index
/// is halved first (the server does the same — `course_handicap_exact`), and
/// a course can be played twice from the Advanced tab.
TeeInfo _tee({required int par, required double rating, required int slope,
    List<Map<String, dynamic>> holes = const []}) =>
    TeeInfo(
      id: 1,
      course: const CourseInfo(id: 1, name: 'The Ridge 9'),
      teeName: 'White', slope: slope, courseRating: rating, par: par,
      sex: 'M', holes: holes,
    );

PlayerProfile _player(String index) => PlayerProfile.fromJson({
      'id': 1, 'name': 'P', 'handicap_index': index,
    });

void main() {
  group('the course handicap on a nine', () {
    final nine = List.generate(9, (i) => {'number': i + 1, 'par': 4});

    test('halves the index for a nine-hole tee (The Ridge 9, White)', () {
      final t = _tee(par: 34, rating: 31.2, slope: 105, holes: nine);
      expect(courseHandicapFor(_player('10.0'), t), 2);
    });

    test('an 18-hole tee is unchanged', () {
      final t = _tee(par: 72, rating: 72.1, slope: 130,
          holes: List.generate(18, (i) => {'number': i + 1, 'par': 4}));
      expect(courseHandicapFor(_player('10.0'), t), 12);
    });

    test('a list payload with no holes is judged by its par', () {
      expect(isNineHoleTee(_tee(par: 34, rating: 31.2, slope: 105)), isTrue);
      expect(isNineHoleTee(_tee(par: 72, rating: 72.1, slope: 130)), isFalse);
      // An 18-hole par-3 course is 54, not a nine.
      expect(isNineHoleTee(_tee(par: 54, rating: 54.0, slope: 90)), isFalse);
    });
  });

  test('the Advanced tab offers to play a nine twice', () {
    final src = File('lib/screens/casual_round_screen.dart').readAsStringSync();
    expect(src, contains('Play it twice (18 holes)'));
    expect(src, contains('client.doubleCourse('));
    expect(src, contains("ValueKey('play-nine-once')"));
  });
}
