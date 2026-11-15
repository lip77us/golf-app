import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// The head of a hole tray, in the template's single line
/// (`handoff-score-entry-template`): **`HOLE 7 · FOURBALL`** in caps on the left
/// and an underlined **Edit scores** on the right.
///
/// There is no `All N scores in` line any more. It was removed in review because
/// the tray cannot appear until every score is in, so it said nothing a golfer
/// could not see — and it cost a whole row on every tray, which is the row the
/// label now shares with Edit scores.
///
/// **One header, many trays.** Rabbit, Sixes and Annandale Friday each drew this
/// row themselves, so when `Edit scores` stopped guessing a golfer (Paul, 31 Oct
/// 2026) it had to be changed in each of them — and the first pass changed one,
/// which is this repo's standing failure: a rule reachable from one screen and
/// not the other.
///
/// **Picking is a state of the tray, not a screen of its own.** The tray stays up
/// while you choose, so the hole you are about to change is still on screen; the
/// card above it was always the real control, and the button had been duplicating
/// it and guessing. `Done` is the way back out without touching anything.
///
/// ## Two forms
///
/// [label] is the template's. [title] is the old one — a sentence (`All 3 scores
/// in`) on the left — and survives only for a tray that has not moved yet; it is
/// ignored when [label] is given.
class TrayEditHeader extends StatelessWidget {
  /// The old left-hand sentence. Ignored when [label] is set.
  final String? title;

  /// `Hole 7 · Fourball`, drawn in caps. The template's line.
  final String? label;

  /// A figure for the right of the label — `$10 a match`, `$5 riding` — drawn
  /// beside Edit scores. Money belongs on a golfer's row or the standing line
  /// where there is one; this is for the games whose stake is a property of the
  /// hole itself.
  final String? labelTrailing;

  /// A state worth saying under the line — `Getting result…`, `Saving…` — while
  /// the tray has nothing yet to report.
  final String? status;

  /// `Edit scores` has been pressed and no golfer is chosen yet.
  final bool picking;

  /// Toggles [picking]. The caller clears its own cursor here.
  final VoidCallback onEdit;

  /// What the picking line says. Every tray edits scores; Wolf's `Edit
  /// scores` also unlocks the CALL, and a line that names only the scores
  /// would leave that half undiscoverable.
  final String pickingHint;

  const TrayEditHeader({
    super.key,
    this.title,
    this.label,
    this.labelTrailing,
    this.status,
    required this.onEdit,
    this.picking = false,
    this.pickingHint = 'Tap a score above to change it',
  }) : assert(title != null || label != null,
            'a tray header needs a label (or, still, a title)');

  static const Color _secondary = Color(0xFFB9CCC3);

  @override
  Widget build(BuildContext context) {
    final edit = GestureDetector(
      onTap: onEdit,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // A 44pt-tall target without a 44pt-tall row.
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Text(
          picking ? 'Done' : 'Edit scores',
          style: Halved.body(color: Colors.white, weight: FontWeight.w700)
              .copyWith(
                  fontSize: 12.5,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Row(children: [
            Expanded(
              child: Text(
                label!.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Halved.label(color: _secondary, weight: FontWeight.w700)
                    .copyWith(fontSize: 11.5, letterSpacing: 0.4),
              ),
            ),
            if (labelTrailing != null && labelTrailing!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  labelTrailing!.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: Halved.label(color: _secondary, weight: FontWeight.w700)
                      .copyWith(fontSize: 11, letterSpacing: 0.4),
                ),
              ),
              const SizedBox(width: 10),
            ],
            edit,
          ])
        else
          Row(children: [
            Expanded(
              child: Text(title!,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            edit,
          ]),
        if (status != null && status!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(status!,
                style: Halved.body(color: Colors.white, weight: FontWeight.w600)
                    .copyWith(fontSize: 13)),
          ),
        if (picking)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Text(pickingHint,
                style: const TextStyle(
                    color: Halved.brightMint, fontSize: 12)),
          ),
      ],
    );
  }
}
