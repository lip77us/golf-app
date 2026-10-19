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

import '../api/client.dart' show ApiClient, ApiException;
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/near_me.dart';

enum _CourseKind { home, recent }

/// Where the "Courses near me" affordance is. **Idle means no location call
/// has been made** — that is the whole point of it being a separate state
/// rather than a loading flag: the golfer can see, before tapping, that
/// nothing has been asked for yet.
enum _NearState { idle, locating, results }

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

  /// Replaces the location fix + lookup. **For tests only** — the real one
  /// goes through `Geolocator`, which has no platform binding under
  /// `flutter test`, so without this seam none of the pill's states can be
  /// asserted and they are the part a future edit breaks.
  final Future<NearMeResult> Function(ApiClient client)? nearMeOverride;

  const CourseSearchField({
    super.key,
    required this.selected,
    required this.onSelected,
    this.selectedLabel = 'Playing today',
    this.suggestHome = true,
    this.nearMeOverride,
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

  /// The course database did not answer, so these hits are local only. Said
  /// out loud because a short list otherwise reads as a complete answer.
  bool _localOnly = false;

  // ── Courses near me ───────────────────────────────────────────────────────
  // Deliberately NOT cached across opens: `_near` starts idle on every fresh
  // picker, so reopening never shows a position from the last time.
  _NearState _near = _NearState.idle;
  List<CourseHit> _nearHits = [];

  /// Why the last tap did not produce a list — drawn as one line under the
  /// pill. Null when nothing has failed.
  NearMeOutcome? _nearProblem;
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
    // Typing returns to the normal list: a "Near you" heading over rows that
    // are being filtered by a name is two different searches in one list.
    if (v.trim().isNotEmpty && _near != _NearState.idle) {
      setState(() {
        _near = _NearState.idle;
        _nearHits = [];
        _nearProblem = null;
      });
    }
    if (v.trim().length < 2) {
      setState(() { _hits = []; _searching = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _search(v.trim()));
  }

  /// **The course database did not answer.** Without this the list is
  /// simply shorter, which reads as "your course is not in there" rather
  /// than "we could not ask" — and a golfer certain his course exists has
  /// no way to tell those apart.
  Widget _localOnlyNote(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.cloud_off_outlined, size: 15,
               color: theme.colorScheme.error),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              "Showing your own courses only — the course database didn't "
              'answer. Try again in a moment.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ]),
      );

  /// One location fix, then one lookup. Nothing here runs un-tapped.
  Future<void> _tapNearMe() async {
    if (_near == _NearState.locating) return;   // further taps ignored
    setState(() {
      _near = _NearState.locating;
      _nearProblem = null;
    });
    final client = context.read<AuthProvider>().client;
    final res = await (widget.nearMeOverride ?? coursesNearMe)(client);
    if (!mounted) return;
    setState(() {
      if (res.ok) {
        // An EMPTY ok list is a result, not a failure: it goes to the
        // `results` state so the section says "No courses within 25 mi"
        // with a Clear, rather than silently returning to the pill.
        _near = _NearState.results;
        _nearHits = res.courses;
        _nearProblem = null;
      } else {
        _near = _NearState.idle;
        _nearProblem = res.outcome;
      }
    });
  }

  void _clearNearMe() => setState(() {
        _near = _NearState.idle;
        _nearHits = [];
        _nearProblem = null;
      });

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    setState(() => _searching = true);
    try {
      final client = context.read<AuthProvider>().client;
      final res = await client.findCourses(q);
      if (!mounted || seq != _searchSeq) return; // a newer search superseded us
      setState(() {
        _hits = res.hits;
        _localOnly = res.localOnly;
        _searching = false;
      });
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
      } catch (e) {
        _failAdd(messenger, e);
      }
    } catch (e) {
      _failAdd(messenger, e);
    }
  }

  void _failAdd(ScaffoldMessengerState messenger, [Object? error]) {
    if (!mounted) return;
    setState(() => _addingKey = null);
    // Surface the server's reason when it sent one — the course-import quality
    // gate returns a 422 whose message names exactly what's wrong (e.g. a bad
    // stroke index).  Fall back to the generic line for network/opaque errors.
    final reason = (error is ApiException && error.message.trim().isNotEmpty)
        ? error.message.trim()
        : null;
    messenger.showSnackBar(SnackBar(
      content: Text(reason == null
          ? 'Could not add that course. Try again.'
          : "Couldn't add that course — $reason"),
      duration: Duration(seconds: reason == null ? 4 : 7),
    ));
  }

  void _commit(CourseInfo c) {
    widget.onSelected(c);
    if (mounted) {
      setState(() {
        _editing = false;
        _hits = [];
        _addingKey = null;
        _ctrl.clear();
        _near = _NearState.idle;
        _nearHits = [];
        _nearProblem = null;
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

  /// The "Courses near me" pill — and in `locating`, the same pill saying so.
  ///
  /// One control in two states rather than a pill that is replaced by a
  /// spinner: the row must not change height when it is tapped, or the list
  /// under the thumb jumps.
  Widget _nearMePill(ThemeData theme) {
    final busy = _near == _NearState.locating;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Halved.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          // Ignores further taps while locating, rather than queueing a
          // second fix — one tap is one fix.
          onTap: busy ? null : _tapNearMe,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Halved.cardBorder, width: 1.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              if (busy)
                const SizedBox(
                    width: 17, height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                const Icon(Icons.place_outlined, size: 19, color: Halved.pine),
              const SizedBox(width: 11),
              Text(
                busy ? 'Finding courses near you…' : 'Courses near me',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: busy
                      ? theme.colorScheme.onSurfaceVariant
                      : Halved.pine,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// One line under the pill when a tap did not produce a list.
  ///
  /// **Settings is offered on `deniedForever` alone.** That is the only
  /// outcome the OS will never re-prompt for; offering it on a plain refusal
  /// sends a golfer to a screen he does not need, and offering it when
  /// location is switched off device-wide points at the wrong screen
  /// entirely.
  Widget _nearMeProblem(ThemeData theme) {
    final outcome = _nearProblem!;
    final text = switch (outcome) {
      NearMeOutcome.serviceOff ||
      NearMeOutcome.denied ||
      NearMeOutcome.deniedForever =>
        'Location is off. Search by name instead.',
      NearMeOutcome.timedOut => "Couldn't get your location. Try again.",
      // Not in the design, which does not cover a position that arrived and a
      // lookup that then failed. Saying "couldn't get your location" there
      // would name the wrong step and send the golfer to his settings.
      NearMeOutcome.failed =>
        "Couldn't search for courses near you. Try again.",
      NearMeOutcome.ok => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 7, 4, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        if (outcome == NearMeOutcome.deniedForever) ...[
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 32),
                visualDensity: VisualDensity.compact),
            onPressed: openLocationSettings,
            child: const Text('Settings'),
          ),
        ],
      ]),
    );
  }

  /// `Near you` + `Clear`, over the rows.
  Widget _nearMeHeader(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(children: [
          Expanded(child: _sectionLabel(theme, 'NEAR YOU')),
          TextButton(
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
                visualDensity: VisualDensity.compact),
            onPressed: _addingKey == null ? _clearNearMe : null,
            child: const Text('Clear'),
          ),
        ]),
      );

  /// One flat, neutral results list — no "in your courses" vs global split, no
  /// add/check source icons (design 9a §6). Tap picks; import is invisible.
  Widget _resultsList(ThemeData theme, List<CourseHit> hits) => Container(
        margin: const EdgeInsets.only(top: 8),
        constraints: const BoxConstraints(maxHeight: 340),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: hits.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final h = hits[i];
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
                  // WHOLE miles, which is what the server sends: the position
                  // it measured from is cut to ~1.1 km, so a tenth would be a
                  // digit nobody has. Tabular figures so the column lines up.
                  : h.distanceMiles == null
                      ? null
                      : Text('${h.distanceMiles} mi',
                          style: TextStyle(
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ],
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          )),
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
    final nearShowing = _near == _NearState.results;
    // Home and Recent are HIDDEN while near-me results show: three competing
    // lists of courses, one of them headed "Near you", is a screen nobody can
    // read. Typing or Clear brings them back.
    final showQuickPick =
        _ctrl.text.trim().isEmpty && _hits.isEmpty && !nearShowing;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _searchBox(theme),
      // Directly under the field, and only while nothing is typed — the pill
      // is an alternative to typing, not a filter on it.
      if (nearMeOffered && _ctrl.text.trim().isEmpty && !nearShowing)
        _nearMePill(theme),
      if (_nearProblem != null && !nearShowing) _nearMeProblem(theme),
      if (nearShowing) ...[
        _nearMeHeader(theme),
        if (_nearHits.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 2),
            child: Text('No courses within 25 mi.',
                style: theme.textTheme.bodySmall),
          )
        else
          _resultsList(theme, _nearHits),
      ],
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
      if (_localOnly) _localOnlyNote(theme),
      if (_hits.isNotEmpty) _resultsList(theme, _hits),
      if (_ctrl.text.trim().length >= 2 && !_searching && _hits.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('No courses found. Try a different spelling or the city.',
              style: theme.textTheme.bodySmall),
        ),
    ]);
  }
}
