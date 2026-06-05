/// catalog_add_screen.dart
/// "Find your course" — searches the SHARED catalog first (instant, free,
/// includes courses other golfers already imported) and falls back to the full
/// GolfCourseAPI for ones not yet in the catalog.
///
/// Tapping a result clones it into the account (copy-on-add, idempotent) and
/// pops the resulting [CourseInfo] so callers (e.g. round setup) can
/// auto-select it. Also reachable as a standalone "add courses" entry.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'course_search_screen.dart';

class CatalogAddScreen extends StatefulWidget {
  const CatalogAddScreen({super.key});

  @override
  State<CatalogAddScreen> createState() => _CatalogAddScreenState();
}

class _CatalogAddScreenState extends State<CatalogAddScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<CatalogCourse> _results = [];
  bool    _searching = false;
  Object? _error;
  int?    _addingId;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() { _results = []; _error = null; _searching = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _search(value.trim()));
  }

  Future<void> _search(String query) async {
    setState(() { _searching = true; _error = null; });
    try {
      final results =
          await context.read<AuthProvider>().client.searchCatalog(query);
      if (mounted) setState(() { _results = results; _searching = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _searching = false; });
    }
  }

  Future<void> _add(CatalogCourse c) async {
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
    // so re-running the catalog search surfaces the new course to select.
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const CourseSearchScreen()),
    );
    if (mounted && _searchCtrl.text.trim().length >= 2) {
      _search(_searchCtrl.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find your course')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
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
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: TextButton.icon(
                onPressed: _openApiImport,
                icon: const Icon(Icons.travel_explore),
                label: const Text("Can't find it? Search the full database"),
              ),
            ),
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
            'Search for your course to add it.\nFriends’ courses show up here too.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!_searching && _results.isEmpty) {
      return const Center(child: Text('No matching courses in the catalog.'));
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final c = _results[i];
        final sub = [
          if (c.location.isNotEmpty) c.location,
          '${c.teeCount} tee${c.teeCount == 1 ? '' : 's'}',
        ].join('  ·  ');
        return ListTile(
          title: Text(c.name),
          subtitle: Text(sub),
          trailing: _addingId == c.id
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : (c.alreadyInAccount
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : const Icon(Icons.add_circle_outline)),
          onTap: _addingId == null ? () => _add(c) : null,
        );
      },
    );
  }
}
