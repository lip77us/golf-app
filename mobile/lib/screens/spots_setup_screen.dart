/// screens/spots_setup_screen.dart
/// --------------------------------
/// Setup for Spots — a capture add-on settled on its own pot. The group decides
/// what counts (one-putt, sandy, barky, …) and tallies them by hand in score
/// entry. Knobs: value of one spot + payout style (pay-around / pool).
/// 2–4 real players.

import 'package:flutter/material.dart';
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
  String _payoutStyle = 'pay_around';

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
          _editing     = true;
          _payoutStyle = summary.payoutStyle;
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
        betUnit:     bet,
        payoutStyle: _payoutStyle,
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
          Text('How the money settles',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'pay_around', label: Text('Pay around')),
              ButtonSegment(value: 'pool',       label: Text('Pool')),
            ],
            selected: {_payoutStyle},
            showSelectedIcon: false,
            onSelectionChanged: (s) =>
                setState(() => _payoutStyle = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _payoutStyle == 'pay_around'
                ? 'Each spot is paid to the achiever by every other player.'
                : 'Everyone antes the stake; the pot splits by spots won.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          StakeField(
            controller: _betCtrl,
            label: 'Value of one spot',
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
