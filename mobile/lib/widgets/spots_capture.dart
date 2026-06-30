/// widgets/spots_capture.dart
/// --------------------------
/// Shared Spots capture used by every score-entry screen (the universal one and
/// the dedicated Wolf / Rabbit screens): the inline ⊖ N spots ⊕ control plus a
/// mixin that owns the optimistic per-hole tally + debounced POST.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';

/// Inline Spots control under a player name — ⊖ N spots ⊕. Always shows the
/// minus (spots can go negative) and starts at "0 spots".
class SpotsDots extends StatelessWidget {
  final int          count;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const SpotsDots({
    super.key,
    required this.count,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onRemove,
          child: Icon(Icons.remove_circle_outline,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 4),
        Text(
          '$count spot${count.abs() == 1 ? '' : 's'}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: count == 0
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.tertiary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onAdd,
          child: Icon(Icons.add_circle_outline,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Per-hole Spots tally capture for a score-entry screen. Manages optimistic
/// overrides + a debounced tally POST + summary refresh. Call [disposeSpots]
/// from the State's dispose().
mixin SpotsCaptureMixin<T extends StatefulWidget> on State<T> {
  final Map<int, Map<int, int>> _spotsOverride = {};
  Timer? _spotsDebounce;

  /// True when Spots is configured for this round (so the controls should show).
  bool spotsActive(RoundProvider rp) {
    final games = rp.round?.activeGames ?? const <String>[];
    return games.contains('spots') &&
        (rp.spotsSummary?.players.isNotEmpty ?? false);
  }

  /// Current count for a player on a hole — pending override else the summary.
  int spotsCount(int pid, int hole, SpotsSummary? s) =>
      _spotsOverride[hole]?[pid] ?? (s?.countFor(pid, hole) ?? 0);

  void adjustSpots(int foursomeId, int pid, int hole, int delta) {
    final rp  = context.read<RoundProvider>();
    final cur = spotsCount(pid, hole, rp.spotsSummary);
    final next = (cur + delta).clamp(-20, 20);
    setState(() => (_spotsOverride[hole] ??= {})[pid] = next);
    // Coalesce rapid +/- into one POST (also avoids out-of-order responses).
    _spotsDebounce?.cancel();
    _spotsDebounce =
        Timer(const Duration(milliseconds: 450), () => _pushSpots(foursomeId, hole));
  }

  Future<void> _pushSpots(int foursomeId, int hole) async {
    final rp     = context.read<RoundProvider>();
    final client = context.read<AuthProvider>().client;
    final fs = rp.round?.foursomes
        .where((f) => f.id == foursomeId).firstOrNull;
    if (fs == null) return;
    final entries = [
      for (final m in fs.memberships.where((m) => !m.player.isPhantom))
        {'player_id': m.player.id,
         'count': spotsCount(m.player.id, hole, rp.spotsSummary)},
    ];
    try {
      final summary = await client.postSpotsTally(
          foursomeId, holeNumber: hole, entries: entries);
      if (!mounted) return;
      rp.setSpotsSummary(summary);
      setState(() => _spotsOverride.remove(hole));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save spots. Tap again to retry.')));
      }
    }
  }

  void disposeSpots() => _spotsDebounce?.cancel();
}
