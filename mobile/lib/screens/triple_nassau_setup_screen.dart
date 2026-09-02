/// screens/triple_nassau_setup_screen.dart
/// ----------------------------------------
/// Setup for Triple Nassau — three players, three simultaneous 1v1 Nassaus
/// (a round-robin) from one setup.  One handicap mode, one stake, one press
/// rule drive all three matches.  Each pair is handicapped on its OWN two
/// players, so the "Strokes by match" card previews how many strokes each
/// golfer gets against each opponent.
///
/// Requires exactly three real (non-phantom) players.

import '../utils/handicap_rounding.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/stake_field.dart';

// Player identity is colour, not "P1/P2" — three fixed colours in roster order.
const List<Color> kTriplePlayerColours = [
  Color(0xFF1976D2),   // blue
  Color(0xFFEF6C00),   // orange
  Color(0xFF7B3FA0),   // plum
];

class TripleNassauSetupScreen extends StatefulWidget {
  final int foursomeId;
  final bool returnToHub;

  const TripleNassauSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<TripleNassauSetupScreen> createState() =>
      _TripleNassauSetupScreenState();
}

class _TripleNassauSetupScreenState extends State<TripleNassauSetupScreen> {
  String _mode       = 'strokes_off';
  int    _netPercent = 100;
  String _pressMode  = 'none';
  bool   _advancedOpen = false;

  final TextEditingController _betCtrl   = TextEditingController();
  final TextEditingController _pressCtrl = TextEditingController(text: '5');
  bool _stakeOk = false;
  bool _betCtrlInitialized = false;

  bool _capEnabled = false;
  final TextEditingController _capCtrl = TextEditingController();

  bool    _loading  = true;
  bool    _starting = false;
  bool    _editing  = false;
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

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      TripleNassauSummary? s;
      try {
        s = await client.getTripleNassauSummary(widget.foursomeId);
      } catch (_) {
        s = null;   // 404 → not configured yet
      }
      if (!mounted) return;
      final configured = s != null && s.players.isNotEmpty;
      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/triple-nassau', arguments: widget.foursomeId);
        return;
      }
      setState(() {
        if (configured) {
          _editing     = true;
          _mode        = s!.handicapMode;
          _netPercent  = s.netPercent;
          _pressMode   = s.pressMode;
          if (s.pressUnit > 0) {
            _pressCtrl.text = s.pressUnit % 1 == 0
                ? s.pressUnit.toStringAsFixed(0)
                : s.pressUnit.toStringAsFixed(2);
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes.firstWhere(
      (f) => f.id == widget.foursomeId,
      orElse: () => rp.round!.foursomes.first,
    );
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  bool get _rosterValid => _realMembers.length == 3;

  bool get _canPress => _pressMode != 'none';

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;
      final bet    = double.tryParse(_betCtrl.text.trim());
      final ids    = _realMembers.map((m) => m.player.id).toList();

      await client.postTripleNassauSetup(
        widget.foursomeId,
        playerIds:    ids,
        handicapMode: _mode,
        netPercent:   _netPercent,
        pressMode:    _pressMode,
        pressUnit:    _canPress
            ? (double.tryParse(_pressCtrl.text.trim()) ?? 0.0) : 0.0,
        lossCap: (_capEnabled && _canPress)
            ? double.tryParse(_capCtrl.text.trim()) : null,
        betUnit: bet,
      );
      await rp.loadTripleNassau(widget.foursomeId);

      if (widget.returnToHub) {
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
          '/triple-nassau', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  // ── Pairwise strokes preview ───────────────────────────────────────────────

  /// Strokes the higher-handicap player of a pair gets = round(diff × net%/100)
  /// in Strokes-Off; the full course handicap difference in Net; 0 in Gross.
  int _pairStrokes(int hcpA, int hcpB) {
    if (_mode == 'gross') return 0;
    final diff = (hcpA - hcpB).abs();
    if (_mode == 'strokes_off') {
      return roundHalfUp(diff * _netPercent / 100);
    }
    // Net: each plays their own allowance; the pair difference is what matters
    // to the head-to-head, so preview the netted difference.
    return roundHalfUp((hcpA - hcpB).abs() * _netPercent / 100);
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrlInitialized = true;
      final b = rp.round!.betUnit;
      if (b > 0) {
        _betCtrl.text = b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
        _stakeOk = true;
      }
    }

    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Triple Nassau'
                                         : 'Triple Nassau — Setup'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error.toString(), onRetry: _load)
              : !_rosterValid
                  ? const _NeedsThree()
                  : _form(context),
    );
  }

  Widget _form(BuildContext context) {
    final members = _realMembers;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              _rosterCard(members),
              const SizedBox(height: 14),
              HandicapModeSelector(
                mode: _mode,
                netPercent: _netPercent,
                onModeChanged: (m) => setState(() => _mode = m),
                onPercentChanged: (p) => setState(() => _netPercent = p),
              ),
              const SizedBox(height: 14),
              _strokesCard(members),
              const SizedBox(height: 14),
              SectionCard(
                title: 'Stake per match',
                child: StakeField(
                  controller: _betCtrl,
                  label: 'Stake (\$)',
                  helpText: 'Each of the three Nassau bets (Front 9, Back 9, '
                            'Overall) is worth this amount, in each of your two '
                            'matches.',
                  onChanged: (ok) => setState(() => _stakeOk = ok),
                ),
              ),
              const SizedBox(height: 6),
              _liabilityNote(),
              const SizedBox(height: 14),
              _advancedCard(),
            ],
          ),
        ),
        _bottomBar(),
      ],
    );
  }

  Widget _rosterCard(List<Membership> members) {
    return SectionCard(
      title: 'Players',
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Three players, three 1v1 matches — everyone is in two.',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF5C6B62))),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < members.length; i++)
                Expanded(
                  child: Column(
                    children: [
                      Container(width: 12, height: 12,
                          decoration: BoxDecoration(
                              color: kTriplePlayerColours[i % 3],
                              shape: BoxShape.circle)),
                      const SizedBox(height: 4),
                      Text(members[i].player.name,
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 13,
                              color: kTriplePlayerColours[i % 3]),
                          textAlign: TextAlign.center),
                      Text('HCP ${members[i].playingHandicap}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF5C6B62))),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _strokesCard(List<Membership> members) {
    final theme = Theme.of(context);
    List<Widget> rows = [];
    final pairs = [[0, 1], [0, 2], [1, 2]];
    for (final pr in pairs) {
      final a = members[pr[0]], b = members[pr[1]];
      final ha = a.playingHandicap, hb = b.playingHandicap;
      final n = _pairStrokes(ha, hb);
      final higher = ha >= hb ? a : b;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            _dot(kTriplePlayerColours[pr[0]]),
            const SizedBox(width: 4),
            Text(a.player.name, style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 13)),
            const Text('  vs  ', style: TextStyle(
                color: Color(0xFF5C6B62), fontSize: 11.5)),
            _dot(kTriplePlayerColours[pr[1]]),
            const SizedBox(width: 4),
            Text(b.player.name, style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            n == 0
                ? const Text('even', style: TextStyle(
                    color: Color(0xFF5C6B62), fontStyle: FontStyle.italic,
                    fontSize: 12.5))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${higher.player.name} gets $n',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 12.5)),
                      Text('SI 1–$n', style: TextStyle(
                          fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
          ],
        ),
      ));
    }
    return SectionCard(
      title: 'Strokes by match',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rows,
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
                color: const Color(0xFFE7F1EC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFC6DED2))),
            child: const Text(
              'Each pair plays off its own difference — set once, allocated the '
              'same way in every match (the lower plays to 0; the higher gets '
              'the difference from SI 1 down).',
              style: TextStyle(fontSize: 12, height: 1.45)),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color c) => Container(width: 9, height: 9,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle));

  Widget _liabilityNote() {
    final bet = double.tryParse(_betCtrl.text.trim())
        ?? context.read<RoundProvider>().round?.betUnit ?? 0;
    final worst = bet * 3 * 2;   // 2 matches × 3 bets
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
          color: const Color(0xFFF7FAF7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFD3DED6))),
      child: Text(
        'You’re in two matches, so a clean sweep against you is '
        '\$${worst.toStringAsFixed(2)} before presses — 2 matches × 3 bets '
        '× \$${bet.toStringAsFixed(2)}.',
        style: const TextStyle(fontSize: 12.5, height: 1.5)),
    );
  }

  Widget _advancedCard() {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: _advancedOpen,
        onExpansionChanged: (v) => setState(() => _advancedOpen = v),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Text('Advanced', style: theme.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
        subtitle: const Text('Presses, loss cap', style: TextStyle(fontSize: 11.5)),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Press stakes', style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 7, runSpacing: 7, children: [
            for (final m in const [
              ['none', 'None'], ['manual', 'Manual'],
              ['auto', 'Auto at 2-down'], ['both', 'Manual + Auto'],
            ])
              ChoiceChip(
                label: Text(m[1]),
                selected: _pressMode == m[0],
                onSelected: (_) => setState(() => _pressMode = m[0]),
              ),
          ]),
          const SizedBox(height: 4),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Presses fire per match — going 2-down to one opponent '
                'doesn’t touch your other match.',
                style: TextStyle(fontSize: 12, color: Color(0xFF5C6B62), height: 1.4)),
          ),
          if (_canPress) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _pressCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Press unit (\$)',
                prefixText: '\$ ',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cap each player’s losses per match'),
              value: _capEnabled,
              onChanged: (v) => setState(() => _capEnabled = v),
            ),
            if (_capEnabled)
              TextField(
                controller: _capCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Max loss per match', prefixText: '\$ ',
                  border: OutlineInputBorder(), isDense: true,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final ready = _rosterValid && _stakeOk && !_starting;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: SizedBox(
        height: 52,
        child: FilledButton(
          onPressed: ready ? _start : null,
          child: _starting
              ? const SizedBox(width: 22, height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_editing ? 'Save Configuration' : 'Start Match'),
        ),
      ),
    );
  }
}

class _NeedsThree extends StatelessWidget {
  const _NeedsThree();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Triple Nassau needs exactly three players.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: Color(0xFF5C6B62)),
          ),
        ),
      );
}
