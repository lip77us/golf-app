/// The Director bar (`handoff-round-tournament-start` §3): pinned at the bottom
/// of the tournament director's screens and never shown to a golfer.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

enum DirectorTab { round, overview, groups, teeTimes, formats, board, settle }

class DirectorBar extends StatelessWidget {
  final DirectorTab active;

  /// The golfer's round view carries a leading **Round** item; the director
  /// screens (Overview, Groups) lead with Overview.
  final bool inRound;
  final ValueChanged<DirectorTab> onTap;

  const DirectorBar(
      {super.key,
      required this.active,
      required this.onTap,
      this.inRound = false});

  static const _items = <(DirectorTab, IconData, String)>[
    (DirectorTab.round, Icons.golf_course, 'Round'),
    (DirectorTab.overview, Icons.star_rounded, 'Overview'),
    (DirectorTab.groups, Icons.groups_rounded, 'Groups'),
    (DirectorTab.teeTimes, Icons.schedule, 'Tee times'),
    (DirectorTab.formats, Icons.sports_golf, 'Formats'),
    (DirectorTab.board, Icons.leaderboard_rounded, 'Board'),
    (DirectorTab.settle, Icons.receipt_long_outlined, 'Settle'),
  ];

  @override
  Widget build(BuildContext context) {
    // In the round the leading item is Round; elsewhere Round is still the
    // way back, so it is always offered, but Overview leads on the director
    // screens as drawn.
    final items = inRound
        ? [_items[0], _items[2], _items[3], _items[5], _items[1], _items[4], _items[6]]
        : [_items[1], _items[2], _items[3], _items[4], _items[5], _items[6], _items[0]];
    return Material(
      color: Colors.white,
      child: Container(
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Halved.cardBorder))),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 82,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => onTap(it.$1),
                      child: SizedBox(
                        width: 68,
                        child: Column(children: [
                          Container(
                            width: 56,
                            height: 40,
                            decoration: BoxDecoration(
                                color: it.$1 == active
                                    ? Halved.deepPine
                                    : Halved.surface,
                                borderRadius: BorderRadius.circular(14)),
                            child: Icon(it.$2,
                                size: 22,
                                color: it.$1 == active
                                    ? Halved.brightMint
                                    : Halved.muted),
                          ),
                          const SizedBox(height: 4),
                          Text(it.$3,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Halved.body(
                                      color: it.$1 == active
                                          ? Halved.pine
                                          : Halved.muted,
                                      weight: FontWeight.w700)
                                  .copyWith(fontSize: 12)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
