/// widgets/pick_sheet.dart
///
/// Pick one thing from a list that may be long.
///
/// Extracted when the second sheet needed it. The move sheet in
/// `scorecard_groups.dart` had just been given a scroll, a Cancel, a height
/// cap and a search — and the next report was the one beside it: *"add a
/// golfer is just the list with no search. tough with 200 players in my
/// membership"* (Paul, 4 Nov 2026). Writing the same four things a second
/// time is what says it is the wrong shape, the same way `TrayEditHeader`
/// came out of three trays drawing one head.
///
/// What the sheet owns, so no caller has to remember it:
///
/// * **`isScrollControlled`** — a sheet without it is capped at 9/16 of the
///   screen and a `Column` inside it does not scroll, it OVERFLOWS: every row
///   past the fold is unreachable and nothing looks broken. That was the
///   original bug, and it is a flag at the call site, which is the kind of
///   thing a call site forgets.
/// * **A height cap**, so there is always a barrier to tap.
/// * **Cancel**, because a sheet with no visible way out is one people escape
///   with the back arrow — which in a wizard used to end the wizard.
/// * **A search past [searchAbove] rows.** 200 golfers is not a scroll
///   anybody finishes.
/// * **[pinned] rows sit ABOVE the list**, outside the scroll, so an option
///   that is not one of the many stays reachable at 200 rows.
library;

import 'package:flutter/material.dart';

/// One row on a [pickFromSheet].
class PickOption<T> {
  /// What the sheet returns when this row is tapped.
  final T value;

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// A row that is shown but cannot be chosen — a full group, say. It still
  /// matches the search: hiding it would read as the group not existing.
  final bool enabled;

  /// Extra text the search looks in, beyond [title] and [subtitle]. For a
  /// group it is the full names of the golfers on it, where the subtitle
  /// carries only the short ones.
  final String searchText;

  const PickOption({
    required this.value,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.enabled = true,
    this.searchText = '',
  });

  bool matches(String q) =>
      title.toLowerCase().contains(q) ||
      (subtitle ?? '').toLowerCase().contains(q) ||
      searchText.toLowerCase().contains(q);
}

/// Show the sheet. Returns the chosen value, or null if it was dismissed.
Future<T?> pickFromSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<PickOption<T>> options,
  List<PickOption<T>> pinned = const [],
  String searchHint = 'Search',
  String Function(String query)? emptyText,
  int searchAbove = _kSearchAbove,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PickSheet<T>(
        title: title,
        subtitle: subtitle,
        options: options,
        pinned: pinned,
        searchHint: searchHint,
        emptyText: emptyText,
        searchAbove: searchAbove,
      ),
    );

/// Above this many rows the sheet offers a search box. A sheet is about half a
/// phone, so eight rows is roughly what fits; past that the scroll on its own
/// is a long one. (The sparse 40 Balls card reaches the same conclusion at
/// twelve, where its rows are golfers rather than groups.)
const int _kSearchAbove = 8;

class _PickSheet<T> extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<PickOption<T>> options;
  final List<PickOption<T>> pinned;
  final String searchHint;
  final String Function(String query)? emptyText;
  final int searchAbove;

  const _PickSheet({
    required this.title,
    required this.subtitle,
    required this.options,
    required this.pinned,
    required this.searchHint,
    required this.emptyText,
    required this.searchAbove,
  });

  @override
  State<_PickSheet<T>> createState() => _PickSheetState<T>();
}

class _PickSheetState<T> extends State<_PickSheet<T>> {
  final TextEditingController _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _row(PickOption<T> o) => ListTile(
        enabled: o.enabled,
        leading: o.leading,
        title: Text(o.title),
        subtitle: o.subtitle == null ? null : Text(o.subtitle!),
        trailing: o.trailing,
        onTap: () => Navigator.of(context).pop(o.value),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final q = _query.trim().toLowerCase();
    final shown =
        q.isEmpty ? widget.options : widget.options.where((o) => o.matches(q));

    return Padding(
      // isScrollControlled is what lets the sheet clear the soft keyboard,
      // which the search field needs.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.75),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ]),
            ),
            for (final o in widget.pinned) _row(o),
            if (widget.options.length > widget.searchAbove)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _ctrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: widget.searchHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              )
            else
              const SizedBox(height: 8),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(
                    widget.emptyText?.call(_query.trim()) ??
                        'Nothing matches "${_query.trim()}".',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final o in shown) _row(o)],
                ),
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }
}
