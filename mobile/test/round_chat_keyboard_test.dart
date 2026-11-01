import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/keyboard_done_bar.dart';

/// Reported from the course: "I went to send a message and then got stuck in
/// the app with the keypad showing. The done button did nothing. I had to exit
/// the app to close the keyboard."
///
/// The round-chat composer is the only field in the app with
/// `TextInputAction.newline`, so its return key inserts a line break rather
/// than dismissing — which leaves the global Done bar as the only way out.
void main() {
  Widget host({double inset = 300, required Widget field}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
          child: KeyboardDismissal(
            child: Scaffold(
              body: Column(children: [const Expanded(child: SizedBox()), field]),
            ),
          ),
        ),
      );

  testWidgets('Done releases focus on a multiline composer', (t) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await t.pumpWidget(host(
      field: TextField(
        focusNode: node,
        minLines: 1,
        maxLines: 4,
        textInputAction: TextInputAction.newline,
      ),
    ));

    node.requestFocus();
    await t.pump();
    expect(node.hasFocus, isTrue, reason: 'field should be focused to start');

    await t.tap(find.text('Done'));
    await t.pumpAndSettle();

    expect(node.hasFocus, isFalse, reason: 'Done must release the keyboard');
  });

  testWidgets('Done releases focus on a plain single-line field', (t) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await t.pumpWidget(host(field: TextField(focusNode: node)));
    node.requestFocus();
    await t.pump();
    expect(node.hasFocus, isTrue);

    await t.tap(find.text('Done'));
    await t.pumpAndSettle();

    expect(node.hasFocus, isFalse);
  });
}
