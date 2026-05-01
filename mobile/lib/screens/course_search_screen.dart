/// course_search_screen.dart
/// Admin screen for searching GolfCourseAPI and importing courses into the
/// local database.
///
/// Flow
/// ~~~~
/// 1. Type at least 2 characters → debounced search fires after 600 ms.
/// 2. Results are individual courses (club_name + course_name).
/// 3. Tap a course → fetch full detail (tees + holes) in a bottom sheet.
/// 4. Tap "Import" → POST /api/courses/import/.
///    - If 409 (already exists): offer Skip / Update options.
///    - On success: show a snackbar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

class CourseSearchScreen extends StatefulWidget {
  const CourseSearchScreen({super.key});

  @override
  State<CourseSearchScreen> createState() => _CourseSearchScreenState();
}

class _CourseSearchScreenState extends State<CourseSearchScreen> {
  final _searchCtrl = TextEditingController();
  Timer?             _debounce;

  List<Map<String, dynamic>> _courses      = [];
  bool    _searching   = false;
  Object? _searchError;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() { _courses = []; _searchError = null; _searching = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () => _search(value.trim()));
  }

  Future<void> _search(String query) async {
    setState(() { _searching = true; _searchError = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final results = await client.searchGolfApiCourses(query);
      if (mounted) setState(() { _courses = results; _searching = false; });
    } catch (e) {
      if (mounted) setState(() { _searchError = e; _searching = false; });
    }
  }

  Future<void> _onCourseTapped(Map<String, dynamic> course) async {
    final client = context.read<AuthProvider>().client;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CourseDetailSheet(
        course:     course,
        client:     client,
        onImported: () {
          if (mounted) setState(() {}); // refresh "already imported" badges
        },
      ),
    );
  }

  /// Display title for a course result: club name, with course name appended
  /// in parentheses when it differs (e.g. multi-course facilities).
  static String _courseTitle(Map<String, dynamic> c) {
    final club   = (c['club_name']   as String? ?? '').trim();
    final course = (c['course_name'] as String? ?? '').trim();
    if (course.isNotEmpty && course != club) return '$club ($course)';
    return club;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Course'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller:    _searchCtrl,
              autofocus:     true,
              decoration: InputDecoration(
                hintText:    'Search by club or course name…',
                prefixIcon:  const Icon(Icons.search),
                suffixIcon:  _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon:      const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                border:      const OutlineInputBorder(),
                filled:      true,
                isDense:     true,
                fillColor:   theme.colorScheme.surface,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
        ),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_searchError != null) {
      return ErrorView(
        message:   friendlyError(_searchError!),
        isNetwork: isNetworkError(_searchError!),
        onRetry:   () => _search(_searchCtrl.text.trim()),
      );
    }

    if (_courses.isEmpty && _searchCtrl.text.trim().length >= 2) {
      return Center(
        child: Text(
          'No courses found for "${_searchCtrl.text.trim()}".',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_courses.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.golf_course,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'Search for a golf course by name\nto import its tees and scorecard.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _courses.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c        = _courses[i];
        final imported = c['already_imported'] as bool? ?? false;
        final location = [
          c['city']    as String? ?? '',
          c['state']   as String? ?? '',
          c['country'] as String? ?? '',
        ].where((s) => s.isNotEmpty).join(', ');

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: imported
                ? theme.colorScheme.secondaryContainer
                : theme.colorScheme.primaryContainer,
            child: Icon(
              imported ? Icons.check : Icons.golf_course,
              color: imported
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onPrimaryContainer,
              size: 20,
            ),
          ),
          title:    Text(_courseTitle(c)),
          subtitle: location.isNotEmpty ? Text(location) : null,
          trailing: imported
              ? Chip(
                  label: const Text('In library',
                      style: TextStyle(fontSize: 11)),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  backgroundColor:
                      theme.colorScheme.secondaryContainer.withOpacity(0.6),
                )
              : const Icon(Icons.chevron_right),
          onTap: () => _onCourseTapped(c),
        );
      },
    );
  }
}

// ── Course detail bottom sheet ────────────────────────────────────────────────

class _CourseDetailSheet extends StatefulWidget {
  final Map<String, dynamic> course;
  final ApiClient            client;
  final VoidCallback         onImported;

  const _CourseDetailSheet({
    required this.course,
    required this.client,
    required this.onImported,
  });

  @override
  State<_CourseDetailSheet> createState() => _CourseDetailSheetState();
}

class _CourseDetailSheetState extends State<_CourseDetailSheet> {
  Map<String, dynamic>? _detail;
  bool    _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() { _loading = true; _error = null; });
    try {
      final courseId = widget.course['id'] as int;
      final detail   = await widget.client.getGolfApiCourse(courseId);
      if (mounted) setState(() { _detail = detail; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _tees =>
      (_detail?['tees'] as List? ?? [])
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList();

  Future<void> _import({bool forceUpdate = false}) async {
    final courseId = widget.course['id'] as int;
    Navigator.of(context).pop();

    final scaffoldMsg = ScaffoldMessenger.of(context);
    try {
      final result  = await widget.client.importCourse(courseId, forceUpdate: forceUpdate);
      widget.onImported();
      final title   = _courseTitle(widget.course);
      final warning = result['warning'] as String?;
      final msg     = warning != null
          ? '$title imported. Note: $warning'
          : '$title imported successfully.';
      scaffoldMsg.showSnackBar(SnackBar(
        content:         Text(msg),
        backgroundColor: warning != null ? Colors.orange : Colors.green,
        duration:        warning != null
            ? const Duration(seconds: 8)
            : const Duration(seconds: 3),
      ));
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        scaffoldMsg.showSnackBar(const SnackBar(
          content:         Text('Course already exists. Use "Update" to overwrite.'),
          backgroundColor: Colors.orange,
        ));
      } else {
        scaffoldMsg.showSnackBar(SnackBar(
          content:         Text(friendlyError(e)),
          backgroundColor: Colors.red,
        ));
      }
    } catch (e) {
      scaffoldMsg.showSnackBar(SnackBar(
        content:         Text(friendlyError(e)),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _onImportTapped() async {
    final alreadyImported = widget.course['already_imported'] as bool? ?? false;

    if (alreadyImported) {
      final choice = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Course Already Exists'),
          content: Text(
            '"${_courseTitle(widget.course)}" is already in your course library.\n\n'
            'Would you like to update it (replacing all tee data) '
            'or skip the import?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('skip'),
              child: const Text('Skip'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop('update'),
              child: const Text('Update'),
            ),
          ],
        ),
      );
      if (choice == 'update') _import(forceUpdate: true);
    } else {
      _import();
    }
  }

  static String _courseTitle(Map<String, dynamic> c) {
    final club   = (c['club_name']   as String? ?? '').trim();
    final course = (c['course_name'] as String? ?? '').trim();
    if (course.isNotEmpty && course != club) return '$club ($course)';
    return club;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize:     0.4,
      maxChildSize:     0.92,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // ── Handle ───────────────────────────────────────────────────
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // ── Header ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                  child: Text(
                    _courseTitle(widget.course),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon:      const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ]),
            ),
            if ((widget.course['city'] as String?)?.isNotEmpty == true ||
                (widget.course['state'] as String?)?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    [
                      widget.course['city']  as String? ?? '',
                      widget.course['state'] as String? ?? '',
                    ].where((s) => s.isNotEmpty).join(', '),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            const Divider(height: 24),
            // ── Body ─────────────────────────────────────────────────────
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: ErrorView(
                            message:   friendlyError(_error!),
                            isNetwork: isNetworkError(_error!),
                            onRetry:   _loadDetail,
                          ),
                        )
                      : _buildDetail(theme, scrollController),
            ),
            // ── Import button ─────────────────────────────────────────────
            if (!_loading && _error == null) ...[
              const Divider(height: 1),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _onImportTapped,
                      icon:  const Icon(Icons.download_rounded),
                      label: Text(
                        (widget.course['already_imported'] as bool? ?? false)
                            ? 'Already in Library — Tap to Update'
                            : 'Import to Library',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildDetail(ThemeData theme, ScrollController scrollController) {
    final tees = _tees;

    if (tees.isEmpty) {
      return const Center(child: Text('No tee data available for this course.'));
    }

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Row(children: [
          Text('Tee Sets',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Text(
            '(${tees.length})',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
        const SizedBox(height: 8),
        ...tees.map((tee) {
          final holes    = tee['holes'] as List? ?? [];
          final sexLabel = tee['sex'] == 'M' ? 'Men' : 'Women';
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tee['name'] as String? ?? '',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(sexLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                )),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Slope ${tee['slope']}',
                        style: theme.textTheme.bodySmall),
                    Text('Rating ${tee['course_rating']}',
                        style: theme.textTheme.bodySmall),
                    Text('Par ${tee['par']}',
                        style: theme.textTheme.bodySmall),
                    if (holes.length != 18)
                      Text('⚠ ${holes.length}/18 holes',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error)),
                  ],
                ),
              ]),
            ),
          );
        }),
        const SizedBox(height: 16),
      ],
    );
  }
}
