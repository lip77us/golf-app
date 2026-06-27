import 'package:flutter/material.dart';

/// Confirmation dialog shown before completing a round (which locks scores).
///
/// Shared by every game's "Done" / "Complete Round" action so the prompt is
/// identical everywhere.  [isMultiGroup] tailors the copy for multi-foursome
/// cup rounds, where finishing only closes the caller's own group and the
/// round flips to complete once every group is done.
///
/// Returns true when the user confirms.
Future<bool> confirmCompleteRound(
  BuildContext context, {
  bool isMultiGroup = false,
}) async {
  final body = isMultiGroup
      ? 'This will lock your group\'s scores. The round will be marked '
          'complete once every other group also finishes. You can still '
          'view live results in the meantime.'
      : 'This will mark the round as finished and lock all scores. You can '
          'still view the final results afterwards, and the round can be '
          'reopened from the leaderboard if needed.';

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(isMultiGroup ? 'Finish Your Group?' : 'Complete Round?'),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dctx).pop(true),
          child: Text(isMultiGroup ? 'Finish Group' : 'Complete Round'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
