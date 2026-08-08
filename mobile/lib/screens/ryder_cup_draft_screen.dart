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
  // Blank by default — the user must name their cup (validated on save).
  final _cupNameCtrl      = TextEditingController();
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

    // Golfers already seated on OTHER sides — shown locked with their side, so
    // the roster reads complete instead of making the captain hunt for a name.
    final taken = <_TakenGolfer>[];
    for (final t in _summary!.teams) {
      if (t.teamId == team.teamId) continue;
      for (final p in t.players) {
        taken.add(_TakenGolfer(
          name: p.name, index: p.handicapIndex,
          teamName: t.name, colour: _teamColor(t.colour)));
      }
    }
    taken.sort((a, b) => a.name.compareTo(b.name));

    if (available.isEmpty) {
      _showSnack('All players are already assigned to a team.');
      return;
    }

    final sideSize = _summary!.playersPerTeam < 1 ? 1 : _summary!.playersPerTeam;
    final chosen = await showDialog<List<PlayerProfile>>(
      context: context,
      builder: (_) => _PlayerPickerDialog(
        players      : available,
        teamName     : team.name,
        teamColour   : _teamColor(team.colour),
        sideSize     : sideSize,
        currentCount : team.players.length,
        taken        : taken,
      ),
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

  Future<void> _setSideSize(int n) async {
    if (n < 1 || _summary == null) return;
    try {
      final updated = await _client.updatePlayersPerTeam(widget.tournamentId, n);
      if (mounted) setState(() => _summary = updated);
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
      onSetSideSize : _setSideSize,
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
          hint: 'e.g. Club Cup 2026',
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
  final void Function(int) onSetSideSize;

  const _DraftBoard({
    required this.summary,
    required this.isLocked,
    required this.onAddPlayer,
    required this.onRemovePlayer,
    required this.onLockDraft,
    required this.onRenameTeam,
    required this.onSetSideSize,
  });

  /// Side size (players per team) — the single input group count derives from.
  int get _sideSize => summary.playersPerTeam < 1 ? 1 : summary.playersPerTeam;
  int get _roster   => summary.teams.length * _sideSize;
  int get _groups   => (_roster / 4).ceil();
  bool get _allSidesFull =>
      summary.teams.every((t) => t.players.length >= _sideSize);

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
                  : (_allSidesFull
                      ? 'Rosters full — lock when ready'
                      : 'Draft open — fill every side'),
              style: TextStyle(
                  color: isLocked
                      ? Colors.green.shade800
                      : theme.colorScheme.primary,
                  fontWeight: FontWeight.w500),
            ),
          ),
          if (!isLocked)
            FilledButton.tonal(
              // Lock stays disabled until every side has reached the side size.
              onPressed: _allSidesFull ? onLockDraft : null,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: Colors.green.shade400,
                foregroundColor: Colors.white,
              ),
              child: const Text('Lock Draft'),
            ),
        ]),
      ),

      // ── Side size + derived group count ────────────────────────────────────
      if (!isLocked)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Players per side',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  Text('Each side drafts this many golfers.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
              _Stepper(
                value: _sideSize,
                min: 1,
                onChanged: onSetSideSize,
              ),
            ]),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${summary.teams.length} sides × $_sideSize = $_roster golfers  ·  '
                '$_groups group${_groups == 1 ? "" : "s"} of four'
                '${_roster % 4 != 0 ? " (one short — round setup will say which)" : ""}',
                style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
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
            sideSize  : _sideSize,
            onAdd     : () => onAddPlayer(team),
            onRemove  : (p) => onRemovePlayer(team, p),
            onRename  : () => onRenameTeam(team),
          )).toList(),
        ),
      ),
    ]);
  }
}

/// Compact −/N/+ stepper.
class _Stepper extends StatelessWidget {
  final int value;
  final int min;
  final ValueChanged<int> onChanged;
  const _Stepper({required this.value, required this.onChanged, this.min = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.remove, size: 18),
          visualDensity: VisualDensity.compact,
          onPressed: value > min ? () => onChanged(value - 1) : null,
          color: theme.colorScheme.primary,
        ),
        SizedBox(
          width: 28,
          child: Text('$value',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 18),
          visualDensity: VisualDensity.compact,
          onPressed: () => onChanged(value + 1),
          color: theme.colorScheme.primary,
        ),
      ]),
    );
  }
}

class _TeamCard extends StatelessWidget {
  final CupTeam  team;
  final bool     isLocked;
  final int      sideSize;
  final VoidCallback onAdd;
  final void Function(CupPlayer) onRemove;
  final VoidCallback onRename;

  const _TeamCard({
    required this.team,
    required this.isLocked,
    required this.sideSize,
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
            Builder(builder: (_) {
              final full = team.players.length >= sideSize;
              return Text('${team.players.length} of $sideSize',
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: full
                          ? Colors.green.shade700
                          : theme.colorScheme.onSurfaceVariant));
            }),
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
              subtitle: p.handicapIndex.isEmpty
                  ? null
                  : Text('Index ${p.handicapIndex}'),
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
}

/// Team badge colour from the stored colour name.  Shared by the team cards and
/// the add-players picker so a side's badge is the same everywhere.
// TODO(cup): the six design swatches are hex — carry the hex on the team so any
// custom colour has a visible badge (bug-bundle item), instead of this fixed set.
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

// ---------------------------------------------------------------------------
// Player picker dialog — "Add to <side>"
// ---------------------------------------------------------------------------
// Names the side it fills (badge + count), caps selection at the side's open
// slots, and shows golfers already drafted elsewhere as locked "On <side>".

/// A golfer already seated on another side (shown locked in the picker).
class _TakenGolfer {
  final String name;
  final String index;
  final String teamName;
  final Color  colour;
  const _TakenGolfer({
    required this.name,
    required this.index,
    required this.teamName,
    required this.colour,
  });
}

class _PlayerPickerDialog extends StatefulWidget {
  final List<PlayerProfile> players;   // available (undrafted) golfers
  final String              teamName;  // the side being filled
  final Color               teamColour;
  final int                 sideSize;
  final int                 currentCount;   // golfers already on this side
  final List<_TakenGolfer>  taken;          // seated on other sides
  const _PlayerPickerDialog({
    required this.players,
    required this.teamName,
    required this.teamColour,
    required this.sideSize,
    required this.currentCount,
    required this.taken,
  });

  @override
  State<_PlayerPickerDialog> createState() => _PlayerPickerDialogState();
}

class _PlayerPickerDialogState extends State<_PlayerPickerDialog> {
  String _search = '';
  /// IDs of golfers currently held (staged), persisted across search changes.
  final Set<int> _selectedIds = <int>{};

  /// Open slots on this side — the most golfers we'll hold before Add.
  int get _slotsLeft =>
      (widget.sideSize - widget.currentCount).clamp(0, widget.sideSize);
  bool get _capReached => _selectedIds.length >= _slotsLeft;

  List<PlayerProfile> get _filtered => widget.players
      .where((p) => p.name.toLowerCase().contains(_search.toLowerCase()))
      .toList();

  List<_TakenGolfer> get _filteredTaken => widget.taken
      .where((t) => t.name.toLowerCase().contains(_search.toLowerCase()))
      .toList();

  void _toggle(PlayerProfile p) {
    setState(() {
      if (!_selectedIds.add(p.id)) _selectedIds.remove(p.id);
    });
  }

  void _commit() {
    final chosen =
        widget.players.where((p) => _selectedIds.contains(p.id)).toList();
    Navigator.pop(context, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final filtered = _filtered;
    final taken    = _filteredTaken;
    final staged   = _selectedIds.length;
    final toPick   = (_slotsLeft - staged).clamp(0, widget.sideSize);

    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    final maxH = MediaQuery.sizeOf(context).height;
    final dialogH = (maxH - viewInsets - 220).clamp(240.0, 480.0);

    // Roster line under the title — reads "4 of 8 on this side · pick 4 more",
    // and states itself instead of silently ignoring taps once the side fills.
    final String rosterLine;
    if (_slotsLeft == 0) {
      rosterLine = '${widget.currentCount} of ${widget.sideSize} — this side is full';
    } else if (_capReached) {
      rosterLine = '${widget.teamName} is full — deselect to swap';
    } else {
      rosterLine = '${widget.currentCount} of ${widget.sideSize} on this side · '
          'pick $toPick more${staged > 0 ? ' · holding $staged' : ''}';
    }

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 12, height: 12,
              decoration: BoxDecoration(
                  color: widget.teamColour, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Add to ${widget.teamName}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          if (staged > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('$staged',
                  style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold)),
            ),
        ]),
        const SizedBox(height: 4),
        Text(rosterLine,
            style: theme.textTheme.bodySmall?.copyWith(
                color: _capReached && _slotsLeft > 0
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant)),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
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
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: (filtered.isEmpty && taken.isEmpty)
                ? Center(
                    child: Text('No matches.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  )
                : ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    children: [
                      ...filtered.map((p) {
                        final selected = _selectedIds.contains(p.id);
                        // Cap: once the open slots are held, unselected rows
                        // disable rather than silently swallowing taps.
                        final enabled = selected || !_capReached;
                        return CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: selected,
                          onChanged: enabled ? (_) => _toggle(p) : null,
                          title: Text(p.name),
                          subtitle: Text('Index ${p.handicapIndex}'),
                        );
                      }),
                      if (taken.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                          child: Text('Already drafted (${taken.length})',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ),
                        ...taken.map((t) => ListTile(
                          dense: true,
                          enabled: false,
                          leading: Icon(Icons.lock_outline, size: 18,
                              color: theme.colorScheme.onSurfaceVariant),
                          title: Text(t.name),
                          subtitle: t.index.isEmpty ? null : Text('Index ${t.index}'),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 8, height: 8,
                                decoration: BoxDecoration(
                                    color: t.colour, shape: BoxShape.circle)),
                            const SizedBox(width: 4),
                            Text('On ${t.teamName}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ]),
                        )),
                      ],
                    ],
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
          onPressed: staged == 0 ? null : _commit,
          child: Text(staged == 0 ? 'Add' : 'Add $staged'),
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
