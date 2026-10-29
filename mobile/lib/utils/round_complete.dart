import 'package:flutter/material.dart';

/// Confirmation dialog shown before completing a round (which locks scores).
///
/// Shared by every game's "Done" / "Complete Round" action so the prompt is
/// identical everywhere. [isMultiGroup] tailors the copy for multi-foursome
/// cup rounds, where finishing only closes the caller's own group.
///
/// ### Two kinds of gap, and they are not the same sentence
///
/// Reported from the course (26 Oct 2026): a Sixes round that was fully
/// scored warned `1 hole still has no score`. The hole had three of four.
///
/// A hole **nobody** has played and a hole **waiting on one golfer** are
/// different states, and saying "no score" about the second is how a golfer
/// learns to disbelieve the dialog — which is exactly what happened. So they
/// get different sentences, and both NAME the holes: a warning the reader
/// can check beats one they have to take on trust.
///
/// Either kind switches to the soft-gate "Finish early?" copy. Completing is
/// still allowed; the warning only makes the gap explicit.
///
/// Returns true when the user confirms.
Future<bool> confirmCompleteRound(
  BuildContext context, {
  bool isMultiGroup = false,
  List<int> unscoredHoles = const [],
  List<int> awaitingHoles = const [],
}) async {
  // A hole nobody has played is never ALSO a hole waiting on somebody.
  final blank = [...unscoredHoles]..sort();
  final waiting = [for (final h in awaitingHoles) if (!blank.contains(h)) h]
    ..sort();
  final earlyFinish = blank.isNotEmpty || waiting.isNotEmpty;

  final String title;
  final String body;
  final String confirmLabel;
  if (earlyFinish) {
    title = 'Finish early?';
    final parts = <String>[
      if (blank.isNotEmpty)
        blank.length == 1
            ? 'Hole ${blank.first} has no score'
            : '${blank.length} holes have no score (${_list(blank)})',
      if (waiting.isNotEmpty)
        waiting.length == 1
            ? 'Hole ${waiting.first} is missing one golfer\'s score'
            : '${waiting.length} holes are missing a golfer\'s score '
              '(${_list(waiting)})',
    ];
    body = '${parts.join(', and ')}. Completing now will lock the round as '
        'it stands. You can still view the results afterwards, and the round '
        'can be reopened from the leaderboard if needed.';
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

/// `4, 9 and 12` — long lists are capped, because a dialog naming eleven
/// holes is one nobody reads.
String _list(List<int> holes) {
  if (holes.length > 4) {
    return '${holes.take(4).join(', ')} and ${holes.length - 4} more';
  }
  if (holes.length == 1) return '${holes.first}';
  return '${holes.take(holes.length - 1).join(', ')} and ${holes.last}';
}
