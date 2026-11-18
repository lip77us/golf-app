import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/halved_marks.dart';

void main() {
  test('the home-course bar is first in the scrolling content and only without a home course', () {
    final src = File('lib/screens/home_screen.dart').readAsStringSync();
    final i = src.indexOf('_HomeCourseBar(onTap: _setHomeCourse)');
    expect(i, greaterThan(0));
    final gate = src.substring(src.lastIndexOf('if (', i), i);
    expect(gate, contains('homeCourseId == null'));
    // First item of the sections list, ahead of the header.
    expect(src.indexOf('_Header(', i), greaterThan(i));
  });

  testWidgets('the marks draw', (t) async {
    await t.pumpWidget(const MaterialApp(
        home: Row(children: [StatsMark(), FlagMark()])));
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
