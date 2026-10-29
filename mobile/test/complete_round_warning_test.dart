import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/round_complete.dart';

/// Reported from the course (26 Oct 2026): a Sixes round that was fully
/// scored warned `1 hole still has no score`. The hole had three of four.
///
/// A hole nobody has played and a hole waiting on one golfer are different
/// states, and calling the second "no score" is how a golfer learns to
/// disbelieve the dialog — which is exactly what happened.

Future<String?> _body(WidgetTester t, {
  List<int> unscored = const [],
  List<int> awaiting = const [],
  bool multi = false,
}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(builder: (ctx) => TextButton(
        onPressed: () => confirmCompleteRound(ctx,
            isMultiGroup: multi,
            unscoredHoles: unscored,
            awaitingHoles: awaiting),
        child: const Text('go'),
      )),
    ),
  ));
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
  final dialog = find.byType(AlertDialog);
  final content = find.descendant(of: dialog, matching: find.byType(Text));
  final texts = t.widgetList<Text>(content).map((w) => w.data ?? '').toList();
  // title, body, then the two action labels
  return texts.length > 1 ? texts[1] : null;
}

String? _title(WidgetTester t) {
  final d = t.widget<AlertDialog>(find.byType(AlertDialog));
  return (d.title as Text?)?.data;
}

void main() {
  testWidgets('nothing missing: the plain confirmation', (t) async {
    final body = await _body(t);
    expect(_title(t), 'Complete Round?');
    expect(body, isNot(contains('no score')));
  });

  testWidgets('a hole nobody played is named, not counted', (t) async {
    final body = await _body(t, unscored: [18]);
    expect(_title(t), 'Finish early?');
    expect(body, contains('Hole 18 has no score'));
  });

  testWidgets('a hole missing ONE golfer says so, and does not say "no score"',
      (t) async {
    // The exact case from the course.
    final body = await _body(t, awaiting: [7]);
    expect(_title(t), 'Finish early?');
    expect(body, contains("Hole 7 is missing one golfer's score"));
    expect(body, isNot(contains('has no score')),
        reason: 'the hole had three of four — saying it has none is how a '
                'golfer learns to disbelieve the warning');
  });

  testWidgets('both kinds read as two clauses, not one', (t) async {
    final body = await _body(t, unscored: [17, 18], awaiting: [7]);
    expect(body, contains('2 holes have no score'));
    expect(body, contains('17 and 18'));
    expect(body, contains("missing one golfer's score"));
  });

  testWidgets('a hole cannot be both — blank wins', (t) async {
    // The server can legitimately report a hole in both lists if the two
    // were ever computed apart; one sentence about it, not two.
    final body = await _body(t, unscored: [9], awaiting: [9]);
    expect(body, contains('Hole 9 has no score'));
    expect(body, isNot(contains('missing one')));
  });

  testWidgets('a long list is capped rather than recited', (t) async {
    final body = await _body(t, unscored: [1, 2, 3, 4, 5, 6, 7]);
    expect(body, contains('7 holes have no score'));
    expect(body, contains('and 3 more'));
  });

  testWidgets('a multi-group round keeps its own copy', (t) async {
    final body = await _body(t, multi: true);
    expect(_title(t), 'Finish Your Group?');
    expect(body, contains('every other group'));
  });

  testWidgets('a gap outranks the multi-group copy', (t) async {
    // Locking with holes missing is the more important thing to say.
    await _body(t, multi: true, awaiting: [4]);
    expect(_title(t), 'Finish early?');
  });
}
