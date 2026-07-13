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
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/inline_message.dart';

class MultiSkinsSetupScreen extends StatefulWidget {
  final int roundId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to the game screen), and
  /// returns to the /round launch page on save instead of jumping to the game.
  final bool returnToHub;

  const MultiSkinsSetupScreen({
    super.key,
    required this.roundId,
    this.returnToHub = false,
  });

  @override
  State<MultiSkinsSetupScreen> createState() => _MultiSkinsSetupScreenState();
}

class _MultiSkinsSetupScreenState extends State<MultiSkinsSetupScreen> {
  // Multi-Group Skins defaults to Net — Strokes-Off Low doesn't translate
  // across foursomes since there's no single "best golfer" in a multi-
  // group pool.  Per-foursome games default to SO Low instead.
  String _mode       = 'net';
  int    _netPercent = 100;

  final TextEditingController _betCtrl = TextEditingController();
  bool _betCtrlInitialized = false;
  /// Explicit opt-in to a no-money game (lets Start proceed at $0 entry).
  bool _noStakes = false;

  /// player_id → checked
  final Map<int, bool> _participants = {};

  /// Connected (on-app) golfers NOT in this round — they ante into the pool but
  /// play in their own round, which the host links to this pool from its hub
  /// (docs/multi-skins-cross-round.md). Only Halved members can be matched
  /// across rounds, so login-less golfers are intentionally excluded.
  List<PlayerProfile> _externalGolfers = [];

  /// Player ids that are on Halved — the only golfers eligible for the pool
  /// (roster is Halved-only; login-less golfers can't be matched cross-round).
  Set<int> _onAppIds = {};

  bool    _loading  = true;
  bool    _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool    _editing  = false;
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

      // A configured game reports its players even before any hole is scored
      // (status 'pending' is sent both when no game exists AND when one exists
      // but is unscored — a non-empty players list is the "already set up"
      // tell).
      final configured =
          _summary!.status == 'in_progress' || _summary!.players.isNotEmpty;

      // Which golfers are on Halved — the pool is Halved-only, so only they are
      // eligible. Fetch first so the roster defaults + gating below can use it.
      // Best-effort: a failed fetch leaves _onAppIds empty (nothing eligible),
      // and hides the external section.
      final memberIds = _allMemberships.map((m) => m.player.id).toSet();
      try {
        final all = await client.getPlayers();
        if (mounted) {
          _onAppIds = all.where((p) => p.isOnApp).map((p) => p.id).toSet();
          _externalGolfers = all
              .where((p) => p.isOnApp && !memberIds.contains(p.id))
              .toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        }
      } catch (_) { /* roster fetch is best-effort */ }

      // Pre-populate roster from an existing game, or default to all ELIGIBLE
      // (on-app) round players. Login-less members are never auto-checked.
      final existingIds = _summary!.players.map((p) => p.playerId).toSet();
      for (final m in _allMemberships) {
        final eligible = _onAppIds.contains(m.player.id);
        _participants[m.player.id] = eligible &&
            (existingIds.isEmpty ? true : existingIds.contains(m.player.id));
      }
      for (final g in _externalGolfers) {
        _participants[g.id] = existingIds.contains(g.id);
      }

      setState(() {
        if (configured) _editing = true;
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

  bool get _canStart =>
      _participantCount >= 2 && (_betUnit > 0 || _noStakes);

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

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": return to the launch page
        // sitting below us.  The round was reloaded above so the hub reflects
        // the freshly-saved game; pop (rather than pushing a new /multi-skins)
        // to keep a single hub on the stack.
        await context.read<RoundProvider>().loadRound(widget.roundId);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacementNamed(
          '/multi-skins',
          arguments: widget.roundId,
        );
      }
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
        appBar: const GolfAppBar(title: 'Multi-Group Skins Setup'),
        body: ErrorView(message: friendlyError(_error!), onRetry: _load),
      );
    }

    final foursomes = context.read<RoundProvider>().round?.foursomes
                          ?? const <Foursome>[];

    return Scaffold(
      appBar: GolfAppBar(
          title: _editing
              ? 'Edit Multi-Group Skins'
              : 'Multi-Group Skins Setup'),
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
                    onChanged: (_) => setState(() {
                      if (_betUnit > 0 && _noStakes) _noStakes = false;
                    }),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Pool: \$${_pool.toStringAsFixed(2)} '
                '($_participantCount × \$${_betUnit.toStringAsFixed(2)})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Play for fun — no stakes'),
                value: _noStakes,
                onChanged: (v) => setState(() {
                  _noStakes = v ?? false;
                  if (_noStakes) _betCtrl.text = '0';
                }),
              ),
              const Divider(height: 32),

              // ── Roster (per foursome) ────────────────────────────────────
              Text('Participants',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final fs in foursomes) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(fs.label,
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                for (final m in fs.memberships.where((m) => !m.player.isPhantom))
                  Builder(builder: (_) {
                    final onApp = _onAppIds.contains(m.player.id);
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(m.player.name),
                      // Roster is Halved-only: a login-less golfer can't be
                      // matched across rounds, so they can't join the pool.
                      subtitle: Text(onApp
                          ? 'Index ${m.player.handicapIndex}'
                          : 'Not on Halved — invite them to include them'),
                      value: onApp && (_participants[m.player.id] ?? false),
                      onChanged: onApp
                          ? (v) => setState(() {
                                _participants[m.player.id] = v ?? false;
                              })
                          : null,
                    );
                  }),
              ],
              // ── Golfers playing in another round (cross-round pool) ────────
              if (_externalGolfers.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 2),
                  child: Text('Playing in another group',
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                Text(
                  'These Halved golfers ante in but play in their own round. '
                  'Link that round to this pool from its hub so their scores '
                  'count.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final g in _externalGolfers)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(g.name),
                    subtitle: Text('Index ${g.handicapIndex}'),
                    value: _participants[g.id] ?? false,
                    onChanged: (v) => setState(() {
                      _participants[g.id] = v ?? false;
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
                      : Text(_editing
                          ? 'Save Configuration'
                          : 'Start Multi-Group Skins',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              if (!_canStart)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InlineMessage(
                    kind: InlineMessageKind.warn,
                    text: _participantCount < 2
                        ? 'Pick at least 2 participants.'
                        : 'Enter an entry fee, or tick “Play for fun”.',
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
