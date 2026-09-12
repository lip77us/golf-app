/// widgets/keyboard_done_bar.dart
///
/// A `Done` bar above the keyboard, and a tap-anywhere-else dismissal.
///
/// **Why this exists.** iOS's 10-key numeric pad has **no return key** — by
/// design, there is nothing for one to submit. Flutter provides no input
/// accessory view, so a screen that raises that pad and puts its buttons near
/// the bottom traps the user: the pad covers Next and Save, tapping outside
/// does nothing, and there is no way back. Found on Tees & Handicaps entering a
/// forced handicap (12 Sep 2026) — not an annoyance, a dead end.
///
/// **Why it is global rather than per screen.** Thirty-four files raise a
/// numeric keyboard. Fixing the one where it was reported would leave the same
/// trap in stake fields, press values, payout tables and paste screens. Wrapping
/// the app once means no screen can ever have the bug, including screens nobody
/// has written yet.
///
/// It shows for ANY keyboard, not only the numeric pad. Flutter gives no
/// reliable way to ask which keyboard is up from outside the focused field, and
/// a redundant Done above a keyboard that already has a return key costs a row
/// of chrome — while a missing one costs the user the screen.
library;

import 'package:flutter/material.dart';

/// Wraps the whole app: dismiss-on-tap-outside, plus the Done bar.
class KeyboardDismissal extends StatelessWidget {
  final Widget child;
  const KeyboardDismissal({super.key, required this.child});

  static void dismiss() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  Widget build(BuildContext context) {
    // `translucent` so the tap still reaches whatever is underneath — a button
    // under the finger wins the gesture arena, so this only fires on taps that
    // nothing else wanted.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: dismiss,
      child: Stack(children: [child, const _DoneBar()]),
    );
  }
}

class _DoneBar extends StatelessWidget {
  const _DoneBar();

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Positioned(
      left: 0,
      right: 0,
      // Sits ON the keyboard's top edge. viewInsets is the keyboard's height,
      // and it animates, so the bar rides up and down with it for free.
      bottom: inset,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: const SafeArea(
          top: false,
          bottom: false,
          child: SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: KeyboardDismissal.dismiss,
                  child: Text('Done',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
