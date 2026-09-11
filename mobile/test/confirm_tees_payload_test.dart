import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/screens/confirm_tees_screen.dart';

/// A save sends EVERY row that has a tee, not only the ones moved here.
///
/// Skipping unchanged rows looks like a free optimisation — a foursome is four
/// rows — and it broke the one job this screen uniquely does.
/// `PATCH /foursomes/{id}/tees/` is the only place a membership's course and
/// playing handicap are recomputed from the golfer's index, and the edit that
/// makes a recompute necessary happens in My Golfers, which this screen cannot
/// see. A TD who corrected an index there and pressed Save got "No changes."
/// and a stale handicap; the workaround was to change a tee and change it back,
/// dirtying the row twice so it recomputed on the way through.
void main() {
  final course = const CourseInfo(id: 1, name: 'Test Links');
  TeeInfo tee(int id) => TeeInfo(
      id: id, course: course, teeName: 'T$id', slope: 113,
      courseRating: 70.0, par: 72);

  Membership member(int pid, {int? teeId}) => Membership(
        id: pid * 10,
        player: PlayerProfile(
            id: pid, name: 'G$pid', handicapIndex: '10.0',
            isPhantom: false, email: ''),
        tee: teeId == null ? null : tee(teeId),
        courseHandicap: 10,
        playingHandicap: 10,
      );

  test('an untouched foursome still sends every row', () {
    final rows = buildTeePayload([member(1, teeId: 7), member(2, teeId: 7)], {});
    expect(rows, [
      {'player_id': 1, 'tee_id': 7},
      {'player_id': 2, 'tee_id': 7},
    ]);
  });

  test('a moved row carries its new tee, the rest their existing one', () {
    final rows = buildTeePayload(
        [member(1, teeId: 7), member(2, teeId: 7)], {1: 9});
    expect(rows.firstWhere((r) => r['player_id'] == 1)['tee_id'], 9);
    expect(rows.firstWhere((r) => r['player_id'] == 2)['tee_id'], 7);
  });

  test('a golfer with no tee and no pick is skipped', () {
    final rows = buildTeePayload([member(1), member(2, teeId: 7)], {});
    expect(rows, [{'player_id': 2, 'tee_id': 7}]);
  });

  test('a golfer with no tee who is given one is included', () {
    expect(buildTeePayload([member(1)], {1: 4}),
           [{'player_id': 1, 'tee_id': 4}]);
  });

  test('a zero pick is treated as no selection', () {
    expect(buildTeePayload([member(1)], {1: 0}), isEmpty);
  });
}
