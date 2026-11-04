/// utils/discard_draft.dart
///
/// "Leave without creating the round?" — the confirmation a setup wizard owes
/// before it throws away what somebody has typed into it.
///
/// Reported from a 60-golfer Multi-Group Skins round (3 Nov 2026): *"I got
/// stuck in a dialog without an esc and the only option was back arrow which
/// ended the wizard and I lost all of the players that I had added."*
///
/// Two separate things were wrong. The sheet he was in had no Cancel, which
/// is fixed in `widgets/scorecard_groups.dart`; and the casual wizard's app
/// bar arrow POPPED THE ROUTE, where the tournament wizard's and the
/// round-setup screen's have always stepped back through the wizard. Making
/// it step is the fix, and this is the other half: leaving from the first
/// step really does throw the draft away, and a wizard several minutes deep
/// should say so before it does.
///
/// [addedGolfers] adds the one piece of good news, and only when it is true:
/// a golfer created inline is written to the roster as he is created, so he
/// is not lost with the draft. Said unconditionally it would be noise; said
/// when it applies it answers the worry he actually had.
///
/// Returns true when the user means to leave.
library;

import 'package:flutter/material.dart';

Future<bool> confirmDiscardDraft(
  BuildContext context, {
  bool addedGolfers = false,
}) async {
  final body = StringBuffer(
      'The course, game and golfers you have picked here will be lost.');
  if (addedGolfers) {
    body.write(' Golfers you added are already saved to My Golfers, so you '
        'can pick them again.');
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Leave without creating the round?'),
      content: Text(body.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep setting up'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return go ?? false;
}
