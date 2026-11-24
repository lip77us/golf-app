/// widgets/swat_step.dart
/// ----------------------
/// Oakmont SWAT's step in the wizard (docs/design-review/handoff-oakmont-swat,
/// shots 01–04): the rules, the stake, and the teams dealt in snake order —
/// which the TD can move or swap anyone out of.
///
/// **The deal is the server's.** This widget asks `/swat/teams/preview/` and
/// draws what it returns; it never sorts, snakes or names a team itself, so the
/// screen and the round that gets created cannot disagree. The phantom is never
/// named here — a threesome shows only a dashed "Phantom" slot.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import 'section_card.dart';

class SwatStep extends StatefulWidget {
  final List<int> playerIds;
  final double stake;
  final bool allowFivesomes;
  final ValueChanged<double> onStake;
  final ValueChanged<bool> onAllowFivesomes;
  /// Called with every fresh preview: the resolved teams, and the problem
  /// (null when the shape is legal). The wizard reads both to gate Next.
  final ValueChanged<Map<String, dynamic>> onPreview;
  /// The TD's own arrangement, or null for the snake order.
  final List<List<int>>? teams;
  final ValueChanged<List<List<int>>?> onTeams;

  const SwatStep({
    super.key,
    required this.playerIds,
    required this.stake,
    required this.allowFivesomes,
    required this.onStake,
    required this.onAllowFivesomes,
    required this.onPreview,
    required this.teams,
    required this.onTeams,
  });

  @override
  State<SwatStep> createState() => _SwatStepState();
}

class _SwatStepState extends State<SwatStep> {
  Map<String, dynamic>? _preview;
  String? _error;
  late final TextEditingController _stakeCtrl;

  @override
  void initState() {
    super.initState();
    _stakeCtrl = TextEditingController(
        text: widget.stake == widget.stake.roundToDouble()
            ? widget.stake.toStringAsFixed(0)
            : widget.stake.toStringAsFixed(2));
    _load();
  }

  @override
  void dispose() {
    _stakeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({List<List<int>>? teams, bool? five}) async {
    final client = context.read<AuthProvider>().client;
    try {
      final p = await client.swatPreview(
        widget.playerIds,
        allowFivesomes: five ?? widget.allowFivesomes,
        teams: teams ?? widget.teams,
      );
      if (!mounted) return;
      setState(() { _preview = p; _error = null; });
      widget.onPreview(p);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  List<List<int>> _teamIds() => [
        for (final t in (_preview!['teams'] as List))
          [for (final p in (t as Map)['players'] as List) (p as Map)['id'] as int]
      ];

  Future<void> _move(int pid, int toTeam) async {
    final teams = _teamIds();
    for (final t in teams) { t.remove(pid); }
    teams[toTeam].add(pid);
    widget.onTeams(teams);
    await _load(teams: teams);
  }

  Future<void> _swap(int a, int b) async {
    final teams = _teamIds();
    for (final t in teams) {
      final ia = t.indexOf(a), ib = t.indexOf(b);
      if (ia >= 0) t[ia] = b;
      if (ib >= 0) t[ib] = a;
    }
    widget.onTeams(teams);
    await _load(teams: teams);
  }

  /// Turning fivesomes ON changes how many teams the field divides into, so
  /// the TD is offered a fresh draft rather than being left to move golfers
  /// by hand (and rebalance the A/B/C/D bands) himself.
  Future<void> _toggleFive(bool v) async {
    if (!v) {
      widget.onAllowFivesomes(false);
      await _load(five: false, teams: null);
      return;
    }
    final keep = _preview == null ? null : _teamIds();
    final client = context.read<AuthProvider>().client;
    Map<String, dynamic> dealt;
    try {
      dealt = await client.swatPreview(widget.playerIds,
          allowFivesomes: true, teams: null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    final newTeams = (dealt['teams'] as List).length;
    final oldTeams = keep?.length ?? newTeams;
    var redraft = true;
    if (keep != null && newTeams != oldTeams) {
      final sizes = [for (final t in dealt['teams'] as List) (t as Map)['size']]
        ..sort((a, b) => (b as int).compareTo(a as int));
      final r = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Redraft the teams?'),
          content: Text('With fivesomes allowed, ${widget.playerIds.length} '
              'golfers make $newTeams teams (${sizes.join(' · ')}) instead of '
              '$oldTeams. The A–D bands are dealt again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep my teams')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Redraft')),
          ],
        ),
      );
      if (!mounted) return;
      redraft = r ?? false;
    }
    widget.onAllowFivesomes(true);
    if (redraft || keep == null) {
      setState(() { _preview = dealt; _error = null; });
      widget.onPreview(dealt);
    } else {
      widget.onTeams(keep);
      await _load(five: true, teams: keep);
    }
  }

  Future<void> _reset() async {
    widget.onTeams(null);
    await _load(teams: null);
  }

  String _idx(num v) => v.toStringAsFixed(1);

  Future<void> _pickGolfer(Map p, int fromTeam) async {
    final teams = _preview!['teams'] as List;
    final five = widget.allowFivesomes;
    final top = five ? 5 : 4;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              title: Text('Move ${p['name']}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('Index ${_idx(p['index'] as num)}'),
            ),
            for (var i = 0; i < teams.length; i++)
              if (i != fromTeam)
                Builder(builder: (_) {
                  final t = teams[i] as Map;
                  final size = t['size'] as int;
                  final from = (teams[fromTeam] as Map)['size'] as int;
                  final legal = size + 1 <= top && from - 1 >= 3;
                  String note = '';
                  if (size + 1 == 5) note = 'makes it a fivesome';
                  if (size + 1 == 4 && size == 3) note = 'makes it a foursome';
                  if (from - 1 == 3) {
                    note = '${(teams[fromTeam] as Map)['name']} would be a threesome';
                  }
                  return ListTile(
                    enabled: legal,
                    title: Text('${t['name']} · ${t['size']}'),
                    subtitle: note.isEmpty ? null : Text(note),
                    onTap: legal
                        ? () { Navigator.pop(ctx); _move(p['id'] as int, i); }
                        : null,
                  );
                }),
            const Divider(),
            const ListTile(title: Text('Or swap with someone')),
            for (var i = 0; i < teams.length; i++)
              for (final q in (teams[i] as Map)['players'] as List)
                if (i != fromTeam)
                  ListTile(
                    dense: true,
                    title: Text('${(q as Map)['name']}'),
                    subtitle: Text('${(teams[i] as Map)['name']} · '
                        'Index ${_idx(q['index'] as num)}'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _swap(p['id'] as int, q['id'] as int);
                    },
                  ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pv = _preview;
    final teams = (pv?['teams'] as List?) ?? const [];
    final n = pv?['field'] as int? ?? widget.playerIds.length;
    final problem = pv?['problem'] as String?;
    final stake = widget.stake;
    final teamStake = stake * 4;
    String money(double v) =>
        v == v.roundToDouble() ? '\$${v.toStringAsFixed(0)}' : '\$${v.toStringAsFixed(2)}';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('Oakmont SWAT', style: Halved.sectionHead()),
        const SizedBox(height: 6),
        Text(
          'Teams of four, each its own group. Every team plays every other '
          'team a best-ball Nassau on gross: front, back and overall.',
          style: Halved.body(color: Halved.muted)),
        const SizedBox(height: 14),
        if (n < 12)
          _Note('SWAT needs at least 12 golfers — you have $n. '
              'Add golfers on the Players step.', warn: true),
        SectionCard(
          title: 'Money',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('A foursome golfer\'s stake per bet')),
              const SizedBox(width: 16),
              SizedBox(
                width: 56,
                child: TextField(
                  controller: _stakeCtrl,
                  textAlign: TextAlign.center,
                  maxLength: 4,
                  buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(prefixText: '\$', isDense: true),
                  onChanged: (v) => widget.onStake(double.tryParse(v) ?? 0),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Text('Team stake ${money(teamStake)} a bet. A threesome golfer pays '
                '${money(teamStake / 3)}, a foursome golfer ${money(stake)}, a '
                'fivesome golfer ${money(teamStake / 5)}. The most a team can '
                'lose is ${money(teamStake * 3 * (teams.length > 1 ? teams.length - 1 : 0))}.',
                style: Halved.body(color: Halved.muted)),
          ]),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Teams',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow fivesomes'),
              subtitle: const Text('Only if the course allows groups of five'),
              value: widget.allowFivesomes,
              onChanged: _toggleFive,
            ),
          ]),
        ),
        const SizedBox(height: 12),
        if (_error != null) _Note(_error!, warn: true),
        if (problem != null && n >= 12) _Note(problem, warn: true),
        if (pv != null) ...[
          Row(children: [
            Expanded(
              child: Text(
                '${teams.length} teams · ${pv['threesomes']} threesome'
                '${pv['threesomes'] == 1 ? '' : 's'} · ${pv['matches']} matches',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (pv['edited'] == true)
              TextButton(onPressed: _reset, child: const Text('Reset to snake')),
          ]),
          if (pv['edited'] == true)
            Text('Changed from snake order',
                style: Halved.body(color: Halved.muted)),
          const SizedBox(height: 8),
          for (var i = 0; i < teams.length; i++)
            _TeamCard(
              team: teams[i] as Map,
              onTap: (p) => _pickGolfer(p, i),
              idx: _idx,
            ),
          const SizedBox(height: 8),
          _Note('A threesome plays a phantom fourth ball: on each hole, the '
              'score of one bottom golfer from another team, drawn at random '
              'and never named until the round is over.'),
        ] else if (_error == null)
          const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator())),
      ],
    );
  }
}

class _TeamCard extends StatelessWidget {
  final Map team;
  final void Function(Map player) onTap;
  final String Function(num) idx;
  const _TeamCard({required this.team, required this.onTap, required this.idx});

  @override
  Widget build(BuildContext context) {
    final players = team['players'] as List;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${team['name']}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
            Text('${team['size']} golfers',
                style: Halved.body(color: Halved.muted)),
          ]),
          const SizedBox(height: 6),
          for (final p in players)
            InkWell(
              onTap: () => onTap(p as Map),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  SizedBox(
                      width: 22,
                      child: Text('${p['band']}',
                          style: Halved.body(color: Halved.muted))),
                  Expanded(child: Text('${p['name']}')),
                  Text(idx(p['index'] as num),
                      style: Halved.body(color: Halved.muted)),
                  const SizedBox(width: 6),
                  const Icon(Icons.swap_horiz, size: 18),
                ]),
              ),
            ),
          if (team['three'] == true)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: Halved.muted.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text('Phantom — a bottom golfer, drawn at random',
                  style: Halved.body(color: Halved.muted)),
            ),
        ]),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final bool warn;
  const _Note(this.text, {this.warn = false});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: warn ? const Color(0xFFFFF3E0) : Colors.black.withOpacity(0.04),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: Halved.body(color: Halved.muted)),
      );
}
