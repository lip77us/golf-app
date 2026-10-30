/// screens/annandale_friday_setup_screen.dart
/// -------------------------------------------
/// Annandale Friday setup, in three steps (`handoff-annandale-friday` §2):
///
///   1. **Teams** — the golfers in card order, each with team buttons. The
///      matches box lists the three Nassaus the teams make, or says what is
///      wrong with the split, and Next stays off until it plays.
///   2. **Nassau** — one set of options for every Nassau: handicap, stake
///      per bet and per press, 2nd ball / Claremont, presses, loss cap.
///   3. **Side games** — any standard side game for the whole group, each
///      opening its own setup. Skins is not part of this game; it is added
///      here like anywhere else.
///
/// The server holds the rules (`services.annandale_friday`) and refuses a
/// split it would not play with the same sentence the matches box shows —
/// `utils/annandale_teams.dart` is the phone's copy of it.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/annandale_teams.dart';
import '../utils/side_game_routes.dart';
import '../widgets/annandale_friday.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/stake_field.dart';

class AnnandaleFridaySetupScreen extends StatefulWidget {
  final int  foursomeId;
  final bool returnToHub;

  const AnnandaleFridaySetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<AnnandaleFridaySetupScreen> createState() =>
      _AnnandaleFridaySetupScreenState();
}

class _AnnandaleFridaySetupScreenState
    extends State<AnnandaleFridaySetupScreen> {
  int _step = 0;

  /// Team index per golfer. The split itself, so moving a golfer is one
  /// assignment and the teams are always derived from it.
  final Map<int, int> _teamOf = {};

  String _mode        = 'strokes_off';
  int    _netPercent  = 100;
  bool   _secondBall  = true;
  bool   _claremont   = false;
  bool   _autoPress   = true;
  bool   _manualPress = false;
  bool   _capOn       = false;

  final _betCtrl   = TextEditingController();
  final _pressCtrl = TextEditingController();
  final _capCtrl   = TextEditingController();
  bool _stakeOk = false;
  /// The press stake follows the bet until somebody types in it: a press is
  /// usually played for the bet, and a press field left at $0 when the bet
  /// is $10 was the first thing the phone showed.
  bool _pressEdited = false;

  bool    _loading = true;
  bool    _saving  = false;
  bool    _editing = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    _pressCtrl.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  // ── Data ───────────────────────────────────────────────────────────────────

  List<Membership> get _members {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId).firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  List<int> get _roster => [for (final m in _members) m.player.id];

  int get _teamCount => teamCountFor(_roster.length);

  /// Teams in team order, golfers in card order inside each.
  List<List<int>> get _teams => [
        for (var t = 0; t < _teamCount; t++)
          [for (final id in _roster) if (_teamOf[id] == t) id],
      ];

  String? get _problem => shapeProblem(_teams, roster: _roster);

  static String _money(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final cfg = await client.getAnnandaleFridaySetup(widget.foursomeId);
      if (!mounted) return;
      final rp = context.read<RoundProvider>();
      final configured = cfg['configured'] == true;
      setState(() {
        _editing = configured;
        _mode        = cfg['handicap_mode'] as String? ?? 'strokes_off';
        _netPercent  = cfg['net_percent'] as int? ?? 100;
        _secondBall  = cfg['second_ball_tiebreak'] as bool? ?? true;
        _claremont   = cfg['claremont'] as bool? ?? false;
        _autoPress   = cfg['auto_press'] as bool? ?? true;
        _manualPress = cfg['manual_press'] as bool? ?? false;
        final bet = (cfg['bet_unit'] as num?)?.toDouble()
            ?? rp.round?.betUnit ?? 0;
        if (bet > 0) { _betCtrl.text = _money(bet); _stakeOk = true; }
        final press = (cfg['press_unit'] as num?)?.toDouble() ?? 0;
        _pressCtrl.text = _money(press > 0 ? press : bet);
        // A saved press stake that differs from the bet was chosen.
        _pressEdited = configured && press > 0 && press != bet;
        final cap = (cfg['loss_cap'] as num?)?.toDouble();
        _capOn = cap != null;
        if (cap != null) _capCtrl.text = _money(cap);

        // Saved teams when there are any; otherwise golfers in card order.
        final saved = <List<int>>[
          for (final t in (cfg['teams'] as List? ?? const []))
            [for (final p in (t as List)) (p as Map)['player_id'] as int],
        ];
        final teams = saved.isNotEmpty ? saved : defaultTeams(_roster);
        _teamOf.clear();
        for (var t = 0; t < teams.length; t++) {
          for (final id in teams[t]) { _teamOf[id] = t; }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;
      final s = await client.postAnnandaleFridaySetup(
        widget.foursomeId,
        teams             : _teams,
        handicapMode      : _mode,
        netPercent        : _netPercent,
        secondBallTiebreak: _secondBall,
        claremont         : _claremont,
        autoPress         : _autoPress,
        manualPress       : _manualPress,
        pressUnit         : (_autoPress || _manualPress)
            ? (double.tryParse(_pressCtrl.text.trim()) ?? 0) : 0,
        lossCap           : _capOn ? double.tryParse(_capCtrl.text.trim()) : null,
        betUnit           : double.tryParse(_betCtrl.text.trim()),
      );
      rp.setAnnandaleFridaySummary(s);
      if (!mounted) return;
      if (widget.returnToHub) {
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacementNamed(
            '/score-entry', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    context.watch<RoundProvider>();   // side games change under step 3
    return Scaffold(
      // The step count lives in the bar, where the reference draws it; the
      // app bar has no subtitle slot.
      appBar: const GolfAppBar(title: 'Annandale Friday'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _members.isEmpty
              ? ErrorView(message: friendlyError(_error!), onRetry: _load)
              : Column(children: [
                  Expanded(
                    child: ListView(
                      // A step opens at its top: without the key the list
                      // keeps the last step's scroll, and step 2 opened
                      // halfway down its own page.
                      key: ValueKey(_step),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      children: switch (_step) {
                        0 => _teamsStep(),
                        1 => _nassauStep(),
                        _ => _sideGamesStep(),
                      },
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Text(friendlyError(_error!),
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  _bottomBar(),
                ]),
    );
  }

  Widget _heading(String title, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('STEP ${_step + 1} OF 3',
              style: Halved.body(color: Halved.muted, weight: FontWeight.w700)
                  .copyWith(fontSize: 11.5, letterSpacing: 0.6)),
          const SizedBox(height: 4),
          Text(title, style: Halved.sectionHead()),
          const SizedBox(height: 3),
          Text(sub, style: Halved.body(color: Halved.muted)),
        ]),
      );

  // ── Step 1: teams ──────────────────────────────────────────────────────────

  List<Widget> _teamsStep() {
    final n = _roster.length;
    return [
      _heading("Who's playing with whom",
          'The teams decide which Nassaus are played.'),
      const SectionCard(
        title: 'How it plays',
        child: Column(children: [
          _HowLine(1, 'Pairs play Nassaus against each other: front, back and '
              'overall, net better ball.'),
          _HowLine(2, 'With 5, the pair plays each pair of the three. With 6, '
              'every pair plays the other two.'),
          _HowLine(3, 'Strokes come off the low man in the group by default, '
              'by stroke index.'),
          _HowLine(4, 'Presses and side games are set on the next steps.'),
        ]),
      ),
      const SizedBox(height: 14),
      if (n != 5 && n != 6)
        SectionCard(
          title: 'Teams',
          child: Text(
              'Annandale Friday is for a group of 5 or 6 — this group has $n.',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        )
      else ...[
        SectionCard(
          title: 'Teams',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Tap a team to move a golfer.',
                  style: Halved.body(color: Halved.muted)
                      .copyWith(fontSize: 13)),
              const SizedBox(height: 6),
              for (final m in _members) _golferRow(m),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _matchesBox(),
      ],
    ];
  }

  Widget _golferRow(Membership m) {
    final mine = _teamOf[m.player.id];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Container(
          width: 4, height: 30,
          decoration: BoxDecoration(
            color: annandaleTeamColour(mine),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.player.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14.5)),
            Text('CH ${m.courseHandicap}',
                style: Halved.body(color: Halved.muted).copyWith(fontSize: 12)),
          ]),
        ),
        for (var t = 0; t < _teamCount; t++)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _TeamButton(
              label: '${t + 1}',
              colour: annandaleTeamColour(t),
              selected: mine == t,
              onTap: () => setState(() => _teamOf[m.player.id] = t),
            ),
          ),
      ]),
    );
  }

  String _nameOf(int id) {
    final m = _members.where((m) => m.player.id == id).firstOrNull;
    if (m == null) return '?';
    return m.player.shortName.isNotEmpty ? m.player.shortName : m.player.name;
  }

  Widget _side(List<int> ids, int? team) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: annandaleTeamColour(team),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(ids.map(_nameOf).join(' & '),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      );

  /// The three Nassaus the teams make — or, when they do not fit, the
  /// sentence the server would refuse them with.
  Widget _matchesBox() {
    final problem = _problem;
    return SectionCard(
      title: 'The matches',
      child: problem != null
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline,
                  size: 18, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(problem,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ),
            ])
          : Column(children: [
              for (final (i, (a, b)) in matchesFor(_teams).indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(
                      width: 22,
                      child: Text('${i + 1}',
                          style: Halved.body(color: Halved.muted)),
                    ),
                    Expanded(child: _side(a, _teamOf[a.first])),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('v', style: TextStyle(color: Halved.muted)),
                    ),
                    Expanded(child: _side(b, _teamOf[b.first])),
                  ]),
                ),
            ]),
    );
  }

  // ── Step 2: Nassau ─────────────────────────────────────────────────────────

  List<Widget> _nassauStep() => [
        _heading('Nassau', 'One set of options for every Nassau in the game.'),
        HandicapModeSelector(
          mode: _mode,
          netPercent: _netPercent,
          onModeChanged: (m) => setState(() => _mode = m),
          onPercentChanged: (p) => setState(() => _netPercent = p),
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: 'Stake',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            StakeField(
              controller: _betCtrl,
              label: 'Per bet (\$)',
              helpText: 'Front, back and overall, each.',
              onChanged: (ok) => setState(() {
                _stakeOk = ok;
                if (!_pressEdited) _pressCtrl.text = _betCtrl.text.trim();
              }),
            ),
            if (_autoPress || _manualPress) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _pressCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Per press (\$)', prefixText: '\$ ',
                  border: OutlineInputBorder(), isDense: true,
                ),
                onChanged: (_) => _pressEdited = true,
              ),
            ],
          ]),
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: 'Game options',
          child: Column(children: [
            _switch('2nd ball breaks ties',
                'When the better balls are level, the other ball decides the '
                'hole',
                _claremont ? false : _secondBall,
                // Claremont makes the 2nd ball a bet of its own, so there is
                // nothing left for it to break — the server ignores it then,
                // and the switch says so rather than looking on.
                _claremont ? null : (v) => setState(() => _secondBall = v)),
            _switch('Claremont scoring',
                'Two Nassau rows: best ball, plus low v. low and high v. high',
                _claremont, (v) => setState(() => _claremont = v)),
          ]),
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: 'Presses',
          child: Column(children: [
            _switch('Auto press',
                'A new press each time a side goes 2 down on the nine',
                _autoPress, (v) => setState(() => _autoPress = v)),
            _switch('Manual press',
                'When 1 down or level, from the next hole',
                _manualPress, (v) => setState(() => _manualPress = v)),
            _switch('Cap losses', 'Per side, per Nassau',
                _capOn, (v) => setState(() => _capOn = v)),
            if (_capOn)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextField(
                  controller: _capCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Most a side can lose in one Nassau',
                    prefixText: '\$ ',
                    border: OutlineInputBorder(), isDense: true,
                  ),
                ),
              ),
          ]),
        ),
      ];

  Widget _switch(String title, String sub, bool value,
          ValueChanged<bool>? onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12.5)),
        value: value,
        onChanged: onChanged,
      );

  // ── Step 3: side games ─────────────────────────────────────────────────────

  List<Widget> _sideGamesStep() {
    final round = context.read<RoundProvider>().round;
    final active = round?.activeGames ?? const <String>[];
    final current = [
      for (final g in active)
        if (g != GameIds.annandaleFriday) g,
    ];
    final eligible = [
      for (final m in sideGamesFor(GameIds.annandaleFriday,
          size: _roster.length))
        if (!active.contains(m.id)) m,
    ];
    return [
      _heading('Side games',
          'Optional. Any standard side game, played by the whole group '
          'alongside the Nassaus.'),
      for (final g in current)
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            title: Text(gameDisplayName(g),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('All ${_roster.length} golfers'),
            trailing: sideGameSetupRoute(g, widget.foursomeId, round!.id) ==
                    null
                ? null
                : const Text('Edit ›',
                    style: TextStyle(
                        color: Halved.pine, fontWeight: FontWeight.w600)),
            onTap: () => _openSideGame(g),
          ),
        ),
      if (current.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('No side games. The Nassaus are the whole game.',
              style: Halved.body(color: Halved.muted)),
        ),
      if (eligible.isNotEmpty)
        OutlinedButton.icon(
          onPressed: () => _addSideGame(eligible),
          icon: const Icon(Icons.add),
          label: const Text('Add side game'),
        ),
    ];
  }

  Future<void> _openSideGame(String g) async {
    final round = context.read<RoundProvider>().round;
    if (round == null) return;
    final target = sideGameSetupRoute(g, widget.foursomeId, round.id);
    if (target == null) return;
    await Navigator.of(context).pushNamed(target.$1, arguments: target.$2);
    if (mounted) setState(() {});
  }

  Future<void> _addSideGame(List<GameMeta> eligible) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Add a side game for ${_roster.length} golfers',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
          ),
          for (final m in eligible)
            ListTile(
              title: Text(m.displayName),
              subtitle: m.blurb == null ? null : Text(m.blurb!),
              onTap: () => Navigator.of(ctx).pop(m.id),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    final rp = context.read<RoundProvider>();
    try {
      await context.read<AuthProvider>().client
          .addSideGame(rp.round!.id, pick);
      await rp.loadRound(rp.round!.id);
    } catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    if (mounted) await _openSideGame(pick);
  }

  // ── Bottom bar ─────────────────────────────────────────────────────────────

  Widget _bottomBar() {
    final last = _step == 2;
    final canNext = switch (_step) {
      0 => _problem == null,
      1 => _stakeOk,
      _ => true,
    };
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Row(children: [
        if (_step > 0) ...[
          Expanded(
            child: SizedBox(
              height: 50,
              child: OutlinedButton(
                onPressed: _saving ? null : () => setState(() => _step--),
                child: const Text('Back'),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: (!canNext || _saving)
                  ? null
                  : last ? _save : () => setState(() => _step++),
              child: _saving
                  ? const SizedBox(width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(!last ? 'Next'
                      : _editing ? 'Save' : 'Start round'),
            ),
          ),
        ),
      ]),
    );
  }
}

class _HowLine extends StatelessWidget {
  const _HowLine(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 20, height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Halved.deepPine,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text('$n',
                style: const TextStyle(
                    color: Colors.white, fontSize: 11.5,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.35)),
          ),
        ]),
      );
}

class _TeamButton extends StatelessWidget {
  const _TeamButton({
    required this.label,
    required this.colour,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final Color colour;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? colour : Halved.card,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                  color: selected ? colour : Halved.cardBorder, width: 1.5),
            ),
            // 44pt — the touch target.
            child: SizedBox(
              width: 44, height: 44,
              child: Center(
                child: Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected ? Colors.white : colour)),
              ),
            ),
          ),
        ),
      );
}
