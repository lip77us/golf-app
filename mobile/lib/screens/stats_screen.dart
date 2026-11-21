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
  String _moneyView = 'game';

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
      if (mgames.isNotEmpty || (money['series'] as List).isNotEmpty) _moneyCard(d),
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

  Widget _moneyCard(Map<String, dynamic> d) {
    final money = (d['money'] as Map).cast<String, dynamic>();
    final total = (money['total'] as num).toDouble();
    final record = (money['record'] as Map?)?.cast<String, dynamic>();
    final series = ((money['series'] as List?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList();
    final views = (money['views'] as Map?)?.cast<String, dynamic>() ?? {};
    final items = ((views[_moneyView] as List?) ?? const []).cast<Map>();
    final shown = items.take(5).toList();
    final maxAmt = items.isEmpty
        ? 1.0
        : items.map((e) => (e['net'] as num).abs().toDouble()).reduce((a, b) => a > b ? a : b);
    final windowLabel = const {'20': 'LAST 20', 'year': 'THIS YEAR', 'all': 'ALL TIME'}[_window]!;
    const down = Color(0xFFF2A86E);

    Widget pill(String k, String label) {
      final on = _moneyView == k;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _moneyView = k),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: on ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(18)),
            child: Text(label,
                style: Halved.body(
                    color: on ? Halved.deepPine : Colors.white70,
                    weight: FontWeight.w800)),
          ),
        ),
      );
    }

    if (series.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment(-0.3, -1),
                end: Alignment(0.3, 1),
                colors: [Color(0xFF0F6E56), Color(0xFF0B1F1A)]),
            borderRadius: BorderRadius.circular(20)),
        child: Text('No money rounds yet',
            style: _head(18, color: Colors.white)),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment(-0.3, -1),
              end: Alignment(0.3, 1),
              colors: [Color(0xFF0F6E56), Color(0xFF0B1F1A)]),
          borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('MONEY · $windowLabel',
            style: Halved.body(color: Colors.white70, weight: FontWeight.w800)),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text(_money(total),
              style: _head(38, color: total >= 0 ? Halved.brightMint : down)),
          const SizedBox(width: 12),
          if (record != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14)),
              child: Text('${record['won']}–${record['lost']}',
                  style: Halved.body(color: Colors.white, weight: FontWeight.w800)),
            ),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 70,
          width: double.infinity,
          child: CustomPaint(painter: _RunningTotalPainter(series)),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.10),
              borderRadius: BorderRadius.circular(20)),
          child: Row(children: [
            pill('game', 'Game'),
            pill('partner', 'Partner'),
            pill('opponent', 'Opponent'),
            pill('course', 'Course'),
          ]),
        ),
        const SizedBox(height: 12),
        for (final e in shown) _moneyRow(e, maxAmt),
        if (items.length > 5)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _allMoney(items),
              child: Text('All ›',
                  style: Halved.body(color: Halved.brightMint, weight: FontWeight.w800)),
            ),
          ),
      ]),
    );
  }

  Widget _moneyRow(Map e, double maxAmt) {
    final net = (e['net'] as num).toDouble();
    final up = net >= 0;
    final c = up ? Halved.brightMint : const Color(0xFFF2A86E);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(
          width: 96,
          child: Text(e['name'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Halved.body(color: Colors.white, weight: FontWeight.w700)),
        ),
        Expanded(
          child: LayoutBuilder(builder: (_, box) {
            final w = maxAmt == 0 ? 0.0 : box.maxWidth * (net.abs() / maxAmt);
            return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                height: 10,
                width: w.clamp(4.0, box.maxWidth),
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(5)),
              ),
            );
          }),
        ),
        SizedBox(
          width: 64,
          child: Text(_money(net),
              textAlign: TextAlign.right,
              style: Halved.body(color: c, weight: FontWeight.w800)),
        ),
      ]),
    );
  }

  void _allMoney(List<Map> items) {
    const titles = {
      'game': 'All games',
      'partner': 'All partners',
      'opponent': 'All opponents',
      'course': 'All courses',
    };
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // A close button, because a long list that covers the screen with
          // only a drag handle has no visible way off it.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(children: [
              Expanded(child: Text(titles[_moneyView] ?? 'All', style: _head(18))),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(c).pop(),
              ),
            ]),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final e in items)
                ListTile(
                  title: Text(e['name'] as String),
                  subtitle: Text(
                      '${e['rounds']} round${e['rounds'] == 1 ? '' : 's'}'),
                  trailing: Text(_money(e['net'] as num),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: (e['net'] as num) < 0
                              ? Halved.warning
                              : Halved.pine)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

}

/// The running total: a mint line with a soft fill, a dashed zero line and a
/// dot on the latest value. No axes or labels.
class _RunningTotalPainter extends CustomPainter {
  final List<double> v;
  _RunningTotalPainter(this.v);

  @override
  void paint(Canvas c, Size s) {
    if (v.isEmpty) return;
    final lo = [0.0, ...v].reduce((a, b) => a < b ? a : b);
    final hi = [0.0, ...v].reduce((a, b) => a > b ? a : b);
    final span = (hi - lo) == 0 ? 1.0 : (hi - lo);
    double y(double x) => s.height - 6 - (s.height - 12) * ((x - lo) / span);
    double xAt(int i) => v.length == 1 ? s.width / 2 : s.width * i / (v.length - 1);

    // dashed zero line
    final zy = y(0);
    final dash = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (double x = 0; x < s.width; x += 8) {
      c.drawLine(Offset(x, zy), Offset(x + 4, zy), dash);
    }
    final line = Path()..moveTo(xAt(0), y(v[0]));
    for (var i = 1; i < v.length; i++) {
      line.lineTo(xAt(i), y(v[i]));
    }
    final fill = Path.from(line)
      ..lineTo(xAt(v.length - 1), s.height)
      ..lineTo(xAt(0), s.height)
      ..close();
    c.drawPath(
        fill,
        Paint()
          ..shader = const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x553BD89A), Color(0x003BD89A)])
              .createShader(Offset.zero & s));
    c.drawPath(
        line,
        Paint()
          ..color = Halved.brightMint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
    c.drawCircle(Offset(xAt(v.length - 1), y(v.last)), 4.5,
        Paint()..color = Halved.brightMint);
  }

  @override
  bool shouldRepaint(covariant _RunningTotalPainter old) => old.v != v;
}
