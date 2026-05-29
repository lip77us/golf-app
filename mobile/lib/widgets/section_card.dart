/// widgets/section_card.dart
/// -----------------
/// Outlined card with a brand-green section title — the canonical
/// container for grouping form controls on setup screens.
///
/// Every setup screen (sixes, skins, triple cup, irish rumble, three-
/// person match, pink ball, nassau, low-net …) had a near-identical
/// hand-rolled helper:
///
/// ```dart
/// Card(
///   elevation: 0,
///   shape: RoundedRectangleBorder(
///     borderRadius: BorderRadius.circular(8),
///     side: BorderSide(color: theme.colorScheme.outline),
///   ),
///   child: Padding(
///     padding: const EdgeInsets.all(14),
///     child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
///       Text(title,
///           style: theme.textTheme.labelLarge?.copyWith(
///               fontWeight: FontWeight.bold,
///               color: theme.colorScheme.primary)),
///       const SizedBox(height: 10),
///       child,
///     ]),
///   ),
/// )
/// ```
///
/// Per the May 2026 design audit, this widget collapses 30+ inline
/// `_sectionCard` / `_SectionCard` / `_section` helpers into one
/// definition.  Tiny drifts that had crept in (spacing, title style,
/// padding) get normalised in the process.
///
/// Usage:
///
/// ```dart
/// SectionCard(
///   title: 'Stake',
///   child: GolfTextField(...),
/// )
/// ```
///
/// Optional `trailing` slot for a small action / status pill next to
/// the title (e.g. a copy-to-all icon button).

import 'package:flutter/material.dart';

class SectionCard extends StatelessWidget {
  /// Section title — rendered bold + brand-primary on the top line.
  final String title;
  /// The body content.  Free-form — typically a Column of controls.
  final Widget child;
  /// Optional trailing widget shown to the right of the title.  Useful
  /// for compact actions ("copy", "?") or status chips.
  final Widget? trailing;
  /// Override the inner padding when the default 14 isn't right
  /// (e.g. tighter dialogs, or content that brings its own padding).
  final EdgeInsetsGeometry padding;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.bold,
      color:      theme.colorScheme.primary,
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (trailing == null)
              Text(title, style: titleStyle)
            else
              Row(children: [
                Expanded(child: Text(title, style: titleStyle)),
                trailing!,
              ]),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}
