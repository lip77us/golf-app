import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/round_start.dart';

void main() {
  testWidgets('the group name never splits across lines beside the tag', (t) async {
    await t.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoundHero(
          title: 'Group 2',
          yourGroupTag: true,
          teeTime: '9:10',
          gameLine: '40 Balls',
          golfers: const [],
        ),
      ),
    ));
    final title = t.getSize(find.text('Group 2'));
    // One line of 24pt text is well under two lines' height.
    expect(title.height, lessThan(40));
    expect(find.text('YOUR GROUP'), findsOneWidget);
  });
}
