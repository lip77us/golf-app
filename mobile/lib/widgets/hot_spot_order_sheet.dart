/// The Hot Spot anchor order, set by the group on its own first tee.
///
/// Four rows dragged into order, each saying which holes that golfer anchors.
/// It is NOT an organiser setting: the TD does not know who will be in which
/// cart, and a screen that let him set it would be writing something the
/// group has to undo on the tee.
///
/// **It locks when the first score goes in**, because it decides who anchored
/// hole 1 — changing it after that hole is scored rewrites what the hole
/// meant. The server refuses it too; this sheet does not open once locked.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';

/// Which holes a golfer at [position] anchors, given the group's play order
/// and how many golfers rotate.
///
/// Derived here only to LABEL the rows. The server owns the rule — this must
/// never become the thing the score is computed from, or there would be two
/// rotations to disagree.
List<int> holesAnchoredBy(List<int> playOrder, int position, int rotateCount) {
  if (rotateCount <= 0) return const [];
  return [
    for (var i = 0; i < playOrder.length; i++)
      if (i % rotateCount == position) playOrder[i],
  ];
}

class HotSpotOrderSheet extends StatefulWidget {
  final int foursomeId;
  final int roundId;

  /// Real golfers only — the borrowed 4th never anchors.
  final List<({int id, String name})> golfers;

  /// The group's play order, for the "anchors 1, 5, 9…" line.
  final List<int> playOrder;

  const HotSpotOrderSheet({
    super.key,
    required this.foursomeId,
    required this.roundId,
    required this.golfers,
    required this.playOrder,
  });

  @override
  State<HotSpotOrderSheet> createState() => _HotSpotOrderSheetState();
}

class _HotSpotOrderSheetState extends State<HotSpotOrderSheet> {
  late List<({int id, String name})> _order;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.golfers);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final client = context.read<AuthProvider>().client;
      await client.postHotSpotOrder(
          widget.foursomeId, _order.map((g) => g.id).toList());
      if (!mounted) return;
      await context.read<RoundProvider>().loadHotSpot(widget.roundId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = _order.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Hot Spot order', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Drag the handles into the order you will anchor. It locks when '
              'the first score goes in.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Flexible(
              // **An EXPLICIT handle per row — the app's standard.**
              // `buildDefaultDragHandles: true` draws a handle on desktop and
              // nothing at all on a phone: it wraps each row in a
              // `ReorderableDelayedDragStartListener`, so the row moves on a
              // LONG PRESS with no affordance saying so, under copy that said
              // "drag". Reported from the course as "it does not allow me to
              // drag and drop" — the long press did work, which is exactly
              // the problem: a gesture nothing on screen mentions.
              //
              // Every other reorder list in the app gives a visible handle —
              // wolf_screen, wolf_setup_screen, pink_ball_screen,
              // match_play_setup_screen, team_splitter_4, new_round_wizard,
              // six of six. This sheet was the one that took the default.
              //
              // `NeverScrollableScrollPhysics` because four rows never need
              // to scroll, and this sits in a draggable bottom sheet where a
              // list that can also scroll vertically is one more thing for a
              // drag to land in.
              child: ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: n,
                onReorder: (from, to) => setState(() {
                  if (to > from) to -= 1;
                  _order.insert(to, _order.removeAt(from));
                }),
                itemBuilder: (ctx, i) {
                  final holes =
                      holesAnchoredBy(widget.playOrder, i, n);
                  return ListTile(
                    key: ValueKey(_order[i].id),
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: Halved.deepPine,
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              color: Halved.cream, fontSize: 12)),
                    ),
                    title: Text(_order[i].name),
                    subtitle: Text(
                      holes.isEmpty
                          ? 'anchors no holes'
                          : 'anchors ${holes.join(', ')}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      // 44 points, because it is the only way to move a row.
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        child: Icon(Icons.drag_handle,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Set the order'),
            ),
          ],
        ),
      ),
    );
  }
}
