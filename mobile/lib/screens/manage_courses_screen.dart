/// screens/manage_courses_screen.dart
/// ----------------------------------
/// Admin screen listing the courses imported into this account.
///
/// Lets admins:
///   * delete a course outright (CASCADE wipes its tees; rounds
///     protect via API 400)
///   * drill into a course to see / delete individual tees
///   * jump to the GolfCourseAPI search screen to import more
///
/// Non-admins shouldn't reach this screen — the entry point in
/// AppDrawer is gated by AuthProvider.isAdmin.  We still re-check
/// inside so a deep-link doesn't bypass the gate.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'course_paste_screen.dart';
import 'manage_course_tees_screen.dart';

class ManageCoursesScreen extends StatefulWidget {
  const ManageCoursesScreen({super.key});

  @override
  State<ManageCoursesScreen> createState() => _ManageCoursesScreenState();
}

class _ManageCoursesScreenState extends State<ManageCoursesScreen> {
  List<CourseInfo>? _courses;
  bool   _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final list = await context.read<AuthProvider>().client.getCourses();
      if (mounted) setState(() {
        _courses = list;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error   = friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<bool> _confirmDelete(CourseInfo c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete course?'),
        content: Text(
          'Delete ${c.name} and all of its tees?  This can\'t be '
          'undone.  Courses that have hosted any rounds are protected — '
          'you\'ll get an error if so.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _delete(CourseInfo c) async {
    if (!await _confirmDelete(c)) return;
    try {
      await context.read<AuthProvider>().client.deleteCourse(c.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${c.name}.')),
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 5),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  Future<void> _openTees(CourseInfo c) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ManageCourseTeesScreen(courseId: c.id)),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Courses')),
        body: const Center(
          child: Text('Only admins can manage courses.'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Courses'),
        actions: [
          // Paste-a-scorecard alt-entry alongside the GolfCourseAPI
          // import.  Lives in the toolbar so it's distinct from the
          // primary FAB, which still points at the catalogue search.
          IconButton(
            icon: const Icon(Icons.content_paste_go_outlined),
            tooltip: 'Paste a scorecard',
            onPressed: () async {
              final created = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => const CoursePasteScreen(),
                ),
              );
              if (created == true && mounted) _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).pushNamed('/course-search');
          if (mounted) _load();
        },
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Import course'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    final list = _courses ?? const [];
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.golf_course, size: 64, color: Colors.grey),
              const SizedBox(height: 12),
              Text('No courses yet.',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Tap "Import course" to add one from GolfCourseAPI.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: list.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (_, i) {
          final c = list[i];
          final tile = ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              foregroundColor:
                  Theme.of(context).colorScheme.onPrimaryContainer,
              child: const Icon(Icons.golf_course),
            ),
            title: Text(c.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              [
                if (c.location.isNotEmpty) c.location,
                c.tees.isEmpty
                    ? 'No tees configured'
                    : '${c.tees.length} tee set'
                      '${c.tees.length == 1 ? '' : 's'}  ·  '
                      '${c.tees.map((t) => t.teeName).join(", ")}',
              ].join('\n'),
              style: const TextStyle(fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              tooltip: 'Delete course',
              onPressed: () => _delete(c),
            ),
            onTap: () => _openTees(c),
          );

          return Dismissible(
            key: ValueKey('course-${c.id}'),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Theme.of(context).colorScheme.error,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            confirmDismiss: (_) async {
              if (!await _confirmDelete(c)) return false;
              try {
                await context.read<AuthProvider>().client.deleteCourse(c.id);
                if (!mounted) return false;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Deleted ${c.name}.')),
                );
                return true;
              } on ApiException catch (e) {
                if (!mounted) return false;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(e.message),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  duration: const Duration(seconds: 5),
                ));
                return false;
              } catch (e) {
                if (!mounted) return false;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(friendlyError(e)),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ));
                return false;
              }
            },
            onDismissed: (_) {
              setState(() => _courses?.removeWhere((x) => x.id == c.id));
            },
            child: tile,
          );
        },
      ),
    );
  }
}
