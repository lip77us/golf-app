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
///
/// **The bar OCCUPIES its row; it does not steal it.** The first version drew
/// itself at `bottom: viewInsets` over the whole app, which is exactly where
/// the keyboard's top edge is — and therefore exactly where a screen that
/// PINS content to the keyboard puts that content. On a form you scroll, so it
/// only ever covered chrome. On the round chat it covered the message field,
/// and a golfer typed a reply he could not read (found playing Ranch Solano,
/// 17 Sep 2026).
///
/// So the wrapper reports a bottom inset 44 larger than the real one: every
/// Scaffold underneath resizes to leave that row free, and the bar fills it.
/// Nothing is ever painted over, on any screen, including screens nobody has
/// written yet — which was the whole point of wrapping the app once.
library;

import 'package:flutter/material.dart';

/// Wraps the whole app: dismiss-on-tap-outside, plus the Done bar.
class KeyboardDismissal extends StatelessWidget {
  final Widget child;
  const KeyboardDismissal({super.key, required this.child});

  static void dismiss() => FocusManager.instance.primaryFocus?.unfocus();

  /// The bar's height, and the extra bottom inset the app is told about. One
  /// constant: if the two ever disagree the bar either floats or covers.
  static const double barHeight = 44;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    // **The row is taken out of the LAYOUT, not announced in a MediaQuery.**
    //
    // The first attempt reported a bottom inset 44 larger and let each Scaffold
    // resize itself. That is the tidier idea and it did not survive the app:
    // `main.dart` had a MediaQuery between this wrapper and the screens, and it
    // rebuilt its data from the ambient `mq` — so the inflated inset was thrown
    // away before any Scaffold saw it, and the bar went straight back over the
    // round-chat composer. Anything anyone nests below could do that again.
    //
    // Padding cannot be undone from below. The subtree is given a box 44
    // shorter, the Scaffold inside insets ITS body by the real keyboard height
    // from that shorter bottom, and the result is one bar's height of clear
    // space with the bar sitting in it.
    //
    // Only while a keyboard is up: with none there is no bar and nothing to
    // make room for.
    // `translucent` so the tap still reaches whatever is underneath — a button
    // under the finger wins the gesture arena, so this only fires on taps that
    // nothing else wanted.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: dismiss,
      child: Stack(children: [
        Padding(
          padding: EdgeInsets.only(bottom: inset > 0 ? barHeight : 0),
          child: child,
        ),
        const _DoneBar(),
      ]),
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
            height: KeyboardDismissal.barHeight,
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
