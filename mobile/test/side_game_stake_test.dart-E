/// A side game's setup must not write the round's stake, which the primary
/// game reads live: a $5 Skins ante turned a finished $10 Nassau into $5.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Honors never writes the round stake', () {
    final src = File('lib/screens/honors_setup_screen.dart').readAsStringSync();
    expect(src, isNot(contains('updateRoundBetUnit')));
    expect(src, contains('stake: parsed'));
  });

  test('Skins writes it only as the primary', () {
    final src = File('lib/screens/skins_setup_screen.dart').readAsStringSync();
    expect(src, contains("_payoutStyle == 'pool' && !_isSideGame"));
    expect(src, contains("poolAnte: _payoutStyle == 'pool' && _isSideGame"));
  });
}
