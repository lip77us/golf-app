/// cup_round_setup_screen.dart
///
/// Phase 3 of the Cup tournament lifecycle.
/// Entry: push with (roundId, tournamentId, roundNumber, courseName).
/// The screen builds foursomes one at a time, enforcing team composition
/// rules, and finishes by calling setupRound + postRyderCupRoundSetup +
/// setTeeTimes on the backend.
///
/// Composition rules
/// -----------------
///   Irish Rumble  → 4 players, ALL from the same team
///   Four Ball    → 4 players (2+2), or 3 players (1+2 / 2+1) — solo side gets a phantom
///   Four Ball Quota→ 4 players (2+2), or 3 players (1+2 / 2+1) — solo side gets a phantom
///   Singles       → 2 OR 4 players, split evenly (1+1 or 2+2)
///
/// For a 4-player Singles group the user additionally pairs each Team-A
/// player with a Team-B player so the scoreboard knows who plays whom.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

// ---------------------------------------------------------------------------
// Game choices (same IDs as the Django backend)
// ---------------------------------------------------------------------------

const _kCupGames = [
  ('nassau',          'Four Ball (Nassau)',        Icons.people),
  ('quota_nassau',    'Four Ball Quota (Nassau)',  Icons.calculate),
  ('irish_rumble',    'Irish Rumble',             Icons.flag),
  ('singles_nassau',  'Singles Nassau (F9/B9/All)', Icons.person),
  ('singles_18',      '18-Hole Singles',          Icons.sports_golf),
];

String _gameLabel(String id) =>
    _kCupGames.firstWhere((g) => g.$1 == id, orElse: () => (id, id, Icons.sports_golf)).$2;

/// Formats a [TimeOfDay] as a zero-padded "HH:MM" string — the only format
/// accepted by the backend's `TimeField` serializer.
String _formatTeeTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';

/// Parses an "HH:MM" or "HH:MM:SS" string back into a [TimeOfDay].  Returns
/// null on any malformed input so the caller can fall back to a sensible
/// default when opening the time picker.
TimeOfDay? _parseTeeTime(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  final parts = s.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return TimeOfDay(hour: h, minute: m);
}

/// Opens the platform time picker and returns the result formatted as
/// "HH:MM", or null if the user cancelled.  Centralised so every entry
/// point produces the same backend-friendly string.
Future<String?> _pickTeeTime(BuildContext context, String? initial) async {
  final result = await showTimePicker(
    context: context,
    initialTime: _parseTeeTime(initial) ?? const TimeOfDay(hour: 8, minute: 0),
  );
  return result == null ? null : _formatTeeTime(result);
}

// ---------------------------------------------------------------------------
// Data holder for one completed foursome draft
// ---------------------------------------------------------------------------

class _FoursomeDraft {
  final String           gameType;
  final List<int>        playerIds;   // in submission order (group1 first, etc.)
  final Map<int, int>    playerTees;  // playerId → teeId
  final String?          teeTime;     // 'HH:MM' or null
  final double           pointValue;  // cup points per segment win (overrides round-level)
  // For 4-player Singles: pairs of (team-A playerId, team-B playerId)
  final List<(int, int)> singlesMatchups;

  const _FoursomeDraft({
    required this.gameType,
    required this.playerIds,
    required this.playerTees,
    this.teeTime,
    this.pointValue = 1.0,
    this.singlesMatchups = const [],
  });
}

// ---------------------------------------------------------------------------
// Main screen
// ---------------------------------------------------------------------------

class CupRoundSetupScreen extends StatefulWidget {
  final int          roundId;
  final int          tournamentId;
  final int          roundNumber;
  final int          courseId;
  final String       courseName;
  /// Game types configured in the wizard for this round (may be empty for
  /// tournaments created before this field was saved).  When non-empty the
  /// game-picker is filtered to only these options; when exactly one game is
  /// in the list it is auto-selected and the picker step is skipped entirely.
  final List<String> availableGames;
  /// Cup point values per game type, set at wizard time.
  /// e.g. {'nassau': 1.0, 'singles': 2.0}
  /// Applied automatically when committing each foursome — no per-foursome
  /// text field is shown when this is non-empty.
  final Map<String, double> gamePointValues;

  const CupRoundSetupScreen({
    super.key,
    required this.roundId,
    required this.tournamentId,
    required this.roundNumber,
    required this.courseId,
    required this.courseName,
    this.availableGames  = const [],
    this.gamePointValues = const {},
  });

  @override
  State<CupRoundSetupScreen> createState() => _CupRoundSetupScreenState();
}

enum _BuildStep { gameType, players, tees, teeTime, matchups, review }

class _CupRoundSetupScreenState extends State<CupRoundSetupScreen> {
  // ── Loaded data ────────────────────────────────────────────────────────────
  TeamTournamentSummary? _cup;
  List<TeeInfo>          _courseTees = [];
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;

  // ── Build state ────────────────────────────────────────────────────────────
  _BuildStep _buildStep = _BuildStep.gameType;

  // Current-foursome draft
  String?        _gameType;
  final Set<int> _selectedIds = {};
  int?           _irishRumbleTeamIdx; // which team (0 or 1) for Irish Rumble
  // Per-player tee selection for the current foursome draft: playerId → teeId
  final Map<int, int> _playerTees = {};
  final _teeTimeCtrl   = TextEditingController();
  // For 4-player singles matchup builder:
  // _matchupA[i] = team-A player paired with _matchupB[i]
  final List<int?> _matchupA = [];
  final List<int?> _matchupB = [];

  // Completed foursomes
  final List<_FoursomeDraft> _foursomes = [];

  // ── Submission state ───────────────────────────────────────────────────────
  bool    _submitting   = false;
  String? _submitError;

  // ── Derived helpers ────────────────────────────────────────────────────────

  ApiClient get _client => context.read<AuthProvider>().client;

  List<CupTeam> get _teams => _cup?.teams ?? [];

  /// Players already assigned to a completed foursome.
  Set<int> get _assignedIds =>
      _foursomes.expand((f) => f.playerIds).toSet();

  /// True when at least one foursome is ready to go.
  /// Unassigned players (sitting out due to uneven singles etc.) are allowed.
  bool get _allPlayersAssigned =>
      _cup != null && _foursomes.isNotEmpty;

  /// Players not placed in any group for this round (sitting out).
  List<CupPlayer> get _sittingOut {
    if (_cup == null) return [];
    return _cup!.teams
        .expand((t) => t.players)
        .where((p) => !_assignedIds.contains(p.id))
        .toList();
  }

  /// Players in [team] not yet assigned to any completed foursome.
  List<CupPlayer> _available(CupTeam team) => team.players
      .where((p) => !_assignedIds.contains(p.id))
      .toList();

  /// Players selected for current foursome, partitioned by team index.
  List<int> _selectedForTeam(int teamIdx) => _selectedIds
      .where((id) => _teamIndexOf(id) == teamIdx)
      .toList();

  int _teamIndexOf(int playerId) {
    for (int i = 0; i < _teams.length; i++) {
      if (_teams[i].players.any((p) => p.id == playerId)) return i;
    }
    return -1;
  }

  String _playerName(int id) {
    for (final t in _teams) {
      final p = t.players.where((p) => p.id == id).firstOrNull;
      if (p != null) return p.name;
    }
    return 'Player $id';
  }

  // ── Game filtering ─────────────────────────────────────────────────────────

  /// Games to show in the picker, filtered to the round's game plan.
  /// Falls back to the full list if no plan was saved (older tournaments).
  List<(String, String, IconData)> get _filteredGames {
    final avail = widget.availableGames;
    if (avail.isEmpty) return _kCupGames;
    return _kCupGames.where((g) => avail.contains(g.$1)).toList();
  }

  // ── Validation for current builder step ────────────────────────────────────

  bool get _canProceed {
    switch (_buildStep) {
      case _BuildStep.gameType:
        return _gameType != null;
      case _BuildStep.players:
        return _playersValid;
      case _BuildStep.tees:
        // Every selected player must have a tee chosen
        return _selectedIds.every((id) => _playerTees.containsKey(id));
      case _BuildStep.teeTime:
        return true; // optional
      case _BuildStep.matchups:
        return _matchupA.every((v) => v != null) &&
               _matchupB.every((v) => v != null);
      case _BuildStep.review:
        return _allPlayersAssigned;
    }
  }

  bool get _playersValid {
    final n = _selectedIds.length;
    switch (_gameType) {
      case 'irish_rumble':
        // exactly 4 players, all from one team
        if (n != 4) return false;
        final teamIdx = _irishRumbleTeamIdx;
        if (teamIdx == null) return false;
        return _selectedIds.every((id) => _teamIndexOf(id) == teamIdx);
      case 'singles_nassau':
      case 'singles_18':
        // 2 players (1+1), 3 players (1+2 or 2+1), or 4 players (2+2)
        if (n != 2 && n != 3 && n != 4) return false;
        final a = _selectedForTeam(0).length;
        final b = _selectedForTeam(1).length;
        if (n == 2) return a == 1 && b == 1;
        if (n == 3) return (a == 1 && b == 2) || (a == 2 && b == 1);
        return a == 2 && b == 2;
      default:
        // nassau / quota_nassau: 4 players (2+2) or 3 players (1+2 / 2+1 — phantom fills the gap)
        if (n != 4 && n != 3) return false;
        final a = _selectedForTeam(0).length;
        final b = _selectedForTeam(1).length;
        if (n == 4) return a == 2 && b == 2;
        // 3 players: one team has 1 real player, other has 2 — phantom fills solo side
        return (a == 1 && b == 2) || (a == 2 && b == 1);
    }
  }

  bool get _needsMatchupStep =>
      (_gameType == 'singles_nassau' || _gameType == 'singles_18') &&
      (_selectedIds.length == 4 || _selectedIds.length == 3);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _teeTimeCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _client.getTeamTournament(widget.tournamentId),
        _client.getTees(),
      ]);
      final cup  = results[0] as TeamTournamentSummary;
      final tees = (results[1] as List<TeeInfo>)
          .where((t) => t.course.id == widget.courseId)
          .toList()
        ..sort((a, b) => a.sortPriority.compareTo(b.sortPriority));

      // Guard: if no team has any players, the draft hasn't been done yet.
      final hasPlayers = cup.teams.any((t) => t.players.isNotEmpty);
      if (!hasPlayers && mounted) {
        setState(() {
          _error = 'No players have been assigned to teams yet.\n\n'
                   'Go back and use "Cup Draft & Teams" on the tournament '
                   'card to assign players before setting up a round.';
          _networkError = false;
        });
        return;
      }

      if (mounted) {
        setState(() {
          _cup        = cup;
          _courseTees = tees;
          // Auto-select game type if only one option for this round
          if (widget.availableGames.length == 1) {
            _gameType  = widget.availableGames.first;
            _buildStep = _BuildStep.players;
          }
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

  // ── Navigation within builder ──────────────────────────────────────────────

  void _nextStep() {
    switch (_buildStep) {
      case _BuildStep.gameType:
        setState(() {
          _selectedIds.clear();
          _playerTees.clear();
          _irishRumbleTeamIdx = null;
          _buildStep = _BuildStep.players;
        });
      case _BuildStep.players:
        // Pre-fill tees: pick the first tee matching each player's sex, or
        // the first tee if no sex match exists.
        _prefillTees();
        setState(() => _buildStep = _BuildStep.tees);
      case _BuildStep.tees:
        setState(() {
          _teeTimeCtrl.clear();
          _buildStep = _BuildStep.teeTime;
        });
      case _BuildStep.teeTime:
        if (_needsMatchupStep) {
          _initMatchups();
          setState(() => _buildStep = _BuildStep.matchups);
        } else {
          _commitFoursome();
        }
      case _BuildStep.matchups:
        _commitFoursome();
      case _BuildStep.review:
        break;
    }
  }

  void _prevStep() {
    switch (_buildStep) {
      case _BuildStep.gameType:
        if (_foursomes.isEmpty) {
          Navigator.of(context).pop();
        } else {
          setState(() => _buildStep = _BuildStep.review);
        }
      case _BuildStep.players:
        // If the game was auto-selected (only 1 option), don't go back to
        // the (skipped) game picker — pop the screen instead.
        if (widget.availableGames.length == 1 && _foursomes.isEmpty) {
          Navigator.of(context).pop();
        } else if (widget.availableGames.length == 1) {
          setState(() => _buildStep = _BuildStep.review);
        } else {
          setState(() => _buildStep = _BuildStep.gameType);
        }
      case _BuildStep.tees:
        setState(() => _buildStep = _BuildStep.players);
      case _BuildStep.teeTime:
        setState(() => _buildStep = _BuildStep.tees);
      case _BuildStep.matchups:
        setState(() => _buildStep = _BuildStep.teeTime);
      case _BuildStep.review:
        _startNewFoursome();
    }
  }

  void _prefillTees() {
    if (_courseTees.isEmpty) return;
    final defaultTee = _courseTees.first;
    for (final id in _selectedIds) {
      _playerTees.putIfAbsent(id, () => defaultTee.id);
    }
    setState(() {});
  }

  void _initMatchups() {
    final teamA = _selectedForTeam(0);
    final teamB = _selectedForTeam(1);
    _matchupA.clear();
    _matchupB.clear();

    if (teamA.length == 1 && teamB.length == 2) {
      // A1 plays both B1 and B2
      _matchupA.add(teamA[0]);
      _matchupA.add(teamA[0]);
      _matchupB.add(teamB[0]);
      _matchupB.add(teamB[1]);
    } else if (teamA.length == 2 && teamB.length == 1) {
      // A1 and A2 both play B1
      _matchupA.add(teamA[0]);
      _matchupA.add(teamA[1]);
      _matchupB.add(teamB[0]);
      _matchupB.add(teamB[0]);
    } else {
      // Even teams (1+1 or 2+2)
      for (int i = 0; i < teamA.length; i++) {
        _matchupA.add(teamA[i]);
        _matchupB.add(teamB.length > i ? teamB[i] : null);
      }
    }
  }

  void _commitFoursome() {
    final teeTime = _teeTimeCtrl.text.trim().isEmpty
        ? null
        : _teeTimeCtrl.text.trim();

    List<(int, int)> matchups = [];
    if (_needsMatchupStep || _buildStep == _BuildStep.matchups) {
      matchups = List.generate(
        _matchupA.length,
        (i) => (_matchupA[i]!, _matchupB[i]!),
      );
    }

    // Order: for Irish Rumble all same team; for others interleave A/B
    List<int> ordered;
    if (_gameType == 'irish_rumble') {
      ordered = _selectedIds.toList();
    } else if ((_gameType == 'singles_nassau' || _gameType == 'singles_18') && matchups.isNotEmpty) {
      // Interleave matchup pairs, deduplicating so a player who appears in
      // two matches (uneven teams) is only in the foursome once.
      final seen = <int>{};
      ordered = matchups
          .expand((m) => [m.$1, m.$2])
          .where((id) => seen.add(id))
          .toList();
    } else {
      // Interleave team A and B players
      final a = _selectedForTeam(0);
      final b = _selectedForTeam(1);
      ordered = [];
      for (int i = 0; i < a.length || i < b.length; i++) {
        if (i < a.length) ordered.add(a[i]);
        if (i < b.length) ordered.add(b[i]);
      }
    }

    // Use wizard-configured point value for this game type, falling back to 1.0
    final pointValue = widget.gamePointValues[_gameType!] ?? 1.0;

    setState(() {
      _foursomes.add(_FoursomeDraft(
        gameType       : _gameType!,
        playerIds      : ordered,
        playerTees     : Map.from(_playerTees),
        teeTime        : teeTime,
        pointValue     : pointValue,
        singlesMatchups: matchups,
      ));
      _buildStep = _BuildStep.review;
    });
  }

  void _startNewFoursome() {
    setState(() {
      // If only one game available, keep it auto-selected and go to players
      final autoGame = widget.availableGames.length == 1
          ? widget.availableGames.first
          : null;
      _gameType           = autoGame;
      _selectedIds.clear();
      _playerTees.clear();
      _irishRumbleTeamIdx = null;
      _teeTimeCtrl.clear();
      _matchupA.clear();
      _matchupB.clear();
      _buildStep = autoGame != null ? _BuildStep.players : _BuildStep.gameType;
    });
  }

  void _removeFoursome(int idx) {
    setState(() => _foursomes.removeAt(idx));
    if (_foursomes.isEmpty) _startNewFoursome();
  }

  Future<void> _editFoursomeTeeTime(int idx) async {
    final draft  = _foursomes[idx];
    final picked = await _pickTeeTime(context, draft.teeTime);
    if (picked == null) return;     // user cancelled — leave value as-is
    setState(() {
      _foursomes[idx] = _FoursomeDraft(
        gameType        : draft.gameType,
        playerIds       : draft.playerIds,
        playerTees      : draft.playerTees,
        teeTime         : picked,
        pointValue      : draft.pointValue,
        singlesMatchups : draft.singlesMatchups,
      );
    });
  }

  void _clearFoursomeTeeTime(int idx) {
    final draft = _foursomes[idx];
    setState(() {
      _foursomes[idx] = _FoursomeDraft(
        gameType        : draft.gameType,
        playerIds       : draft.playerIds,
        playerTees      : draft.playerTees,
        teeTime         : null,
        pointValue      : draft.pointValue,
        singlesMatchups : draft.singlesMatchups,
      );
    });
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    setState(() { _submitting = true; _submitError = null; });
    try {
      // Build flat ordered player list for setupRound.
      // Players from each foursome appear in order; backend groups first-N
      // into group 1, next-N into group 2, etc. (randomise=false).
      // Singles groups may have 2 real players → backend adds 2 phantoms.
      final flatPlayers = <Map<String, int>>[];
      for (final f in _foursomes) {
        for (final pid in f.playerIds) {
          final entry = <String, int>{'player_id': pid};
          final teeId = f.playerTees[pid];
          if (teeId != null) entry['tee_id'] = teeId;
          flatPlayers.add(entry);
        }
      }

      // 1. Call setupRound — creates foursomes and marks round in_progress.
      final fullRound = await _client.setupRound(
        widget.roundId,
        players        : flatPlayers,
        randomise      : false,
        autoSetupGames : false,
      );

      // 2. Match our draft foursomes to the created foursomes by index.
      //    The backend preserves submission order, so index aligns.
      final teams = _cup!.teams;
      final team1Id = teams.isNotEmpty ? teams[0].teamId : null;
      final team2Id = teams.length > 1  ? teams[1].teamId : null;

      final foursomesPayload = <Map<String, dynamic>>[];
      for (int i = 0; i < _foursomes.length && i < fullRound.foursomes.length; i++) {
        final draft = _foursomes[i];
        final fs    = fullRound.foursomes[i];
        foursomesPayload.add({
          'foursome_id' : fs.id,
          'game_type'   : draft.gameType,
          'point_value' : draft.pointValue,
          if (team1Id != null) 'team1_id': team1Id,
          if (team2Id != null) 'team2_id': team2Id,
          if (draft.singlesMatchups.isNotEmpty)
            'singles_matchups': draft.singlesMatchups
                .map((m) => {'player1_id': m.$1, 'player2_id': m.$2})
                .toList(),
        });
      }

      await _client.postRyderCupRoundSetup(
        widget.roundId,
        nassauPointValue : 1.0,
        pointMultiplier  : 1.0,
        foursomes        : foursomesPayload,
      );

      // 3. Set tee times where provided.
      final teeEntries = <Map<String, dynamic>>[];
      for (int i = 0; i < _foursomes.length && i < fullRound.foursomes.length; i++) {
        final t = _foursomes[i].teeTime;
        if (t != null) {
          teeEntries.add({
            'group_number': fullRound.foursomes[i].groupNumber,
            'tee_time'    : t,
          });
        }
      }
      if (teeEntries.isNotEmpty) {
        await _client.setTeeTimes(widget.roundId, teeEntries);
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() {
        _submitError = friendlyError(e);
        _submitting  = false;
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _prevStep),
        title: Text('Round ${widget.roundNumber} · ${widget.courseName}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: _buildStep == _BuildStep.review
                ? 1.0
                : (_BuildStep.values.indexOf(_buildStep) + 1) /
                  (_BuildStep.values.length),
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: _error!, isNetwork: _networkError, onRetry: _load)
              : _buildBody(),
      bottomNavigationBar: (_loading || _error != null)
          ? null
          : _buildBottomBar(),
    );
  }

  Widget _buildBody() {
    switch (_buildStep) {
      case _BuildStep.gameType:  return _GameTypePicker(
        selected        : _gameType,
        games           : _filteredGames,
        onPick          : (g) => setState(() => _gameType = g),
        foursomeNumber  : _foursomes.length + 1,
        gamePointValues : widget.gamePointValues,
      );
      case _BuildStep.players:   return _PlayerPicker(
        gameType           : _gameType!,
        teams              : _teams,
        selectedIds        : _selectedIds,
        assignedIds        : _assignedIds,
        irishRumbleTeamIdx : _irishRumbleTeamIdx,
        onToggle           : (id) => setState(() {
          _selectedIds.contains(id)
              ? _selectedIds.remove(id)
              : _selectedIds.add(id);
        }),
        onPickIrishTeam    : (idx) => setState(() {
          _irishRumbleTeamIdx = idx;
          // Remove any selected players not on this team
          _selectedIds.removeWhere((id) => _teamIndexOf(id) != idx);
        }),
      );
      case _BuildStep.teeTime:   return _TeeTimePicker(
        ctrl          : _teeTimeCtrl,
        foursomeNumber: _foursomes.length + 1,
        gameType      : _gameType!,
        playerIds     : _selectedIds.toList(),
        playerName    : _playerName,
      );
      case _BuildStep.tees:      return _TeePicker(
        playerIds  : _selectedIds.toList(),
        playerName : _playerName,
        courseTees : _courseTees,
        playerTees : _playerTees,
        onPickTee  : (pid, teeId) => setState(() => _playerTees[pid] = teeId),
        gameType   : _gameType!,
        foursomeNumber: _foursomes.length + 1,
      );
      case _BuildStep.matchups:  return _MatchupBuilder(
        matchupA     : _matchupA,
        matchupB     : _matchupB,
        teamAPlayers : _selectedForTeam(0),
        teamBPlayers : _selectedForTeam(1),
        teamAName    : _teams.isNotEmpty ? _teams[0].name : 'Team A',
        teamBName    : _teams.length > 1 ? _teams[1].name : 'Team B',
        playerName   : _playerName,
        onSwapB      : (matchIdx, playerId) =>
            setState(() => _matchupB[matchIdx] = playerId),
        onSwapA      : (matchIdx, playerId) =>
            setState(() => _matchupA[matchIdx] = playerId),
      );
      case _BuildStep.review:    return _ReviewPage(
        foursomes      : _foursomes,
        playerName     : _playerName,
        onRemove       : _removeFoursome,
        onEditTeeTime  : _editFoursomeTeeTime,
        onClearTeeTime : _clearFoursomeTeeTime,
        onAddAnother   : _startNewFoursome,
        submitError    : _submitError,
        sittingOut     : _sittingOut,
      );
    }
  }

  Widget _buildBottomBar() {
    final isReview = _buildStep == _BuildStep.review;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          OutlinedButton(
            onPressed: _prevStep,
            child: const Text('Back'),
          ),
          const Spacer(),
          if (isReview)
            FilledButton.icon(
              onPressed: (_allPlayersAssigned && !_submitting) ? _submit : null,
              icon: _submitting
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Colors.white))
                  : const Icon(Icons.flag),
              label: const Text('Start Round'),
            )
          else
            FilledButton(
              onPressed: _canProceed ? _nextStep : null,
              child: Text(_buildStep == _BuildStep.teeTime ? 'Add Group' : 'Next'),
            ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Step A — Game Type Picker
// ===========================================================================

class _GameTypePicker extends StatelessWidget {
  final String?              selected;
  final List<(String, String, IconData)> games;
  final ValueChanged<String> onPick;
  final int                  foursomeNumber;
  /// Point value for each game type (from wizard config). Shown read-only
  /// so the organiser can confirm what was set at creation time.
  final Map<String, double>  gamePointValues;

  const _GameTypePicker({
    required this.selected,
    required this.games,
    required this.onPick,
    required this.foursomeNumber,
    this.gamePointValues = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Group $foursomeNumber — Game Format',
            style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('What game will this group play?',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
        const SizedBox(height: 24),
        ...games.map((g) {
          final isSelected = selected == g.$1;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              onTap: () => onPick(g.$1),
              borderRadius: BorderRadius.circular(12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(children: [
                  Icon(g.$3,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 16),
                  Expanded(child: Text(g.$2,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : null))),
                  if (isSelected)
                    Icon(Icons.check_circle,
                        color: theme.colorScheme.primary),
                ]),
              ),
            ),
          );
        }),

        // ── Cup Points reminder (read-only, set at wizard time) ──────────
        if (gamePointValues.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          Text('Points per win (from tournament setup)',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: gamePointValues.entries.map((e) {
              final label = _kCupGames
                  .firstWhere((g) => g.$1 == e.key,
                      orElse: () => (e.key, e.key, Icons.sports_golf))
                  .$2;
              final pts = e.value % 1 == 0
                  ? e.value.toInt().toString()
                  : e.value.toString();
              return Chip(
                label: Text('$label · ${pts}pt',
                    style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}

// ===========================================================================
// Step B — Player Picker (team-enforced)
// ===========================================================================
// NOTE: Step C (Tee Picker) is defined further below, after _PlayerPicker.
// ===========================================================================

class _PlayerPicker extends StatelessWidget {
  final String       gameType;
  final List<CupTeam> teams;
  final Set<int>     selectedIds;
  final Set<int>     assignedIds;
  final int?         irishRumbleTeamIdx;
  final ValueChanged<int> onToggle;
  final ValueChanged<int> onPickIrishTeam;

  const _PlayerPicker({
    required this.gameType,
    required this.teams,
    required this.selectedIds,
    required this.assignedIds,
    required this.irishRumbleTeamIdx,
    required this.onToggle,
    required this.onPickIrishTeam,
  });

  String get _rule {
    switch (gameType) {
      case 'irish_rumble':
        return 'Pick 4 players from the same team.';
      case 'singles_nassau':
      case 'singles_18':
        return 'Pick 1–2 per team. Uneven (1 vs 2) — the solo player plays two matches.';
      default:
        return 'Pick 2 per team (4 total), or 1 vs 2 — the solo side gets a phantom partner.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      // Game name + rule hint
      Container(
        color: theme.colorScheme.surfaceContainerLow,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_gameLabel(gameType),
                style: theme.textTheme.labelLarge?.copyWith(
                    color     : theme.colorScheme.primary,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(_rule,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),

      // Irish Rumble: team selector first
      if (gameType == 'irish_rumble') ...[
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text('Team: ', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            ...teams.asMap().entries.map((e) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(e.value.name),
                selected: irishRumbleTeamIdx == e.key,
                onSelected: (_) => onPickIrishTeam(e.key),
              ),
            )),
          ]),
        ),
        const SizedBox(height: 8),
      ],

      // Player lists
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: teams.asMap().entries.map((teamEntry) {
            final teamIdx  = teamEntry.key;
            final team     = teamEntry.value;

            // For Irish Rumble, only show the selected team
            if (gameType == 'irish_rumble' &&
                irishRumbleTeamIdx != null &&
                irishRumbleTeamIdx != teamIdx) {
              return const SizedBox.shrink();
            }

            final available = team.players
                .where((p) => !assignedIds.contains(p.id))
                .toList();

            if (available.isEmpty && gameType == 'irish_rumble') {
              return const SizedBox.shrink();
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: Text(team.name,
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                ),
                ...available.map((p) {
                  final sel = selectedIds.contains(p.id);
                  return CheckboxListTile(
                    dense: true,
                    value: sel,
                    title: Text(p.name),
                    onChanged: (_) => onToggle(p.id),
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                }),
                if (available.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 8),
                    child: Text('All players assigned.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontStyle: FontStyle.italic)),
                  ),
              ],
            );
          }).toList(),
        ),
      ),

      // Running count
      Container(
        color: theme.colorScheme.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Text('Selected: ${selectedIds.length}',
              style: theme.textTheme.bodySmall),
          const Spacer(),
          if (gameType != 'irish_rumble')
            ...teams.asMap().entries.map((e) {
              final cnt = selectedIds
                  .where((id) => teams[e.key].players
                      .any((p) => p.id == id))
                  .length;
              return Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text('${e.value.name}: $cnt',
                    style: theme.textTheme.bodySmall),
              );
            }),
        ]),
      ),
    ]);
  }
}

// ===========================================================================
// Step C — Tee Picker (per-player tee selection)
// ===========================================================================

class _TeePicker extends StatelessWidget {
  final List<int>            playerIds;
  final String Function(int) playerName;
  final List<TeeInfo>        courseTees;
  final Map<int, int>        playerTees;    // playerId → teeId
  final void Function(int pid, int teeId) onPickTee;
  final String               gameType;
  final int                  foursomeNumber;

  const _TeePicker({
    required this.playerIds,
    required this.playerName,
    required this.courseTees,
    required this.playerTees,
    required this.onPickTee,
    required this.gameType,
    required this.foursomeNumber,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Group $foursomeNumber — Tee Selection',
            style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('${_gameLabel(gameType)} · ${playerIds.length} players',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
        const SizedBox(height: 24),

        if (courseTees.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No tees found for this course. '
                'Please add tees via the course management screen.'),
          )
        else
          ...playerIds.map((pid) {
            final selectedTeeId = playerTees[pid];
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(children: [
                  Expanded(
                    child: Text(playerName(pid),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: selectedTeeId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense      : true,
                        border       : OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      items: courseTees.map((t) => DropdownMenuItem(
                        value: t.id,
                        child: Text(t.teeName,
                            overflow: TextOverflow.ellipsis),
                      )).toList(),
                      onChanged: (id) {
                        if (id != null) onPickTee(pid, id);
                      },
                    ),
                  ),
                ]),
              ),
            );
          }),
      ],
    );
  }
}

// ===========================================================================
// Step D — Tee Time
// ===========================================================================

class _TeeTimePicker extends StatefulWidget {
  final TextEditingController ctrl;
  final int                   foursomeNumber;
  final String                gameType;
  final List<int>             playerIds;
  final String Function(int)  playerName;

  const _TeeTimePicker({
    required this.ctrl,
    required this.foursomeNumber,
    required this.gameType,
    required this.playerIds,
    required this.playerName,
  });

  @override
  State<_TeeTimePicker> createState() => _TeeTimePickerState();
}

class _TeeTimePickerState extends State<_TeeTimePicker> {
  Future<void> _pick() async {
    final picked = await _pickTeeTime(context, widget.ctrl.text);
    if (picked != null) {
      setState(() { widget.ctrl.text = picked; });
    }
  }

  void _clear() {
    setState(() { widget.ctrl.clear(); });
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final current = widget.ctrl.text.trim();
    final hasValue = current.isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Group ${widget.foursomeNumber} — Tee Time',
            style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('${_gameLabel(widget.gameType)} · '
             '${widget.playerIds.length} players',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
        const SizedBox(height: 8),
        Text(widget.playerIds.map(widget.playerName).join(', '),
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 24),

        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.schedule),
              label: Text(
                hasValue ? 'Tee time: $current' : 'Set tee time (optional)',
              ),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 16),
              ),
            ),
          ),
          if (hasValue) ...[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear tee time',
              onPressed: _clear,
            ),
          ],
        ]),
        const SizedBox(height: 12),
        Text('Leave blank if tee times aren\'t set yet.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

// ===========================================================================
// Step E — Singles Matchup Builder (4-player Singles only)
// ===========================================================================

class _MatchupBuilder extends StatelessWidget {
  final List<int?>       matchupA;
  final List<int?>       matchupB;
  final List<int>        teamAPlayers;
  final List<int>        teamBPlayers;
  final String           teamAName;
  final String           teamBName;
  final String Function(int) playerName;
  final void Function(int matchIdx, int playerId) onSwapB;
  final void Function(int matchIdx, int playerId)? onSwapA;

  const _MatchupBuilder({
    required this.matchupA,
    required this.matchupB,
    required this.teamAPlayers,
    required this.teamBPlayers,
    required this.teamAName,
    required this.teamBName,
    required this.playerName,
    required this.onSwapB,
    this.onSwapA,
  });

  // Is one side "solo" (same player ID in all matchup slots)?
  bool get _aIsSolo => teamAPlayers.length == 1;
  bool get _bIsSolo => teamBPlayers.length == 1;
  bool get _isUneven => _aIsSolo || _bIsSolo;
  String get _soloName => _aIsSolo
      ? playerName(teamAPlayers.first)
      : playerName(teamBPlayers.first);
  String get _soloTeamName => _aIsSolo ? teamAName : teamBName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Define Matchups', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          _isUneven
              ? 'Uneven group — $_soloName ($_soloTeamName) plays 2 matches.'
              : 'Pair each $teamAName player with a $teamBName player.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),

        // Banner for uneven groups
        if (_isUneven) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$_soloName will use their single scorecard for both matches. '
                  'They can earn points in each match independently.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ]),
          ),
        ],

        const SizedBox(height: 24),

        ...List.generate(matchupA.length, (i) {
          final aId = matchupA[i];
          final bId = matchupB[i];

          Widget aWidget = _aIsSolo
              // Solo A player — fixed, show as text
              ? Text(aId != null ? playerName(aId) : '—',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600))
              // Multiple A players — dropdown (for 2v1 swap)
              : (onSwapA != null && teamAPlayers.length > 1)
                  ? DropdownButton<int>(
                      value: aId,
                      isExpanded: true,
                      hint: Text('Pick $teamAName player'),
                      items: teamAPlayers.map((id) => DropdownMenuItem(
                        value: id,
                        child: Text(playerName(id)),
                      )).toList(),
                      onChanged: (id) { if (id != null) onSwapA!(i, id); },
                    )
                  : Text(aId != null ? playerName(aId) : '—',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600));

          Widget bWidget = _bIsSolo
              // Solo B player — fixed, show as text
              ? Text(bId != null ? playerName(bId) : '—',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600))
              // Multiple B players — dropdown
              : DropdownButton<int>(
                  value: bId,
                  isExpanded: true,
                  hint: Text('Pick $teamBName player'),
                  items: teamBPlayers.map((id) => DropdownMenuItem(
                    value: id,
                    child: Text(playerName(id)),
                  )).toList(),
                  onChanged: (id) { if (id != null) onSwapB(i, id); },
                );

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isUneven)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('Match ${i + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold)),
                    ),
                  Row(children: [
                    Expanded(child: aWidget),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('vs',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    Expanded(child: bWidget),
                  ]),
                ],
              ),
            ),
          );
        }),
      ]),
    );
  }
}

// ===========================================================================
// Step F — Review page
// ===========================================================================

class _ReviewPage extends StatelessWidget {
  final List<_FoursomeDraft> foursomes;
  final String Function(int) playerName;
  final void Function(int)   onRemove;
  final Future<void> Function(int) onEditTeeTime;
  final void Function(int)   onClearTeeTime;
  final VoidCallback         onAddAnother;
  final String?              submitError;
  final List<CupPlayer>      sittingOut;

  const _ReviewPage({
    required this.foursomes,
    required this.playerName,
    required this.onRemove,
    required this.onEditTeeTime,
    required this.onClearTeeTime,
    required this.onAddAnother,
    this.submitError,
    this.sittingOut = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Groups for this round',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Tap "Start Round" when all groups are ready.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),

        ...foursomes.asMap().entries.map((e) {
          final i     = e.key;
          final draft = e.value;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: CircleAvatar(
                child: Text('${i + 1}'),
              ),
              title: Text(_gameLabel(draft.gameType),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    draft.playerIds.map(playerName).join(', ') +
                    ((draft.playerIds.length == 3 &&
                        (draft.gameType == 'nassau' || draft.gameType == 'quota_nassau'))
                        ? ' + Phantom'
                        : ''),
                  ),
                  // Tee time row: tap to edit (opens time picker); a clear
                  // button appears next to it when a time is already set.
                  InkWell(
                    onTap: () => onEditTeeTime(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        Icon(Icons.schedule, size: 14,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          draft.teeTime != null
                              ? 'Tee: ${draft.teeTime}'
                              : 'Set tee time',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: draft.teeTime != null
                                ? null
                                : theme.colorScheme.primary,
                            decoration: draft.teeTime != null
                                ? null
                                : TextDecoration.underline,
                          ),
                        ),
                        if (draft.teeTime != null) ...[
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () => onClearTeeTime(i),
                            child: Icon(Icons.close, size: 14,
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ]),
                    ),
                  ),
                  Text(
                    '${draft.pointValue % 1 == 0 ? draft.pointValue.toInt() : draft.pointValue} pt${draft.pointValue == 1.0 ? '' : 's'} per win',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: draft.pointValue != 1.0
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => onRemove(i),
                tooltip: 'Remove group',
              ),
              isThreeLine: true,
            ),
          );
        }),

        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onAddAnother,
          icon: const Icon(Icons.add),
          label: const Text('Add another group'),
        ),

        // Sitting-out players (e.g. leftover from uneven singles)
        if (sittingOut.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.event_busy,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text('Sitting out this round',
                      style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurfaceVariant)),
                ]),
                const SizedBox(height: 6),
                Text(
                  sittingOut.map((p) => p.name).join(', '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],

        if (submitError != null) ...[
          const SizedBox(height: 16),
          Text(submitError!,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}
