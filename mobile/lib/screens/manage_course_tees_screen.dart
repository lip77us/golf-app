/// screens/manage_course_tees_screen.dart
/// --------------------------------------
/// Drill-down from ManageCoursesScreen.  Shows the tee sets at one
/// course, with delete buttons.  Future passes will add an edit
/// flow (re-rate after USGA update) and a paste-from-spreadsheet
/// importer; for now this is purely a remove-tee surface.
///
/// Returns `true` to its caller if any tee was deleted, so the
/// course list above can refresh its tee-count display.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'course_paste_screen.dart';
import 'tee_paste_screen.dart';

class ManageCourseTeesScreen extends StatefulWidget {
  final int courseId;
  const ManageCourseTeesScreen({super.key, required this.courseId});

  @override
  State<ManageCourseTeesScreen> createState() => _ManageCourseTeesScreenState();
}

class _ManageCourseTeesScreenState extends State<ManageCourseTeesScreen> {
  CourseInfo? _course;
  bool   _loading = true;
  String? _error;
  bool   _anyDeleted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final c = await context.read<AuthProvider>().client
          .getCourse(widget.courseId);
      if (mounted) setState(() {
        _course  = c;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error   = friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _editTee(CourseTeeSummary summary) async {
    // The summary on the course detail payload skips the per-hole
    // blob to keep the list cheap; fetch the full tee so the paste
    // textarea can be pre-filled.
    try {
      final full = await context.read<AuthProvider>().client.getTee(summary.id);
      if (!mounted) return;
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => TeePasteScreen(
            courseId:    widget.courseId,
            courseName:  _course?.name ?? 'Course',
            existingTee: full,
          ),
        ),
      );
      if (changed == true) {
        _anyDeleted = true;   // signal the list above to reload
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  Future<void> _addTee() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TeePasteScreen(
          courseId:   widget.courseId,
          courseName: _course?.name ?? 'Course',
        ),
      ),
    );
    if (changed == true) {
      _anyDeleted = true;
      await _load();
    }
  }

  Future<void> _delete(CourseTeeSummary t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete tee set?'),
        content: Text(
          'Delete the ${t.teeName} tees at ${_course?.name ?? 'this course'}?  '
          'Tees that have been used in any round are protected.',
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
    if (ok != true) return;
    try {
      await context.read<AuthProvider>().client.deleteTee(t.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${t.teeName} tees.')),
      );
      _anyDeleted = true;
      await _load();
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

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      // ignore: deprecated_member_use
      onWillPop: () async {
        Navigator.of(context).pop(_anyDeleted);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_course?.name ?? 'Course'),
          actions: [
            // Re-rate tees: paste fresh ratings/yardages.  Updates
            // matching tees in place so existing rounds aren't
            // broken by PROTECT FKs.
            if (_course != null)
              IconButton(
                icon: const Icon(Icons.update_outlined),
                tooltip: 'Re-rate tees from a scorecard',
                onPressed: () async {
                  final changed =
                      await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => CoursePasteScreen(
                        replaceCourseId:   _course!.id,
                        replaceCourseName: _course!.name,
                      ),
                    ),
                  );
                  if (changed == true) {
                    _anyDeleted = true;   // signal upstream to reload
                    await _load();
                  }
                },
              ),
          ],
        ),
        floatingActionButton: _course == null ? null :
          FloatingActionButton.extended(
            onPressed: _addTee,
            icon: const Icon(Icons.add),
            label: const Text('Add tee'),
          ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    final tees = _course?.tees ?? const [];
    if (tees.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No tees configured on this course.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    final sorted = [...tees]
      ..sort((a, b) => a.sortPriority.compareTo(b.sortPriority));

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: sorted.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (_, i) {
        final t  = sorted[i];
        final sx = t.sex == 'M' ? "M's" : t.sex == 'W' ? "W's" : 'Unisex';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor:
                Theme.of(context).colorScheme.primaryContainer,
            foregroundColor:
                Theme.of(context).colorScheme.onPrimaryContainer,
            child: const Icon(Icons.flag_outlined),
          ),
          title: Text(t.teeName,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            'Slope ${t.slope}  ·  Rating ${t.courseRating.toStringAsFixed(1)}'
            '  ·  Par ${t.par}  ·  $sx',
            style: const TextStyle(fontSize: 13),
          ),
          trailing: IconButton(
            icon: Icon(Icons.delete_outline,
                color: Theme.of(context).colorScheme.error),
            tooltip: 'Delete tee set',
            onPressed: () => _delete(t),
          ),
          onTap: () => _editTee(t),
        );
      },
    );
  }
}
