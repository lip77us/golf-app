/// widgets/swat_board.dart
/// -----------------------
/// The Oakmont SWAT tab (docs/design-review/handoff-oakmont-swat, shots 10–13).
///
/// Two cards over the server's own figures — this widget ranks nothing and
/// settles nothing:
///   * **Teams**, in the order the server ranked them: place, thru, W–L–P and
///     the team's money with each under it. Tap a name for its golfers.
///   * **One team against the field**: chips for the team to read (yours by
///     default) and a row per other team with Front / Back / Overall cells —
///     solid for a settled bet, outlined for one still in play.
/// The phantom's donor is never here; the server names it only once the round
/// is over, and then only on the Gross tab's scorecard.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import 'field_progress_bar.dart';

class SwatBoard extends StatefulWidget {
  final Map<String, dynamic> data;
  /// The leaderboard's "N still out" block; drawn under the versus card.
  final Object? progress;
  const SwatBoard({super.key, required this.data, this.progress});

  @override
  State<SwatBoard> createState() => _SwatBoardState();
}

class _SwatBoardState extends State<SwatBoard> {
  final Set<int> _open = {};
  int? _picked;

  List<Map> get _teams =>
      [for (final t in (widget.data['teams'] as List? ?? const [])) t as Map];
  List<Map> get _matches =>
      [for (final m in (widget.data['matches'] as List? ?? const [])) m as Map];

  bool _isMine(Map t, int? me) =>
      me != null &&
      (t['players'] as List).any((p) => (p as Map)['id'] == me);

  String _money(num v, {bool sign = true}) {
    final a = v.abs();
    final s = a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
    if (!sign || v == 0) return '\$$s';
    return v > 0 ? '+\$$s' : '−\$$s';
  }

  @override
  Widget build(BuildContext context) {
    final me = context.read<AuthProvider>().player?.id;
    final teams = _teams;
    if (teams.isEmpty) {
      return const Center(child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('The teams have not been drawn yet.')));
    }
    _picked ??= (teams.firstWhere((t) => _isMine(t, me),
        orElse: () => teams.first))['id'] as int;
    final open = widget.data['bets_open'] as int? ?? 0;
    final total = widget.data['bets_total'] as int? ?? 0;
    final fin = widget.data['final'] == true;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _card(
          title: 'Teams',
          trailing: fin ? 'Final' : '$open of $total bets still open',
          child: Column(children: [
            for (final t in teams) _teamRow(t, me),
          ]),
        ),
        const SizedBox(height: 14),
        _card(
          title: 'One team against the field',
          child: _versus(teams, me),
        ),
        FieldProgressBar(data: widget.progress),
        if (fin) ...[
          const SizedBox(height: 14),
          _moneyCard(teams),
        ],
      ],
    );
  }

  Widget _card({required String title, String? trailing, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Halved.cardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: Halved.sectionHead())),
          if (trailing != null)
            Text(trailing, style: Halved.body(color: Halved.muted)),
        ]),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }

  Widget _teamRow(Map t, int? me) {
    final id = t['id'] as int;
    final mine = _isMine(t, me);
    final isOpen = _open.contains(id);
    final thru = t['finished'] == true ? 'F' : '${t['thru']}';
    final money = (t['money'] as num);
    final each = (t['each'] as num);
    return Container(
      color: mine ? Halved.pine.withOpacity(0.07) : null,
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => isOpen ? _open.remove(id) : _open.add(id)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(children: [
              SizedBox(width: 28, child: Text(
                  '${t['tied'] == true ? 'T' : ''}${t['place']}',
                  style: const TextStyle(fontWeight: FontWeight.w700))),
              Expanded(child: Row(children: [
                Flexible(child: Text('${t['name']}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
                if (t['three'] == true) _badge('3'),
                if (t['five'] == true) _badge('5'),
                if (mine) _badge('You'),
              ])),
              SizedBox(width: 30, child: Text(thru, textAlign: TextAlign.center,
                  style: Halved.body(color: Halved.muted))),
              SizedBox(width: 56, child: Text(
                  '${t['wins']}–${t['losses']}–${t['pushes']}',
                  textAlign: TextAlign.center,
                  style: Halved.body(color: Halved.muted))),
              SizedBox(width: 64, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_money(money), style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: money > 0 ? Halved.pine
                        : money < 0 ? Halved.teamClay : null)),
                Text('${_money(each)} each',
                    style: Halved.body(color: Halved.muted)
                        .copyWith(fontSize: 10.5)),
              ])),
            ]),
          ),
        ),
        if (isOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 8, 8),
            child: Column(children: [
              for (final p in t['players'] as List)
                Row(children: [
                  Expanded(child: Text('${(p as Map)['name']}')),
                  Text((p['index'] as num).toStringAsFixed(1),
                      style: Halved.body(color: Halved.muted)),
                ]),
              if (t['three'] == true)
                Align(alignment: Alignment.centerLeft,
                    child: Text('+ the phantom',
                        style: Halved.body(color: Halved.muted))),
            ]),
          ),
        const Divider(height: 1),
      ]),
    );
  }

  Widget _badge(String s) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
            color: Halved.pine.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6)),
        child: Text(s, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
      );

  /// The bet between [a] (the picked team) and another, from [a]'s side.
  List<Map> _betsFor(int a, int b) {
    for (final m in _matches) {
      if (m['a'] == a && m['b'] == b) return [for (final x in m['bets'] as List) x as Map];
      if (m['a'] == b && m['b'] == a) {
        return [
          for (final x in m['bets'] as List)
            {
              ...(x as Map),
              'margin': -(x['margin'] as int),
              'result': x['result'] == 'W' ? 'L' : x['result'] == 'L' ? 'W' : x['result'],
            }
        ];
      }
    }
    return const [];
  }

  int _thru(int a, int b) {
    for (final m in _matches) {
      if ((m['a'] == a && m['b'] == b) || (m['a'] == b && m['b'] == a)) {
        return m['thru'] as int;
      }
    }
    return 0;
  }

  Widget _versus(List<Map> teams, int? me) {
    final picked = _picked!;
    final order = [
      teams.firstWhere((t) => t['id'] == picked),
      ...teams.where((t) => t['id'] != picked),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final t in order)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text('${t['name']}'),
                selected: t['id'] == picked,
                onSelected: (_) => setState(() => _picked = t['id'] as int),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      for (final t in order.skip(1))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text('v ${t['name']}\nthru ${_thru(picked, t['id'] as int)}',
                style: Halved.body(color: Halved.muted))),
            for (final b in _betsFor(picked, t['id'] as int))
              Padding(padding: const EdgeInsets.only(left: 4), child: _cell(b)),
          ]),
        ),
    ]);
  }

  Widget _cell(Map b) {
    final done = b['done'] == true;
    final margin = b['margin'] as int;
    final played = b['played'] as int;
    String text;
    Color? fill;
    final Color border;
    Color ink;
    if (played == 0) {
      return const SizedBox(width: 62, child: Center(child: Text('–')));
    }
    if (done) {
      final r = b['result'];
      text = r == 'P' ? 'Push'
          : '${r}${b['closed'] == true ? ' ${margin.abs()}&${b['left']}' : ' ${margin.abs()}'}';
      final Color f = r == 'W' ? Halved.pine : r == 'L' ? Halved.teamClay : Colors.grey.shade300;
      fill = f;
      border = f;
      ink = r == 'P' ? Colors.black87 : Colors.white;
    } else {
      text = margin == 0 ? 'AS' : '${margin.abs()} ${margin > 0 ? 'UP' : 'DN'}';
      border = margin > 0 ? Halved.pine : margin < 0 ? Halved.teamClay : Colors.grey;
      ink = border;
    }
    return Container(
      width: 62,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text(text, style: TextStyle(
            color: ink, fontWeight: FontWeight.w700, fontSize: 12)),
        Text('${b['key']}'.substring(0, b['key'] == 'Overall' ? 3 : 5),
            style: TextStyle(color: ink.withOpacity(0.75), fontSize: 9.5)),
      ]),
    );
  }

  Widget _moneyCard(List<Map> teams) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Halved.deepPine, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('MONEY BY TEAM',
            style: TextStyle(color: Colors.white70, fontSize: 11,
                fontWeight: FontWeight.w700, letterSpacing: 0.6)),
        const SizedBox(height: 8),
        for (final t in teams)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text('${t['name']}',
                  style: const TextStyle(color: Colors.white))),
              Text(_money(t['money'] as num), style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700)),
              SizedBox(width: 84, child: Text(
                  '${_money(t['each'] as num)} each', textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 12))),
            ]),
          ),
        const SizedBox(height: 6),
        const Text('Who pays whom is on Settle up.',
            style: TextStyle(color: Colors.white70, fontSize: 12)),
      ]),
    );
  }
}
