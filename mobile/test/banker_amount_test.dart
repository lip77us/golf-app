/// test/banker_amount_test.dart
/// ---------------------------
/// Reading a money amount out of a text field.
///
/// Both of Banker's caps describe money going OUT, so a golfer types `-500`
/// as readily as `500`. The first version required a positive number and
/// dropped everything else — so a cap typed with a minus sign silently never
/// existed, and the screen said nothing at all about it.
library;

import 'package:flutter_test/flutter_test.dart';

/// Mirrors `_BankerSetupScreenState._amount`.
double? amount(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
  final v = double.tryParse(cleaned);
  return (v != null && v > 0) ? v : null;
}

void main() {
  test('a minus sign is a magnitude, not a rejection', () {
    expect(amount('-500'), 500);
    expect(amount('500'), 500);
  });

  test('currency symbols and separators are not the golfer\'s problem', () {
    expect(amount(r'$500'), 500);
    expect(amount('1,000'), 1000);
    expect(amount(r'-$1,250'), 1250);
    expect(amount(' 500 '), 500);
  });

  test('nothing usable reads as no cap', () {
    for (final raw in ['', '  ', 'none', '0', '-0', r'$', '.']) {
      expect(amount(raw), isNull, reason: 'expected no cap from "$raw"');
    }
  });

  test('decimals survive', () {
    expect(amount('12.50'), 12.5);
  });
}
