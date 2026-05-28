/// ryder_cup_draft_screen.dart
///
/// Allows staff to:
///   • Create a new Cup (cup name, team count, team names)
///   • Draft players onto teams (add / remove)
///   • Lock the draft when rosters are final
///
/// Entry point: push this screen with the tournament id.
/// It handles both the "no cup yet" case (shows setup form) and the
/// "cup exists" case (shows roster management UI).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import 'ryder_cup_scoreboard_screen.dart';

class RyderCupDraftScreen extends StatefulWidget {
  final int  tournamentId;
  final String tournamentName;

  const RyderCupDraftScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<RyderCupDraftScreen> createState() => _RyderCupDraftScreenState();
}

class _RyderCupDraftScreenState extends State<RyderCupDraftScreen> {
  // ── State ──────────────────────────────────────────────────────────────────
  TeamTournamentSummary? _summary;
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;
  bool    _notSetUp     = false;   // 404 → show setup form

  // ── Setup-form controllers ─────────────────────────────────────────────────
  final _cupNameCtrl      = TextEditingController(text: 'Ryder Cup');
  final _ppTeamCtrl       = TextEditingController(text: '6');
  int   _teamCount        = 2;
  final List<TextEditingController> _teamNameCtrls = [
    TextEditingController(text: 'Team 1'),
    TextEditingController(text: 'Team 2'),
  ];

  // ── Player list (for the "Add player" picker) ─────────────────────────────
  List<PlayerProfile>? _allPlayers;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cupNameCtrl.dispose();
    _ppTeamCtrl.dispose();
    for (final c in _teamNameCtrls) c.dispose();
    super.dispose();
  }

  // ── API helpers ────────────────────────────────────────────────────────────

  ApiClient get _client => context.read<AuthProvider>().client;

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _notSetUp = false; });
    try {
      final summary = await _client.getTeamTournament(widget.tournamentId);
      if (mounted) setState(() { _summary = summary; });
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        if (mounted) setState(() { _notSetUp = true; });
      } else {
        if (mounted) setState(() {
          _error        = friendlyError(e);
          _networkError = isNetworkError(e);
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _error        = friendlyError(e);
        _networkError = isNetworkError(e);
      });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  Future<void> _loadPlayers() async {
    if (_allPlayers != null) return;
    try {
      final players = await _client.getPlayers();
      if (mounted) setState(() { _allPlayers = players.where((p) => !p.isPhantom).toList(); });
    } catch (_) {}
  }

  // ── Setup form submit ──────────────────────────────────────────────────────

  Future<void> _submitSetup() async {
    final cupName = _cupNameCtrl.text.trim();
    final ppt     = int.tryParse(_ppTeamCtrl.text.trim()) ?? 6;
    if (cupName.isEmpty) {
      _showSnack('Please enter a cup name.');
      return;
    }
    final teams = <Map<String, dynamic>>[];
    for (int i = 0; i < _teamCount; i++) {
      final name = _teamNameCtrls[i].text.trim();
      if (name.isEmpty) {
        _showSnack('Please enter a name for Team ${i + 1}.');
        return;
      }
      teams.add({'team_number': i + 1, 'name': name});
    }

    setState(() { _loading = true; });
    try {
      await _client.postTeamTournamentSetup(
        widget.tournamentId,
        cupName:        cupName,
        playersPerTeam: ppt,
        teams:          teams,
      );
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; });
        _showSnack(friendlyError(e));
      }
    }
  }

  // ── Roster management ──────────────────────────────────────────────────────

  Future<void> _addPlayers(CupTeam team) async {
    await _loadPlayers();
    if (!mounted) return;

    final draftedIds = _summary!.teams
        .expand((t) => t.players.map((p) => p.id))
        .toSet();

    final available = (_allPlayers ?? [])
        .where((p) => !draftedIds.contains(p.id))
        .toList();

    if (available.isEmpty) {
      _showSnack('All players are already assigned to a team.');
      return;
    }

    final chosen = await showDialog<List<PlayerProfile>>(
      context: context,
      builder: (_) => _PlayerPickerDialog(players: available),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;

    // Post players one-by-one.  Backend has no batch endpoint and most
    // adds are <10 players, so sequential is fine.  Stop on first error
    // and surface it — successful adds remain in place because the
    // backend commits per-request, and _load() at the end shows the
    // current state regardless.
    int added = 0;
    String? errorMsg;
    for (final p in chosen) {
      try {
        await _client.postAddTeamPlayer(
          widget.tournamentId, team.teamId, p.id,
        );
        added++;
      } catch (e) {
        errorMsg = friendlyError(e);
        break;
      }
    }
    _load();
    if (mounted) {
      if (errorMsg != null) {
        _showSnack('Added $added of ${chosen.length} — $errorMsg');
      } else if (added > 1) {
        _showSnack('Added $added players to ${team.name}.');
      }
    }
  }

  Future<void> _removePlayer(CupTeam team, CupPlayer player) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove player?'),
        content: Text('Remove ${player.name} from ${team.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await _client.deleteTeamPlayer(
        widget.tournamentId, team.teamId, player.id,
      );
      _load();
    } catch (e) {
      if (mounted) _showSnack(friendlyError(e));
    }
  }

  Future<void> _renameTeam(CupTeam team) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameTeamDialog(initialName: team.name),
    );
    if (newName == null || newName.isEmpty || !mounted) return;
    try {
      await _client.patchTeamName(widget.tournamentId, team.teamId, newName);
      _load();
    } catch (e) {
      if (mounted) _showSnack(friendlyError(e));
    }
  }

  Future<void> _lockDraft() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Lock draft?'),
        content: const Text(
            'This will lock all rosters. Players cannot be moved after this.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Lock'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await _client.postDraftComplete(widget.tournamentId);
      _load();
    } catch (e) {
      if (mounted) _showSnack(friendlyError(e));
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_summary?.cupName ?? 'Cup Setup'),
        actions: [
          if (_summary != null)
            IconButton(
              icon: const Icon(Icons.leaderboard_outlined),
              tooltip: 'Scoreboard',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RyderCupScoreboardScreen(
                  tournamentId:   widget.tournamentId,
                  tournamentName: widget.tournamentName,
                ),
              )),
            ),
          if (_summary != null)
            IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(message: _error!, isNetwork: _networkError, onRetry: _load);
    }
    if (_notSetUp) return _SetupForm(
      cupNameCtrl : _cupNameCtrl,
      ppTeamCtrl  : _ppTeamCtrl,
      teamCount   : _teamCount,
      teamNameCtrls: _teamNameCtrls,
      onTeamCountChanged: (n) {
        setState(() {
          _teamCount = n;
          while (_teamNameCtrls.length < n) {
            _teamNameCtrls.add(
                TextEditingController(text: 'Team ${_teamNameCtrls.length + 1}'));
          }
        });
      },
      onSubmit: _submitSetup,
    );
    return _DraftBoard(
      summary       : _summary!,
      isLocked      : _summary!.draftComplete,
      onAddPlayer   : _addPlayers,
      onRemovePlayer: _removePlayer,
      onLockDraft   : _lockDraft,
      onRenameTeam  : _renameTeam,
    );
  }
}

// ---------------------------------------------------------------------------
// Setup form (first-time cup creation)
// ---------------------------------------------------------------------------

class _SetupForm extends StatelessWidget {
  final TextEditingController cupNameCtrl;
  final TextEditingController ppTeamCtrl;
  final int    teamCount;
  final List<TextEditingController> teamNameCtrls;
  final void Function(int) onTeamCountChanged;
  final VoidCallback onSubmit;

  const _SetupForm({
    required this.cupNameCtrl,
    required this.ppTeamCtrl,
    required this.teamCount,
    required this.teamNameCtrls,
    required this.onTeamCountChanged,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Create a new Cup',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        GolfTextField(
          controller: cupNameCtrl,
          label: 'Cup name',
          hint: 'e.g. Bandon Cup 2026',
        ),
        const SizedBox(height: 16),
        GolfTextField(
          controller: ppTeamCtrl,
          keyboardType: TextInputType.number,
          label: 'Players per team (target)',
        ),
        const SizedBox(height: 20),
        Text('Number of teams', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [2, 3, 4].map((n) => Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('$n'),
              selected: teamCount == n,
              onSelected: (_) => onTeamCountChanged(n),
            ),
          )).toList(),
        ),
        const SizedBox(height: 16),
        ...List.generate(teamCount, (i) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GolfTextField(
            controller: teamNameCtrls[i],
            label: 'Team ${i + 1} name',
          ),
        )),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: onSubmit,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Create Cup'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Draft board — roster management
// ---------------------------------------------------------------------------

class _DraftBoard extends StatelessWidget {
  final TeamTournamentSummary summary;
  final bool      isLocked;
  final void Function(CupTeam) onAddPlayer;
  final void Function(CupTeam, CupPlayer) onRemovePlayer;
  final VoidCallback onLockDraft;
  final void Function(CupTeam) onRenameTeam;

  const _DraftBoard({
    required this.summary,
    required this.isLocked,
    required this.onAddPlayer,
    required this.onRemovePlayer,
    required this.onLockDraft,
    required this.onRenameTeam,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      // ── Lock banner / status bar ───────────────────────────────────────────
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: isLocked
            ? Colors.green.shade100
            : theme.colorScheme.primaryContainer,
        child: Row(children: [
          Icon(isLocked ? Icons.lock : Icons.edit_outlined,
              size: 18,
              color: isLocked ? Colors.green.shade800 : theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isLocked
                  ? 'Draft locked — rosters are final'
                  : 'Draft open — drag players to teams',
              style: TextStyle(
                  color: isLocked
                      ? Colors.green.shade800
                      : theme.colorScheme.primary,
                  fontWeight: FontWeight.w500),
            ),
          ),
          if (!isLocked)
            FilledButton.tonal(
              onPressed: onLockDraft,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: Colors.green.shade400,
                foregroundColor: Colors.white,
              ),
              child: const Text('Lock Draft'),
            ),
        ]),
      ),

      // ── Team columns ───────────────────────────────────────────────────────
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: summary.teams.map((team) => _TeamCard(
            team      : team,
            isLocked  : isLocked,
            onAdd     : () => onAddPlayer(team),
            onRemove  : (p) => onRemovePlayer(team, p),
            onRename  : () => onRenameTeam(team),
          )).toList(),
        ),
      ),
    ]);
  }
}

class _TeamCard extends StatelessWidget {
  final CupTeam  team;
  final bool     isLocked;
  final VoidCallback onAdd;
  final void Function(CupPlayer) onRemove;
  final VoidCallback onRename;

  const _TeamCard({
    required this.team,
    required this.isLocked,
    required this.onAdd,
    required this.onRemove,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Row(children: [
            Container(
              width: 12, height: 12,
              decoration: BoxDecoration(
                color: _teamColor(team.colour),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(team.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _teamColor(team.colour))),
            ),
            Text('${team.players.length} player${team.players.length != 1 ? "s" : ""}',
                style: theme.textTheme.bodySmall),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: 'Rename team',
              visualDensity: VisualDensity.compact,
              onPressed: onRename,
            ),
          ]),
          const Divider(height: 16),

          // Players
          if (team.players.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('No players yet',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic)),
            )
          else
            ...team.players.map((p) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: Text(p.shortName,
                    style: const TextStyle(fontSize: 11)),
              ),
              title: Text(p.name,
                  style: TextStyle(color: _teamColor(team.colour))),
              trailing: isLocked ? null : IconButton(
                icon: Icon(Icons.remove_circle_outline,
                    color: theme.colorScheme.error, size: 20),
                onPressed: () => onRemove(p),
                tooltip: 'Remove from team',
              ),
            )),

          // Add button
          if (!isLocked) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('Add player'),
            ),
          ],
        ]),
      ),
    );
  }

  Color _teamColor(String colour) {
    switch (colour.toLowerCase()) {
      case 'red':    return Colors.red;
      case 'blue':   return Colors.blue;
      case 'green':  return Colors.green;
      case 'yellow': return Colors.amber;
      case 'orange': return Colors.deepOrange;
      case 'purple': return Colors.purple;
      case 'black':  return Colors.black87;
      default:       return Colors.grey;
    }
  }
}

// ---------------------------------------------------------------------------
// Player picker dialog
// ---------------------------------------------------------------------------

class _PlayerPickerDialog extends StatefulWidget {
  final List<PlayerProfile> players;
  const _PlayerPickerDialog({required this.players});

  @override
  State<_PlayerPickerDialog> createState() => _PlayerPickerDialogState();
}

class _PlayerPickerDialogState extends State<_PlayerPickerDialog> {
  String _search = '';
  /// IDs of players currently checked.  Selection persists across
  /// search-term changes so users can search "Sm", check Smith, clear
  /// the search, then check Jones — and submit both together.
  final Set<int> _selectedIds = <int>{};

  List<PlayerProfile> get _filtered => widget.players
      .where((p) => p.name.toLowerCase().contains(_search.toLowerCase()))
      .toList();

  void _toggle(PlayerProfile p) {
    setState(() {
      if (!_selectedIds.add(p.id)) _selectedIds.remove(p.id);
    });
  }

  void _commit() {
    final chosen = widget.players
        .where((p) => _selectedIds.contains(p.id))
        .toList();
    Navigator.pop(context, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;
    final count = _selectedIds.length;

    // Shrink the result area when the on-screen keyboard is up so the
    // bottom rows aren't tucked behind the keyboard / prediction bar
    // (the original 400px fixed height left rows unreachable on iOS).
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    final maxH = MediaQuery.sizeOf(context).height;
    final dialogH = (maxH - viewInsets - 200).clamp(220.0, 480.0);

    return AlertDialog(
      // Title shows live selection count so the user can verify before
      // hitting Add — important for multi-select where it's easy to lose
      // track of checked rows after scrolling.
      title: Row(children: [
        const Expanded(child: Text('Add players')),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$count',
                style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold)),
          ),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 320,
        height: dialogH,
        child: Column(children: [
          TextField(
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText       : 'Search…',
              prefixIcon     : Icon(Icons.search),
              border         : OutlineInputBorder(),
              isDense        : true,
              contentPadding : EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged:   (v) => setState(() => _search = v),
            // Enter just dismisses the keyboard — multi-select shouldn't
            // auto-commit since users typically tap several boxes after
            // each search.
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      'No matches.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final p = filtered[i];
                      final selected = _selectedIds.contains(p.id);
                      return CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: selected,
                        onChanged: (_) => _toggle(p),
                        title: Text(p.name),
                        subtitle: Text('Hcp ${p.handicapIndex}'),
                      );
                    },
                  ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: count == 0 ? null : _commit,
          child: Text(count == 0
              ? 'Add'
              : count == 1
                  ? 'Add 1 player'
                  : 'Add $count players'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Rename team dialog — manages its own controller lifecycle to avoid
// "TextEditingController used after dispose" during dialog teardown.
// ---------------------------------------------------------------------------

class _RenameTeamDialog extends StatefulWidget {
  final String initialName;
  const _RenameTeamDialog({required this.initialName});

  @override
  State<_RenameTeamDialog> createState() => _RenameTeamDialogState();
}

class _RenameTeamDialogState extends State<_RenameTeamDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename team'),
      content: GolfTextField(
        controller: _ctrl,
        autofocus: true,
        label: 'Team name',
        onFieldSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
