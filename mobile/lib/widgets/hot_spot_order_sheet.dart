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
              'Drag into the order you will anchor. It locks when the first '
              'score goes in.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: true,
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
