/// screens/setup_round_players_screen.dart
/// -----------------------------------------
/// Lightweight setup screen for a stub round that has already been created
/// but has no foursomes yet (status = 'pending').
///
/// Steps:
///   0. Select games for this round
///   1. Select players
///   2. Drag to assign groups + pick tees → call setupRound()
///
/// Used when a multi-day tournament has round stubs for days 2..N.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../utils/grouping.dart';
import '../widgets/error_view.dart';

// Group badge colours — mirrors new_round_wizard.dart
const _groupColors = [
  Color(0xFF1565C0),
  Color(0xFF2E7D32),
  Color(0xFFB71C1C),
  Color(0xFFE65100),
  Color(0xFF6A1B9A),
];

class SetupRoundPlayersScreen extends StatefulWidget {
  final int roundId;
  const SetupRoundPlayersScreen({super.key, required this.roundId});

  @override
  State<SetupRoundPlayersScreen> createState() =>
      _SetupRoundPlayersScreenState();
}

class _SetupRoundPlayersScreenState extends State<SetupRoundPlayersScreen> {
  // ── Step ──────────────────────────────────────────────────────────────────
  int _step = 0; // 0 = games, 1 = players, 2 = groups + tees

  // ── Reference data ────────────────────────────────────────────────────────
  Round?               _round;
  List<PlayerProfile>  _allPlayers = [];
  List<TeeInfo>        _tees       = [];
  bool                 _loading    = true;
  String?              _loadError;

  // ── Step 0: Game selection ────────────────────────────────────────────────
  final Set<String> _selectedGames = {};

  // ── Step 1: Player selection ──────────────────────────────────────────────
  final Set<int> _selectedIds = {};
  String         _search      = '';

  // ── Step 2: Groups + tees ─────────────────────────────────────────────────
  List<int>          _orderedIds = [];
  Map<int, TeeInfo?> _playerTees = {};

  // ── Create ────────────────────────────────────────────────────────────────
  bool    _saving      = false;
  String? _saveError;

  // ── Derived ───────────────────────────────────────────────────────────────
  List<TeeInfo> get _courseTees {
    final courseId = _round?.course.id;
    if (courseId == null) return _tees;
    return _tees.where((t) => t.course.id == courseId).toList();
  }

  List<PlayerProfile> get _orderedPlayers => _orderedIds
      .map((id) => _allPlayers.firstWhere((p) => p.id == id))
      .toList();

  bool get _canAdvanceStep0 => true; // games step — always allowed to continue
  bool get _canAdvanceStep1 => _selectedIds.length >= 2;

  bool get _canCreate =>
      _orderedIds.isNotEmpty &&
      _orderedIds.every((id) => _playerTees[id] != null);

  // ── Init ──────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _loadError = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final results = await Future.wait([
        client.getRound(widget.roundId),
        client.getTees(),
        client.getPlayers(),
      ]);
      if (!mounted) return;

      final rawTees = results[1] as List<TeeInfo>;
      int sexRank(String? s) => s == 'M' ? 0 : (s == null ? 1 : 2);
      final tees = rawTees
        ..sort((a, b) {
          final pc = a.sortPriority.compareTo(b.sortPriority);
          if (pc != 0) return pc;
          return sexRank(a.sex).compareTo(sexRank(b.sex));
        });

      setState(() {
        _round      = results[0] as Round;
        _tees       = tees;
        _allPlayers = (results[2] as List<PlayerProfile>)
            .where((p) => !p.isPhantom)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loadError = friendlyError(e); _loading = false; });
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _next() {
    if (_step == 0) {
      setState(() => _step = 1);
    } else if (_step == 1) {
      _initGroups();
      setState(() => _step = 2);
    }
  }

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
    } else {
      Navigator.of(context).pop();
    }
  }

  void _initGroups() {
    final newIds = _selectedIds.toList();
    final kept   = _orderedIds.where((id) => newIds.contains(id)).toList();
    final added  = newIds.where((id) => !kept.contains(id)).toList();
    _orderedIds  = [...kept, ...added];
    for (final id in added) {
      final player = _allPlayers.firstWhere((p) => p.id == id);
      _playerTees[id] = _defaultTee(player);
    }
    _playerTees.removeWhere((id, _) => !newIds.contains(id));
  }

  TeeInfo? _defaultTee(PlayerProfile player) {
    if (_courseTees.isEmpty) return null;
    final sorted = List.of(_courseTees)
        ..sort((a, b) => a.sortPriority.compareTo(b.sortPriority));
    final sexMatch = sorted.where((t) => t.sex == player.sex);
    if (sexMatch.isNotEmpty) return sexMatch.first;
    final unisex = sorted.where((t) => t.sex == null);
    if (unisex.isNotEmpty) return unisex.first;
    return sorted.first;
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    setState(() { _saving = true; _saveError = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final playersList = _orderedIds.map((id) {
        final tee = _playerTees[id];
        if (tee == null) throw Exception('Player $id has no tee selected.');
        return {'player_id': id, 'tee_id': tee.id};
      }).toList();

      await client.setupRound(
        widget.roundId,
        players       : playersList,
        randomise     : false,
        autoSetupGames: _selectedGames.isNotEmpty,
        activeGames   : _selectedGames.toList(),
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _saveError = friendlyError(e); _saving = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final roundLabel = _round != null
        ? 'Round ${_round!.roundNumber} — ${_round!.course.name}'
        : 'Setup Round';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _back(); },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          title: Text(roundLabel),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              value: (_step + 1) / 3,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? ErrorView(message: _loadError!, onRetry: _loadData)
                : _stepBody(),
        bottomNavigationBar: (_loading || _loadError != null)
            ? null
            : _BottomBar(
                step      : _step,
                canNext   : _step == 0 ? _canAdvanceStep0 : _canAdvanceStep1,
                canCreate : _canCreate,
                saving    : _saving,
                onBack    : _back,
                onNext    : _next,
                onCreate  : _save,
              ),
      ),
    );
  }

  Widget _stepBody() {
    if (_step == 0) return _buildGamesStep();
    if (_step == 1) return _buildPlayersStep();
    return _buildGroupsStep();
  }

  // ── Step 0: Game selection ────────────────────────────────────────────────

  Widget _buildGamesStep() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      children: [
        Text('Select Games', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Choose which games will be played in this round. '
          'You can add none and configure games individually from the round screen.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: tournamentRoundGames.map((meta) {
            final selected = _selectedGames.contains(meta.id);
            return FilterChip(
              label: Text(meta.displayName),
              selected: selected,
              onSelected: (_) => setState(() {
                selected
                    ? _selectedGames.remove(meta.id)
                    : _selectedGames.add(meta.id);
              }),
            );
          }).toList(),
        ),
        if (_selectedGames.isEmpty) ...[
          const SizedBox(height: 20),
          Container(
            padding   : const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color        : theme.colorScheme.surfaceContainerHighest,
              borderRadius : BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.info_outline,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No games selected — you can add them later from the round screen.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ]),
          ),
        ],
      ],
    );
  }

  // ── Step 1: Player selection ──────────────────────────────────────────────

  Widget _buildPlayersStep() {
    final filtered = _search.isEmpty
        ? _allPlayers
        : _allPlayers
            .where((p) => p.name.toLowerCase().contains(_search.toLowerCase()))
            .toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Select Players',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '${_selectedIds.length} selected  •  '
            '${groupSizes(_selectedIds.length).length} group(s)',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Colors.grey),
          ),
        ]),
      ),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: TextField(
              decoration: const InputDecoration(
                hintText  : 'Search players…',
                prefixIcon: Icon(Icons.search),
                isDense   : true,
                border    : OutlineInputBorder(),
              ),
              onChanged: (s) => setState(() => _search = s),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => setState(() =>
                _selectedIds.addAll(_allPlayers.map((p) => p.id))),
            child: const Text('All'),
          ),
          TextButton(
            onPressed: () => setState(() => _selectedIds.clear()),
            child: const Text('None'),
          ),
        ]),
      ),
      const SizedBox(height: 8),

      Expanded(
        child: filtered.isEmpty
            ? const Center(child: Text('No players found.'))
            : ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final p   = filtered[i];
                  final sel = _selectedIds.contains(p.id);
                  return CheckboxListTile(
                    value    : sel,
                    onChanged: (_) => setState(() {
                      sel ? _selectedIds.remove(p.id) : _selectedIds.add(p.id);
                    }),
                    title    : Text(p.name),
                    subtitle : Text('Hcp ${p.handicapIndex}'),
                    secondary: CircleAvatar(
                      backgroundColor: sel
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Text(
                        p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          color   : sel ? Colors.white : null,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),

      if (_selectedIds.length < 2)
        Container(
          width  : double.infinity,
          color  : Theme.of(context).colorScheme.errorContainer,
          padding: const EdgeInsets.all(8),
          child  : Text(
            'Select at least 2 players to continue.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer),
          ),
        ),
    ]);
  }

  // ── Step 1: Groups + tees ─────────────────────────────────────────────────

  Widget _buildGroupsStep() {
    final theme      = Theme.of(context);
    final players    = _orderedPlayers;
    final sizes      = groupSizes(players.length);
    final groupCount = sizes.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Groups & Tees', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Drag  ≡  to reorder. Foursomes fill first; remaining players '
          'form threesomes.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: List.generate(groupCount, (i) {
            final color = _groupColors[i % _groupColors.length];
            return Chip(
              label: Text('Group ${i + 1}',
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
              backgroundColor: color.withOpacity(0.1),
              side: BorderSide(color: color.withOpacity(0.4)),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            );
          }),
        ),
        const SizedBox(height: 12),

        Card(
          elevation  : 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.colorScheme.outline),
          ),
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            height: players.length * 68.0,
            child: ReorderableListView(
              shrinkWrap: true,
              physics   : const NeverScrollableScrollPhysics(),
              onReorder : (oldIdx, newIdx) => setState(() {
                if (newIdx > oldIdx) newIdx--;
                final id = _orderedIds.removeAt(oldIdx);
                _orderedIds.insert(newIdx, id);
              }),
              proxyDecorator: (child, _, animation) => Material(
                elevation    : 4,
                color        : theme.colorScheme.surfaceContainerHigh,
                borderRadius : BorderRadius.circular(8),
                child: child,
              ),
              children: players.asMap().entries.map((entry) {
                final idx      = entry.key;
                final player   = entry.value;
                final groupNum = groupOf(idx, sizes);
                final color    = _groupColors[(groupNum - 1) % _groupColors.length];
                final tee      = _playerTees[player.id];

                final playerTeeOptions = _courseTees
                    .where((t) => t.sex == player.sex || t.sex == null)
                    .toList();

                final isGroupStart = isGroupBoundary(idx, sizes);

                return Container(
                  key   : ValueKey(player.id),
                  height: 68,
                  decoration: BoxDecoration(
                    color: idx.isEven
                        ? theme.colorScheme.surface
                        : theme.colorScheme.surfaceContainerLowest,
                    border: Border(
                      top: BorderSide(
                        color: isGroupStart
                            ? theme.colorScheme.outline
                            : theme.colorScheme.outlineVariant,
                        width: isGroupStart ? 2.0 : 0.5,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(children: [
                    ReorderableDragStartListener(
                      index: idx,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Icon(Icons.drag_handle,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment : MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(player.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          DropdownButton<TeeInfo>(
                            value    : (tee != null && playerTeeOptions.contains(tee))
                                ? tee : null,
                            isDense  : true,
                            underline: const SizedBox.shrink(),
                            hint     : Text('Pick tee',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface),
                            items: playerTeeOptions.map((t) => DropdownMenuItem(
                                value: t, child: Text(t.teeName))).toList(),
                            onChanged: (t) {
                              if (t != null) {
                                setState(() => _playerTees[player.id] = t);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color        : color.withOpacity(0.12),
                        borderRadius : BorderRadius.circular(12),
                        border       : Border.all(color: color.withOpacity(0.4)),
                      ),
                      child: Text('G $groupNum',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: color, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                  ]),
                );
              }).toList(),
            ),
          ),
        ),

        const SizedBox(height: 12),
        Text(
          'Groups with fewer than 4 players will have a phantom added '
          'automatically so all scoring works correctly.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant),
        ),

        if (_saveError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding   : const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color        : theme.colorScheme.errorContainer,
              borderRadius : BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_saveError!,
                    style: TextStyle(
                        color: theme.colorScheme.onErrorContainer)),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom navigation bar
// ---------------------------------------------------------------------------

class _BottomBar extends StatelessWidget {
  final int          step;
  final bool         canNext;
  final bool         canCreate;
  final bool         saving;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onCreate;

  const _BottomBar({
    required this.step,
    required this.canNext,
    required this.canCreate,
    required this.saving,
    required this.onBack,
    required this.onNext,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          OutlinedButton(onPressed: onBack, child: const Text('Back')),
          const Spacer(),
          if (step < 2)
            FilledButton(
              onPressed: canNext ? onNext : null,
              child: const Text('Next'),
            )
          else
            FilledButton.icon(
              onPressed: (canCreate && !saving) ? onCreate : null,
              icon: saving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.flag),
              label: const Text('Set Up Round'),
            ),
        ]),
      ),
    );
  }
}
