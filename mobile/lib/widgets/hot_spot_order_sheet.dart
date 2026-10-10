/// The Hot Spot anchor order, set by the group on its own first tee.
///
/// Four rows dragged into order, each saying which holes that golfer anchors.
/// It is NOT an organiser setting: the TD does not know who will be in which
/// cart, and a screen that let him set it would be writing something the
/// group has to undo on the tee.
///
/// **Each POSITION locks as it is spent**, not the whole order at the first
/// score. A scored hole fixes the one position that anchored it; the rest are
/// still the group's to arrange, which is how Red Ball has always worked. A
/// group that teed off and then noticed it had the back three the wrong way
/// round used to have no way back.
///
/// A locked row draws a lock instead of a handle and cannot move — and no row
/// may move THROUGH it, because a reorder that shifted a locked row would
/// change which golfer anchored a hole that has been played. The free rows
/// are permuted among themselves and the locked ones stay exactly where they
/// are. The server enforces the same rule and names the position it refuses.
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

  /// Positions (0-based) that have already anchored a scored hole, from the
  /// server's `order_positions_locked`. They cannot move and nothing can move
  /// through them.
  final Set<int> lockedPositions;

  const HotSpotOrderSheet({
    super.key,
    required this.foursomeId,
    required this.roundId,
    required this.golfers,
    required this.playOrder,
    this.lockedPositions = const {},
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

  /// Move the golfer at [from] to [to], leaving every LOCKED position holding
  /// the golfer it already holds.
  ///
  /// A plain `removeAt`/`insert` shifts everything between the two indices, so
  /// a drag past a locked row would move the golfer who anchored a played
  /// hole. Instead the free slots are treated as a list of their own: the
  /// drag is mapped into that list, permuted there, and written back into the
  /// free slots in order. Locked slots are never touched, so a non-contiguous
  /// lock — which is what entering holes out of order produces — works the
  /// same as a leading one.
  void _reorder(int from, int to) {
    if (from == to) return;
    final locked = widget.lockedPositions;
    if (locked.contains(from) || locked.contains(to)) return;
    final free = [for (var i = 0; i < _order.length; i++)
        if (!locked.contains(i)) i];
    final a = free.indexOf(from);
    final b = free.indexOf(to);
    if (a < 0 || b < 0) return;
    final golfers = [for (final i in free) _order[i]];
    golfers.insert(b, golfers.removeAt(a));
    for (var k = 0; k < free.length; k++) {
      _order[free[k]] = golfers[k];
    }
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
                  _reorder(from, to);
                }),
                itemBuilder: (ctx, i) {
                  final holes =
                      holesAnchoredBy(widget.playOrder, i, n);
                  final locked = widget.lockedPositions.contains(i);
                  return ListTile(
                    key: ValueKey(_order[i].id),
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: locked
                          ? theme.colorScheme.surfaceContainerHighest
                          : Halved.deepPine,
                      child: Text('${i + 1}',
                          style: TextStyle(
                              color: locked
                                  ? theme.colorScheme.onSurfaceVariant
                                  : Halved.cream,
                              fontSize: 12)),
                    ),
                    title: Text(_order[i].name,
                        style: locked
                            ? TextStyle(
                                color: theme.colorScheme.onSurfaceVariant)
                            : null),
                    subtitle: Text(
                      holes.isEmpty
                          ? 'anchors no holes'
                          : locked
                              // Said once, on the row it applies to, rather
                              // than as a banner about "the order".
                              ? 'anchored ${holes.join(', ')} — played'
                              : 'anchors ${holes.join(', ')}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    // A lock where the handle would be: the row says why it
                    // cannot move, in the place you would reach to move it.
                    trailing: locked
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                            child: Icon(Icons.lock_outline,
                                size: 18,
                                color: theme.colorScheme.onSurfaceVariant),
                          )
                        : ReorderableDragStartListener(
                            index: i,
                            // 44 points — the only way to move a row.
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
