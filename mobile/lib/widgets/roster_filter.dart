/// roster_filter.dart
///
/// The chip row that cuts the roster down.
///
/// By the second season "everybody you have ever played with" is a scroll, and
/// the fourth man you are looking for is usually one of the same nine people.
/// Two filters answer the questions a golfer actually asks on the first tee:
/// who here is on Halved, and who do I play with every week.
///
/// One filter at a time — not multi-select — and [RosterFilter.all] on every
/// entry to the screen.  A filter does not survive into the next round's setup:
/// somebody setting up a member-guest should not find last Saturday's filter
/// still applied.
///
/// Design reference: handoff-select-players §1.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import 'favorite_flag.dart';

enum RosterFilter { all, favorites, onHalved }

/// Fill and border of an active chip — soft pine, distinct from the sage the
/// screen sits on.
const _activeFill = Color(0xFFE4F2EA);

class RosterFilterChips extends StatelessWidget {
  const RosterFilterChips({
    super.key,
    required this.value,
    required this.onChanged,
    required this.allCount,
    required this.favoriteCount,
    required this.onHalvedCount,
  });

  final RosterFilter value;
  final ValueChanged<RosterFilter> onChanged;

  /// Counts of the WHOLE roster, not of what a search has narrowed it to: a
  /// filter that could empty the list has to say so before it is tapped.
  final int allCount;
  final int favoriteCount;
  final int onHalvedCount;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        _chip(RosterFilter.all, 'All', allCount),
        const SizedBox(width: 7),
        _chip(RosterFilter.favorites, 'Favorites', favoriteCount,
            glyph: true),
        const SizedBox(width: 7),
        _chip(RosterFilter.onHalved, 'On Halved', onHalvedCount),
      ]),
    );
  }

  Widget _chip(RosterFilter filter, String label, int count,
      {bool glyph = false}) {
    final active = value == filter;
    final ink = active ? Halved.pine : Halved.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(Halved.rPill),
      onTap: () => onChanged(filter),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: active ? _activeFill : Halved.card,
          border: Border.all(
              color: active ? Halved.pine : Halved.cardBorder, width: 1.5),
          borderRadius: BorderRadius.circular(Halved.rPill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // Only Favorites carries the mark; the other two are text, so the
          // glyph reads as "this is the flag filter" rather than decoration.
          if (glyph) ...[
            SizedBox(
              width: 13,
              height: 13,
              child: CustomPaint(
                  painter: PinFlagGlyph(color: ink, strokeWidth: 1.9)),
            ),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: ink)),
          const SizedBox(width: 5),
          Text('$count',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: active ? Halved.pine.withValues(alpha: 0.75)
                                : Halved.muted)),
        ]),
      ),
    );
  }
}
