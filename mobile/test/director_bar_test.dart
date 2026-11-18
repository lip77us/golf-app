import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/director_bar.dart';

void main() {
  testWidgets('the bar highlights the active tab and reports taps', (t) async {
    DirectorTab? got;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: DirectorBar(
            active: DirectorTab.overview, onTap: (x) => got = x),
      ),
    ));
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);
    await t.tap(find.text('Groups'));
    expect(got, DirectorTab.groups);
  });

  test('a golfer never sees the bar: it is gated on managing a tournament round', () {
    final src = File('lib/screens/round_screen.dart').readAsStringSync();
    final i = src.indexOf('? DirectorBar(');
    expect(i, greaterThan(0));
    final gate = src.substring(src.lastIndexOf('bottomNavigationBar:', i), i);
    expect(gate, contains('round.canManage'));
    expect(gate, contains('round.tournamentId != null'));
  });
}
