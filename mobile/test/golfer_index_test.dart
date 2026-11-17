import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/golfer_index.dart';

String _type(String keys) {
  var t = '';
  for (final k in keys.split(' ')) {
    t = padKey(t, k);
  }
  return t;
}

void main() {
  group('the pad', () {
    test('1-9-4 gives 19.4', () => expect(_type('1 9 4'), '19.4'));
    test('one decimal place only', () => expect(_type('1 9 4 5'), '19.4'));
    test('a point after one digit', () => expect(_type('9 +. 4'), '9.4'));
    test('a plus first makes a plus handicap', () => expect(_type('+. 2 +. 1'), '+2.1'));
    test('a second point is ignored', () => expect(_type('9 +. +. 4'), '9.4'));
    test('refuses anything over 54.0', () {
      expect(_type('5 5'), '5');
      expect(_type('5 4 1'), '54');
    });
    test('54.0 is allowed', () => expect(_type('5 4 0'), '54.0'));
    test('back removes one key', () => expect(_type('1 9 4 back'), '19.'));
    test('back on empty is empty', () => expect(padKey('', 'back'), ''));
  });

  group('storing', () {
    test('a plus handicap is stored negative', () => expect(storedFromTyped('+2.1'), '-2.1'));
    test('a trailing point reads as .0', () => expect(storedFromTyped('9.'), '9.0'));
    test('nothing typed is nothing', () {
      expect(storedFromTyped(''), isNull);
      expect(storedFromTyped('+'), isNull);
    });
    test('the chip shows a stored negative as a plus', () {
      expect(indexLabel('-2.1'), '+2.1');
      expect(indexLabel('12.4'), '12.4');
      expect(indexLabel(''), isNull);
      expect(indexLabel(null), isNull);
    });
  });
}
