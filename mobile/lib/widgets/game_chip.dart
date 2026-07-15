/// widgets/game_chip.dart
/// -----------------
/// Game-name chip widgets — read-only ([GameChip]) and selectable
/// ([GameSelectableChip]) — built from a single visual spec so chips
/// look the same wherever they appear.
///
/// Per the May 2026 design audit:
///   * Read-only chips were drifting on font size (10 / 11 / 12),
///     padding, density, and optional background fill across
///     round_screen, leaderboard_screen, and new_round_wizard.
///   * The casual-round picker (D-10) had a polished
///     "brand-green-fill + white text + no checkmark" treatment, but
///     the wizard's same-shaped FilterChips were still using the
///     default Material checkmark/grey-fill look.
///
/// This file gives both classes one canonical implementation so
/// future screens can drop a chip in without re-deriving its shape.
///
/// Usage:
///
/// ```dart
/// // Read-only label
/// GameChip(gameId: 'sixes')
///
/// // Tight chip inside a dense list (foursome card etc.)
/// GameChip(gameId: 'points_531', dense: true, filled: true)
///
/// // Selectable picker — same look as the casual-round picker
/// GameSelectableChip(
///   gameId:     'skins',
///   selected:   isPicked,
///   onSelected: (v) => toggle(v),
/// )
/// ```

import 'package:flutter/material.dart';
import '../game_catalog.dart';
import '../theme/halved_brand.dart';

/// Read-only chip that displays a game label.
///
/// Pass [gameId] to look up the display name via [gameDisplayName] (the
/// app's single source of truth for game slugs → human labels).  Pass
/// [label] instead to render any string verbatim — useful for the
/// handful of non-game pills that share this visual class
/// (Pink Ball, Entry Fee, places-paid, etc.).
class GameChip extends StatelessWidget {
  /// Game-catalog slug.  Mutually exclusive with [label]; whichever is
  /// provided becomes the chip text.
  final String? gameId;
  /// Free-form label.  Use when the chip isn't a game per se.
  final String? label;
  /// Smaller text + tighter padding for dense lists (foursome card,
  /// multi-chip rows).  Default false.
  final bool dense;
  /// Pale brand-tinted background fill.  Default false (transparent
  /// fill with the standard chip outline).
  final bool filled;

  const GameChip({
    super.key,
    this.gameId,
    this.label,
    this.dense = false,
    this.filled = false,
  }) : assert(gameId != null || label != null,
            'Provide either gameId or label.');

  @override
  Widget build(BuildContext context) {
    final text = gameId != null ? gameDisplayName(gameId!) : label!;

    // Explicit pill (not a Material Chip): a bare display Chip doesn't reliably
    // pick up the themed label colour, which rendered these blank on the sage
    // theme. This guarantees a readable deep-pine label everywhere GameChip is
    // used (round hub, leaderboard, foursome cards, wizard).
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 10, vertical: dense ? 3 : 4),
      decoration: BoxDecoration(
        color: filled ? Halved.pine.withValues(alpha: 0.10) : Halved.card,
        borderRadius: BorderRadius.circular(Halved.rChip),
        border: Border.all(color: Halved.cardBorder),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: dense ? 10 : 11,
          fontWeight: FontWeight.w600,
          color: Halved.deepPine,
        ),
      ),
    );
  }
}

/// Selectable game chip — matches the casual-round picker (D-10).
///
/// Selected = high-contrast brand-green fill, white bold text, no
/// checkmark icon.  Unselected = pale outlined.  The fill itself is
/// the affordance; the missing checkmark keeps the chip from looking
/// cluttered when many are visible.
///
/// Pass [gameId] for catalog-driven label, or [label] for free-form
/// text (useful when the wizard's championship-game tuples carry
/// their own pre-built labels).
class GameSelectableChip extends StatelessWidget {
  final String? gameId;
  final String? label;
  final bool    selected;
  final ValueChanged<bool> onSelected;

  const GameSelectableChip({
    super.key,
    this.gameId,
    this.label,
    required this.selected,
    required this.onSelected,
  }) : assert(gameId != null || label != null,
            'Provide either gameId or label.');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text  = gameId != null ? gameDisplayName(gameId!) : label!;

    return FilterChip(
      label: Text(
        text,
        style: TextStyle(
          color: selected ? Colors.white : theme.colorScheme.onSurface,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      selected:        selected,
      showCheckmark:   false,
      selectedColor:   theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surface,
      side: BorderSide(
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant,
      ),
      onSelected: onSelected,
    );
  }
}
