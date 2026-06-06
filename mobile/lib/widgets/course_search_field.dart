/// widgets/course_search_field.dart
/// Inline course picker: a search box that, as you type, shows matches from
/// your own account courses AND the shared Core catalog right below it — no
/// jump to a separate screen. A "Search the full course database" button falls
/// back to the GolfCourseAPI import. Calls [onSelected] with the chosen course
/// (cloning a catalog course into the account first when needed).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../screens/course_search_screen.dart';

class _Hit {
  final String name;
  final String location;
  final int teeCount;
  final CourseInfo? local; // already in the account
  final CatalogCourse? catalog; // addable from the catalog

  const _Hit._({
    required this.name,
    required this.location,
    required this.teeCount,
    this.local,
    this.catalog,
  });

  factory _Hit.local(CourseInfo c) => _Hit._(
        name: c.name, location: c.location, teeCount: c.tees.length, local: c);
  factory _Hit.catalog(CatalogCourse c) => _Hit._(
        name: c.name, location: c.location, teeCount: c.teeCount, catalog: c);

  bool get added => local != null;
}

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

  List<CourseInfo> _local = [];
  List<_Hit> _hits = [];
  bool _searching = false;
  int? _addingId; // catalog id being cloned
  late bool _editing;

  @override
  void initState() {
    super.initState();
    _editing = widget.selected == null;
    _loadLocal();
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
    } catch (_) {/* degrade to catalog-only */}
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().length < 2) {
      setState(() { _hits = []; _searching = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300),
        () => _search(v.trim()));
  }

  Future<void> _search(String q) async {
    setState(() => _searching = true);
    try {
      final catalog =
          await context.read<AuthProvider>().client.searchCatalog(q);
      if (!mounted) return;
      final ql = q.toLowerCase();
      final hits = <_Hit>[
        for (final c in _local)
          if (c.name.toLowerCase().contains(ql) ||
              c.location.toLowerCase().contains(ql))
            _Hit.local(c),
        for (final c in catalog)
          if (!c.alreadyInAccount) _Hit.catalog(c),
      ]..sort((a, b) {
          if (a.added != b.added) return a.added ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      setState(() { _hits = hits; _searching = false; });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _select(_Hit h) async {
    if (h.local != null) {
      _commit(h.local!);
      return;
    }
    final c = h.catalog!;
    setState(() => _addingId = c.id);
    try {
      final course =
          await context.read<AuthProvider>().client.addCatalogCourse(c.id);
      _commit(course);
    } catch (_) {
      if (mounted) {
        setState(() => _addingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add that course.')),
        );
      }
    }
  }

  void _commit(CourseInfo c) {
    widget.onSelected(c);
    if (mounted) {
      setState(() {
        _editing = false;
        _hits = [];
        _addingId = null;
        _ctrl.clear();
      });
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _openApiImport() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => CourseSearchScreen(initialQuery: _ctrl.text.trim()),
    ));
    if (!mounted) return;
    await _loadLocal();
    if (_ctrl.text.trim().length >= 2) _search(_ctrl.text.trim());
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

    // Expanded: search box + inline results + full-database fallback.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText: 'Course',
            hintText: 'Search by city or course',
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
        if (_hits.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 260),
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
                  if (h.teeCount > 0)
                    '${h.teeCount} tee${h.teeCount == 1 ? '' : 's'}',
                  if (h.added) 'In your courses',
                ].join('  ·  ');
                final busy =
                    h.catalog != null && _addingId == h.catalog!.id;
                return ListTile(
                  dense: true,
                  title: Text(h.name),
                  subtitle: sub.isEmpty ? null : Text(sub),
                  trailing: busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : (h.added
                          ? const Icon(Icons.check_circle,
                              color: Colors.green, size: 20)
                          : const Icon(Icons.add_circle_outline, size: 20)),
                  onTap: _addingId == null ? () => _select(h) : null,
                );
              },
            ),
          ),
        if (_ctrl.text.trim().length >= 2 && !_searching && _hits.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('No matches in your courses or the catalog.',
                style: theme.textTheme.bodySmall),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _openApiImport,
            icon: const Icon(Icons.travel_explore),
            label: const Text('Search the full course database'),
          ),
        ),
      ],
    );
  }
}
