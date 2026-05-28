/// widgets/inline_message.dart
/// -----------------
/// Compact icon-prefixed message for non-field-bound inline content:
/// validation warnings, helper hints, success confirmations, etc.
///
/// Per the May 2026 design audit (D-07), the app had two competing styles
/// for the same job — bare red sentences for errors and gray-italic
/// sentences for helpers — with no consistent surface, icon, or padding.
/// This widget gives every such message a unified shape so the user reads
/// them as a class.
///
/// Use cases:
///   * Game-validation warning ("Sixes is a 4-player game — remove 1 below.")
///   * Setup hints ("Please select a course first to assign tees.")
///   * Inline success ("Saved.")
///
/// Do NOT use for full-screen error states with a retry action — that's
/// what `widgets/error_view.dart` is for.

import 'package:flutter/material.dart';

/// Tone of the message — drives color, default icon, and surface tint.
enum InlineMessageKind {
  /// Validation failures, blocking conditions.  Red surface, alert icon.
  error,

  /// Non-blocking caution — "this won't work the way you expect."
  /// Amber surface, warning icon.
  warn,

  /// Neutral helper / hint.  Blue-tinted surface, info icon.
  info,

  /// Success confirmation.  Green surface, check icon.
  success,
}

class InlineMessage extends StatelessWidget {
  final String text;
  final InlineMessageKind kind;

  /// Optional icon override.  When null, a sensible default per [kind]
  /// is used.
  final IconData? icon;

  const InlineMessage({
    super.key,
    required this.text,
    this.kind = InlineMessageKind.info,
    this.icon,
  });

  // ── Defaults per kind ──────────────────────────────────────────────────

  IconData get _defaultIcon {
    switch (kind) {
      case InlineMessageKind.error:   return Icons.error_outline;
      case InlineMessageKind.warn:    return Icons.warning_amber_outlined;
      case InlineMessageKind.info:    return Icons.info_outline;
      case InlineMessageKind.success: return Icons.check_circle_outline;
    }
  }

  /// Returns (foreground, background) for the given kind.  Background is a
  /// soft tint so multiple messages on one screen don't shout.
  ({Color fg, Color bg}) _colors(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (kind) {
      case InlineMessageKind.error:
        return (fg: scheme.error, bg: scheme.errorContainer.withOpacity(0.5));
      case InlineMessageKind.warn:
        // M3's tertiary slot leans toward amber/orange with the brand-green
        // seed — good enough as a warning tint without introducing a new
        // hue.  Fall back to a literal amber if needed in the future.
        return (fg: const Color(0xFFB76E00),
                bg: const Color(0xFFFFF4E0));
      case InlineMessageKind.info:
        return (fg: scheme.primary,
                bg: scheme.primaryContainer.withOpacity(0.35));
      case InlineMessageKind.success:
        return (fg: const Color(0xFF1B5E20),
                bg: const Color(0xFFE6F4E7));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final c      = _colors(context);
    final effIcon = icon ?? _defaultIcon;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(effIcon, size: 18, color: c.fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.fg,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
