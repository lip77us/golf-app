/// screens/multi_skins_setup_screen.dart
/// -------------------------------------
/// Setup screen for Multi-Foursome Skins — a round-level skins pool that
/// crosses every participating foursome.
///
/// Setup knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + Net % allowance
///   • Bet unit — each participating player chips in this amount
///   • Roster — pick which players (across every foursome in the round)
///     are paying into the pool.  Defaults to all real players checked.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';

class MultiSkinsSetupScreen extends StatefulWidget {
  final int roundId;
  const MultiSkinsSetupScreen({super.key, required this.roundId});

  @override
  State<MultiSkinsSetupScreen> createState() => _MultiSkinsSetupScreenState();
}

class _MultiSkinsSetupScreenState extends State<MultiSkinsSetupScreen> {
  String _mode       = 'net';
  int    _netPercent = 100;

  final TextEditingController _betCtrl = TextEditingController();
  bool _betCtrlInitialized = false;

  /// player_id → checked
  final Map<int, bool> _participants = {};

  bool    _loading  = true;
  bool    _starting = false;
  Object? _error;

  MultiSkinsSummary? _summary;

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
      final client = context.read<AuthProvider>().client;
      _summary = await client.getMultiSkinsSummary(widget.roundId);
      if (!mounted) return;

      // Pre-populate roster from existing game, or default to all real
      // players in the round.
      final existingIds = _summary!.players.map((p) => p.playerId).toSet();
      for (final m in _allMemberships) {
        _participants[m.player.id] =
            existingIds.isEmpty ? true : existingIds.contains(m.player.id);
      }

      setState(() {
        _mode       = _summary!.handicapMode;
        _netPercent = _summary!.netPercent;
        if (!_betCtrlInitialized) {
          // Default to $10 (the common "everyone throw in a ten" amount).
          // Existing game: use whatever the user previously saved.
          final v = _summary!.betUnit > 0 ? _summary!.betUnit : 10.0;
          // Drop trailing .00 so the placeholder reads "10" not "10.00".
          _betCtrl.text = v == v.roundToDouble()
              ? v.toStringAsFixed(0)
              : v.toStringAsFixed(2);
          _betCtrlInitialized = true;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  List<Membership> get _allMemberships {
    final rp = context.read<RoundProvider>();
    final out = <Membership>[];
    for (final fs in rp.round?.foursomes ?? const <Foursome>[]) {
      for (final m in fs.memberships) {
        if (!m.player.isPhantom) out.add(m);
      }
    }
    return out;
  }

  int get _participantCount => _participants.values.where((v) => v).length;

  double get _betUnit {
    final v = double.tryParse(_betCtrl.text.trim());
    return v == null || v < 0 ? 0.0 : v;
  }

  double get _pool => _participantCount * _betUnit;

  bool get _canStart => _participantCount >= 2 && _betUnit > 0;

  Future<void> _start() async {
    if (!_canStart) return;
    setState(() { _starting = true; });
    try {
      final client = context.read<AuthProvider>().client;
      final ids = _participants.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toList();
      final rp = context.read<RoundProvider>();
      await client.postMultiSkinsSetup(
        widget.roundId,
        participantIds: ids,
        handicapMode  : _mode,
        netPercent    : _netPercent,
        betUnit       : _betUnit,
      );
      // Refresh round so multi_skins shows up in activeGames, and pre-load
      // the summary into the provider.
      await rp.loadRound(widget.roundId);
      await rp.loadMultiSkins(widget.roundId);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        '/multi-skins',
        arguments: widget.roundId,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to start: $e'),
        ));
        setState(() { _starting = false; });
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Multi-Group Skins')),
        body: ErrorView(message: friendlyError(_error!), onRetry: _load),
      );
    }

    final foursomes = context.read<RoundProvider>().round?.foursomes
                          ?? const <Foursome>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Multi-Group Skins')),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Round-level skins pool. Lowest score on each hole wins '
                  '1 skin; tied holes die (no carryover).',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),

              // ── Handicap mode ────────────────────────────────────────────
              HandicapModeSelector(
                mode:             _mode,
                netPercent:       _netPercent,
                onModeChanged:    (m) => setState(() => _mode = m),
                onPercentChanged: (p) => setState(() => _netPercent = p),
              ),
              const Divider(height: 32),

              // ── Bet unit ─────────────────────────────────────────────────
              Row(children: [
                const Expanded(
                    flex: 2, child: Text('Entry fee per player (\$)')),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _betCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(
                      prefixText: '\$ ', isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Pool: \$${_pool.toStringAsFixed(2)} '
                '($_participantCount × \$${_betUnit.toStringAsFixed(2)})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Divider(height: 32),

              // ── Roster (per foursome) ────────────────────────────────────
              Text('Participants',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final fs in foursomes) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text('Group ${fs.groupNumber}',
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                for (final m in fs.memberships.where((m) => !m.player.isPhantom))
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(m.player.name),
                    subtitle: Text('Hcp ${m.player.handicapIndex}'),
                    value: _participants[m.player.id] ?? false,
                    onChanged: (v) => setState(() {
                      _participants[m.player.id] = v ?? false;
                    }),
                  ),
              ],
            ],
          ),
        ),

        // ── Persistent Start button (outside ListView so it stays above
        // the soft keyboard when the bet field is being edited). ─────────
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(children: [
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _canStart && !_starting ? _start : null,
                  child: _starting
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(_summary?.status == 'in_progress'
                          ? 'Save Changes'
                          : 'Start Multi-Group Skins',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              if (!_canStart)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _participantCount < 2
                        ? 'Pick at least 2 participants.'
                        : 'Enter a positive entry fee.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
