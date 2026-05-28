/// widgets/golf_app_bar.dart
/// -----------------
/// Standard app-bar wrapper used across the golf app.
///
/// Pattern (per the May 2026 design audit, D-02): back arrow · context-
/// specific title · 0–2 trailing actions.  Centers the title by default to
/// preserve current iOS-leaning behavior; flip [centerTitle] to false for
/// Material-default left alignment.
///
/// Use this for every non-login screen rather than reaching for `AppBar(...)`
/// directly.  The wrapper exists so we can flip global title styling, leading
/// behavior, or trailing slot rules in one place later.

import 'package:flutter/material.dart';

class GolfAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// The title text.  Always a String — for richer titles (e.g. badges next
  /// to the name) drop down to a raw [AppBar] for that screen.
  final String title;

  /// Trailing actions.  Keep to 0–2 per the audit; if you need more, fold
  /// them behind a `more_vert` PopupMenuButton.
  final List<Widget>? actions;

  /// When true (default) the title is centered.  Flip to false for Material-
  /// default left alignment.  Defaulting to true preserves current behavior;
  /// we can change the default app-wide later by editing this one line.
  final bool centerTitle;

  /// Optional bottom widget (e.g. TabBar).  Forwarded as-is.
  final PreferredSizeWidget? bottom;

  /// Optional leading widget.  Defaults to the automatic back button.
  final Widget? leading;

  /// Hide the auto-inserted back button (e.g. for top-level screens behind
  /// a drawer).  Mirrors [AppBar.automaticallyImplyLeading].
  final bool automaticallyImplyLeading;

  const GolfAppBar({
    super.key,
    required this.title,
    this.actions,
    this.centerTitle = true,
    this.bottom,
    this.leading,
    this.automaticallyImplyLeading = true,
  });

  @override
  Size get preferredSize => Size.fromHeight(
        kToolbarHeight + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      centerTitle: centerTitle,
      actions: actions,
      bottom: bottom,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
    );
  }
}
