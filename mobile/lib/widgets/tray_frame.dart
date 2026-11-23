/// The dark tray's frame (`handoff-score-entry-template`) — the one part every
/// game's tray shares, so a game writes only its BLOCKS.
///
///  * a label line — `HOLE 7 · FOURBALL` in caps on the left, **Edit scores**
///    underlined on the right. There is no "All 4 scores in" line: it was
///    removed in review because the tray cannot appear otherwise;
///  * the game's blocks;
///  * at the bottom, a round **‹** (previous hole) and a white **Hole 8 ›**
///    pill, which reads **Finish round ›** on the last hole.
///
/// Nine trays each draw this row themselves today (`TrayEditHeader` plus a
/// hand-built pager). This is the template's version, used first by the generic
/// tray; the others move onto it one at a time.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// `rgba(255,255,255,.07)` block on deep pine, radius 12 — what a tray part
/// sits in.
class TrayBlock extends StatelessWidget {
  final Widget child;
  const TrayBlock({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );
}

class TrayFrame extends StatelessWidget {
  /// `Hole 7 · Fourball` — drawn in caps.
  final String label;

  /// Edit scores has been pressed and nobody is chosen yet. The tray stays up
  /// while you choose, so the hole you are about to change is still on screen.
  final bool picking;
  final VoidCallback onEdit;

  /// The game's own blocks, in order.
  final List<Widget> blocks;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// The forward pill: `Hole 8`, or `Finish round` on the last. The chevron is
  /// added here.
  final String nextLabel;

  const TrayFrame({
    super.key,
    required this.label,
    required this.onEdit,
    required this.blocks,
    required this.nextLabel,
    this.picking = false,
    this.onPrev,
    this.onNext,
  });

  static const Color _label = Color(0xFFB9CCC3);

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78),
        decoration: const BoxDecoration(
          color: Halved.deepPine,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Halved.label(color: _label, weight: FontWeight.w700)
                      .copyWith(fontSize: 11.5, letterSpacing: 0.4),
                ),
              ),
              GestureDetector(
                onTap: onEdit,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Text(
                    picking ? 'Done' : 'Edit scores',
                    style: Halved.body(color: Colors.white, weight: FontWeight.w700)
                        .copyWith(
                            fontSize: 12.5,
                            decoration: TextDecoration.underline,
                            decorationColor: Colors.white),
                  ),
                ),
              ),
            ]),
            if (picking)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('Tap a score above to change it',
                    style: Halved.body(color: Halved.brightMint)
                        .copyWith(fontSize: 12)),
              ),
            const SizedBox(height: 2),
            // While choosing a score to change the blocks step aside: they
            // report the hole as it stands, a change is about to move them,
            // and with them up the golfers to tap are behind the tray.
            if (!picking)
            Flexible(
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < blocks.length; i++) ...[
                    if (i > 0) const SizedBox(height: 9),
                    blocks[i],
                  ],
                ]),
              ),
            ),
            const SizedBox(height: 11),
            Row(children: [
              SizedBox(
                width: 50,
                height: 50,
                child: OutlinedButton(
                  onPressed: onPrev,
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white24,
                    side: BorderSide(
                        color: Colors.white
                            .withValues(alpha: onPrev == null ? 0.12 : 0.3),
                        width: 1.5),
                  ),
                  child: const Text('‹',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: FilledButton(
                    onPressed: onNext,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Halved.deepPine,
                      disabledBackgroundColor: Colors.white24,
                      shape: const StadiumBorder(),
                    ),
                    child: Text('$nextLabel ›',
                        style: Halved.body(
                                color: Halved.deepPine, weight: FontWeight.w700)
                            .copyWith(fontSize: 15)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      );
}
