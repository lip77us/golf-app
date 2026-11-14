/// widgets/course_bar.dart
///
/// The **course bar**: the mint "Playing today" card with the course name, its
/// town (or *(Home Course)*) and **Change**, which opens the Find a course
/// screen (`screens/course_find_screen.dart`). It replaces the inline
/// `CourseSearchField` everywhere the app has a course bar.
///
/// ## Starting course
///
/// With [preselectDefault] and nothing chosen yet the bar fills itself in:
/// first the golfer's HOME course, immediately; then, if the phone says he is
/// standing at one of his courses, that one instead. **Nothing waits for the
/// phone** — the home course is on the form before the fix is asked for, the
/// fix has a two-second budget, and any failure leaves the home course (or
/// nothing, when he has none). See `utils/default_course.dart` for why the
/// radius is what it is and why this is allowed to read location untapped.
///
/// A golfer who has already opened Change is never overridden: the late swap
/// is dropped the moment he touches the course, because a form that changes
/// its answer under a thumb is worse than one that never knew.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../screens/course_find_screen.dart';
import '../theme/halved_brand.dart';
import '../utils/default_course.dart';

class CourseBar extends StatefulWidget {
  final CourseInfo? selected;
  final ValueChanged<CourseInfo> onSelected;

  /// Called right after [onSelected] with the tees a RECENT was played from,
  /// or null when the course came from search or location. The form uses it
  /// to pre-select tees.
  final ValueChanged<String?>? onTeeHint;

  /// Called just before [onSelected] when the BAR chose the course (home or
  /// nearby), as opposed to the golfer. A form uses it to tell a seeded
  /// course from a picked one — so backing out of an untouched form does not
  /// ask whether to discard a draft.
  final ValueChanged<CourseInfo>? onDefaulted;

  /// Header over the chosen course. 'Playing today' for round creation;
  /// callers picking a home course (Profile) pass their own.
  final String selectedLabel;

  /// Whether to say *(Home Course)* when the chosen course IS the home
  /// course. Off when the bar is for choosing the home course itself.
  final bool suggestHome;

  /// Fill in the home / nearby course when nothing is chosen. Only the forms
  /// that start a round ask for this.
  final bool preselectDefault;

  /// Test seam: replaces the quiet fix.
  final Future<({double lat, double lon})?> Function()? positionOverride;

  const CourseBar({
    super.key,
    required this.selected,
    required this.onSelected,
    this.onTeeHint,
    this.onDefaulted,
    this.selectedLabel = 'Playing today',
    this.suggestHome = true,
    this.preselectDefault = false,
    this.positionOverride,
  });

  @override
  State<CourseBar> createState() => _CourseBarState();
}

class _CourseBarState extends State<CourseBar> {
  /// The golfer has opened Change: stop auto-filling.
  bool _touched = false;

  /// The id we filled in ourselves, so a late nearby swap only replaces OUR
  /// choice and never one he made some other way.
  int? _autoId;

  @override
  void initState() {
    super.initState();
    if (widget.preselectDefault && widget.selected == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _preselect());
    }
  }

  Future<void> _preselect() async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final homeId = auth.player?.homeCourseId;
    final List<CourseInfo> courses;
    try {
      courses = await auth.client.getCourses();
    } catch (_) {
      return; // no list, no default — the form just starts blank
    }
    if (!mounted || _touched || widget.selected != null) return;

    // Step 1 — immediate, and the whole answer when anything below fails.
    final home = homeCourse(courses, homeId);
    if (home != null) _auto(home);

    // Step 2 — a bonus. Cannot delay, fail or prompt.
    final here = await courseHere(courses, position: widget.positionOverride);
    if (!mounted || _touched || here == null) return;
    // Only replace what WE put there (or nothing).
    final cur = widget.selected;
    if (cur == null || cur.id == _autoId) {
      if (cur?.id != here.id) _auto(here);
    }
  }

  void _auto(CourseInfo c) {
    _autoId = c.id;
    widget.onDefaulted?.call(c);
    widget.onSelected(c);
    widget.onTeeHint?.call(null);
  }

  Future<void> _change() async {
    _touched = true;
    final messenger = ScaffoldMessenger.of(context);
    final r = await Navigator.of(context).push<CourseFindResult>(
      MaterialPageRoute(builder: (_) => const CourseFindScreen()),
    );
    if (r == null || !mounted) return; // back: no change
    widget.onSelected(r.course);
    widget.onTeeHint?.call(r.teeName);
    messenger.showSnackBar(SnackBar(
      content: Text(r.toast),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.selected;
    final homeId = context.watch<AuthProvider>().player?.homeCourseId;
    final isHome = widget.suggestHome && c != null && c.id == homeId;
    final sub = isHome ? '(Home Course)' : (c?.location ?? '');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 6),
        child: Text(
          (c == null ? 'Course' : widget.selectedLabel).toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      Material(
        color: c == null ? Halved.card : const Color(0xFFE3F6EC),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: const ValueKey('course-bar'),
          borderRadius: BorderRadius.circular(14),
          onTap: _change,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: c == null ? Halved.cardBorder : const Color(0xFF3BD89A),
                  width: c == null ? 1 : 1.5),
            ),
            child: Row(children: [
              Icon(c == null ? Icons.search : Icons.check_circle,
                  size: 20,
                  color: c == null
                      ? theme.colorScheme.onSurfaceVariant
                      : const Color(0xFF0F6E56)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(c?.name ?? 'Find a course',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  if (sub.isNotEmpty)
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
              TextButton(
                onPressed: _change,
                child: Text(c == null ? 'Choose' : 'Change'),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}
