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
      // The list IS the sheet's content and it is as long as the field, so it
      // has to be free to take the height it needs — see [_MoveSheet].
      isScrollControlled: true,
      builder: (ctx) => _MoveSheet(
        name: byId[id]?.name ?? 'golfer',
        from: from,
        cards: cards,
        byId: byId,
      ),
    );
    if (target == null) return;
    final next = Map<int, int>.from(groups);
    next[id] = target == -1 ? nextFreeCard(groups.values) : target;
    onChanged(next);
  }
}

/// Above this many destinations the sheet offers a search box. A sheet is
/// about half a phone, so eight tiles is roughly what fits; past that, the
/// scroll on its own is a long one. (The sparse 40 Balls card draws the same
/// conclusion at twelve, where the rows are golfers rather than groups.)
const int _kSearchAbove = 8;

/// Where to move a golfer: another group, or a card of his own.
///
/// Reported from a 60-golfer pool (3 Nov 2026): *"The group mover does not
/// scroll and so the bottom groups could not be adjusted"*, and *"I got stuck
/// in a dialog without an esc and the only option was back arrow which ended
/// the wizard"*. Both are this sheet, and three things were wrong with it.
///
/// **It could not scroll.** Everyone starts on his own card, because most of
/// a pool is spread across the field — so the destination list is as long as
/// the field, 59 tiles for a 60-man pool. The old sheet was a plain `Column`,
/// which does not scroll: it overflows its box and every tile past the fold
/// is simply unreachable. The list is the sheet's whole content, so the list
/// is what has to scroll, and the sheet is capped at three quarters of the
/// screen rather than sized to its contents.
///
/// **There was no visible way out.** Tapping the barrier always dismissed it,
/// but a sheet with no Cancel is one people escape with the back arrow — and
/// in the create-round wizard that arrow used to end the wizard. The fix to
/// that is in `casual_round_screen.dart`; the missing Cancel is what sent him
/// looking for it.
///
/// **A card of his own was at the BOTTOM.** It is pinned above the list now:
/// it is not a group, and anything below a 59-tile list is exactly as
/// unreachable as the bottom group was.
class _MoveSheet extends StatefulWidget {
  final String name;

  /// The stored number of the card he is on — the one destination not offered.
  final int from;

  /// Stored group number → the ids on it, in group order.
  final Map<int, List<int>> cards;

  final Map<int, PlayerProfile> byId;

  const _MoveSheet({
    required this.name,
    required this.from,
    required this.cards,
    required this.byId,
  });

  @override
  State<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<_MoveSheet> {
  final TextEditingController _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Who is on a card. Short names, deliberately: a card holds four, and four
  /// full names do not fit a subtitle. The search is what finds a golfer.
  String _namesOn(List<int> ids) =>
      ids.map((p) => widget.byId[p]?.displayShort ?? '?').join(', ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);

    // Every card except the one he is already on, carrying its DISPLAY label
    // (position, not the stored number — the numbers have gaps).
    final all = <({int label, int number, List<int> ids})>[
      for (final (i, e) in widget.cards.entries.indexed)
        if (e.key != widget.from) (label: i + 1, number: e.key, ids: e.value),
    ];
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? all
        : [
            for (final c in all)
              if ('group ${c.label}'.contains(q) ||
                  c.ids.any((p) =>
                      (widget.byId[p]?.name ?? '').toLowerCase().contains(q)))
                c,
          ];

    return Padding(
      // isScrollControlled lets the sheet clear the soft keyboard, which the
      // search field needs.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.75),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(children: [
                Expanded(
                  child: Text('Move ${widget.name}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ]),
            ),
            // Only offered when it would change something — a golfer already
            // alone has nowhere new to go.
            if ((widget.cards[widget.from]?.length ?? 0) > 1)
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('A card of his own'),
                onTap: () => Navigator.of(context).pop(-1),
              ),
            if (all.length > _kSearchAbove)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _ctrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Find a group or a golfer',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text('No group has a golfer called "$_query".',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final c = shown[i];
                    final full = c.ids.length >= kMaxCardSize;
                    return ListTile(
                      enabled: !full,
                      title: Text('Group ${c.label}'),
                      subtitle: Text(_namesOn(c.ids)),
                      trailing: full ? const Text('Full') : null,
                      onTap: () => Navigator.of(context).pop(c.number),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }
}
