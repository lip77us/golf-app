import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// A shipped-and-unreachable guard: the teams screen exists only if the hub
/// can open it, and only before the first score (saving redraws the groups).
void main() {
  final hub = File('lib/screens/round_screen.dart').readAsStringSync();
  final main = File('lib/main.dart').readAsStringSync();

  test('the hub offers Edit SWAT teams and the route exists', () {
    expect(hub, contains("'/swat-teams'"));
    expect(hub, contains('Edit SWAT teams'));
    expect(main, contains("case '/swat-teams':"));
  });

  test('it is offered only until the first score is posted', () {
    expect(hub, contains("round.activeGames.contains('oakmont_swat') &&"));
    expect(hub, contains('!round.foursomes.any((f) => f.hasAnyScore)'));
  });

  test('the card opens for a round whose only setup is SWAT', () {
    expect(hub, contains('hasFortyBalls || hasSwat ||'));
  });
}
