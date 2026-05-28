/// widgets/golf_primary_button.dart
/// -----------------
/// Standard full-width primary action button used across the golf app.
///
/// Per the May 2026 design audit (D-01), there were three competing
/// primary-button styles: dark green pill, light green FAB pill, and a
/// one-off dark teal pill.  This widget is the single source of truth for
/// the dark-green-pill style — terminal actions like "Sign In", "Start
/// Game", "Complete Round" all use it.  Reserve [GolfFab] (and
/// FloatingActionButton.extended directly until a wrapper exists) for
/// additive "+ new" actions over scrollable lists.
///
/// Bakes in the common pattern across the app:
///   * Full width (SizedBox width: double.infinity)
///   * 52-px height (slightly taller than M3 default for touch targets)
///   * Loading spinner that swaps in for the label when `loading: true`
///   * Optional leading icon

import 'package:flutter/material.dart';

class GolfPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  /// When true the label is replaced by a spinner and the button is
  /// implicitly disabled.  Callers don't need to also pass `onPressed: null`.
  final bool loading;

  /// Optional leading icon.  Renders to the left of the label using the
  /// standard FilledButton.icon layout.
  final IconData? icon;

  /// Optional height override.  Defaults to 52 (the size most setup
  /// screens already use); pass smaller (e.g. 44) for tighter contexts.
  final double height;

  const GolfPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveOnPressed = loading ? null : onPressed;

    Widget child;
    if (loading) {
      child = const SizedBox(
        width: 20, height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2, color: Colors.white,
        ),
      );
    } else {
      child = Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w600),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: height,
      child: icon != null && !loading
          ? FilledButton.icon(
              onPressed: effectiveOnPressed,
              icon: Icon(icon, size: 20),
              label: child,
            )
          : FilledButton(
              onPressed: effectiveOnPressed,
              child: child,
            ),
    );
  }
}
