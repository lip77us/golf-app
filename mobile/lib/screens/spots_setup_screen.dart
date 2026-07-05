/// screens/spots_setup_screen.dart
/// --------------------------------
/// Setup for Spots — a capture add-on settled on its own pot. The group decides
/// what counts (one-putt, sandy, barky, …) and tallies them by hand in score
/// entry. Knobs: value of one spot + payout style (pay-around / pool).
/// 2–4 real players.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/stake_field.dart';

class SpotsSetupScreen extends StatefulWidget {
  final int foursomeId;
  final bool returnToHub;
  const SpotsSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<SpotsSetupScreen> createState() => _SpotsSetupScreenState();
}

class _SpotsSetupScreenState extends State<SpotsSetupScreen> {
  final _betCtrl = TextEditingController();
  bool   _stakeOk = false;
  String _payoutStyle  = 'per_point';   // 'pool' | 'per_point'
  String _perPointMode = 'all';         // 'average' | 'all' | 'first'
  bool _advancedOpen = false;
  bool _capEnabled   = false;
  final _capCtrl = TextEditingController();

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
    _capCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final summary = await client.getSpotsSummary(widget.foursomeId);
      if (!mounted) return;
      final configured =
          summary.status == 'in_progress' || summary.players.isNotEmpty;
      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/score-entry', arguments: widget.foursomeId);
        return;
      }
      setState(() {
        if (configured) {
          _editing      = true;
          _payoutStyle  = summary.payoutStyle;
          _perPointMode = summary.perPointMode;
          if (summary.lossCap != null) {
            _capEnabled   = true;
            _advancedOpen = true;
            _capCtrl.text = summary.lossCap!.toStringAsFixed(0);
          }
          final b = summary.betUnit;
          _betCtrl.text =
              b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
          _stakeOk = true;
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

  bool get _rosterValid {
    final n = _realMembers.length;
    return n >= 2 && n <= 4;
  }

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;
      final bet    = double.tryParse(_betCtrl.text.trim());
      await client.postSpotsSetup(
        widget.foursomeId,
        betUnit:      bet,
        payoutStyle:  _payoutStyle,
        perPointMode: _perPointMode,
        lossCap: (_payoutStyle == 'per_point' && _capEnabled)
            ? (double.tryParse(_capCtrl.text.trim()) ?? 0.0)
            : null,
      );
      await rp.loadSpots(widget.foursomeId);
      if (widget.returnToHub) {
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
          '/score-entry', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Spots' : 'Spots Setup'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load)
              : Column(children: [
                  Expanded(child: _buildBody()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: GolfPrimaryButton(
                        label: _editing ? 'Save Configuration' : 'Start Spots',
                        loading: _starting,
                        onPressed:
                            (_rosterValid && _stakeOk) ? _start : null,
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outline),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('How the money settles',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'pool',      label: Text('Pool')),
                      ButtonSegment(value: 'per_point', label: Text('Per spot')),
                    ],
                    selected: {_payoutStyle},
                    onSelectionChanged: (s) =>
                        setState(() => _payoutStyle = s.first),
                  ),
                  const SizedBox(height: 8),
                  if (_payoutStyle == 'pool')
                    Text(
                        'Everyone antes the spot value; the pot splits by '
                        'spots won.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))
                  else ...[
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'average', label: Text('vs Average')),
                        ButtonSegment(value: 'all',     label: Text('Above you')),
                        ButtonSegment(value: 'first',   label: Text('Just leader')),
                      ],
                      selected: {_perPointMode},
                      onSelectionChanged: (s) =>
                          setState(() => _perPointMode = s.first),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (_perPointMode) {
                        'first' => 'Only the leader collects — everyone else pays '
                            'the leader their spot deficit × the spot value.',
                        'all' => 'Each spot pays the achiever the spot value from '
                            'every other player ("pay around").',
                        _ => 'Settle vs the field average — spots above the '
                            'average win, below owe, at the spot value.',
                      },
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        initiallyExpanded: _advancedOpen,
                        onExpansionChanged: (v) => _advancedOpen = v,
                        childrenPadding: EdgeInsets.zero,
                        title: Text('Advanced', style: theme.textTheme.bodyMedium),
                        children: [
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Cap each player's losses"),
                            value: _capEnabled,
                            onChanged: (v) => setState(() => _capEnabled = v),
                          ),
                          if (_capEnabled)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _capCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: 'Max loss',
                                    prefixText: '\$ ',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          StakeField(
            controller: _betCtrl,
            label: _payoutStyle == 'pool' ? 'Ante per player' : 'Value per spot',
            onChanged: (v) => setState(() => _stakeOk = v),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outline),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('How Spots works',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  Text(
                    'A "spot" is anything the group agrees on — a one-putt, a '
                    'sandy, a barky, hitting the flag. Tally them per player on '
                    'each hole from the score-entry screen. Spots are a separate '
                    'pot, kept apart from your main game.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}
