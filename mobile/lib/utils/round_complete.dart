import 'package:flutter/material.dart';

/// Confirmation dialog shown before completing a round (which locks scores).
///
/// Shared by every game's "Done" / "Complete Round" action so the prompt is
/// identical everywhere.  [isMultiGroup] tailors the copy for multi-foursome
/// cup rounds, where finishing only closes the caller's own group and the
/// round flips to complete once every group is done.
///
/// [unscoredHoles] > 0 switches to the soft-gate "Finish early?" copy — used
/// when completing before every hole has a score (e.g. a match decided before
/// the 18th).  Completing is still allowed; the warning just makes the blank
/// holes explicit.
///
/// Returns true when the user confirms.
Future<bool> confirmCompleteRound(
  BuildContext context, {
  bool isMultiGroup = false,
  int unscoredHoles = 0,
}) async {
  final earlyFinish = unscoredHoles > 0;

  final String title;
  final String body;
  final String confirmLabel;
  if (earlyFinish) {
    title = 'Finish early?';
    final holesPhrase = unscoredHoles == 1
        ? '1 hole still has no score'
        : '$unscoredHoles holes still have no score';
    body = '$holesPhrase. Completing now will lock the round with those '
        'holes left blank. You can still view the results afterwards, and the '
        'round can be reopened from the leaderboard if needed.';
    confirmLabel = 'Complete Anyway';
  } else if (isMultiGroup) {
    title = 'Finish Your Group?';
    body = 'This will lock your group\'s scores. The round will be marked '
        'complete once every other group also finishes. You can still '
        'view live results in the meantime.';
    confirmLabel = 'Finish Group';
  } else {
    title = 'Complete Round?';
    body = 'This will mark the round as finished and lock all scores. You can '
        'still view the final results afterwards, and the round can be '
        'reopened from the leaderboard if needed.';
    confirmLabel = 'Complete Round';
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) {
      final scheme = Theme.of(dctx).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: earlyFinish
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}
