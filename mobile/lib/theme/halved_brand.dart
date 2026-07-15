/// theme/halved_brand.dart
/// -----------------------
/// The Halved brand system (palette + type + small helpers) from
/// docs/Halved-Brand-Guidelines.md, packaged for the redesigned screens.
///
/// This is deliberately SCOPED — it is not (yet) wired into the global app
/// theme in main.dart. Screens that have been reworked to the brand pull from
/// here; the rest of the app keeps its current Material-green theme until we
/// decide whether to do a global swap.
///
/// Rules encoded here (guidelines §05):
///   • App runs on the light SAGE surface; pine is structure; bright mint is
///     reserved for the ONE CTA per screen, live states, and the hole.
///   • Selected chips/segments are PINE fill (structural), never mint.
///   • Headings use Schibsted Grotesk; body/labels use Spline Sans.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class Halved {
  Halved._();

  // ── Core palette ──────────────────────────────────────────────────────────
  static const deepPine   = Color(0xFF0B1F1A); // text · dark tile
  static const pine       = Color(0xFF0F6E56); // primary · structure
  static const mint       = Color(0xFF1D9E75); // accent
  static const brightMint = Color(0xFF3BD89A); // CTA · live · hole
  static const surface    = Color(0xFFEEF3EE); // light sage background
  static const card       = Color(0xFFFFFFFF); // card fill
  static const cardBorder = Color(0xFFD3DED6); // card / chip border
  static const muted      = Color(0xFF5C6B62); // secondary text
  static const cream      = Color(0xFFF3F1EA); // text/mark on dark
  static const ink        = Color(0xFF06120E); // deepest shadow

  // ── Semantic ──────────────────────────────────────────────────────────────
  static const win     = Color(0xFF3BD89A);
  static const owe     = Color(0xFFF0916E);
  static const warning = Color(0xFFB24225);

  // ── Disabled (buttons) ────────────────────────────────────────────────────
  static const disabledFill = Color(0xFFD3DAD5);
  static const disabledText = Color(0xFF93A099);

  // ── Radius ────────────────────────────────────────────────────────────────
  static const double rCta  = 16; // CTA buttons
  static const double rCard = 18; // cards
  static const double rChip = 12; // chips
  static const double rPill = 999;

  // ── Type — Schibsted Grotesk (display) · Spline Sans (body) ───────────────
  static TextStyle appBarTitle() => GoogleFonts.schibstedGrotesk(
        fontSize: 20, fontWeight: FontWeight.w600, color: deepPine);

  static TextStyle sectionHead() => GoogleFonts.schibstedGrotesk(
        fontSize: 22, fontWeight: FontWeight.w600, color: deepPine, height: 1.1);

  static TextStyle emptyTitle() => GoogleFonts.schibstedGrotesk(
        fontSize: 26, fontWeight: FontWeight.w700, color: deepPine);

  static TextStyle body({Color? color, FontWeight? weight}) =>
      GoogleFonts.splineSans(
        fontSize: 15, fontWeight: weight ?? FontWeight.w400,
        color: color ?? deepPine);

  static TextStyle label({Color? color, FontWeight? weight}) =>
      GoogleFonts.splineSans(
        fontSize: 12.5, fontWeight: weight ?? FontWeight.w600,
        letterSpacing: 0.4, color: color ?? muted);

  static TextStyle button({Color? color}) => GoogleFonts.splineSans(
        fontSize: 16, fontWeight: FontWeight.w700, color: color ?? deepPine);

  /// A theme override that repaints the brand palette onto descendant Material
  /// widgets (used to make the shared FilterChip render pine-selected /
  /// white-bordered without forking the widget).
  static ThemeData chipScope(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary:        pine,
        surface:        card,
        onSurface:      deepPine,
        outlineVariant: cardBorder,
      ),
      // Rounded-rectangle chips (not the default pill) to match the mockup.
      // The border itself is drawn by GameSelectableChip's `side`, so the
      // theme shape carries no side of its own.
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rChip),
        ),
        labelStyle: body(weight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}

/// The one bright-mint CTA per screen: mint fill, deep-pine label, radius 16.
class HalvedCtaButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool trailingIcon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool expand;

  const HalvedCtaButton({
    super.key,
    required this.label,
    this.icon,
    this.trailingIcon = false,
    required this.onPressed,
    this.loading = false,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final fg = enabled ? Halved.deepPine : Halved.disabledText;
    final child = loading
        ? SizedBox(
            height: 20, width: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: fg))
        : Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null && !trailingIcon) ...[
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 8),
              ],
              Text(label, style: Halved.button(color: fg)),
              if (icon != null && trailingIcon) ...[
                const SizedBox(width: 8),
                Icon(icon, size: 20, color: fg),
              ],
            ],
          );

    return SizedBox(
      width: expand ? double.infinity : null,
      height: 54,
      child: Material(
        color: enabled ? Halved.brightMint : Halved.disabledFill,
        borderRadius: BorderRadius.circular(Halved.rCta),
        // Subtle lift under the CTA (the mockup shows a soft mint glow).
        elevation: enabled ? 2 : 0,
        shadowColor: Halved.brightMint.withValues(alpha: 0.55),
        child: InkWell(
          borderRadius: BorderRadius.circular(Halved.rCta),
          onTap: enabled ? onPressed : null,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: expand ? 20 : 28),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// The "Live / in-progress" indicator: a soft mint pill with a bright-mint dot
/// and deep-pine label (guidelines §05). Self-contained colors so it never
/// disappears against a themed background.
class HalvedLivePill extends StatelessWidget {
  final String label;
  const HalvedLivePill({super.key, this.label = 'Live'});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Halved.mint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Halved.rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: const BoxDecoration(
                color: Halved.brightMint, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('Live',
              style: Halved.label(color: Halved.pine, weight: FontWeight.w700)
                  .copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

/// A two-or-more option segmented pill (sage track, pine-filled selected).
class HalvedSegmented<T> extends StatelessWidget {
  final List<({T value, String label, IconData? icon})> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  const HalvedSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Halved.pine.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Halved.rPill),
      ),
      child: Row(
        children: [
          for (final s in segments)
            Expanded(
              child: _seg(s.value == selected, s.label, s.icon,
                  () => onChanged(s.value)),
            ),
        ],
      ),
    );
  }

  Widget _seg(bool active, String label, IconData? icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? Halved.pine : Colors.transparent,
          borderRadius: BorderRadius.circular(Halved.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18,
                  color: active ? Colors.white : Halved.muted),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: Halved.body(
                    weight: FontWeight.w700,
                    color: active ? Colors.white : Halved.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
