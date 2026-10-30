/// widgets/match_panel.dart
/// ------------------------
/// The box round the board a match picker drives: Front, Back and the 18,
/// and whatever else on the board belongs to the ONE match picked.
///
/// Paul, 29 Oct 2026: the three cards are related and are what changes when
/// a match is tapped, and nothing on the screen said so. The box says it
/// three ways — it wears the SELECTED pill's colour and weight (so the two
/// read as one control), and it opens with a line naming the match, so a
/// board can be traced back to its pill without comparing swatches.
///
/// **Its edge goes round exactly what the pick changes.** The settings strip
/// above and a net-position ledger below total EVERY match, so they stay
/// outside; inside, they would look as though they ought to change too.
///
/// Used by Annandale Friday and Triple Nassau, the two boards with a match
/// picker. One widget, so the two show the same control the same way.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// One side of the match being shown: who, and the swatch they wear on the
/// pills above.
class MatchPanelSide {
  const MatchPanelSide(this.names, this.colour);
  final String names;
  final Color colour;
}

class MatchPanel extends StatelessWidget {
  const MatchPanel({
    super.key,
    required this.side1,
    required this.side2,
    required this.child,
  });

  final MatchPanelSide side1;
  final MatchPanelSide side2;

  /// The board itself.
  final Widget child;

  /// The selected pill's border — the panel is drawn in it so the pill and
  /// the panel read as one control. Pickers use this, not their own colour.
  ///
  /// **Deep pine, not pine.** Pine is the first golfer's / team's colour on
  /// both boards, and a settled card inside is bordered in its winner's
  /// colour — so a pine box read as "Paul & Jim lead" rather than "picked".
  static const Color accent = Halved.deepPine;
  static const double accentWidth = 2;

  Widget _side(MatchPanelSide s) => Row(mainAxisSize: MainAxisSize.min,
          children: [
        Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
              color: s.colour, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(s.names,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w800,
                  color: Halved.deepPine)),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent, width: accentWidth),
        ),
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(children: [
              Flexible(child: _side(side1)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text('v.',
                    style: TextStyle(
                        fontSize: 12, color: Halved.muted,
                        fontWeight: FontWeight.w600)),
              ),
              Flexible(child: _side(side2)),
            ]),
          ),
          child,
        ]),
      );
}
