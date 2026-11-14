/// The team header over a side's golfers (`handoff-score-entry-template`): a
/// caps label — `PAUL + DAVE` — on a pale band, and **nothing else**. A "best"
/// figure sat on it until review removed it: the tray reports the best balls
/// once the hole is complete.
///
/// Three games each wrote this (Fourball, Las Vegas, Annandale Friday) as a
/// swatch and a coloured label floating above the first row, with the same
/// numbers three times; they draw this now, so the next team game gets the
/// template's header by being in it. The side's colour is carried by the bar
/// down the left edge of its rows, not by the header.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

class SideHeaderBand extends StatelessWidget {
  final String label;

  /// Kept for callers that have a side colour to hand; the band itself is
  /// neutral, because the rows' own bars say which side is which.
  final Color? colour;

  const SideHeaderBand({super.key, required this.label, this.colour});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
        decoration: const BoxDecoration(
          color: Color(0xFFF4F7F4),
          border: Border(top: BorderSide(color: Color(0xFFEEF3EE))),
        ),
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Halved.label(color: Halved.muted, weight: FontWeight.w700)
              .copyWith(fontSize: 10.5, letterSpacing: 0.4),
        ),
      );
}
