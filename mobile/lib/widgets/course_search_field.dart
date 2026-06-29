/// widgets/course_search_field.dart
/// One-box course picker: type a course name and pick it. As you type, a single
/// merged list shows matches from your own courses, the shared catalog, and the
/// full GolfCourseAPI database — no separate "search the full database" step.
/// Tapping a result selects it, cloning a catalog course or importing an API
/// course (with its tees) into the account first when needed. Calls [onSelected]
/// with the resulting account-owned course.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';

class CourseSearchField extends StatefulWidget {
  final CourseInfo? selected;
  final ValueChanged<CourseInfo> onSelected;

  const CourseSearchField({
    super.key,
    required this.selected,
    required this.onSelected,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Collapsed: show the selected course in a normal single-line field, with a
    // compact "change" suffix icon so the box matches the search field height.
    if (!_editing && widget.selected != null) {
      final c = widget.selected!;
      return InputDecorator(
        decoration: InputDecoration(
          labelText: 'Course',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.golf_course),
          suffixIcon: IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Change course',
            onPressed: () => setState(() => _editing = true),
          ),
        ),
        child: Text(
          c.location.isEmpty ? c.name : '${c.name}  ·  ${c.location}',
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    // Expanded: one search box + one merged result list.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText: 'Course',
            hintText: 'Search by course or city',
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
        ),
        // Recents quick-pick: shown only while the box is empty; the first
        // keystroke hides it and the live search list takes over the same slot.
        if (_ctrl.text.trim().isEmpty && _hits.isEmpty && _recents.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Text('Recent courses',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                for (final c in _recents)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.history,
                        size: 20, color: theme.colorScheme.onSurfaceVariant),
                    title: Text(c.name),
                    subtitle: c.location.isEmpty ? null : Text(c.location),
                    onTap: _addingKey == null ? () => _commit(c) : null,
                  ),
              ],
            ),
          ),
        if (_hits.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _hits.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final h = _hits[i];
                final sub = [
                  if (h.location.isNotEmpty) h.location,
                  if (h.teeCount != null && h.teeCount! > 0)
                    '${h.teeCount} tee${h.teeCount == 1 ? '' : 's'}',
                  if (h.inAccount) 'In your courses',
                ].join('  ·  ');
                final busy = _addingKey == _keyOf(h);
                return ListTile(
                  dense: true,
                  title: Text(h.name),
                  subtitle: sub.isEmpty ? null : Text(sub),
                  trailing: busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : (h.inAccount
                          ? const Icon(Icons.check_circle,
                              color: Colors.green, size: 20)
                          : const Icon(Icons.add_circle_outline, size: 20)),
                  onTap: _addingKey == null ? () => _select(h) : null,
                );
              },
            ),
          ),
        if (_ctrl.text.trim().length >= 2 && !_searching && _hits.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('No courses found. Try a different spelling or the city.',
                style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}
