import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';

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

/// Completes [roundId], and when the field has not finished, offers the TD
/// the force — NAMING the groups that are holding it open.
///
/// ### Why this is shared and not a method on a screen
///
/// Reported from TPSGC Fall Scramble 2026 (30 Oct 2026): *"I can not close
/// the Fall scramble. It stays in my active tab no matter what."* Ten of its
/// fourteen groups never entered a score, so the server was right to wait —
/// and the force built for exactly this (TPSGC 2026 Ryder Cup, closed by
/// hand over SSH) lived in `score_entry_screen` alone. **A Foursome Play
/// round never opens that screen**; it routes to `/team-play-score`, which
/// has no complete action at all, so the only button is the round hub's —
/// and that one posted no `force`.
///
/// Worse than the Ryder Cup case it was meant to fix: the hub navigates to
/// the leaderboard on a non-null response, so the tap LOOKED like it worked
/// while the round stayed `in_progress` and the tournament stayed in Active.
/// No snackbar, nothing to act on. Hence "no matter what".
///
/// Same shape as the day bet's picker and Hot Seat's Road Trip sheet: one
/// rule reachable from one screen and not the other. So the flow lives here,
/// where any Complete Round action can reach it.
///
/// **Driven entirely off the server's answer.** `canForceComplete` is
/// `is_td and not all_done and not single_foursome`, so a status that is not
/// `complete` with no force on offer means the caller is a group scorer — the
/// one case the wait is actually for. Deriving that on the phone would be a
/// second copy of a rule the server already states, and the client must never
/// offer a button the server will ignore.
///
/// **The nine dedicated play screens still call `completeRound` directly**,
/// and that is deliberate rather than missed: Wolf, Points 5-3-1, Rabbit,
/// Survivor, Skins, Nassau, Triple Nassau, Quota Nassau and Sequoya 3s are
/// casual games on one foursome, and the server completes a single-foursome
/// round on the first call — there is no force to offer. Anything that can
/// host a FIELD comes through here.
///
/// Returns the final leaderboard — the forced one when it was forced — or
/// null when the call failed (the error is shown).
Future<Leaderboard?> completeRoundOrOfferForce(
  BuildContext context, {
  required int roundId,
}) async {
  final rp        = context.read<RoundProvider>();
  final messenger = ScaffoldMessenger.of(context);
  // Captured before the await: the messenger and the colour outlive this
  // context, and the snackbars below are shown after it.
  final errorColour = Theme.of(context).colorScheme.error;

  final lb = await rp.completeRound(roundId);
  if (lb == null) {
    messenger.showSnackBar(SnackBar(
      content: Text(rp.error ?? 'Could not complete round.'),
      backgroundColor: errorColour,
    ));
    return null;
  }
  if (lb.status == 'complete' || !context.mounted) return lb;

  if (!lb.canForceComplete) {
    messenger.showSnackBar(const SnackBar(
      duration: Duration(seconds: 4),
      content: Text(
        'Your group is finished. The round will close once every '
        'other group also completes.',
      ),
    ));
    return lb;
  }

  if (!await confirmForceComplete(context, lb.groupsOutstanding)) return lb;
  if (!context.mounted) return lb;

  final forced = await rp.completeRound(roundId, force: true);
  if (forced?.status == 'complete') {
    messenger.showSnackBar(const SnackBar(content: Text('Round closed.')));
  } else if (forced == null) {
    messenger.showSnackBar(SnackBar(
      content: Text(rp.error ?? 'Could not close the round.'),
      backgroundColor: errorColour,
    ));
  }
  return forced ?? lb;
}


/// The force dialog: it NAMES the groups holding the round open.
///
/// Its own function so it can be tested without a provider, and because the
/// naming is the part that was missing long before the force was — *"Some
/// groups have not finished"* is not something a TD can act on, where
/// `Group 7 — 0 of 18` is.
Future<bool> confirmForceComplete(
  BuildContext context,
  List<Map<String, dynamic>> outstanding,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('Close the round anyway?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(outstanding.length == 1
                ? 'One group has not finished:'
                : '${outstanding.length} groups have not finished:'),
            const SizedBox(height: 8),
            // Named and counted. "Some groups have not finished" is not
            // something a TD can act on; "Group 7 — 0 of 18" is.
            for (final g in outstanding)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '· ${g['name'] ?? 'Group ${g['group_number']}'} — '
                  '${g['holes_scored']} of ${g['holes_expected']} holes',
                  style: Theme.of(dctx).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Closing now scores their matches on what has been '
              'entered, and a group with no scores counts for nothing. '
              'You can reopen the round afterwards.',
              style: Theme.of(dctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: const Text('Keep it open'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dctx).pop(true),
          child: const Text('Close the round'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
