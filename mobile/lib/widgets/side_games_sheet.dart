/// The More side games sheet — the side games that do not get a chip.
///
/// Unlike the All games sheet, which picks ONE primary and closes, side games
/// are any number, so this is a list of checkboxes that stays open until Done.
///
/// The screen owns the rule for what a toggle does (a game that cannot run
/// beside the one just ticked is dropped), so the sheet asks it rather than
/// deciding: [onToggle] returns the selection AFTER the change, and the sheet
/// draws that.
library;

import 'package:flutter/material.dart';

import '../game_catalog.dart';
import '../theme/halved_brand.dart';

Future<void> showSideGamesSheet(
  BuildContext context, {
  required List<GameMeta> games,
  required Set<String> selected,
  required Set<String> Function(String id, bool picked) onToggle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x730B1F1A),
    builder: (_) => SideGamesSheet(
        games: games, selected: selected, onToggle: onToggle),
  );
}

class SideGamesSheet extends StatefulWidget {
  final List<GameMeta> games;
  final Set<String> selected;
  final Set<String> Function(String id, bool picked) onToggle;

  const SideGamesSheet({
    super.key,
    required this.games,
    required this.selected,
    required this.onToggle,
  });

  @override
  State<SideGamesSheet> createState() => _SideGamesSheetState();
}

class _SideGamesSheetState extends State<SideGamesSheet> {
  late Set<String> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.7;
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: Halved.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('More side games',
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
        Text('Each settles separately and shows up as a leaderboard tab.',
            style: Halved.body(color: Halved.muted).copyWith(fontSize: 12)),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.separated(
            itemCount: widget.games.length,
            separatorBuilder: (_, __) => const SizedBox(height: 7),
            itemBuilder: (_, i) {
              final g = widget.games[i];
              final on = _selected.contains(g.id);
              return Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                      color: on ? Halved.pine : const Color(0xFFE7EDE8),
                      width: on ? 1.5 : 1),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(
                      () => _selected = {...widget.onToggle(g.id, !on)}),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(g.displayName,
                                  style: Halved.body(
                                          color: Halved.deepPine,
                                          weight: FontWeight.w600)
                                      .copyWith(fontSize: 14.5)),
                              if ((g.summary ?? '').isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(g.summary!,
                                    style: Halved.body(color: Halved.muted)
                                        .copyWith(fontSize: 12)),
                              ],
                            ]),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                          on
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          color: on ? Halved.pine : Halved.cardBorder),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
