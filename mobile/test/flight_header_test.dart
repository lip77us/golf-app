/// test/flight_header_test.dart
///
/// The band that replaced the `A · Paul L` name prefix.
///
/// The prefix was the Phase 1 stopgap: the server could flight a field with no
/// client build, but nothing could say where one flight ended, so the letter
/// rode in the golfer's own name. These tests pin what the header has to do
/// before that stopgap can stay deleted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/flight_header.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Column(children: [child])));

void main() {
  testWidgets('it names the flight the way golfers do', (tester) async {
    // "I'm in B", never "I'm in flight 2".
    await tester.pumpWidget(_wrap(
        const FlightHeader(label: 'B', size: 13, purse: 200)));
    expect(find.text('B FLIGHT'), findsOneWidget);
  });

  testWidgets('it states the flight own purse, not a share of one pot',
      (tester) async {
    // Every flight pays the SAME table, which is the whole point of the
    // header: a golfer in B is not competing for a share of one prize fund,
    // he is playing for a fund of his own.
    await tester.pumpWidget(_wrap(
        const FlightHeader(label: 'A', size: 10, purse: 200)));
    expect(find.textContaining('10 golfers'), findsOneWidget);
    expect(find.textContaining('\$200 in prizes'), findsOneWidget);
  });

  testWidgets('no purse draws no money rather than \$0', (tester) async {
    // A zero would read as a flight playing for nothing, which is a different
    // and wrong statement from a club event whose table is not yet typed.
    await tester.pumpWidget(_wrap(
        const FlightHeader(label: 'A', size: 8, purse: 0)));
    expect(find.text('8 golfers'), findsOneWidget);
    expect(find.textContaining('\$'), findsNothing);
  });

  testWidgets('one golfer is a golfer, not 1 golfers', (tester) async {
    await tester.pumpWidget(_wrap(
        const FlightHeader(label: 'C', size: 1, purse: 50)));
    expect(find.textContaining('1 golfer ·'), findsOneWidget);
  });
}
