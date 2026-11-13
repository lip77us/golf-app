/// widgets/pink_ball_order_sheet.dart
///
/// The ball rotation sheet — who carries the Pink Ball (or Devil Ball, or
/// whatever the TD called it) on which hole. Shared by `pink_ball_screen` and
/// the shared score-entry screen, which a tournament group scored on Stroke
/// Play or Stableford now enters on.
///
/// The server stores the order per foursome, 18 long, and the carrier on a
/// hole is `carrier_on_hole` over it; an EMPTY order means nobody carries the
/// ball and the lost-ball switch files nothing. So the group has to say the
/// order out loud before the first score — which is why score entry opens
/// this sheet by itself on the first tee.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';

/// How many leading positions are already fixed by scored holes: once hole 1
/// is scored position 1 is fixed, and so on. With N golfers, after N-1 holes
/// the last position is inferred, so everything is locked.
int pinkBallLockedCount(List<Membership> members, Scorecard? sc) {
  var scored = 0;
  if (sc != null) {
    for (final hole in sc.holes) {
      final all = members.every((m) => hole.scores
          .any((s) => s.playerId == m.player.id && s.grossScore != null));
      if (all) {
        scored++;
      } else {
        break; // only consecutive complete holes from the first tee
      }
    }
  }
  return scored >= members.length - 1 ? members.length : scored;
}

/// Open the sheet for [foursome] and post the order on confirm. Returns true
/// if a new order was saved.
Future<bool> openPinkBallOrder(
  BuildContext context, {
  required Foursome foursome,
  required Scorecard? scorecard,
  required String gameName,
}) async {
  final members =
      foursome.memberships.where((m) => !m.player.isPhantom).toList();
  if (members.isEmpty) return false;
  final stored = foursome.pinkBallOrder;
  final ordered = <Membership>[];
  final seen = <int>{};
  for (final pid in stored) {
    if (seen.add(pid)) {
      final m = members.where((m) => m.player.id == pid).firstOrNull;
      if (m != null) ordered.add(m);
    }
  }
  for (final m in members) {
    if (!seen.contains(m.player.id)) ordered.add(m);
  }
  final locked = pinkBallLockedCount(members, scorecard);
  final client = context.read<AuthProvider>().client;
  var saved = false;
  await showModalBottomSheet<void>(
    context: context,
    isDismissible: locked >= members.length,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => PinkBallOrderSheet(
      gameName: gameName,
      members: ordered,
      lockedCount: locked,
      onConfirm: (order) async {
        final full =
            List.generate(18, (i) => order[i % order.length]);
        try {
          await client.postPinkBallOrder(foursome.id, order: full);
          saved = true;
        } catch (_) {
          // Non-fatal: the order stays as it was; they can retry.
        }
      },
    ),
  );
  return saved;
}

// ---------------------------------------------------------------------------
// Order setup bottom sheet  (shown once per foursome before scoring starts)
// ---------------------------------------------------------------------------

class PinkBallOrderSheet extends StatefulWidget {
  final String           gameName;
  final List<Membership> members;
  /// Number of leading positions that are already fixed by played holes.
  /// 0 = all positions freely reorderable.
  final int              lockedCount;
  final Future<void> Function(List<int>) onConfirm;

  const PinkBallOrderSheet({
    required this.gameName,
    required this.members,
    required this.lockedCount,
    required this.onConfirm,
  });

  @override
  State<PinkBallOrderSheet> createState() => _PinkBallOrderSheetState();
}

class _PinkBallOrderSheetState extends State<PinkBallOrderSheet> {
  late final List<Membership> _ordered;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ordered = List.of(widget.members);
  }

  bool get _allLocked => widget.lockedCount >= _ordered.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: MediaQuery.of(context).viewInsets,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ball Rotation',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    _allLocked
                        ? 'The rotation is locked — at least 3 holes have been scored.'
                        : widget.lockedCount > 0
                            ? 'The first ${widget.lockedCount} position${widget.lockedCount > 1 ? 's are' : ' is'} locked by scored holes. '
                              'Drag the remaining players to set their order.'
                            : 'Drag to set the order your group will carry the '
                              '${widget.gameName}. The rotation repeats across all 18 holes.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),

            // Reorderable player list.
            // Uses ReorderableListView.builder with buildDefaultDragHandles: false
            // so that ReorderableDragStartListener gives precise drag control.
            // Locked rows get a lock icon instead of a drag handle.
            SizedBox(
              height: _ordered.length * 76.0,
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _ordered.length,
                onReorder: (oldIndex, newIndex) {
                  // Prevent dragging a locked row or dropping into a locked slot.
                  if (oldIndex < widget.lockedCount) return;
                  final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
                  if (target < widget.lockedCount) return;
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final item = _ordered.removeAt(oldIndex);
                    _ordered.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, idx) {
                  final m        = _ordered[idx];
                  final isLocked = idx < widget.lockedCount;
                  return Card(
                    key: ValueKey(m.player.id),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _posColor(idx),
                        radius: 16,
                        child: Text(
                          '${idx + 1}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                        ),
                      ),
                      title: Text(m.player.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('HCP ${m.playingHandicap}',
                          style: theme.textTheme.bodySmall),
                      trailing: isLocked
                          ? Icon(Icons.lock_outline,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withOpacity(0.45))
                          : ReorderableDragStartListener(
                              index: idx,
                              child: const Icon(Icons.drag_handle),
                            ),
                    ),
                  );
                },
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: _allLocked
                    ? OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      )
                    : FilledButton(
                        onPressed: _saving
                            ? null
                            : () async {
                                setState(() => _saving = true);
                                final playerOrder =
                                    _ordered.map((m) => m.player.id).toList();
                                await widget.onConfirm(playerOrder);
                                if (context.mounted) Navigator.of(context).pop();
                              },
                        child: _saving
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('Confirm Rotation'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _posColor(int index) {
    const colors = [Colors.blue, Colors.orange, Colors.green, Colors.purple];
    return colors[index % colors.length];
  }
}

