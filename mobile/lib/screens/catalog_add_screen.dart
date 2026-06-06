/// catalog_add_screen.dart
/// "Find your course" — one unified type-ahead over the courses already in your
/// account AND the shared Core catalog (instant, free, includes courses other
/// golfers imported). If your course is in neither, a button searches the full
/// GolfCourseAPI and imports it.
///
/// Tapping a course you already have selects it instantly; tapping a catalog
/// course clones it into the account (copy-on-add, idempotent) first. Either
/// way the resulting [CourseInfo] is popped so callers (e.g. round setup) can
/// auto-select it. Also reachable as a standalone "add courses" entry.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'course_search_screen.dart';

/// One row in the merged result list — either a course already in the account
/// (`local` set) or an addable catalog course (`catalog` set).
class _CourseHit {
  final String name;
  final String location;
  final int teeCount;
  final CourseInfo? local; // non-null → already in the account
  final CatalogCourse? catalog; // non-null → addable from the catalog

  const _CourseHit._({
    required this.name,
    required this.location,
    required this.teeCount,
    this.local,
    this.catalog,
  });

  factory _CourseHit.fromLocal(CourseInfo c) => _CourseHit._(
        name: c.name,
        location: c.location,
        teeCount: c.tees.length,
        local: c,
      );

  factory _CourseHit.fromCatalog(CatalogCourse c) => _CourseHit._(
        name: c.name,
        location: c.location,
        teeCount: c.teeCount,
        catalog: c,
      );

  bool get added => local != null;
}

class CatalogAddScreen extends StatefulWidget {
  const CatalogAddScreen({super.key});

  @override
  State<CatalogAddScreen> createState() => _CatalogAddScreenState();
}

class _CatalogAddScreenState extends State<CatalogAddScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  /// The account's own courses, loaded once and filtered client-side. Small
  /// per account, so this is cheap and keeps "your courses" instant.
  List<CourseInfo> _localCourses = [];

  List<_CourseHit> _hits = [];
  bool    _searching = false;
  Object? _error;
  int?    _addingId; // catalog id currently being cloned

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    try {
      final courses = await context.read<AuthProvider>().client.getCourses();
      if (!mounted) return;
      setState(() => _localCourses = courses);
      // If the user already typed while we were loading, fold them in now.
      final q = _searchCtrl.text.trim();
      if (q.length >= 2) _search(q);
    } catch (_) {
      // Non-fatal: degrade to a catalog-only search.
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() { _hits = []; _error = null; _searching = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _search(value.trim()));
  }

  List<CourseInfo> _filterLocal(String query) {
    final q = query.toLowerCase();
    return _localCourses
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.location.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _search(String query) async {
    setState(() { _searching = true; _error = null; });
    try {
      final catalog =
          await context.read<AuthProvider>().client.searchCatalog(query);
      if (!mounted) return;

      final hits = <_CourseHit>[
        for (final c in _filterLocal(query)) _CourseHit.fromLocal(c),
        // Drop catalog courses already in the account — the local copy above
        // represents them, so there's exactly one row per course.
        for (final c in catalog)
          if (!c.alreadyInAccount) _CourseHit.fromCatalog(c),
      ]..sort((a, b) {
          // Your courses first, then alphabetical.
          if (a.added != b.added) return a.added ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

      setState(() { _hits = hits; _searching = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _searching = false; });
    }
  }

  Future<void> _select(_CourseHit hit) async {
    // Already in the account → return it directly, no network.
    if (hit.local != null) {
      Navigator.of(context).pop(hit.local);
      return;
    }
    final c = hit.catalog!;
    setState(() => _addingId = c.id);
    try {
      final course =
          await context.read<AuthProvider>().client.addCatalogCourse(c.id);
      if (mounted) Navigator.of(context).pop(course);
    } catch (_) {
      if (mounted) {
        setState(() => _addingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add that course.')),
        );
      }
    }
  }

  Future<void> _openApiImport() async {
    // The full GolfCourseAPI search/import; importing populates the catalog,
    // so re-running the search surfaces the new course to select. Carry over
    // whatever the user already typed so they don't retype it.
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            CourseSearchScreen(initialQuery: _searchCtrl.text.trim()),
      ),
    );
    if (!mounted) return;
    // A fresh import may have added a course to the account, too — reload so it
    // shows under "your courses".
    await _loadLocal();
    if (_searchCtrl.text.trim().length >= 2) {
      _search(_searchCtrl.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find your course')),
      body: Column(
        children: [
          // Full-database fallback sits above the search box so it's the
          // natural place to look when your course isn't already in the list.
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: TextButton.icon(
                onPressed: _openApiImport,
                icon: const Icon(Icons.travel_explore),
                label: const Text('Search the full course database'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                hintText: 'Search by course or city…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(),
          Expanded(
            child: _error != null
                ? ErrorView(
                    message: 'Search failed.',
                    onRetry: () => _search(_searchCtrl.text.trim()),
                  )
                : _buildResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searchCtrl.text.trim().length < 2) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Search your courses and the catalog.\n'
            'Friends’ courses show up here too.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!_searching && _hits.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No matches yet.\nTry the full database below.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final hit = _hits[i];
        final sub = [
          if (hit.location.isNotEmpty) hit.location,
          if (hit.teeCount > 0)
            '${hit.teeCount} tee${hit.teeCount == 1 ? '' : 's'}',
          if (hit.added) 'In your courses',
        ].join('  ·  ');
        final busy = hit.catalog != null && _addingId == hit.catalog!.id;
        return ListTile(
          title: Text(hit.name),
          subtitle: sub.isEmpty ? null : Text(sub),
          trailing: busy
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : (hit.added
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : const Icon(Icons.add_circle_outline)),
          onTap: _addingId == null ? () => _select(hit) : null,
        );
      },
    );
  }
}
