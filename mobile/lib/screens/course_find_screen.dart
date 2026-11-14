/// screens/course_find_screen.dart
///
/// **Find a course** — one screen behind Change on the course bar, everywhere
/// the app has one (`~/Downloads/handoff-find-a-course`, option A, 13 Nov
/// 2026). It replaces the inline `CourseSearchField` box.
///
/// Top to bottom: a search bar that takes the keyboard; **Courses near me**
/// (location read ONLY when tapped, once, never kept); **Near you** within
/// 8 miles; **Recents** — the last five courses this golfer played, with the
/// tees and the date.
///
/// It returns a [CourseFindResult] and the form that opened it does the rest.
/// A recent also returns its tees, so the form can pre-select them; an `Add`
/// course is created before it is returned.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/client.dart' show ApiClient, ApiException;
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../utils/near_me.dart';

// The handoff's colours, which are final.
const _mint = Color(0xFF3BD89A);
const _pine = Color(0xFF0F6E56);
const _deepPine = Color(0xFF0B1F1A);
const _surface = Color(0xFFEEF3EE);
const _muted = Color(0xFF5C6B62);
const _border = Color(0xFFDCE7DF);
const _hair = Color(0xFFEEF2EE);

/// Near you is limited to this many miles, nearest first.
const int kNearYouMiles = 8;

/// What the screen hands back.
class CourseFindResult {
  final CourseInfo course;

  /// The tees a RECENT was played from, for the form to pre-select. Null when
  /// the course was found by search or by location.
  final String? teeName;

  /// The line the form shows once the screen has closed.
  final String toast;

  const CourseFindResult(this.course, {this.teeName, required this.toast});
}

enum _Near { ready, locating, located, denied }

class CourseFindScreen extends StatefulWidget {
  /// Replaces the fix + lookup. **For tests only**: `Geolocator` has no
  /// platform binding under `flutter test`.
  final Future<NearMeResult> Function(ApiClient client)? nearMeOverride;

  const CourseFindScreen({super.key, this.nearMeOverride});

  @override
  State<CourseFindScreen> createState() => _CourseFindScreenState();
}

class _CourseFindScreenState extends State<CourseFindScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  int _seq = 0;

  List<CourseInfo> _local = [];
  List<RecentPlay> _recents = [];
  List<CourseHit> _hits = [];
  bool _searching = false;
  bool _localOnly = false;

  // Deliberately NOT remembered: a fresh screen is a fresh `ready`.
  _Near _near = _Near.ready;
  List<CourseHit> _nearHits = [];
  String? _adding;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = context.read<AuthProvider>().client;
    try {
      final r = await client.getRecentPlays();
      if (mounted) setState(() => _recents = r);
    } catch (_) {/* Recents are a convenience; search still works */}
    try {
      final c = await client.getCourses();
      if (mounted) setState(() => _local = c);
    } catch (_) {}
  }

  // ── search ────────────────────────────────────────────────────────────────

  void _onChanged(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) {
      setState(() {
        _hits = [];
        _searching = false;
        _localOnly = false;
      });
      return;
    }
    setState(() {});
    if (q.length < 2) {
      setState(() => _hits = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    final mine = ++_seq;
    setState(() => _searching = true);
    try {
      final res = await context.read<AuthProvider>().client.findCourses(q);
      if (!mounted || mine != _seq) return;
      setState(() {
        _hits = res.hits;
        _localOnly = res.localOnly;
        _searching = false;
      });
    } catch (_) {
      if (mounted && mine == _seq) setState(() => _searching = false);
    }
  }

  // ── near me ───────────────────────────────────────────────────────────────

  Future<void> _tapNear() async {
    if (_near == _Near.locating || _near == _Near.denied) return;
    setState(() => _near = _Near.locating);
    final client = context.read<AuthProvider>().client;
    final res = await (widget.nearMeOverride ??
        (c) => coursesNearMe(c, radiusMiles: kNearYouMiles))(client);
    if (!mounted) return;
    setState(() {
      if (res.ok) {
        _near = _Near.located;
        _nearHits = res.courses;
      } else if (res.outcome == NearMeOutcome.serviceOff ||
          res.outcome == NearMeOutcome.denied ||
          res.outcome == NearMeOutcome.deniedForever) {
        // "Location is off" and nothing else — search and Recents carry on.
        _near = _Near.denied;
      } else {
        _near = _Near.ready; // timed out / offline: no second error to show
      }
    });
  }

  void _clearNear() => setState(() {
        _near = _Near.ready;
        _nearHits = [];
      });

  // ── picking ───────────────────────────────────────────────────────────────

  String _keyOf(CourseHit h) =>
      '${h.source}:${h.courseId ?? h.catalogId ?? h.golfApiId}';

  Future<void> _pickHit(CourseHit h) async {
    if (_adding != null) return;
    final client = context.read<AuthProvider>().client;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding = _keyOf(h));
    try {
      final CourseInfo course;
      var added = false;
      switch (h.source) {
        case 'account':
          course = _local.firstWhere((c) => c.id == h.courseId,
              orElse: () => const CourseInfo(id: 0, name: ''));
          if (course.id == 0) {
            _finish(await client.getCourse(h.courseId!), added: false);
            return;
          }
          break;
        case 'catalog':
          course = await client.addCatalogCourse(h.catalogId!);
          added = !h.inAccount;
          break;
        default: // 'api' — created for this golfer first
          course = await client.importApiCourse(h.golfApiId);
          added = true;
      }
      _finish(course, added: added);
    } catch (e) {
      if (!mounted) return;
      setState(() => _adding = null);
      final reason = (e is ApiException && e.message.trim().isNotEmpty)
          ? e.message.trim()
          : null;
      messenger.showSnackBar(SnackBar(
        content: Text(reason == null
            ? 'Could not add that course. Try again.'
            : "Couldn't add that course — $reason"),
        duration: Duration(seconds: reason == null ? 4 : 7),
      ));
    }
  }

  void _finish(CourseInfo c, {required bool added, String? teeName}) {
    if (!mounted) return;
    Navigator.of(context).pop(CourseFindResult(
      c,
      teeName: teeName,
      toast: added
          ? '${c.name} · added to your courses'
          : '${c.name} · playing today',
    ));
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final q = _ctrl.text.trim();
    final searching = q.isNotEmpty;
    return Scaffold(
      backgroundColor: _surface,
      resizeToAvoidBottomInset: false,
      body: Column(children: [
        _header(context),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                16, 0, 16, _focus.hasFocus ? 300 : 20),
            children: searching ? _results(q) : _browse(),
          ),
        ),
      ]),
    );
  }

  Widget _header(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.26, -0.97), // 165°
          end: Alignment(0.26, 0.97),
          colors: [_pine, _deepPine],
          stops: [0, 0.78],
        ),
      ),
      child: Stack(children: [
        // The mint glow behind the top right.
        Positioned(
          right: -40,
          top: -30,
          child: Container(
            width: 170,
            height: 170,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                Color(0x593BD89A),
                Color(0x003BD89A),
              ], stops: [0, 0.7]),
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                // Back without changing the course.
                InkWell(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: const SizedBox(
                    width: 36,
                    height: 40,
                    child: Center(
                      child: Text('‹',
                          style: TextStyle(
                              color: _mint, fontSize: 19, height: 1)),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text('Find a course',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 6),
              const Text('Where are you playing today?',
                  style: TextStyle(color: Color(0xFFB9CCC3), fontSize: 13)),
              const SizedBox(height: 12),
              _searchBar(),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _searchBar() {
    final focused = _focus.hasFocus;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: focused ? _mint : Colors.transparent, width: 1.5),
        boxShadow: const [
          BoxShadow(
              color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      child: Row(children: [
        const Icon(Icons.search, size: 17, color: _muted),
        const SizedBox(width: 9),
        Expanded(
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            onChanged: _onChanged,
            // The keyboard's search key only lowers it: results are live.
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _focus.unfocus(),
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w500, color: _deepPine),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Search by name or town',
              hintStyle: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w500, color: _muted),
            ),
          ),
        ),
        if (_ctrl.text.isNotEmpty)
          // Clearing keeps the keyboard up.
          InkWell(
            onTap: () {
              _ctrl.clear();
              _onChanged('');
              _focus.requestFocus();
            },
            child: Container(
              key: const ValueKey('clear'),
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                  color: Color(0xFFE7EDE8), shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 12, color: _muted),
            ),
          ),
      ]),
    );
  }

  // ── browse (search empty) ─────────────────────────────────────────────────

  List<Widget> _browse() => [
        _nearButton(),
        if (_near == _Near.located) ...[
          _sectionHead('Near you', action: 'Clear', onAction: _clearNear),
          if (_nearHits.isEmpty)
            _listCard([_emptyRow('No courses within $kNearYouMiles mi.')])
          else
            _listCard([for (final h in _nearHits) _hitRow(h, mi: true)]),
        ],
        if (_recents.isNotEmpty) ...[
          _sectionHead('Recents'),
          _listCard([for (final r in _recents) _recentRow(r)]),
        ],
      ];

  Widget _nearButton() {
    final ready = _near == _Near.ready || _near == _Near.located;
    final (String label, String? hint) = switch (_near) {
      _Near.ready => ('Courses near me', 'uses your location once'),
      _Near.locating => ('Finding courses near you…', null),
      _Near.located => ('Courses near me', 'updated just now'),
      _Near.denied => ('Location is off', 'search still works'),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Material(
        color: ready ? _mint : Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: const ValueKey('near-me'),
          borderRadius: BorderRadius.circular(12),
          onTap: ready ? _tapNear : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: ready ? _mint : const Color(0xFFD3DED6), width: 1.5),
            ),
            child: Row(children: [
              Icon(Icons.place_outlined,
                  size: 17, color: ready ? _deepPine : _muted),
              const SizedBox(width: 9),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: ready ? _deepPine : _muted)),
              ),
              if (hint != null)
                Text(hint,
                    style: TextStyle(
                        fontSize: 12,
                        color: ready ? const Color(0xFF0B5A44) : _muted)),
            ]),
          ),
        ),
      ),
    );
  }

  // ── results (searching) ───────────────────────────────────────────────────

  List<Widget> _results(String q) {
    final rows = <Widget>[];
    if (_hits.isEmpty) {
      rows.add(_emptyRow(_searching
          ? 'Searching…'
          : 'No course matches "$q". Try the town.'));
    } else {
      rows.addAll([for (final h in _hits) _hitRow(h, tag: true)]);
    }
    return [
      _sectionHead('Results'),
      _listCard(rows),
      if (_localOnly)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            "Showing your own courses only — the course database didn't "
            'answer. Try again in a moment.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ];
  }

  // ── pieces ────────────────────────────────────────────────────────────────

  Widget _sectionHead(String t, {String? action, VoidCallback? onAction}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic, children: [
        Expanded(
          child: Text(t.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: _pine)),
        ),
        if (action != null)
          InkWell(
            onTap: onAction,
            child: Text(action,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _pine)),
          ),
      ]),
    );
  }

  Widget _listCard(List<Widget> rows) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0D0B1F1A), blurRadius: 2, offset: Offset(0, 1)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1, thickness: 1, color: _hair),
          rows[i],
        ],
      ]),
    );
  }

  Widget _emptyRow(String t) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        child: Text(t, style: const TextStyle(fontSize: 13, color: _muted)),
      );

  Widget _row({
    required Widget mark,
    required String title,
    required String sub,
    required Widget trailing,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          mark,
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: _deepPine)),
              if (sub.isNotEmpty)
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _muted)),
            ]),
          ),
          const SizedBox(width: 8),
          trailing,
        ]),
      ),
    );
  }

  /// A Near you / Results row.
  Widget _hitRow(CourseHit h, {bool mi = false, bool tag = false}) {
    final busy = _adding == _keyOf(h);
    final Widget trailing;
    if (busy) {
      trailing = const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2));
    } else if (mi && h.distanceMiles != null) {
      trailing = _pill(
        h.distanceMiles == 0 ? '<1 mi' : '${h.distanceMiles} mi',
        fill: _deepPine,
        ink: _mint,
        tabular: true,
      );
    } else if (tag) {
      trailing = _tag(h);
    } else {
      trailing = const SizedBox.shrink();
    }
    return _row(
      mark: const _Mark(flag: true),
      title: h.name,
      sub: h.location,
      trailing: trailing,
      onTap: _adding == null ? () => _pickHit(h) : null,
    );
  }

  Widget _tag(CourseHit h) {
    final (String label, bool solid) = switch (h.source) {
      'account' => ('Yours', false),
      'catalog' => (h.inAccount ? 'Yours' : 'Catalog', false),
      _ => ('Add', true),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: solid ? _pine : const Color(0x170F6E56),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: solid ? Colors.white : _pine)),
    );
  }

  Widget _pill(String t,
      {required Color fill, required Color ink, bool tabular = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
          color: fill, borderRadius: BorderRadius.circular(999)),
      child: Text(t,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: ink,
              fontFeatures:
                  tabular ? const [FontFeature.tabularFigures()] : null)),
    );
  }

  Widget _recentRow(RecentPlay r) {
    final when = recentWhen(r.lastPlayed, DateTime.now());
    final sub = [
      if (r.course.location.isNotEmpty) r.course.location,
      if (r.teeName.isNotEmpty) '${r.teeName} tees',
    ].join(' · ');
    return _row(
      mark: const _Mark(flag: false),
      title: r.course.name,
      sub: sub,
      // The home course gets a solid pine pill, white text: `Home · Sat`.
      trailing: r.isHome
          ? _pill(when.isEmpty ? 'Home' : 'Home · $when',
              fill: _pine, ink: Colors.white)
          : (when.isEmpty
              ? const SizedBox.shrink()
              : _pill(when, fill: const Color(0xFFE3F6EC), ink: _pine)),
      onTap: () => _finish(r.course,
          added: false,
          teeName: r.teeName.isEmpty ? null : r.teeName),
    );
  }
}

/// `Sat` when the round was this week, else `Nov 14`.
///
/// "This week" is the last six days, so a weekday never repeats one that has
/// not yet come round again (a round on Saturday, read on Saturday a week
/// later, is `Nov 7`, not `Sat`).
String recentWhen(DateTime? d, DateTime now) {
  if (d == null) return '';
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final ago = today.difference(day).inDays;
  if (ago >= 0 && ago < 7) return DateFormat('EEE').format(day);
  return DateFormat('MMM d').format(day);
}

/// The two 40 × 40 tiles, drawn from the handoff's own SVG.
class _Mark extends StatelessWidget {
  final bool flag;
  const _Mark({required this.flag});

  static const _flagSvg =
      '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg">'
      '<ellipse cx="22" cy="31.5" rx="8" ry="2.6" fill="#3BD89A"/>'
      '<ellipse cx="22" cy="31" rx="7.1" ry="2" fill="#0F6E56"/>'
      '<rect x="20.6" y="8" width="2.8" height="23.5" rx="1.4" fill="#F3F1EA"/>'
      '<path d="M23.4 8.6l9.4 3.9-9.4 3.9z" fill="#3BD89A"/></svg>';

  static const _replaySvg =
      '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg">'
      '<ellipse cx="20" cy="31.5" rx="7" ry="2.3" fill="#3BD89A"/>'
      '<ellipse cx="20" cy="31" rx="6.2" ry="1.8" fill="#0B1F1A"/>'
      '<path d="M12.2 21.5a8.2 8.2 0 1 0 2.6-7.4" fill="none" stroke="#F3F1EA" '
      'stroke-width="3.2" stroke-linecap="round"/>'
      '<path d="M10.6 9.6l1.2 7.4 7-2.6z" fill="#3BD89A"/>'
      '<circle cx="20.4" cy="19.8" r="2.6" fill="#F3F1EA"/></svg>';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        gradient: flag
            ? const LinearGradient(
                begin: Alignment(-0.5, -0.87),
                end: Alignment(0.5, 0.87),
                colors: [Color(0xFF14896B), _pine])
            : null,
        color: flag ? null : _deepPine,
        border: flag
            ? null
            : Border.all(color: const Color(0x593BD89A), width: 1),
      ),
      child: SvgPicture.string(flag ? _flagSvg : _replaySvg,
          width: 40, height: 40),
    );
  }
}
