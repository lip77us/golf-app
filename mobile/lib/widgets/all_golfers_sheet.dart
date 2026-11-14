/// The All golfers sheet (`handoff-add-players`): everyone in your golfers,
/// regulars first, each with an Add / Added pill.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import '../utils/add_players.dart';
import 'add_players_body.dart' show AddPlayersResultRow;
import 'golfer_avatar.dart';

/// Opens the sheet. [onToggle] is called for a tap on a golfer (seat or unseat)
/// and the sheet then reads [seatedIds] again, so the pills follow the host.
Future<void> showAllGolfersSheet(
  BuildContext context, {
  required List<PlayerProfile> golfers,
  required RoundCounts counts,
  required Set<int> Function() seatedIds,
  required void Function(PlayerProfile) onToggle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x730B1F1A),
    builder: (_) => AllGolfersSheet(
      golfers: golfers,
      counts: counts,
      seatedIds: seatedIds,
      onToggle: onToggle,
    ),
  );
}

class AllGolfersSheet extends StatefulWidget {
  final List<PlayerProfile> golfers;
  final RoundCounts counts;
  final Set<int> Function() seatedIds;
  final void Function(PlayerProfile) onToggle;

  const AllGolfersSheet({
    super.key,
    required this.golfers,
    required this.counts,
    required this.seatedIds,
    required this.onToggle,
  });

  @override
  State<AllGolfersSheet> createState() => _AllGolfersSheetState();
}

class _AllGolfersSheetState extends State<AllGolfersSheet> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final seated = widget.seatedIds();
    final q = _filter.trim();
    final shown = q.isEmpty
        ? widget.golfers
        : [
            for (final p in widget.golfers)
              if (nameMatches(p.name, q) || phoneMatches(p.phone, q)) p
          ];
    return Container(
      height: MediaQuery.of(context).size.height * 0.86,
      decoration: const BoxDecoration(
        color: Halved.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 14, 16, MediaQuery.of(context).viewInsets.bottom + 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('All your golfers',
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
        Text('Everyone you have played with, most rounds first.',
            style: Halved.body(color: Halved.muted).copyWith(fontSize: 12.5)),
        const SizedBox(height: 10),
        TextField(
          onChanged: (v) => setState(() => _filter = v),
          decoration: InputDecoration(
            hintText: 'Filter your golfers',
            prefixIcon: const Icon(Icons.search, size: 20),
            filled: true,
            fillColor: Colors.white,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Halved.cardBorder, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Halved.pine, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text('NO GOLFER CALLED "${q.toUpperCase()}"',
                      style: Halved.label(
                              color: Halved.muted, weight: FontWeight.w700)
                          .copyWith(fontSize: 10.5, letterSpacing: 0.8)),
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final p = shown[i];
                    final played = widget.counts[p.id]?.rounds ?? 0;
                    return AddPlayersResultRow(
                      avatar: GolferAvatar(
                          name: p.name, onHalved: p.isOnApp, size: 34),
                      name: p.name,
                      sub: 'Index ${p.handicapIndex} · ${playedLabel(played)}',
                      added: seated.contains(p.id),
                      onTap: () {
                        widget.onToggle(p);
                        setState(() {});
                      },
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
