/// utils/skins_pool_link.dart
/// ---------------------------
/// "Link to a Multi-Group Skins pool" flow (docs/multi-skins-cross-round.md).
///
/// A foursome round joins a cross-round skins pool by pasting the pool's host
/// round /watch/<token>/ spectator link. We resolve the token, show the pool +
/// the exact overlap of THIS round's players with the pool roster (auto-matched
/// by phone), and on confirm link the round so its scores feed the pool.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';

/// Run the paste-link → resolve → confirm → join flow for [roundId].
/// Returns true if the round was linked into a pool.
Future<bool> linkRoundToPoolFlow(BuildContext context,
    {required int roundId}) async {
  final client   = context.read<AuthProvider>().client;
  final messenger = ScaffoldMessenger.of(context);

  final raw = await _promptForLink(context);
  if (raw == null) return false;                       // cancelled

  final token = ApiClient.parsePoolToken(raw);
  if (token == null) {
    messenger.showSnackBar(const SnackBar(
      content: Text("Couldn't read a pool link there — paste the leaderboard "
          "share link."),
    ));
    return false;
  }

  SkinsPoolResolve pool;
  try {
    pool = await client.resolveSkinsPool(token, roundId: roundId);
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text(e.statusCode == 404
          ? 'No Multi-Group Skins pool found for that link.'
          : e.message),
    ));
    return false;
  }

  final overlap = pool.overlapMembers;
  if (overlap.isEmpty) {
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('No pool players in this round'),
        content: Text(
          'None of this round\'s golfers are in the ${pool.courseName} '
          'Multi-Group Skins pool. Add them to the pool first, or link a '
          'round they\'re playing in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  if (!context.mounted) return false;
  final confirmed = await _confirmLink(context, pool, overlap);
  if (confirmed != true) return false;

  try {
    await client.joinSkinsPool(token, roundId);
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }

  // Refresh so the pool tab appears on this round's leaderboard.
  if (context.mounted) {
    await context.read<RoundProvider>().loadRound(roundId);
  }
  messenger.showSnackBar(SnackBar(
    content: Text('Linked to the ${pool.courseName} skins pool — '
        '${_names(overlap)} in the pool.'),
  ));
  return true;
}

Future<String?> _promptForLink(BuildContext context) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Link to a Skins pool'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Paste the pool\'s leaderboard share link. Your players who are in '
            'the pool will have their scores added to it.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'https://halved.golf/watch/…',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ctl.text),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}

Future<bool?> _confirmLink(BuildContext context, SkinsPoolResolve pool,
    List<SkinsPoolRosterMember> overlap) {
  final bet = pool.betUnit == pool.betUnit.roundToDouble()
      ? pool.betUnit.toStringAsFixed(0)
      : pool.betUnit.toStringAsFixed(2);
  return showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Link this round?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${pool.courseName} · Multi-Group Skins · \$$bet per player'),
          const SizedBox(height: 12),
          Text('From this round, these golfers are in the pool:',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(_names(overlap),
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Link'),
        ),
      ],
    ),
  );
}

String _names(List<SkinsPoolRosterMember> m) =>
    m.map((e) => e.name.isNotEmpty ? e.name : e.shortName).join(', ');
