/// The Your pool sheet: everyone seated in a Multi-Group Skins round, to review
/// and remove (`handoff-add-players`, Paul 14 Nov 2026 — review and remove only,
/// so a golfer is added from the screen behind it, not from here).
///
/// It opens from the **+N more** tile when the seats row has collapsed to two
/// lines. The host owns who is seated, so [seated] is asked again after every
/// removal and the list follows.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'golfer_avatar.dart';

Future<void> showPoolSheet(
  BuildContext context, {
  required List<PlayerProfile> Function() seated,
  required int? meId,
  required void Function(PlayerProfile) onRemove,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x730B1F1A),
    builder: (_) => PoolSheet(seated: seated, meId: meId, onRemove: onRemove),
  );
}

class PoolSheet extends StatefulWidget {
  final List<PlayerProfile> Function() seated;
  final int? meId;
  final void Function(PlayerProfile) onRemove;

  const PoolSheet({
    super.key,
    required this.seated,
    required this.meId,
    required this.onRemove,
  });

  @override
  State<PoolSheet> createState() => _PoolSheetState();
}

class _PoolSheetState extends State<PoolSheet> {
  @override
  Widget build(BuildContext context) {
    final golfers = widget.seated();
    return Container(
      height: MediaQuery.of(context).size.height * 0.86,
      decoration: const BoxDecoration(
        color: Halved.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('Your pool',
                style: Halved.sectionHead()
                    .copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Done',
                style: Halved.body(color: Halved.pine, weight: FontWeight.w600)
                    .copyWith(fontSize: 14)),
          ),
        ]),
        Text(
            '${golfers.length} ${golfers.length == 1 ? 'golfer' : 'golfers'}. '
            'Remove anyone who is not playing.',
            style: Halved.body(color: Halved.muted).copyWith(fontSize: 12.5)),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.separated(
            itemCount: golfers.length,
            separatorBuilder: (_, __) => const SizedBox(height: 7),
            itemBuilder: (_, i) {
              final p = golfers[i];
              final isMe = p.id == widget.meId;
              return Container(
                padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE7EDE8)),
                ),
                child: Row(children: [
                  GolferAvatar(name: p.name, onHalved: p.isOnApp, size: 34),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(isMe ? '${p.name} (you)' : p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Halved.body(
                                      color: Halved.deepPine,
                                      weight: FontWeight.w600)
                                  .copyWith(fontSize: 15)),
                          Text('Index ${p.handicapIndex}',
                              style: Halved.body(color: Halved.muted)
                                  .copyWith(fontSize: 12)),
                        ]),
                  ),
                  // You cannot take yourself out of your own round.
                  if (!isMe)
                    TextButton(
                      onPressed: () {
                        widget.onRemove(p);
                        setState(() {});
                      },
                      child: Text('Remove',
                          style: Halved.body(
                                  color: Halved.warning,
                                  weight: FontWeight.w700)
                              .copyWith(fontSize: 13)),
                    ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}
