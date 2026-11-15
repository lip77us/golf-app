import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/tee_assignment.dart';

/// `teesForPlayer` — the FIRST entry is the default every caller takes, so
/// what this really tests is which tee a golfer is offered.
///
/// Numbers are Tilden Park's real rows, including the `sort_priority` values
/// that get the women wrong today: WHITE is 12 against RED's 15.
TeeInfo _tee(int id, String name, String? sex, int prio,
        {List<String> suggested = const []}) =>
    TeeInfo(
      id: id,
      course: const CourseInfo(id: 1, name: 'Tilden Park'),
      teeName: name,
      slope: 122,
      courseRating: 69.0,
      par: 70,
      sex: sex,
      sortPriority: prio,
      suggestedForSex: suggested,
    );

PlayerProfile _p(String sex) => PlayerProfile(
      id: 1, name: 'A Golfer', shortName: 'AG',
      handicapIndex: '12.0', isPhantom: false, email: '', sex: sex,
    );

void main() {
  group('no basis set — nothing changes', () {
    final tees = [
      _tee(1, 'Blue',  'M', 10),
      _tee(2, 'White', 'M', 8),
      _tee(3, 'WHITE', 'W', 12),
      _tee(4, 'RED',   'W', 15),
    ];

    test('men still get the lowest sort_priority', () {
      expect(teesForPlayer(tees, _p('M')).first.teeName, 'White');
    });

    test('women still get what they got before', () {
      // The shipped behaviour, wrong at Tilden but unchanged until a basis
      // is named — which is what makes this additive.
      expect(teesForPlayer(tees, _p('W')).first.teeName, 'WHITE');
    });
  });

  group('with a basis — the suggestion wins', () {
    final tees = [
      _tee(1, 'Blue',  'M', 10),
      _tee(2, 'White', 'M', 8,  suggested: ['M']),
      _tee(3, 'WHITE', 'W', 12),
      _tee(4, 'RED',   'W', 15, suggested: ['W']),
    ];

    test('a woman is offered RED despite WHITE sorting higher', () {
      expect(teesForPlayer(tees, _p('W')).first.teeName, 'RED');
    });

    test('a man is still offered White', () {
      expect(teesForPlayer(tees, _p('M')).first.teeName, 'White');
    });

    test('the rest of the list keeps its order behind the suggestion', () {
      final w = teesForPlayer(tees, _p('W')).map((t) => t.teeName).toList();
      expect(w, ['RED', 'WHITE']);
    });

    test('a suggestion for the OTHER sex does not float', () {
      // Men's White is suggested for M; a woman must not be offered it, and
      // it is not even in her list.
      final w = teesForPlayer(tees, _p('W'));
      expect(w.any((t) => t.teeName == 'White'), isFalse);
    });
  });

  group('unisex tees', () {
    test('a unisex tee is offered to everyone and can be the suggestion', () {
      final tees = [
        _tee(1, 'Combo', null, 50, suggested: ['M', 'W']),
        _tee(2, 'White', 'M', 8),
        _tee(3, 'RED',   'W', 15),
      ];
      expect(teesForPlayer(tees, _p('M')).first.teeName, 'Combo');
      expect(teesForPlayer(tees, _p('W')).first.teeName, 'Combo');
    });
  });

  group('parsing', () {
    test('an older server sending neither key is the shipped behaviour', () {
      final t = TeeInfo.fromJson({
        'id': 1,
        'course': {'id': 1, 'name': 'Tilden Park'},
        'tee_name': 'White', 'slope': 122, 'course_rating': 69.0,
        'par': 70, 'sex': 'M', 'sort_priority': 8,
      });
      expect(t.suggestedForSex, isEmpty);
      expect(t.isBasis, isFalse);
    });

    test('it reads both keys when present', () {
      final t = TeeInfo.fromJson({
        'id': 2,
        'course': {'id': 1, 'name': 'Tilden Park'},
        'tee_name': 'RED', 'slope': 125, 'course_rating': 71.5,
        'par': 71, 'sex': 'W', 'sort_priority': 15,
        'suggested_for_sex': ['W'], 'is_basis': false,
      });
      expect(t.suggestedForSex, ['W']);
      expect(t.isBasis, isFalse);
    });
  });
}
