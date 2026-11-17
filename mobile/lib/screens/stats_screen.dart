import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';

TextStyle _head(double size, {Color color = Halved.deepPine}) =>
    GoogleFonts.schibstedGrotesk(
        fontSize: size, fontWeight: FontWeight.w700, color: color);

String _money(num v) {
  final a = v.abs();
  final s = a == a.roundToDouble() ? a.toInt().toString() : a.toStringAsFixed(2);
  return v < 0 ? '−\$$s' : '+\$$s';
}

String _toPar(num v) =>
    v == 0 ? 'E' : (v > 0 ? '+${v.toStringAsFixed(1)}' : '−${v.abs().toStringAsFixed(1)}');

String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return '$n${const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th'}';
}

/// Everything Halved records from scoring, shown back to the golfer.
/// Finished casual rounds only; the server does the arithmetic.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  String _window = '20';
  int? _course;
  String? _game;
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _filters; // from the unfiltered answer, so chips persist
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final d = await context.read<AuthProvider>().client.getPlayerStats(
          window: _window, courseId: _course, game: _game);
      if (!mounted) return;
      setState(() {
        _data = d;
        _filters ??= (d['filters'] as Map?)?.cast<String, dynamic>();
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _pick(String title, List<(String?, String)> options,
      String? current, void Function(String?) set) async {
    final r = await showModalBottomSheet<(String?,)>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title, style: _head(18)),
          ),
          for (final o in options)
            ListTile(
              title: Text(o.$2),
              trailing: o.$1 == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, (o.$1,)),
            ),
        ]),
      ),
    );
    if (r == null) return;
    set(r.$1);
    _data = null;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final f = _filters;
    final courses = ((f?['courses'] as List?) ?? []).cast<Map>();
    final games = ((f?['games'] as List?) ?? []).cast<Map>();
    final windows = {'20': 'Last 20 rounds', 'year': 'This year', 'all': 'All time'};

    Widget chip(String text, bool active, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                  color: active ? Halved.deepPine : Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Halved.cardBorder)),
              child: Text(text,
                  style: Halved.body(
                      color: active ? Colors.white : Halved.deepPine,
                      weight: FontWeight.w700)),
            ),
          ),
        );

    final d = _data;
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        centerTitle: true,
        title: Text('Your stats', style: _head(20)),
      ),
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(children: [
            chip(windows[_window]!, _window != '20', () => _pick(
                'Rounds', [for (final e in windows.entries) (e.key, e.value)],
                _window, (v) => _window = v ?? '20')),
            chip(
                _course == null
                    ? 'All courses'
                    : (courses.firstWhere((c) => c['id'] == _course,
                        orElse: () => {'name': 'Course'})['name'] as String),
                _course != null,
                () => _pick(
                    'Course',
                    [(null, 'All courses'),
                      for (final c in courses) ('${c['id']}', c['name'] as String)],
                    _course?.toString(),
                    (v) => _course = v == null ? null : int.parse(v))),
            chip(
                _game == null
                    ? 'All games'
                    : (games.firstWhere((g) => g['id'] == _game,
                        orElse: () => {'name': 'Game'})['name'] as String),
                _game != null,
                () => _pick(
                    'Game',
                    [(null, 'All games'),
                      for (final g in games) (g['id'] as String, g['name'] as String)],
                    _game,
                    (v) => _game = v)),
          ]),
        ),
        Expanded(
          child: _failed
              ? Center(
                  child: FilledButton(
                      onPressed: _load, child: const Text('Try again')))
              : d == null
                  ? const Center(child: CircularProgressIndicator())
                  : (d['count'] ?? 0) == 0
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                                'No finished rounds match yet. Finish a round '
                                'and your numbers show up here.',
                                textAlign: TextAlign.center,
                                style: Halved.body(color: Halved.muted)),
                          ),
                        )
                      : _body(d),
        ),
      ]),
    );
  }

  Widget _label(String t, {String? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
        child: Row(children: [
          Expanded(
              child: Text(t.toUpperCase(),
                  style: Halved.body(color: Halved.muted, weight: FontWeight.w800))),
          if (trailing != null)
            Text(trailing,
                style: Halved.body(color: Halved.muted, weight: FontWeight.w800)),
        ]),
      );

  BoxDecoration get _box => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Halved.cardBorder));

  Widget _tile(String k, String v, String sub, {Color? vc}) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Halved.surface, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k.toUpperCase(),
                style: Halved.body(color: Halved.muted, weight: FontWeight.w700)),
            FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(v, style: _head(24, color: vc ?? Halved.deepPine))),
            Text(sub, style: Halved.body(color: Halved.muted)),
          ]),
        ),
      );

  Widget _row(String lead, String title, String sub, String? right, Color? rc,
          {VoidCallback? onTap}) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: const Color(0xFFE3F1E8),
                  borderRadius: BorderRadius.circular(12)),
              child: Text(lead,
                  style: Halved.body(color: Halved.pine, weight: FontWeight.w800)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: _head(16)),
                Text(sub, style: Halved.body(color: Halved.muted)),
              ]),
            ),
            if (right != null) Text(right, style: _head(18, color: rc ?? Halved.deepPine)),
          ]),
        ),
      );

  Widget _list(List<Widget> rows) => Container(
        decoration: _box,
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: Halved.cardBorder),
            rows[i],
          ]
        ]),
      );

  Widget _body(Map<String, dynamic> d) {
    final s = (d['scoring'] as Map).cast<String, dynamic>();
    final mix = (s['mix'] as Map).cast<String, dynamic>();
    final pa = (s['par_avg'] as Map).cast<String, dynamic>();
    final money = (d['money'] as Map).cast<String, dynamic>();
    final mgames = (money['games'] as List).cast<Map>();
    final people = (d['people'] as List).cast<Map>();
    final cs = (d['courses'] as List).cast<Map>();

    const mixColours = {
      'eagle': Color(0xFF0B1F1A),
      'birdie': Color(0xFF0F6E56),
      'par': Color(0xFFBFDCC6),
      'bogey': Color(0xFFF3D5BF),
      'double': Color(0xFFE3A57A),
    };
    const mixNames = {
      'eagle': 'Eagle', 'birdie': 'Birdie', 'par': 'Par',
      'bogey': 'Bogey', 'double': 'Double+'
    };
    String pct(num v) => v == v.roundToDouble() ? '${v.toInt()}%' : '$v%';

    Widget parTile(String k, num? v) => _tile(k, v == null ? '—' : _toPar(v), '',
        vc: v != null && v < 0 ? Halved.pine : null);

    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 40), children: [
      _label('Scoring'),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: _box,
        child: Column(children: [
          Row(children: [
            _tile('Avg gross', s['avg_gross'] == null ? '—' : '${s['avg_gross']}',
                s['best_gross'] == null ? '' : 'best ${s['best_gross']}'),
            _tile('Avg net', _toPar(s['avg_net_to_par'] as num), 'to par'),
            _tile('Birdies', '${s['birdies']}', '${s['birdies_per_round']} a round'),
          ]),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 14,
                child: Row(children: [
                  for (final k in mixColours.keys)
                    if (((mix[k] as num?) ?? 0) > 0)
                      Expanded(
                          flex: ((mix[k] as num) * 10).round().clamp(1, 1000),
                          child: Container(color: mixColours[k])),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 10, runSpacing: 2, children: [
            for (final k in mixColours.keys)
              Text('${mixNames[k]} ${pct(mix[k] as num)}',
                  style: Halved.body(color: Halved.muted)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            parTile('Par 3s', pa['3'] as num?),
            parTile('Par 4s', pa['4'] as num?),
            parTile('Par 5s', pa['5'] as num?),
          ]),
        ]),
      ),
      if (mgames.isNotEmpty) ...[
        _label('Money by game', trailing: _money(money['total'] as num)),
        _list([
          for (final g in mgames)
            _row('${g['rounds']}', g['label'] as String,
                'won ${g['won']} of ${g['rounds']}', _money(g['net'] as num),
                (g['net'] as num) < 0 ? Halved.warning : Halved.pine),
        ]),
      ],
      if (people.isNotEmpty) ...[
        _label('Who you play'),
        _list([
          for (final p in people)
            _row(
                _initials(p['name'] as String),
                p['name'] as String,
                '${p['rounds']} rounds · you beat them on net ${p['beat']} '
                    'time${p['beat'] == 1 ? '' : 's'}',
                (p['money'] as num) == 0 ? null : _money(p['money'] as num),
                (p['money'] as num) < 0 ? Halved.warning : Halved.pine),
        ]),
      ],
      if (cs.isNotEmpty) ...[
        _label('Courses and holes'),
        _list([
          for (final c in cs)
            _row('⛳', c['name'] as String,
                [
                  '${c['rounds']} round${c['rounds'] == 1 ? '' : 's'}',
                  if (c['avg_gross'] != null) 'avg ${c['avg_gross']}',
                  if (c['best_hole'] != null)
                    'best hole ${_ordinal((c['best_hole'] as Map)['hole'] as int)} '
                        '(${_toPar((c['best_hole'] as Map)['avg'] as num)})',
                ].join(' · '),
                null, null),
        ]),
      ],
    ]);
  }

  String _initials(String name) {
    final p = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (p.isEmpty) return '?';
    return (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase();
  }
}
