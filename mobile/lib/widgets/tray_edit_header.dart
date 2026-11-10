import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// The head of a hole tray: `All N scores in`, and the way into editing them.
///
/// **One header, three trays.** Rabbit, Sixes and Annandale Friday each drew
/// this row themselves, so when `Edit scores` stopped guessing a golfer
/// (Paul, 31 Oct 2026) it had to be changed in each of them — and the first
/// pass changed one, which is this repo's standing failure: a rule reachable
/// from one screen and not the other.
///
/// **Picking is a state of the tray, not a screen of its own.** The tray
/// stays up while you choose, so the hole you are about to change is still on
/// screen; the card above it was always the real control, and the button had
/// been duplicating it and guessing. `Done` is the way back out without
/// touching anything.
class TrayEditHeader extends StatelessWidget {
  /// `All 3 scores in`.
  final String title;

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
    required this.title,
    required this.onEdit,
    this.picking = false,
    this.pickingHint = 'Tap a score above to change it',
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: onEdit,
              style: TextButton.styleFrom(
                  foregroundColor: Halved.brightMint,
                  minimumSize: const Size(44, 40)),
              child: Text(picking ? 'Done' : 'Edit scores'),
            ),
          ]),
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
