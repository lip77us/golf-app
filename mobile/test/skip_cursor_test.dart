import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/skip_cursor.dart';

void main() {
  final ids = [1, 2, 3, 4];
  bool Function(int) owes(Set<int> scored) => (id) => !scored.contains(id);

  test('a new hole starts on the top golfer owed a score', () {
    expect(SkipCursor().hotIndex(5, ids, owes({})), 0);
  });

  test('a score moves the cursor DOWN, not back to a skipped golfer', () {
    final c = SkipCursor()..skip(5, 1);
    expect(c.hotIndex(5, ids, owes({})), 1);
    c.moveFrom(5, 2);
    expect(c.hotIndex(5, ids, owes({2})), 2);
  });

  test('past the last golfer it wraps to the top', () {
    final c = SkipCursor()..moveFrom(5, 4);
    expect(c.hotIndex(5, ids, owes({3, 4})), 0);
  });

  test('another hole forgets the cursor and the marks', () {
    final c = SkipCursor()..skip(5, 1);
    expect(c.hotIndex(6, ids, owes({})), 0);
    expect(c.skippedOn(6), isEmpty);
    expect(c.skippedOn(5), {1});
  });

  test('nobody owed means -1', () {
    expect(SkipCursor().hotIndex(5, ids, owes({1, 2, 3, 4})), -1);
  });
}
