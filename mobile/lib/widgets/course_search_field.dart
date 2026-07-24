/// widgets/course_search_field.dart
/// One-box course picker (design 9a — "suggested is not selected").
///
/// Nothing is ever pre-selected. Type a course name and pick from a single
/// merged list (your own courses, the shared catalog, and the full
/// GolfCourseAPI database — no source split). Before searching, the home course
/// shows as an explicit "Play here" SUGGESTION and recents as pills — neither
/// looks chosen. Once a course is picked it collapses to a distinct
/// mint-checked "Playing today" card with a Change action and a lighter
/// "OR SWITCH TO" list. Tapping a result clones a catalog course or imports an
/// API course (with tees) behind the selection and calls [onSelected].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';

enum _CourseKind { home, recent }

class CourseSearchField extends StatefulWidget {
  final CourseInfo? selected;
  final ValueChanged<CourseInfo> onSelected;

  /// Header shown over the chosen course. 'Playing today' for round creation;
  /// callers picking a home course (settings) pass their own.
  final String selectedLabel;

  /// Whether to surface the golfer's home course as a "Play here" suggestion.
  /// Off when the picker IS for choosing the home course (settings), where a
  /// home suggestion would be circular.
  final bool suggestHome;

  const CourseSearchField({
    super.key,
    required this.selected,
    required this.onSelected,
    this.selectedLabel = 'Playing today',
    this.suggestHome = true,
  });

  @override
  State<CourseSearchField> createState() => _CourseSearchFieldState();
}

class _CourseSearchFieldState extends State<CourseSearchField> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  int _searchSeq = 0; // guards against out-of-order async results

  List<CourseInfo> _local = []; // account courses, for resolving 'account' hits
  List<CourseInfo> _recents = []; // last few played, shown when the box is empty
  List<CourseHit> _hits = [];
  bool _searching = false;
  String? _addingKey; // the hit currently being added/imported
  late bool _editing;

  @override
  void initState() {
    super.initState();
    _editing = widget.selected == null;
    _loadLocal();
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    try {
      final r = await context.read<AuthProvider>().client.getRecentCourses();
      if (mounted) setState(() => _recents = r);
    } catch (_) {/* degrade — just don't show the quick-pick */}
  }

  @override
  void didUpdateWidget(CourseSearchField old) {
    super.didUpdateWidget(old);
    // A selection arriving from the parent (e.g. an extra tournament day being
    // defaulted to Round 1's course) should collapse to show it.
    if (widget.selected != null && old.selected == null && _editing) {
      setState(() => _editing = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    try {
      final c = await context.read<AuthProvider>().client.getCourses();
      if (mounted) setState(() => _local = c);
    } catch (_) {/* degrade — account hits fall back to a direct fetch */}
  }

  String _keyOf(CourseHit h) =>
      '${h.source}:${h.courseId ?? h.catalogId ?? h.golfApiId}';

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().length < 2) {
      setState(() { _hits = []; _searching = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _search(v.trim()));
  }

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    setState(() => _searching = true);
    try {
      final hits = await context.read<AuthProvider>().client.findCourses(q);
      if (!mounted || seq != _searchSeq) return; // a newer search superseded us
      setState(() { _hits = hits; _searching = false; });
    } catch (_) {
      if (mounted && seq == _searchSeq) setState(() => _searching = false);
    }
  }

  Future<void> _select(CourseHit h) async {
    final client = context.read<AuthProvider>().client;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _addingKey = _keyOf(h));
    try {
      final CourseInfo course;
      switch (h.source) {
        case 'account':
          course = _local.firstWhere(
            (c) => c.id == h.courseId,
            orElse: () => throw StateError('not loaded'),
          );
          break;
        case 'catalog':
          course = await client.addCatalogCourse(h.catalogId!);
          break;
        default: // 'api'
          course = await client.importApiCourse(h.golfApiId);
      }
      _commit(course);
    } on StateError {
      // Account course wasn't in the cached list — fetch it directly.
      try {
        final course = await client.getCourse(h.courseId!);
        _commit(course);
      } catch (_) {
        _failAdd(messenger);
      }
    } catch (_) {
      _failAdd(messenger);
    }
  }

  void _failAdd(ScaffoldMessengerState messenger) {
    if (!mounted) return;
    setState(() => _addingKey = null);
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not add that course. Try again.')),
    );
  }

  void _commit(CourseInfo c) {
    widget.onSelected(c);
    if (mounted) {
      setState(() {
        _editing = false;
        _hits = [];
        _addingKey = null;
        _ctrl.clear();
      });
      FocusScope.of(context).unfocus();
    }
    // Keep the cache fresh so a freshly added course resolves instantly next time.
    if (c.id != 0 && !_local.any((x) => x.id == c.id)) _loadLocal();
  }

  CourseInfo? _homeCourse() {
    if (!widget.suggestHome) return null;
    final homeId = context.watch<AuthProvider>().player?.homeCourseId;
    if (homeId == null) return null;
    for (final c in _local) {
      if (c.id == homeId) return c;
    }
    return null;
  }

  // ── UI pieces ──────────────────────────────────────────────────────────────

  Widget _sectionLabel(ThemeData theme, String t) => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 6, left: 2),
        child: Text(t,
            style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: theme.colorScheme.onSurfaceVariant)),
      );

  Widget _card({
    required Widget child,
    Color? borderColor,
    Color? fill,
    VoidCallback? onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: fill ?? Halved.card,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: borderColor ?? Halved.cardBorder,
                    width: borderColor != null ? 1.5 : 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: child,
            ),
          ),
        ),
      );

  /// A tappable course "pill" — the home course (pine-accented, "Play here") or
  /// a recent (history icon). Both share the same card so recents match home.
  Widget _suggestionCard(ThemeData theme, CourseInfo c, _CourseKind kind) {
    final home = kind == _CourseKind.home;
    return _card(
      borderColor: home ? Halved.pine : null,
      onTap: _addingKey == null ? () => _commit(c) : null,
      child: Row(children: [
        Icon(home ? Icons.flag : Icons.history,
            size: 20,
            color: home ? Halved.pine : theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: _nameAndLocation(theme, c)),
        if (home)
          Text('Play here',
              style: TextStyle(
                  color: Halved.pine,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
      ]),
    );
  }

  /// The distinct mint-checked "Playing today" card + Change.
  Widget _selectedCard(ThemeData theme, CourseInfo c) => _card(
        borderColor: Halved.mint,
        fill: Halved.mint.withValues(alpha: 0.08),
        child: Row(children: [
          const Icon(Icons.check_circle, color: Halved.mint, size: 22),
          const SizedBox(width: 12),
          Expanded(child: _nameAndLocation(theme, c, bold: true)),
          TextButton(
            onPressed: () => setState(() => _editing = true),
            child: const Text('Change'),
          ),
        ]),
      );

  /// A lighter row for "OR SWITCH TO" — one-tap switch, no card chrome.
  Widget _switchRow(ThemeData theme, CourseInfo c, _CourseKind kind) {
    final home = kind == _CourseKind.home;
    return InkWell(
      onTap: _addingKey == null ? () => _commit(c) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(children: [
          Icon(home ? Icons.flag_outlined : Icons.history,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: c.name,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                if (c.location.isNotEmpty)
                  TextSpan(
                      text: '  ·  ${c.location}${home ? ' · Home' : ''}',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12)),
              ]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ]),
      ),
    );
  }

  Widget _nameAndLocation(ThemeData theme, CourseInfo c, {bool bold = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
          if (c.location.isNotEmpty)
            Text(c.location,
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
        ],
      );

  Widget _searchBox(ThemeData theme) => TextField(
        controller: _ctrl,
        onChanged: _onChanged,
        decoration: InputDecoration(
          labelText: 'Search',
          hintText: 'Search 40,000+ courses…',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : null,
        ),
      );

  /// One flat, neutral results list — no "in your courses" vs global split, no
  /// add/check source icons (design 9a §6). Tap picks; import is invisible.
  Widget _resultsList(ThemeData theme) => Container(
        margin: const EdgeInsets.only(top: 8),
        constraints: const BoxConstraints(maxHeight: 340),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _hits.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final h = _hits[i];
            final busy = _addingKey == _keyOf(h);
            final sub = [
              if (h.location.isNotEmpty) h.location,
              if (h.teeCount != null && h.teeCount! > 0)
                '${h.teeCount} tee${h.teeCount == 1 ? '' : 's'}',
            ].join('  ·  ');
            return ListTile(
              dense: true,
              title: Text(h.name),
              subtitle: sub.isEmpty ? null : Text(sub),
              trailing: busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
              onTap: _addingKey == null ? () => _select(h) : null,
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final home = _homeCourse();
    final selectedId = widget.selected?.id;

    // ── A course is chosen: "Playing today" card + lighter "OR SWITCH TO" ──────
    if (!_editing && widget.selected != null) {
      final switches = <(_CourseKind, CourseInfo)>[
        if (home != null && home.id != selectedId)
          (_CourseKind.home, home),
        for (final c in _recents)
          if (c.id != selectedId && c.id != home?.id) (_CourseKind.recent, c),
      ];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionLabel(theme, widget.selectedLabel.toUpperCase()),
        _selectedCard(theme, widget.selected!),
        if (switches.isNotEmpty) ...[
          const SizedBox(height: 12),
          _sectionLabel(theme, 'OR SWITCH TO'),
          for (final (kind, c) in switches) _switchRow(theme, c, kind),
        ],
      ]);
    }

    // ── Nothing selected: search + (when empty) home suggestion + recents ─────
    final recentsToShow = _recents
        .where((c) => c.id != home?.id && c.id != selectedId)
        .toList();
    final showQuickPick = _ctrl.text.trim().isEmpty && _hits.isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _searchBox(theme),
      if (showQuickPick && home != null) ...[
        const SizedBox(height: 12),
        _sectionLabel(theme, 'YOUR HOME COURSE'),
        _suggestionCard(theme, home, _CourseKind.home),
      ],
      if (showQuickPick && recentsToShow.isNotEmpty) ...[
        const SizedBox(height: 12),
        _sectionLabel(theme, 'RECENT'),
        for (final c in recentsToShow) _suggestionCard(theme, c, _CourseKind.recent),
      ],
      if (_hits.isNotEmpty) _resultsList(theme),
      if (_ctrl.text.trim().length >= 2 && !_searching && _hits.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('No courses found. Try a different spelling or the city.',
              style: theme.textTheme.bodySmall),
        ),
    ]);
  }
}
