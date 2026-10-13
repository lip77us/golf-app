/// widgets/scorecard_groups.dart
///
/// Who shares a scorecard — the groups of a Multi-Group Skins round.
///
/// A group is a `Foursome`, which is a scorecard, which is ONE person keeping
/// the score; the pool federates across them, which is the game. Everyone
/// starts on their own card because most of a pool is spread across a field,
/// and the work is saying which few play together.
///
/// Its own widget because the second case Paul named — skins attached to
/// groups that already EXIST — will want the same control, and because a list
/// with rules in it ought to be testable without standing up the whole
/// create-round screen.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import '../utils/skins_cards.dart';
import 'halved_mark.dart';

class ScorecardGroups extends StatelessWidget {
  /// The golfers in the round, in roster order.
  final List<PlayerProfile> players;

  /// player id → group number. Numbers may have gaps; the LABEL comes from
  /// position, so the list never reads "Group 1, Group 3".
  final Map<int, int> groups;

  final ValueChanged<Map<int, int>> onChanged;

  const ScorecardGroups({
    super.key,
    required this.players,
    required this.groups,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final byId = {for (final p in players) p.id: p};
    final mine = {
      for (final e in groups.entries)
        if (byId.containsKey(e.key)) e.key: e.value,
    };
    final cards = cardsOf(mine);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, entry) in cards.entries.indexed) ...[
          _card(context, i + 1, entry.key, entry.value, byId, cards),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _card(BuildContext context, int label, int number, List<int> ids,
      Map<int, PlayerProfile> byId, Map<int, List<int>> cards) {
    final theme = Theme.of(context);
    final full = ids.length >= kMaxCardSize;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Halved.cardBorder),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Group $label',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text(
              ids.length == 1
                  ? 'own card'
                  : '${ids.length} golfers · one card',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
          const SizedBox(height: 2),
          for (final id in ids)
            Row(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Flexible(
                      child: Text(byId[id]?.name ?? 'Golfer',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium),
                    ),
                    if (byId[id]?.isOnApp == true) ...[
                      const SizedBox(width: 6),
                      const HalvedMark(size: 13),
                    ] else if (!ids.any((o) => byId[o]?.isOnApp == true)) ...[
                      // Named on the ROW, not only in the message under the
                      // list: the golfer who has to move is the one to point
                      // at. Silent once somebody on his card can score him.
                      const SizedBox(width: 6),
                      Text('needs a scorer',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.error)),
                    ],
                  ]),
                ),
              ),
              TextButton(
                onPressed: () => _move(context, id, number, byId, cards),
                child: const Text('Move'),
              ),
            ]),
          if (full)
            Text('Full — a group is a foursome.',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// Move one golfer onto another group, or onto a card of his own.
  ///
  /// A sheet rather than a dropdown: the `G1 / G2` picker this replaces said
  /// nothing about who was already there, which is the only thing a golfer
  /// deciding this cares about.
  Future<void> _move(BuildContext context, int id, int from,
      Map<int, PlayerProfile> byId, Map<int, List<int>> cards) async {
    final target = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12),
            Text('Move ${byId[id]?.name ?? 'golfer'}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final (i, entry) in cards.entries.indexed)
              if (entry.key != from)
                ListTile(
                  enabled: entry.value.length < kMaxCardSize,
                  title: Text('Group ${i + 1}'),
                  subtitle: Text(entry.value
                      .map((p) => byId[p]?.displayShort ?? '?')
                      .join(', ')),
                  trailing: entry.value.length >= kMaxCardSize
                      ? const Text('Full')
                      : null,
                  onTap: () => Navigator.of(ctx).pop(entry.key),
                ),
            // Only offered when it would change something — a golfer already
            // alone has nowhere new to go.
            if ((cards[from]?.length ?? 0) > 1)
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('A card of his own'),
                onTap: () => Navigator.of(ctx).pop(-1),
              ),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
    if (target == null) return;
    final next = Map<int, int>.from(groups);
    next[id] = target == -1 ? nextFreeCard(groups.values) : target;
    onChanged(next);
  }
}
