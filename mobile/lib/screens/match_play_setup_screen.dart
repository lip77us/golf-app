/// match_play_setup_screen.dart
/// ----------------------------
/// Configure entry fee, payout distribution, and bracket seedings for a
/// foursome's match play bracket before play begins.
///
/// Features:
///   • Drag to reorder seeds — explicit drag handle, no gesture conflict.
///   • Integer-only dollar amounts (no pennies).
///   • "Copy to all match plays" on entry fee.
///   • "Copy to other foursomes / threesomes" on payouts.
///
/// If the bracket is already in_progress or complete we redirect immediately
/// to /match-play so the coordinator can't accidentally reset a live match.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/payout_config_field.dart';

// ---------------------------------------------------------------------------
// Local model
// ---------------------------------------------------------------------------

class _SeedPlayer {
  final int    id;
  final String name;
  final int    playingHandicap;
  const _SeedPlayer({
    required this.id,
    required this.name,
    required this.playingHandicap,
  });
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

class MatchPlaySetupScreen extends StatefulWidget {
  final int       foursomeId;
  /// All foursome IDs that have match play active in this round — used for
  /// the "Copy entry fee to all match plays" action.
  final List<int> allMatchPlayIds;
  /// Other foursomes of the same player-count — used for the
  /// "Copy payouts to other foursomes/threesomes" action.
  final List<int> peerIds;

  /// When true, this screen was opened from round creation: after saving the
  /// bracket it returns to the /round launch page instead of jumping into
  /// scoring, and it won't auto-redirect to /match-play during setup.
  final bool returnToHub;

  const MatchPlaySetupScreen({
    super.key,
    required this.foursomeId,
    this.allMatchPlayIds = const [],
    this.peerIds         = const [],
    this.returnToHub     = false,
  });

  @override
  State<MatchPlaySetupScreen> createState() => _MatchPlaySetupScreenState();
}

class _MatchPlaySetupScreenState extends State<MatchPlaySetupScreen> {
  Map<String, dynamic>? _bracket;
  bool    _loading       = true;
  bool    _saving        = false;
  bool    _copyingFee    = false;
  bool    _copyingPayouts= false;
  Object? _error;

  // Per-bracket handicap mode — defaults to Strokes-Off Low (matches the
  // other casual game setup screens).  Existing brackets overwrite this
  // from their persisted handicap.mode in _load().
  String _mode       = 'strokes_off';
  int    _netPercent = 100;

  // Entry fee
  final _entryFeeCtrl = TextEditingController(text: '0');
  /// Explicit opt-in to a no-money match (lets Start proceed at $0).
  bool _noStakes = false;

  // Payouts: N paid places (1–4) with one integer amount per place
  int _numPayouts = 3;
  static const _placeLabels = ['1st', '2nd', '3rd', '4th'];
  final _payoutCtrls = List.generate(4, (_) => TextEditingController(text: '0'));

  // Seedings: ordered list — index 0 = seed 1 (plays seed 4 in Semi 1)
  List<_SeedPlayer> _seedPlayers = [];
  // Real player count, read from the bracket's players list (3 or 4).
  int _playerCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _entryFeeCtrl.addListener(_onFeeChanged);
  }

  @override
  void dispose() {
    _entryFeeCtrl.removeListener(_onFeeChanged);
    _entryFeeCtrl.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  // ── Derived ───────────────────────────────────────────────────────────────

  // _playerCount is set from bracket data in _load(); defaults to 4 until loaded.
  int get _effectivePlayerCount => _playerCount > 0 ? _playerCount : 4;

  double get _pool =>
      (double.tryParse(_entryFeeCtrl.text.trim()) ?? 0) * _effectivePlayerCount;

  // Peer type label — use _playerCount (from bracket data) so it's correct
  // even if _seedPlayers is temporarily empty.
  String get _peerLabel =>
      _effectivePlayerCount == 3 ? 'other threesomes' : 'other foursomes';

  // ── Load ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final Map<String, dynamic> data;
      try {
        data = await client.getMatchPlay(widget.foursomeId);
      } on ApiException catch (e) {
        if (e.statusCode == 404) {
          // No bracket yet for this foursome — the expected state when a user
          // lands here from a fresh round.  Seed the form from the foursome's
          // assigned players (handicap order) so they can arrange the matchups
          // and save, instead of showing "no players assigned".
          if (mounted) {
            setState(() {
              _seedPlayers = _rosterSeeds();
              if (_seedPlayers.isNotEmpty) _playerCount = _seedPlayers.length;
              _loading = false;
            });
          }
          return;
        }
        rethrow;
      }
      if (!mounted) return;

      final st = data['status'] as String? ?? 'pending';
      // During round creation (returnToHub) stay on the form even for a live
      // bracket so the user can return to the launch page; only the normal
      // entry-point bounces straight into the live match.
      if ((st == 'in_progress' || st == 'complete') && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
            '/match-play', arguments: widget.foursomeId);
        return;
      }

      // Pre-populate money fields if already configured
      final money    = data['money'] as Map? ?? {};
      final entryFee = (money['entry_fee'] as num? ?? 0).toDouble();
      if (entryFee > 0) {
        _entryFeeCtrl.text = entryFee.round().toString();
        final cfg     = (money['payout_config'] as Map? ?? {});
        int   nPlaces = 0;
        for (int i = 0; i < 4; i++) {
          final amt = (cfg[_placeLabels[i]] as num? ?? 0).toDouble();
          _payoutCtrls[i].text = amt.round().toString();
          if (amt > 0) nPlaces = i + 1;
        }
        if (nPlaces > 0) _numPayouts = nPlaces;
      }

      // Per-bracket handicap mode + net percent.  The summary returns
      // these under `handicap` once the bracket is created; for a brand-
      // new bracket the keys may be missing, in which case we keep the
      // local Strokes-Off-Low default.
      final hcap = data['handicap'] as Map? ?? const {};
      final hcapMode = hcap['mode'] as String?;
      if (hcapMode != null) _mode = hcapMode;
      final hcapPct  = hcap['net_percent'] as int?;
      if (hcapPct  != null) _netPercent = hcapPct;

      // Store actual player count (3 for threesome, 4 for foursome)
      _playerCount = (data['players'] as List? ?? []).length;
      if (_playerCount == 0) _playerCount = 4; // safe fallback

      // Build seed list from summary
      _seedPlayers = _parseSeedPlayers(data);

      setState(() { _bracket = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// Seed list built from the foursome's assigned real players, in handicap
  /// order (lowest = seed 1).  Used before a bracket exists so the matchups can
  /// be arranged at setup time.
  List<_SeedPlayer> _rosterSeeds() {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    return fs.realPlayers
        .map((m) => _SeedPlayer(
              id:              m.player.id,
              name:            m.player.name,
              playingHandicap: m.playingHandicap,
            ))
        .toList()
      ..sort((a, b) => a.playingHandicap.compareTo(b.playingHandicap));
  }

  List<_SeedPlayer> _parseSeedPlayers(Map<String, dynamic> data) {
    final playersRaw = data['players'] as List? ?? [];
    final playerMap  = <int, Map<String, dynamic>>{};
    for (final p in playersRaw) {
      final pm = Map<String, dynamic>.from(p as Map);
      playerMap[pm['player_id'] as int] = pm;
    }

    final seedIds = (data['seed_order'] as List? ?? []).cast<int>();
    final ordered = seedIds
        .map((id) {
          final pm = playerMap[id];
          if (pm == null) return null;
          return _SeedPlayer(
            id:              id,
            name:            pm['name'] as String,
            playingHandicap: (pm['playing_handicap'] as num? ?? 0).toInt(),
          );
        })
        .whereType<_SeedPlayer>()
        .toList();

    if (ordered.isNotEmpty) return ordered;

    // Fallback: list in handicap order from the players array; if the bracket
    // carries no players, fall back to the foursome roster.
    if (playersRaw.isEmpty) return _rosterSeeds();
    return playersRaw.map((p) {
      final pm = Map<String, dynamic>.from(p as Map);
      return _SeedPlayer(
        id:              pm['player_id'] as int,
        name:            pm['name'] as String,
        playingHandicap: (pm['playing_handicap'] as num? ?? 0).toInt(),
      );
    }).toList();
  }

  void _onFeeChanged() => setState(() {
        if ((double.tryParse(_entryFeeCtrl.text.trim()) ?? 0) > 0 && _noStakes) {
          _noStakes = false;
        }
      });

  /// Start gate: an entry fee entered, or "no stakes" ticked.
  bool get _stakeChosen =>
      _noStakes || (double.tryParse(_entryFeeCtrl.text.trim()) ?? 0) > 0;

  void _autoSeed() {
    final sorted = List<_SeedPlayer>.from(_seedPlayers)
      ..sort((a, b) => a.playingHandicap.compareTo(b.playingHandicap));
    setState(() => _seedPlayers = sorted);
  }

  void _suggestPayouts() {
    final pool = _pool.round();
    if (pool <= 0) return;
    final suggested = suggestPayouts(pool, _numPayouts);
    for (int i = 0; i < 4; i++) {
      _payoutCtrls[i].text = suggested[i].toString();
    }
    setState(() {});
  }

  // ── Copy actions ──────────────────────────────────────────────────────────

  Future<void> _copyEntryFeeToAll() async {
    final others = widget.allMatchPlayIds
        .where((id) => id != widget.foursomeId)
        .toList();
    if (others.isEmpty) return;
    setState(() => _copyingFee = true);
    try {
      final client   = context.read<AuthProvider>().client;
      final entryFee = double.tryParse(_entryFeeCtrl.text.trim()) ?? 0;
      for (final id in others) {
        await client.postMatchPlaySetup(id, entryFee: entryFee, payoutConfig: {});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Entry fee copied to ${others.length} '
              'other group${others.length == 1 ? "" : "s"}'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:         Text('Copy failed: ${friendlyError(e)}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _copyingFee = false);
    }
  }

  Future<void> _copyPayoutsToPeers() async {
    if (widget.peerIds.isEmpty) return;
    setState(() => _copyingPayouts = true);
    try {
      final client   = context.read<AuthProvider>().client;
      final entryFee = double.tryParse(_entryFeeCtrl.text.trim()) ?? 0;
      final payouts  = <String, double>{};
      for (int i = 0; i < _numPayouts; i++) {
        payouts[_placeLabels[i]] =
            double.tryParse(_payoutCtrls[i].text.trim()) ?? 0;
      }
      for (final id in widget.peerIds) {
        await client.postMatchPlaySetup(
            id, entryFee: entryFee, payoutConfig: payouts);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Payouts copied to ${widget.peerIds.length} '
              'other group${widget.peerIds.length == 1 ? "" : "s"}'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:         Text('Copy failed: ${friendlyError(e)}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _copyingPayouts = false);
    }
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final client   = context.read<AuthProvider>().client;
      // Read the round provider before the async save so the post-save
      // reload doesn't reach across an async gap for `context`.
      final rp       = context.read<RoundProvider>();
      final entryFee = double.tryParse(_entryFeeCtrl.text.trim()) ?? 0;
      final payouts  = <String, double>{};
      for (int i = 0; i < _numPayouts; i++) {
        payouts[_placeLabels[i]] =
            double.tryParse(_payoutCtrls[i].text.trim()) ?? 0;
      }
      final seedOrder = _seedPlayers.map((p) => p.id).toList();

      await client.postMatchPlaySetup(
        widget.foursomeId,
        entryFee:     entryFee,
        payoutConfig: payouts,
        seedOrder:    seedOrder.isNotEmpty ? seedOrder : null,
        handicapMode: _mode,
        netPercent:   _netPercent,
      );

      if (widget.returnToHub) {
        // Round creation: reload the round so the /round launch page below us
        // reflects the freshly-saved bracket, then pop back to it (rather than
        // pushing a new route) so a single hub stays on the stack.
        if (rp.round != null) {
          await rp.loadRound(rp.round!.id);
        }
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        // Return to the round overview (round screen or wizard step 6),
        // not directly into score entry.
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Match Play — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message:   friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry:   _load,
                )
              : _buildBody(),
      bottomNavigationBar: _loading ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity, height: 52,
            child: FilledButton(
              onPressed: (_saving || !_stakeChosen) ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save Configuration',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(title: 'Bracket Seedings', child: _buildSeedings(theme)),
          const SizedBox(height: 16),
          // Per-bracket handicap mode — Strokes-Off Low is the casual
          // default since the side game lives entirely within the
          // foursome.  The selector is the same widget the other game
          // setup screens use so the picker reads identically everywhere.
          HandicapModeSelector(
            mode:             _mode,
            netPercent:       _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
            soNote: 'The lowest-handicap player in this foursome plays '
                'to 0.  Other players receive (own HCP − foursome low '
                'HCP) strokes, allocated by stroke index, scaled by Net %.',
          ),
          const SizedBox(height: 16),
          SectionCard(title: 'Entry Fee',    child: _buildEntryFee(theme)),
          const SizedBox(height: 16),
          SectionCard(title: 'Payouts',      child: _buildPayouts(theme)),
          const SizedBox(height: 16),
          SectionCard(title: 'How it works', child: _buildRules(theme)),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  // ── Seedings ──────────────────────────────────────────────────────────────

  Widget _buildSeedings(ThemeData theme) {
    if (_seedPlayers.isEmpty) {
      return Text(
        'Seedings will appear once players are assigned.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    final n = _seedPlayers.length;

    // Live matchup preview
    final List<String> matchupLines;
    if (n >= 4) {
      matchupLines = [
        'Semi 1 (front 9):  ${_seedPlayers[0].name}  vs  ${_seedPlayers[3].name}',
        'Semi 2 (front 9):  ${_seedPlayers[1].name}  vs  ${_seedPlayers[2].name}',
      ];
    } else if (n == 3) {
      matchupLines = [
        'Semi 1 (front 9):  ${_seedPlayers[0].name}  vs  ${_seedPlayers[2].name}',
        'Semi 2 (front 9):  ${_seedPlayers[0].name}  vs  ${_seedPlayers[1].name}',
      ];
    } else {
      matchupLines = [
        'Match (front 9):  ${_seedPlayers[0].name}  vs  ${_seedPlayers[1].name}',
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Drag to reorder seeds',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            TextButton.icon(
              icon:      const Icon(Icons.sort, size: 16),
              label:     const Text('Auto-seed'),
              onPressed: _autoSeed,
              style:     TextButton.styleFrom(
                  visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // ReorderableListView with explicit drag handles so the gesture
        // doesn't conflict with the parent SingleChildScrollView.
        ReorderableListView(
          shrinkWrap:              true,
          physics:                 const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,   // ← key: only handle triggers drag
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _seedPlayers.removeAt(oldIndex);
              _seedPlayers.insert(newIndex, item);
            });
          },
          children: [
            for (int i = 0; i < _seedPlayers.length; i++)
              ListTile(
                key:            ValueKey(_seedPlayers[i].id),
                contentPadding: EdgeInsets.zero,
                dense:          true,
                leading:        _seedBadge(theme, i + 1),
                title: Text(
                  _seedPlayers[i].name,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  'HCP ${_seedPlayers[i].playingHandicap}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                // Wrap the handle in ReorderableDragStartListener so only
                // dragging the handle icon starts the reorder.
                trailing: ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.drag_handle, color: Colors.grey),
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 16),
        for (final line in matchupLines) ...[
          Text(
            line,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
        ],
      ],
    );
  }

  Widget _seedBadge(ThemeData theme, int seed) => Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          '$seed',
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer),
        ),
      );

  // ── Entry fee ─────────────────────────────────────────────────────────────

  Widget _buildEntryFee(ThemeData theme) {
    final otherCount = widget.allMatchPlayIds
        .where((id) => id != widget.foursomeId)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GolfTextField(
          controller: _entryFeeCtrl,
          label: 'Per player (\$)',
          prefixIcon: Icons.attach_money,
          keyboardType: TextInputType.number,
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Play for fun — no stakes'),
          value: _noStakes,
          onChanged: (v) => setState(() {
            _noStakes = v ?? false;
            if (_noStakes) _entryFeeCtrl.text = '0';
          }),
        ),
        if (_pool > 0) ...[
          const SizedBox(height: 6),
          Text(
            'Prize pool: \$${_pool.round()}  ($_effectivePlayerCount players)',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        // Copy entry fee to all other match play groups
        if (otherCount > 0) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: _copyingFee
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.copy_all, size: 18),
              label: Text(
                'Copy to all match plays ($otherCount other '
                'group${otherCount == 1 ? "" : "s"})',
              ),
              onPressed: _copyingFee ? null : _copyEntryFeeToAll,
            ),
          ),
        ],
      ],
    );
  }

  // ── Payouts ───────────────────────────────────────────────────────────────

  Widget _buildPayouts(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PayoutConfigField(
          pool:                _pool.round(),
          numPayouts:          _numPayouts,
          payoutCtrls:         _payoutCtrls,
          onNumPayoutsChanged: (n) => setState(() => _numPayouts = n),
          onPayoutChanged:     () => setState(() {}),
          onSuggest:           _suggestPayouts,
        ),
        // Copy payouts to peers (same group size)
        if (widget.peerIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: _copyingPayouts
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.copy, size: 18),
              label: Text(
                'Copy payouts to $_peerLabel '
                '(${widget.peerIds.length} other '
                'group${widget.peerIds.length == 1 ? "" : "s"})',
              ),
              onPressed: _copyingPayouts ? null : _copyPayoutsToPeers,
            ),
          ),
        ],
      ],
    );
  }

  // ── Rules ─────────────────────────────────────────────────────────────────

  Widget _buildRules(ThemeData theme) {
    return Text(
      'Front 9 — Two semi-finals run simultaneously.\n'
      'Seed 1 vs Seed 4 · Seed 2 vs Seed 3.\n'
      'Ties after hole 9 go to sudden death using back-9 scores.\n\n'
      'Back 9 — Both semi winners play the Final (1st/2nd);\n'
      'both losers play for 3rd/4th.\n'
      'Ties after 18 use last-hole-won.',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

}
