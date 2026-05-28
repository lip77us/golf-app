/// theme/tokens.dart
/// -----------------
/// Single source of truth for the app's visual primitives: colors, spacing,
/// and radius.  Per the May 2026 design audit (docs/design-review/README.md),
/// these tokens prevent the kind of drift that produced four shades of
/// "primary green" and four meanings for red across the app.
///
/// Usage:
///   import 'package:golf_app/theme/tokens.dart';
///   Container(color: GolfTokens.brandGreen, ...);
///   const SizedBox(height: GolfTokens.s16);
///
/// New screens should pull from this file rather than hardcoding hex values
/// or magic numbers.

import 'package:flutter/material.dart';

class GolfTokens {
  // ── Color ────────────────────────────────────────────────────────────────
  // Brand: the Material 3 seed (#2E7D32) anchors the palette.  The soft
  // variant is used for FAB fill and selected-chip backgrounds.
  static const brandGreen     = Color(0xFF2E7D32);
  static const brandGreenSoft = Color(0xFFC8E6C1);

  /// Page background tint used across the app.
  static const surfaceTint    = Color(0xFFF4F6ED);

  /// Team identity colors — intentionally calmer than the alert reds/blues
  /// so red can be reserved for errors and destructive actions.  See D-04.
  static const teamRed  = Color(0xFF8E2E2E);
  static const teamBlue = Color(0xFF1B4F8E);

  /// Reserved for error / destructive surfaces only.  Do not reuse for
  /// team identity or any decorative purpose.
  static const error    = Color(0xFFB33A2E);

  /// Text ink.  `ink` for primary copy, `inkMute` for secondary / meta.
  static const ink      = Color(0xFF1A1A1A);
  static const inkMute  = Color(0xFF6B6B6B);

  /// Soft 1-px dividers / card borders.
  static const lineSoft = Color(0xFFE6E3DA);

  // ── Spacing — 4-pt grid ──────────────────────────────────────────────────
  static const double s4  = 4.0;
  static const double s8  = 8.0;
  static const double s12 = 12.0;
  static const double s16 = 16.0;
  static const double s24 = 24.0;
  static const double s32 = 32.0;

  // ── Radius ───────────────────────────────────────────────────────────────
  static const double rSm   = 8.0;
  static const double rMd   = 12.0;
  static const double rLg   = 16.0;
  static const double rPill = 999.0;
}
