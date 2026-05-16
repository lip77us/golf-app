import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../utils/grouping.dart';
import '../widgets/error_view.dart';
import '../widgets/net_double_bogey_card.dart';
import '../widgets/payout_config_field.dart';
import 'irish_rumble_setup_screen.dart'; // also exports LowNetSetupScreen
import 'pink_ball_setup_screen.dart';
import 'ryder_cup_draft_screen.dart';

// Group badge colours — cycles for > 4 foursomes
const _groupColors = [
  Color(0xFF1565C0), // blue
  Color(0xFF2E7D32), // green
  Color(0xFFB71C1C), // red
  Color(0xFFE65100), // orange
  Color(0xFF6A1B9A), // purple
];

// ---------------------------------------------------------------------------
// Per-round draft for additional rounds (2..N) in a multi-round tournament
// ---------------------------------------------------------------------------

class _RoundDraft {
  int?     courseId;
  DateTime date;
  _RoundDraft({this.courseId, DateTime? date}) : date = date ?? DateTime.now();
}

// ---------------------------------------------------------------------------
// Wizard entry point
// ---------------------------------------------------------------------------

class NewRoundWizard extends StatefulWidget {
  const NewRoundWizard({super.key});

  @override
  State<NewRoundWizard> createState() => _NewRoundWizardState();
}

class _NewRoundWizardState extends State<NewRoundWizard> {
  // ---- step index ----
  int _step = 0;

  // Cup tournaments use a shorter wizard (steps 0-3 only) that ends at the
  // game plan.  Team assignment and round setup happen later from the
  // tournament card.  _isCupTournament and _totalSteps are computed getters.
  bool get _isCupTournament =>
      _createNewTournament &&
      _tournamentActiveGames.contains(GameIds.teamCup);
  // Cup: 5 steps (0=tournament, 1=courses, 2=cup design, 3=game plan,
  //              4=review → create, 5=post-create confirmation).
  // Non-cup: 6 steps (adds players, groups, games before review).
  int  get _totalSteps => _isCupTournament ? 5 : 6;

  // ---- Step 0: Tournament ----
  bool              _createNewTournament = true;
  Tournament?       _existingTournament;
  final _nameCtrl   = TextEditingController();
  int               _numRounds           = 1;
  /// Additional round drafts for rounds 2..N (length = _numRounds - 1).
  List<_RoundDraft> _additionalRounds    = [];
  /// Tournament-level games (e.g. low_net championship).
  final Set<String> _tournamentActiveGames = {};

  // ---- Cup Design (step 2 for cup tournaments) ----
  // Team NAMES are set later during Phase 2 (team roster screen).
  // The wizard only captures the cup name and team count here.
  final _cupNameCtrl = TextEditingController(text: 'Ryder Cup');
  int   _cupTeamCount = 2;

  // ---- Cup Round Games (step 3 for cup tournaments) ----
  // Per-round game plan: round index (0 = round 1, 1 = round 2, …) →
  // Cup game types per round.  Each unique game type appears once; the count
  // of how many groups play it is in _roundCupGroupCounts.
  // e.g. {0: ['nassau', 'irish_rumble']}
  final Map<int, List<String>>        _roundCupGames       = {};
  // Cup point values per game type per round: round index → game_type → pts.
  // e.g. {0: {'nassau': 1.0, 'singles_nassau': 2.0}}  Default 1.0.
  final Map<int, Map<String, double>> _roundCupPoints      = {};
  // Number of groups playing each game type per round.
  // e.g. {0: {'nassau': 2, 'irish_rumble': 2}}
  final Map<int, Map<String, int>>    _roundCupGroupCounts = {};

  // ---- Step 1: Round details (course, dates, handicap — NO game selection) ----
  List<CourseInfo>  _courses        = [];
  int?              _selectedCourseId;
  DateTime          _date           = DateTime.now();
  String            _handicapMode   = 'net';
  int               _netPercent     = 100;
  bool              _netMaxDoubleBogey = true;

  // ---- Step 4: Side-game selection + buy-in config ----
  final Set<String> _activeGames = {}; // no defaults — user picks

  // Stroke Play Championship entry fee / payouts entered in Step 4.
  // Applied automatically to the tournament during _createRound().
  int       _lowNetEntryFee      = 0;
  int       _lowNetNumPayouts    = 3;
  List<int> _lowNetPayouts       = const [0, 0, 0, 0];

  // Match Play entry fee / payouts entered in Step 4.
  // Applied automatically to all groups during _createRound().
  int       _matchPlayEntryFee       = 0;
  int       _matchPlayNumPayouts     = 3;
  List<int> _matchPlayPayouts        = const [0, 0, 0, 0];
  // Tracks whether we auto-configured match play so Step 6 can skip it.
  bool      _matchPlayStep6Configured = false;

  // ---- Step 2: Players ----
  List<PlayerProfile> _allPlayers = [];
  final Set<int>      _selectedIds = {};
  String              _search = '';

  // ---- Step 3: Drag-and-drop group assignment + per-player tee ----
  List<int>           _orderedPlayerIds = [];
  Map<int, TeeInfo?>  _playerTees       = {};

  // ---- Step 5: Review / create ----
  bool    _creating    = false;
  String? _createError;

  // ---- Step 6: Game setup (shown after round is created) ----
  Round? _createdRound;
  int?   _createdTournamentId;

  // ---- reference data ----
  List<TeeInfo>    _tees        = [];
  List<Tournament> _tournaments = [];
  bool             _dataLoading = true;
  String?          _dataError;

  // ---- form keys ----
  final _step0Key = GlobalKey<FormState>();
  final _step1Key = GlobalKey<FormState>();

  // ---- derived helpers ----

  List<TeeInfo> get _courseTees => _selectedCourseId == null
      ? []
      : _tees.where((t) => t.course.id == _selectedCourseId).toList();

  CourseInfo? get _selectedCourse =>
      _courses.where((c) => c.id == _selectedCourseId).firstOrNull;

  List<PlayerProfile> get _orderedPlayers => _orderedPlayerIds
      .map((id) => _allPlayers.firstWhere((p) => p.id == id))
      .toList();

  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(() => setState(() {}));
    _loadReferenceData();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cupNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadReferenceData() async {
    setState(() { _dataLoading = true; _dataError = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final results = await Future.wait([
        client.getTournaments(),
        client.getTees(),
        client.getPlayers(),
      ]);
      if (!mounted) return;

      final rawTees = results[1] as List<TeeInfo>;
      // Sort tees: lower sort_priority first; within same priority, M < null < W
      int sexRank(String? s) => s == 'M' ? 0 : (s == null ? 1 : 2);
      final tees = rawTees
        ..sort((a, b) {
          final pc = a.sortPriority.compareTo(b.sortPriority);
          if (pc != 0) return pc;
          final sc = sexRank(a.sex).compareTo(sexRank(b.sex));
          if (sc != 0) return sc;
          return a.teeName.compareTo(b.teeName);
        });

      // Derive unique courses from tees
      final courseMap = <int, CourseInfo>{};
      for (final t in tees) courseMap[t.course.id] = t.course;
      final courses = courseMap.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      setState(() {
        _tournaments      = results[0] as List<Tournament>;
        _tees             = tees;
        _courses          = courses;
        // No auto-select: leave _selectedCourseId null so the user must
        // explicitly pick a course (avoids surprising defaults like
        // "Augusta National" being pre-filled).
        // Additional round drafts also start with no course pre-selected.
        for (final d in _additionalRounds) {
          d.courseId ??= null; // explicit: remains null until user picks
        }
        _allPlayers       = (results[2] as List<PlayerProfile>)
            .where((p) => !p.isPhantom)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        _dataLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() { _dataError = friendlyError(e); _dataLoading = false; });
      }
    }
  }

  // ---- navigation ----

  bool _canAdvance() {
    final cup = _isCupTournament;
    switch (_step) {
      case 0:
        if (_createNewTournament) {
          if (_nameCtrl.text.trim().isEmpty) return false;
          // Multi-day tournaments require a primary accumulator game.
          if (_numRounds > 1) {
            final hasPrimary =
                _tournamentActiveGames.contains(GameIds.championshipStrokePlay) ||
                _tournamentActiveGames.contains(GameIds.championshipStableford) ||
                _tournamentActiveGames.contains(GameIds.teamCup);
            if (!hasPrimary) return false;
          }
          return true;
        }
        return _existingTournament != null;
      case 1:
        // Course required; no game selection here any more.
        if (_selectedCourseId == null) return false;
        return _additionalRounds.every((d) => d.courseId != null);
      case 2:
        if (cup) return _cupNameCtrl.text.trim().isNotEmpty; // Cup Design
        return _selectedIds.length >= 2;                     // Players (non-cup)
      case 3:
        if (cup) {
          // Per-round game plan — every round must have at least one game.
          if (_roundCupGames.length < _numRounds) return false;
          return _roundCupGames.values.every((g) => g.isNotEmpty);
        }
        // Groups + tees (non-cup)
        return _orderedPlayerIds.isNotEmpty &&
            _orderedPlayerIds.every((id) => _playerTees[id] != null);
      case 4:
        // Cup: Review step (always OK).  Non-cup: side games (always OK).
        return true;
      case 5: return true; // Review (non-cup) / post-create (cup)
      default: return false;
    }
  }

  void _next() {
    if (_step == 0 && !(_step0Key.currentState?.validate() ?? true)) return;
    if (_step == 1 && !(_step1Key.currentState?.validate() ?? true)) return;
    // For non-cup tournaments, _initGroups() must run when leaving the
    // Players step (step 2) so the groups/tees step has an ordered player list.
    // Cup tournaments don't select players in the wizard at all.
    if (!_isCupTournament && _step == 2) _initGroups();
    if (_step < _totalSteps - 1) setState(() => _step++);
    // Note: the post-creation step is _totalSteps; _next() never reaches it.
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
    else Navigator.of(context).pop();
  }

  /// Build/update the ordered player list and per-player tee defaults when
  /// advancing from Step 2 → Step 3.  Preserves existing order and tee
  /// choices for players that are still selected.
  void _initGroups() {
    final newIds = _selectedIds.toList();
    // Keep existing order for players that stayed selected
    final kept  = _orderedPlayerIds.where((id) => newIds.contains(id)).toList();
    final added = newIds.where((id) => !kept.contains(id)).toList();
    _orderedPlayerIds = [...kept, ...added];
    // Assign default tees for newly-added players
    for (final id in added) {
      final player = _allPlayers.firstWhere((p) => p.id == id);
      _playerTees[id] = _defaultTeeForPlayer(player);
    }
    // Remove tees for players that were deselected
    _playerTees.removeWhere((id, _) => !newIds.contains(id));
  }

  /// Pick the best default tee for a player based on sex + sort priority.
  TeeInfo? _defaultTeeForPlayer(PlayerProfile player) {
    if (_courseTees.isEmpty) return null;
    final sorted = List.of(_courseTees)
        ..sort((a, b) => a.sortPriority.compareTo(b.sortPriority));
    // 1. Sex match
    final sexMatch = sorted.where((t) => t.sex == player.sex);
    if (sexMatch.isNotEmpty) return sexMatch.first;
    // 2. Unisex fallback
    final unisex = sorted.where((t) => t.sex == null);
    if (unisex.isNotEmpty) return unisex.first;
    // 3. Any tee
    return sorted.first;
  }

  // ---- create ----

  Future<void> _createRound() async {
    setState(() { _creating = true; _createError = null; });
    try {
      if (_isCupTournament) {
        await _createCupTournament();
      } else {
        await _createCasualOrStandardRound();
      }
    } catch (e) {
      if (mounted) {
        setState(() { _createError = friendlyError(e); _creating = false; });
      }
    }
  }

  // ── Cup path ─────────────────────────────────────────────────────────────
  // Creates the tournament skeleton (all rounds as stubs) + TeamTournament
  // with placeholder team names.  No foursomes or players are set up here —
  // those happen later via "Assign Teams" and "Set Up Round N" on the
  // tournament card.

  Future<void> _createCupTournament() async {
    final client  = context.read<AuthProvider>().client;
    final dateStr = DateFormat('yyyy-MM-dd').format(_date);

    // 1. Create tournament
    final t = await client.createTournament(
      name       : _nameCtrl.text.trim(),
      startDate  : dateStr,
      activeGames: _tournamentActiveGames.toList(),
      totalRounds: _numRounds,
    );
    final tournamentId = t.id;
    if (!mounted) return;

    // 2. Create Round 1 as a stub (no foursomes; will be set up in Phase 3).
    //    Save unique game types, per-game point values, and group counts so
    //    cup_standings_summary can compute total_possible before setup runs.
    final round1Games  = List<String>.from(_roundCupGames[0] ?? []);
    final round1Points = Map<String, double>.from(_roundCupPoints[0] ?? {});
    final round1Counts = Map<String, int>.from(_roundCupGroupCounts[0] ?? {});
    for (final g in round1Games) {
      round1Points.putIfAbsent(g, () => 1.0);
      round1Counts.putIfAbsent(g, () => 1);
    }
    final round1 = await client.createRound(
      tournamentId    : tournamentId,
      courseId        : _selectedCourseId!,
      date            : dateStr,
      activeGames     : round1Games,
      gamePointValues : round1Points,
      cupGroupCounts  : round1Counts,
      roundNumber     : 1,
      handicapMode    : _handicapMode,
      netPercent      : _netPercent,
      netMaxDoubleBogey: _netMaxDoubleBogey,
    );
    if (!mounted) return;

    // 3. Create stub rounds for rounds 2..N
    for (int i = 0; i < _additionalRounds.length; i++) {
      final draft        = _additionalRounds[i];
      final draftDate    = DateFormat('yyyy-MM-dd').format(draft.date);
      final roundGames   = List<String>.from(_roundCupGames[i + 1] ?? []);
      final roundPoints  = Map<String, double>.from(_roundCupPoints[i + 1] ?? {});
      final roundCounts  = Map<String, int>.from(_roundCupGroupCounts[i + 1] ?? {});
      for (final g in roundGames) {
        roundPoints.putIfAbsent(g, () => 1.0);
        roundCounts.putIfAbsent(g, () => 1);
      }
      await client.createRound(
        tournamentId    : tournamentId,
        courseId        : draft.courseId!,
        date            : draftDate,
        activeGames     : roundGames,
        gamePointValues : roundPoints,
        cupGroupCounts  : roundCounts,
        roundNumber     : i + 2,
        handicapMode    : _handicapMode,
        netPercent      : _netPercent,
        netMaxDoubleBogey: _netMaxDoubleBogey,
      );
      if (!mounted) return;
    }

    // 4. Create TeamTournament with placeholder team names.
    //    Real names and player assignments come from the Phase 2 roster screen.
    final placeholderTeams = List.generate(_cupTeamCount, (i) => <String, dynamic>{
      'team_number': i + 1,
      'name'       : 'Team ${i + 1}',
    });
    await client.postTeamTournamentSetup(
      tournamentId,
      cupName        : _cupNameCtrl.text.trim(),
      playersPerTeam : 1,          // placeholder; real value set in Phase 2
      teams          : placeholderTeams,
    );
    if (!mounted) return;

    // 5. Navigate to post-creation confirmation.
    setState(() {
      _createdRound        = round1;
      _createdTournamentId = tournamentId;
      _step                = _totalSteps;   // 5 for cup
      _creating            = false;
    });
  }

  // ── Non-cup path ─────────────────────────────────────────────────────────
  // Full wizard flow: creates tournament + Round 1 with foursomes + any
  // side-game auto-config (same logic as before).

  Future<void> _createCasualOrStandardRound() async {
    final client  = context.read<AuthProvider>().client;
    final dateStr = DateFormat('yyyy-MM-dd').format(_date);
    final games   = _activeGames.toList();

    // 1. Resolve or create tournament
    int? tournamentId;
    if (_createNewTournament) {
      final t = await client.createTournament(
        name       : _nameCtrl.text.trim(),
        startDate  : dateStr,
        activeGames: _tournamentActiveGames.toList(),
        totalRounds: _numRounds,
      );
      tournamentId = t.id;
    } else {
      tournamentId = _existingTournament?.id;
    }

    // 1b. Auto-apply Stroke Play Championship config if entered in Step 4.
    if (tournamentId != null &&
        _tournamentActiveGames.contains(GameIds.championshipStrokePlay) &&
        (_lowNetEntryFee > 0 || _lowNetPayouts.any((p) => p > 0))) {
      final payoutList = <Map<String, dynamic>>[];
      for (int i = 0; i < _lowNetNumPayouts; i++) {
        if (_lowNetPayouts[i] > 0) {
          payoutList.add({'place': i + 1, 'amount': _lowNetPayouts[i].toDouble()});
        }
      }
      await client.postTournamentLowNetSetup(
        tournamentId,
        LowNetChampionshipSetup(
          handicapMode: _handicapMode,
          netPercent  : _netPercent,
          entryFee    : _lowNetEntryFee.toDouble(),
          payouts     : payoutList,
        ),
      );
    }
    if (!mounted) return;

    // 2. Create stub rounds for rounds 2..N
    if (_createNewTournament) {
      for (int i = 0; i < _additionalRounds.length; i++) {
        final draft     = _additionalRounds[i];
        final draftDate = DateFormat('yyyy-MM-dd').format(draft.date);
        await client.createRound(
          tournamentId: tournamentId,
          courseId    : draft.courseId!,
          date        : draftDate,
          activeGames : games,
          roundNumber : i + 2,
          handicapMode: _handicapMode,
          netPercent  : _netPercent,
          netMaxDoubleBogey: _netMaxDoubleBogey,
        );
      }
    }

    // 3. Create Round 1 with foursomes
    final existing = _existingTournament?.rounds.length ?? 0;
    final round = await client.createRound(
      tournamentId: tournamentId,
      courseId    : _selectedCourseId!,
      date        : dateStr,
      activeGames : games,
      roundNumber : _createNewTournament ? 1 : existing + 1,
      handicapMode: _handicapMode,
      netPercent  : _netPercent,
      netMaxDoubleBogey: _netMaxDoubleBogey,
    );

    final playersList = _orderedPlayerIds.map((id) {
      final tee = _playerTees[id];
      if (tee == null) throw Exception('Player $id has no tee selected.');
      return {'player_id': id, 'tee_id': tee.id};
    }).toList();

    final fullRound = await client.setupRound(
      round.id,
      players       : playersList,
      randomise     : false,
      autoSetupGames: true,
    );
    if (!mounted) return;

    // Auto-apply match play config entered in Step 4.
    bool matchPlayAutoConfigured = false;
    if (_tournamentActiveGames.contains(GameIds.singlesNassau)) {
      const labels = ['1st', '2nd', '3rd', '4th'];
      final payoutConfig = <String, double>{};
      for (int i = 0; i < _matchPlayNumPayouts; i++) {
        if (_matchPlayPayouts[i] > 0) {
          payoutConfig[labels[i]] = _matchPlayPayouts[i].toDouble();
        }
      }
      if (_matchPlayEntryFee > 0 || payoutConfig.isNotEmpty) {
        for (final fs in fullRound.foursomes) {
          await client.postMatchPlaySetup(
            fs.id,
            entryFee:     _matchPlayEntryFee.toDouble(),
            payoutConfig: payoutConfig,
          );
        }
        matchPlayAutoConfigured = true;
      }
    }
    if (!mounted) return;

    final needsConfig =
        _activeGames.contains(GameIds.irishRumble) ||
        _activeGames.contains(GameIds.strokePlay)  ||
        _activeGames.contains(GameIds.pinkBall)    ||
        (_tournamentActiveGames.contains(GameIds.singlesNassau) && !matchPlayAutoConfigured);
    if (needsConfig) {
      setState(() {
        _createdRound             = fullRound;
        _createdTournamentId      = tournamentId;
        _step                     = _totalSteps;   // 6 for non-cup
        _creating                 = false;
        _matchPlayStep6Configured = matchPlayAutoConfigured;
      });
    } else {
      Navigator.of(context).pop(true);
    }
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _back(); },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          title: Text(_step >= _totalSteps
              ? (_isCupTournament ? 'Tournament Created' : 'Game Setup')
              : (_isCupTournament
                  ? 'New Cup Tournament  ($_step of ${_totalSteps - 1})'
                  : 'New Round  ($_step of ${_totalSteps - 1})')),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              // Cap at 1.0 on the post-creation step so bar stays full
              value: (_step >= _totalSteps ? _totalSteps : _step + 1) / _totalSteps,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: _dataLoading
              ? const Center(child: CircularProgressIndicator())
              : _dataError != null
                  ? ErrorView(message: _dataError!, onRetry: _loadReferenceData)
                  : _stepBody(),
        ),
        bottomNavigationBar: _dataLoading || _dataError != null
            ? null
            : _BottomBar(
                step            : _step,
                totalSteps      : _totalSteps,
                canAdvance      : _canAdvance(),
                creating        : _creating,
                isCupTournament : _isCupTournament,
                onBack          : _back,
                onNext          : _next,
                onCreate        : _createRound,
                onDone          : () => Navigator.of(context).pop(true),
              ),
      ),
    );
  }

  Widget _stepBody() {
    // For cup tournaments a "Cup Design" step sits at position 2, pushing
    // players → groups → games → review each one position later.
    final cup = _isCupTournament;

    // --- Cup Design step (step 2, cup only) ---
    if (cup && _step == 2) {
      return _Step2CupDesign(
        cupNameCtrl       : _cupNameCtrl,
        teamCount         : _cupTeamCount,
        onTeamCountChanged: (n) => setState(() => _cupTeamCount = n),
        lowNetEnabled     : _tournamentActiveGames.contains('low_net'),
        onToggleLowNet    : (on) => setState(() {
          on ? _tournamentActiveGames.add('low_net')
             : _tournamentActiveGames.remove('low_net');
        }),
      );
    }

    // --- Per-round game plan step (step 3, cup only) ---
    if (cup && _step == 3) {
      return _Step3CupRoundGames(
        numRounds           : _numRounds,
        roundCupGames       : _roundCupGames,
        roundCupPoints      : _roundCupPoints,
        roundCupGroupCounts : _roundCupGroupCounts,
        selectedCourseId    : _selectedCourseId,
        additionalRounds    : _additionalRounds,
        courses             : _courses,
        date                : _date,
        onChanged           : (roundIdx, games) =>
            setState(() => _roundCupGames[roundIdx] = games),
        onPointsChanged     : (roundIdx, points) =>
            setState(() => _roundCupPoints[roundIdx] = points),
        onGroupCountsChanged: (roundIdx, counts) =>
            setState(() => _roundCupGroupCounts[roundIdx] = counts),
      );
    }

    // Map the raw step to a logical step for the shared step widgets.
    // Cup:     step 4→logical 5 (review), step 5→logical 6 (post-create).
    // Non-cup: no shift — step numbers match logical steps directly.
    final logicalStep = (cup && _step >= 4) ? _step + 1 : _step;

    switch (logicalStep) {
      case 0:
        return _Step0Tournament(
          createNew            : _createNewTournament,
          tournaments          : _tournaments,
          existingTournament   : _existingTournament,
          nameCtrl             : _nameCtrl,
          formKey              : _step0Key,
          numRounds            : _numRounds,
          tournamentActiveGames: _tournamentActiveGames,
          onToggleNew          : (v) => setState(() {
            _createNewTournament = v;
            _existingTournament  = null;
          }),
          onPickTournament  : (t) => setState(() => _existingTournament = t),
          onNumRoundsChanged: (n) => setState(() {
            _numRounds = n;
            // Resize _additionalRounds to (n - 1)
            while (_additionalRounds.length < n - 1) {
              // Stagger dates by 1 day each; no default course so user must pick
              final baseDate = _additionalRounds.isEmpty
                  ? _date
                  : _additionalRounds.last.date;
              _additionalRounds.add(_RoundDraft(
                courseId: null,
                date    : baseDate.add(const Duration(days: 1)),
              ));
            }
            if (_additionalRounds.length > n - 1) {
              _additionalRounds = _additionalRounds.sublist(0, n - 1);
            }
          }),
          onToggleTournamentGame: (g, on) => setState(() {
            on ? _tournamentActiveGames.add(g) : _tournamentActiveGames.remove(g);
            // Picking Cup Play auto-enables Stroke Play Championship by
            // default — without it the cup leaderboard has no place to
            // show per-player round detail.  User can untoggle on the
            // Cup Design step (2 of 4) if they really don't want it.
            if (g == GameIds.teamCup && on) {
              _tournamentActiveGames.add(GameIds.championshipStrokePlay);
            }
          }),
        );
      case 1:
        return _Step1Details(
          courses           : _courses,
          selectedCourseId  : _selectedCourseId,
          date              : _date,
          handicapMode      : _handicapMode,
          netPercent        : _netPercent,
          netMaxDoubleBogey : _netMaxDoubleBogey,
          formKey           : _step1Key,
          additionalRounds  : _additionalRounds,
          onPickCourse      : (id) => setState(() {
            _selectedCourseId = id;
            // Clear per-player tees if course changes (tees list changes)
            _playerTees.clear();
          }),
          onPickDate        : (d) => setState(() => _date = d),
          onChangeHandicap  : (mode, pct) => setState(() {
            _handicapMode = mode;
            _netPercent   = pct;
          }),
          onChangeNetMaxDoubleBogey: (v) =>
              setState(() => _netMaxDoubleBogey = v),
          onPickAdditionalCourse: (idx, id) => setState(() {
            _additionalRounds[idx].courseId = id;
          }),
          onPickAdditionalDate: (idx, d) => setState(() {
            _additionalRounds[idx].date = d;
          }),
        );
      case 2:
        return _Step2Players(
          players    : _allPlayers,
          selectedIds: _selectedIds,
          search     : _search,
          onToggle   : (id) => setState(() {
            _selectedIds.contains(id)
                ? _selectedIds.remove(id)
                : _selectedIds.add(id);
          }),
          onSearch   : (s) => setState(() => _search = s),
          onSelectAll: () => setState(() =>
              _selectedIds.addAll(_allPlayers.map((p) => p.id))),
          onClearAll : () => setState(() => _selectedIds.clear()),
        );
      case 3:
        return _Step3GroupsAndTees(
          orderedPlayers: _orderedPlayers,
          playerTees    : _playerTees,
          courseTees    : _courseTees,
          onReorder     : (oldIdx, newIdx) => setState(() {
            if (newIdx > oldIdx) newIdx--;
            final id = _orderedPlayerIds.removeAt(oldIdx);
            _orderedPlayerIds.insert(newIdx, id);
          }),
          onPickTee     : (playerId, tee) =>
              setState(() => _playerTees[playerId] = tee),
        );
      case 4:
        return _Step4Games(
          activeGames               : _activeGames,
          groupSizeList             : groupSizes(_selectedIds.length),
          onToggleGame              : (g, on) => setState(() {
            on ? _activeGames.add(g) : _activeGames.remove(g);
          }),
          hasTournamentLowNet       : _tournamentActiveGames.contains(GameIds.championshipStrokePlay),
          numPlayers                : _selectedIds.length,
          initialLowNetFee          : _lowNetEntryFee,
          initialLowNetNumPayouts   : _lowNetNumPayouts,
          initialLowNetPayouts      : _lowNetPayouts,
          onLowNetConfigChanged     : (fee, nPays, pays) => setState(() {
            _lowNetEntryFee    = fee;
            _lowNetNumPayouts  = nPays;
            _lowNetPayouts     = pays;
          }),
          hasTournamentMatchPlay    : _tournamentActiveGames.contains(GameIds.singlesNassau),
          initialMatchPlayFee       : _matchPlayEntryFee,
          initialMatchPlayNumPayouts: _matchPlayNumPayouts,
          initialMatchPlayPayouts   : _matchPlayPayouts,
          onMatchPlayConfigChanged  : (fee, nPays, pays) => setState(() {
            _matchPlayEntryFee    = fee;
            _matchPlayNumPayouts  = nPays;
            _matchPlayPayouts     = pays;
          }),
        );
      case 5:
        return _Step5Review(
          createNew            : _createNewTournament,
          tournamentName       : _createNewTournament
              ? _nameCtrl.text.trim()
              : (_existingTournament?.name ?? '—'),
          numRounds            : _numRounds,
          tournamentActiveGames: _tournamentActiveGames.toList(),
          course               : _selectedCourse,
          date                 : _date,
          activeGames          : _activeGames.toList(),
          additionalRounds     : _additionalRounds,
          courses              : _courses,
          orderedPlayers       : _orderedPlayers,
          playerTees           : _playerTees,
          createError          : _createError,
        );
      case 6:  // post-creation (logical 6 = step 6 non-cup or step 7 cup)
        return _Step6GameSetup(
          round               : _createdRound!,
          tournamentId        : _createdTournamentId,
          tournamentName      : _createNewTournament
              ? _nameCtrl.text.trim()
              : (_existingTournament?.name ?? ''),
          activeGames         : _activeGames,
          isCupTournament     : _tournamentActiveGames.contains(GameIds.teamCup),
          matchPlayConfigured : _matchPlayStep6Configured,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// ---------------------------------------------------------------------------
// Bottom nav bar
// ---------------------------------------------------------------------------

class _BottomBar extends StatelessWidget {
  final int step;
  final int totalSteps;
  final bool canAdvance;
  final bool creating;
  final bool isCupTournament;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onCreate;
  final VoidCallback onDone;

  const _BottomBar({
    required this.step,
    required this.totalSteps,
    required this.canAdvance,
    required this.creating,
    required this.isCupTournament,
    required this.onBack,
    required this.onNext,
    required this.onCreate,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    // Post-creation step — show Done only
    if (step >= totalSteps) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            const Spacer(),
            FilledButton.icon(
              onPressed: onDone,
              icon: const Icon(Icons.check),
              label: const Text('Done'),
            ),
          ]),
        ),
      );
    }

    final isLast = step == totalSteps - 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          OutlinedButton(onPressed: onBack, child: const Text('Back')),
          const Spacer(),
          if (isLast)
            FilledButton.icon(
              onPressed: (canAdvance && !creating) ? onCreate : null,
              icon: creating
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Colors.white))
                  : Icon(isCupTournament ? Icons.emoji_events : Icons.flag),
              label: Text(isCupTournament ? 'Save Tournament' : 'Create Round'),
            )
          else
            FilledButton(
              onPressed: canAdvance ? onNext : null,
              child: const Text('Next'),
            ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Step 0 — Tournament
// ===========================================================================

class _Step0Tournament extends StatelessWidget {
  final bool              createNew;
  final List<Tournament>  tournaments;
  final Tournament?       existingTournament;
  final TextEditingController nameCtrl;
  final GlobalKey<FormState> formKey;
  final int               numRounds;
  final Set<String>       tournamentActiveGames;
  final ValueChanged<bool>        onToggleNew;
  final ValueChanged<Tournament?> onPickTournament;
  final ValueChanged<int>         onNumRoundsChanged;
  final void Function(String game, bool on) onToggleTournamentGame;

  const _Step0Tournament({
    required this.createNew,
    required this.tournaments,
    required this.existingTournament,
    required this.nameCtrl,
    required this.formKey,
    required this.numRounds,
    required this.tournamentActiveGames,
    required this.onToggleNew,
    required this.onPickTournament,
    required this.onNumRoundsChanged,
    required this.onToggleTournamentGame,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Tournament', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Create a new tournament or add this round to an existing one.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Colors.grey)),
          const SizedBox(height: 24),

          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true,  label: Text('New'),      icon: Icon(Icons.add)),
              ButtonSegment(value: false, label: Text('Existing'), icon: Icon(Icons.list)),
            ],
            selected: {createNew},
            onSelectionChanged: (s) => onToggleNew(s.first),
          ),

          const SizedBox(height: 24),

          if (createNew) ...[
            TextFormField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Tournament name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.emoji_events),
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter a tournament name' : null,
            ),
            const SizedBox(height: 24),

            // ── Number of rounds ────────────────────────────────────────────
            Text('Number of Rounds',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('How many rounds will this tournament span?',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.grey)),
            const SizedBox(height: 12),
            Row(children: [
              IconButton(
                onPressed: numRounds > 1
                    ? () => onNumRoundsChanged(numRounds - 1)
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
                color: Theme.of(context).colorScheme.primary,
              ),
              Container(
                width: 56,
                alignment: Alignment.center,
                child: Text(
                  '$numRounds',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                onPressed: numRounds < 7
                    ? () => onNumRoundsChanged(numRounds + 1)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
                color: Theme.of(context).colorScheme.primary,
              ),
            ]),

            // ── Tournament-level games ───────────────────────────────────────
            const SizedBox(height: 24),
            Text('Tournament Games',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              numRounds > 1
                  ? 'Multi-day tournaments require Stroke Play, Stableford, '
                    'or Cup Play as the primary format.'
                  : 'Format tracked across all rounds (configured separately).',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (gameValue, gameLabel) in kChampionshipGames)
                  FilterChip(
                    label: Text(gameLabel),
                    selected: tournamentActiveGames.contains(gameValue),
                    onSelected: (v) => onToggleTournamentGame(gameValue, v),
                  ),
              ],
            ),
            if (numRounds > 1) ...[
              const SizedBox(height: 6),
              Builder(builder: (ctx) {
                final hasPrimary =
                    tournamentActiveGames.contains(GameIds.championshipStrokePlay) ||
                    tournamentActiveGames.contains(GameIds.championshipStableford) ||
                    tournamentActiveGames.contains(GameIds.teamCup);
                if (hasPrimary) return const SizedBox.shrink();
                return Text(
                  'Select Stroke Play, Stableford, or Cup Play to continue.',
                  style: Theme.of(ctx).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(ctx).colorScheme.error),
                );
              }),
            ],
          ] else ...[
            if (tournaments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('No existing tournaments. Create a new one instead.',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              DropdownButtonFormField<Tournament>(
                value: existingTournament,
                decoration: const InputDecoration(
                  labelText: 'Select tournament',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.emoji_events),
                ),
                items: tournaments.map((t) => DropdownMenuItem(
                  value: t, child: Text(t.name),
                )).toList(),
                onChanged: onPickTournament,
                validator: (v) => v == null ? 'Select a tournament' : null,
              ),
          ],
        ]),
      ),
    );
  }
}

// ===========================================================================
// Step 1 — Round Details (course, date, bet unit, active games)
// ===========================================================================

class _Step1Details extends StatelessWidget {
  final List<CourseInfo>  courses;
  final int?              selectedCourseId;
  final DateTime          date;
  final String            handicapMode;
  final int               netPercent;
  final bool              netMaxDoubleBogey;
  final GlobalKey<FormState> formKey;
  final List<_RoundDraft> additionalRounds;
  final ValueChanged<int?>      onPickCourse;
  final ValueChanged<DateTime>  onPickDate;
  final void Function(String mode, int pct) onChangeHandicap;
  final ValueChanged<bool> onChangeNetMaxDoubleBogey;
  final void Function(int idx, int? courseId) onPickAdditionalCourse;
  final void Function(int idx, DateTime date) onPickAdditionalDate;

  const _Step1Details({
    required this.courses,
    required this.selectedCourseId,
    required this.date,
    required this.handicapMode,
    required this.netPercent,
    required this.netMaxDoubleBogey,
    required this.formKey,
    required this.additionalRounds,
    required this.onPickCourse,
    required this.onPickDate,
    required this.onChangeHandicap,
    required this.onChangeNetMaxDoubleBogey,
    required this.onPickAdditionalCourse,
    required this.onPickAdditionalDate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Round Details',
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Tees are assigned per player in the next step.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: Colors.grey)),
          const SizedBox(height: 20),

          // ── Round 1 header (only shown when multi-round) ─────────────────
          if (additionalRounds.isNotEmpty) ...[
            Text('Round 1',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
          ],

          // Course picker (Round 1)
          DropdownButtonFormField<int>(
            value: selectedCourseId,
            decoration: const InputDecoration(
              labelText: 'Course',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.golf_course),
            ),
            items: courses.map((c) => DropdownMenuItem(
              value: c.id, child: Text(c.name),
            )).toList(),
            onChanged: onPickCourse,
            validator: (v) => v == null ? 'Select a course' : null,
          ),
          const SizedBox(height: 16),

          // Date (Round 1)
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context   : context,
                initialDate: date,
                firstDate : DateTime(2020),
                lastDate  : DateTime(2030),
              );
              if (picked != null) onPickDate(picked);
            },
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Date',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.calendar_today),
              ),
              child: Text(DateFormat('MMMM d, yyyy').format(date)),
            ),
          ),
          const SizedBox(height: 16),

          // ── Additional rounds (2..N) ─────────────────────────────────────
          for (int i = 0; i < additionalRounds.length; i++) ...[
            const Divider(),
            const SizedBox(height: 8),
            Text('Round ${i + 2}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              value: additionalRounds[i].courseId,
              decoration: const InputDecoration(
                labelText: 'Course',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.golf_course),
              ),
              items: courses.map((c) => DropdownMenuItem(
                value: c.id, child: Text(c.name),
              )).toList(),
              onChanged: (id) => onPickAdditionalCourse(i, id),
              validator: (v) => v == null ? 'Select a course' : null,
            ),
            const SizedBox(height: 12),
            Builder(builder: (ctx) => InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context   : ctx,
                  initialDate: additionalRounds[i].date,
                  firstDate : DateTime(2020),
                  lastDate  : DateTime(2030),
                );
                if (picked != null) onPickAdditionalDate(i, picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Date',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.calendar_today),
                ),
                child: Text(DateFormat('MMMM d, yyyy')
                    .format(additionalRounds[i].date)),
              ),
            )),
            const SizedBox(height: 16),
          ],

          if (additionalRounds.isNotEmpty) ...[
            const Divider(),
            const SizedBox(height: 8),
          ],

          // ── Handicap Mode ───────────────────────────────────────────────
          Text('Handicap Mode',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Applies to all games in this tournament round.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey)),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, constraints) {
            // 3 buttons → 4 borders at 1px each → subtract 4px before dividing
            final segW = (constraints.maxWidth - 4) / 3;
            return ToggleButtons(
              borderRadius: BorderRadius.circular(8),
              constraints: BoxConstraints.tightFor(width: segW, height: 44),
              isSelected: [
                handicapMode == 'gross',
                handicapMode == 'net',
                handicapMode == 'strokes_off',
              ],
              onPressed: (i) {
                const modes = ['gross', 'net', 'strokes_off'];
                onChangeHandicap(modes[i], netPercent);
              },
              children: [
                const Text('Gross'),
                const Text('Net'),
                // FittedBox auto-shrinks text on narrow screens to avoid
                // the 4px overflow that "Strokes Off" causes at default size.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text('Strokes Off'),
                  ),
                ),
              ],
            );
          }),

          // Handicap allowance — shown for net and strokes-off (not gross).
          if (handicapMode != 'gross') ...[
            const SizedBox(height: 12),
            Row(children: [
              const Text('Handicap %:'),
              const SizedBox(width: 12),
              SizedBox(
                width: 80,
                child: TextFormField(
                  initialValue: '$netPercent',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    suffixText: '%',
                  ),
                  onChanged: (v) {
                    final pct = int.tryParse(v);
                    if (pct != null && pct >= 0 && pct <= 200) {
                      onChangeHandicap(handicapMode, pct);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text('(100 = full handicap)',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey)),
            ]),
          ],

          const SizedBox(height: 16),

          // Net double-bogey cap — round-level rule, applied to every
          // round in this tournament at creation time.
          NetDoubleBogeyCard(
            value: netMaxDoubleBogey,
            onChanged: onChangeNetMaxDoubleBogey,
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Step 2 — Player Selection
// ===========================================================================

class _Step2Players extends StatelessWidget {
  final List<PlayerProfile> players;
  final Set<int>            selectedIds;
  final String              search;
  final ValueChanged<int>   onToggle;
  final ValueChanged<String> onSearch;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;

  const _Step2Players({
    required this.players,
    required this.selectedIds,
    required this.search,
    required this.onToggle,
    required this.onSearch,
    required this.onSelectAll,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final filtered = search.isEmpty
        ? players
        : players
            .where((p) => p.name.toLowerCase().contains(search.toLowerCase()))
            .toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Select Players',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '${selectedIds.length} selected  •  '
            '${groupSizes(selectedIds.length).length} group(s)  •  '
            'Assign tees in the next step',
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
                hintText: 'Search players…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: onSearch,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onSelectAll, child: const Text('All')),
          TextButton(onPressed: onClearAll,  child: const Text('None')),
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
                  final sel = selectedIds.contains(p.id);
                  return CheckboxListTile(
                    value    : sel,
                    onChanged: (_) => onToggle(p.id),
                    title    : Text(p.name),
                    subtitle : Text('Hcp ${p.handicapIndex}'),
                    secondary: CircleAvatar(
                      backgroundColor: sel
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Text(
                        p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          color: sel ? Colors.white : null,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),

      if (selectedIds.length < 2)
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.errorContainer,
          padding: const EdgeInsets.all(8),
          child: Text(
            'Select at least 2 players to continue.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer),
          ),
        ),
    ]);
  }
}

// ===========================================================================
// Step 3 — Group arrangement + per-player tee
// ===========================================================================

class _Step3GroupsAndTees extends StatelessWidget {
  /// Players in drag order — position ÷ 4 determines group (1-based).
  final List<PlayerProfile>     orderedPlayers;
  final Map<int, TeeInfo?>      playerTees;
  final List<TeeInfo>           courseTees;
  final void Function(int, int) onReorder;
  final void Function(int playerId, TeeInfo tee) onPickTee;

  const _Step3GroupsAndTees({
    required this.orderedPlayers,
    required this.playerTees,
    required this.courseTees,
    required this.onReorder,
    required this.onPickTee,
  });

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final sizes      = groupSizes(orderedPlayers.length);
    final groupCount = sizes.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Groups & Tees',
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Drag  ≡  to reorder. Foursomes fill first; remaining players '
            'form threesomes. Pick each player\'s tee on the right.',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 4),
          // Group legend chips
          Wrap(
            spacing: 6,
            children: List.generate(groupCount, (i) {
              final color = _groupColors[i % _groupColors.length];
              return Chip(
                label: Text(
                  'Group ${i + 1}',
                  style: TextStyle(
                      color: color, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                backgroundColor: color.withOpacity(0.1),
                side: BorderSide(color: color.withOpacity(0.4)),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              );
            }),
          ),
          const SizedBox(height: 12),

          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outline),
            ),
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              // 68 px per row
              height: orderedPlayers.length * 68.0,
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: onReorder,
                proxyDecorator: (child, _, animation) => Material(
                  elevation: 4,
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                  child: child,
                ),
                children: orderedPlayers.asMap().entries.map((entry) {
                  final idx      = entry.key;
                  final player   = entry.value;
                  final groupNum = groupOf(idx, sizes);
                  final color    =
                      _groupColors[(groupNum - 1) % _groupColors.length];
                  final tee      = playerTees[player.id];

                  // Only show tees that match this player's sex, plus unisex.
                  final playerTeeOptions = courseTees
                      .where((t) => t.sex == player.sex || t.sex == null)
                      .toList();

                  // First player in a group gets a stronger top border
                  final isGroupStart = isGroupBoundary(idx, sizes);

                  return Container(
                    key: ValueKey(player.id),
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
                    child: Row(
                      children: [
                        // ── Drag handle ──
                        ReorderableDragStartListener(
                          index: idx,
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            child: Icon(Icons.drag_handle,
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),

                        // ── Player name + tee dropdown ──
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                player.name,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              DropdownButton<TeeInfo>(
                                value: (tee != null &&
                                        playerTeeOptions.contains(tee))
                                    ? tee
                                    : null,
                                isDense: true,
                                underline: const SizedBox.shrink(),
                                hint: Text('Pick tee',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant)),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface),
                                items: playerTeeOptions
                                    .map((t) => DropdownMenuItem(
                                          value: t,
                                          child: Text(t.teeName),
                                        ))
                                    .toList(),
                                onChanged: (t) {
                                  if (t != null) onPickTee(player.id, t);
                                },
                              ),
                            ],
                          ),
                        ),

                        // ── Group badge ──
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: color.withOpacity(0.4)),
                          ),
                          child: Text(
                            'G $groupNum',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: color, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
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
        ],
      ),
    );
  }
}

// ===========================================================================
// Step 2 (Cup) — Cup Design
// ===========================================================================

class _Step2CupDesign extends StatefulWidget {
  final TextEditingController cupNameCtrl;
  final int                   teamCount;
  final void Function(int)    onTeamCountChanged;
  final bool                  lowNetEnabled;
  final void Function(bool)   onToggleLowNet;

  const _Step2CupDesign({
    required this.cupNameCtrl,
    required this.teamCount,
    required this.onTeamCountChanged,
    required this.lowNetEnabled,
    required this.onToggleLowNet,
  });

  @override
  State<_Step2CupDesign> createState() => _Step2CupDesignState();
}

class _Step2CupDesignState extends State<_Step2CupDesign> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Cup Design', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Give the cup a name and choose how many teams will compete. '
          'Team names and player assignments come later.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 24),

        // Cup name
        TextField(
          controller: widget.cupNameCtrl,
          decoration: const InputDecoration(
            labelText : 'Cup name',
            hintText  : 'e.g. Bandon Cup 2026',
            border    : OutlineInputBorder(),
            prefixIcon: Icon(Icons.emoji_events_outlined),
          ),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 24),

        // Number of teams
        Text('Number of Teams',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: [2, 3, 4].map((n) => Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('$n teams'),
              selected: widget.teamCount == n,
              onSelected: (_) {
                widget.onTeamCountChanged(n);
                setState(() {});
              },
            ),
          )).toList(),
        ),
        const SizedBox(height: 24),

        // Secondary game
        Text('Secondary Game (optional)',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          'A cross-team side game played by all golfers every round.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Low Net (Stroke Play)'),
          subtitle: const Text('Individual net scores across all players'),
          value: widget.lowNetEnabled,
          onChanged: (v) {
            widget.onToggleLowNet(v);
            setState(() {});
          },
        ),
        const SizedBox(height: 16),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'After creating the tournament, tap "Assign Teams" on the '
                'tournament card to name the teams and assign players. '
                'Set up each round\'s foursomes and tee times from '
                '"Set Up Round N" when you\'re ready to play.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Step 3 (Cup) — Per-round game plan
// ===========================================================================

const _kCupGameChoices = [
  ('nassau',          'Four Ball (Nassau)'),
  ('quota_nassau',    'Four Ball Quota (Nassau)'),
  ('irish_rumble',    'Irish Rumble'),
  ('singles_nassau',  'Singles Nassau (F9/B9/All)'),
  ('singles_18',      '18-Hole Singles'),
];

class _Step3CupRoundGames extends StatelessWidget {
  final int                                   numRounds;
  final Map<int, List<String>>                roundCupGames;
  final Map<int, Map<String, double>>         roundCupPoints;
  final Map<int, Map<String, int>>            roundCupGroupCounts;
  final int?                                  selectedCourseId;
  final List<_RoundDraft>                     additionalRounds;
  final List<CourseInfo>                      courses;
  final DateTime                              date;
  final void Function(int roundIdx, List<String> games)           onChanged;
  final void Function(int roundIdx, Map<String, double> points)   onPointsChanged;
  final void Function(int roundIdx, Map<String, int> counts)      onGroupCountsChanged;

  const _Step3CupRoundGames({
    super.key,
    required this.numRounds,
    required this.roundCupGames,
    required this.roundCupPoints,
    required this.roundCupGroupCounts,
    required this.selectedCourseId,
    required this.additionalRounds,
    required this.courses,
    required this.date,
    required this.onChanged,
    required this.onPointsChanged,
    required this.onGroupCountsChanged,
  });

  String _courseName(int? courseId) {
    if (courseId == null) return '—';
    return courses.firstWhere((c) => c.id == courseId,
            orElse: () => CourseInfo(id: courseId, name: '—'))
        .name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Games by Round', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'For each round, add one entry per foursome. '
          'The order defines which group plays which format.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 20),
        for (int r = 0; r < numRounds; r++) ...[
          _RoundGameSlots(
            roundIndex        : r,
            roundNumber       : r + 1,
            courseName        : r == 0
                ? _courseName(selectedCourseId)
                : _courseName(additionalRounds[r - 1].courseId),
            date              : r == 0 ? date : additionalRounds[r - 1].date,
            currentGames      : roundCupGames[r] ?? [],
            currentPoints     : roundCupPoints[r] ?? {},
            currentGroupCounts: roundCupGroupCounts[r] ?? {},
            onChanged         : (games) => onChanged(r, games),
            onPointsChanged   : (pts) => onPointsChanged(r, pts),
            onGroupCountsChanged: (counts) => onGroupCountsChanged(r, counts),
          ),
          if (r < numRounds - 1) const SizedBox(height: 16),
        ],
      ]),
    );
  }
}

class _RoundGameSlots extends StatefulWidget {
  final int                     roundIndex;
  final int                     roundNumber;
  final String                  courseName;
  final DateTime                date;
  final List<String>            currentGames;
  final Map<String, double>     currentPoints;
  final Map<String, int>        currentGroupCounts;
  final void Function(List<String>)           onChanged;
  final void Function(Map<String, double>)    onPointsChanged;
  final void Function(Map<String, int>)       onGroupCountsChanged;

  const _RoundGameSlots({
    required this.roundIndex,
    required this.roundNumber,
    required this.courseName,
    required this.date,
    required this.currentGames,
    required this.currentPoints,
    required this.currentGroupCounts,
    required this.onChanged,
    required this.onPointsChanged,
    required this.onGroupCountsChanged,
  });

  @override
  State<_RoundGameSlots> createState() => _RoundGameSlotsState();
}

class _RoundGameSlotsState extends State<_RoundGameSlots> {
  final Map<String, TextEditingController> _ptCtrl = {};

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void didUpdateWidget(_RoundGameSlots old) {
    super.didUpdateWidget(old);
    _syncControllers();
  }

  void _syncControllers() {
    // currentGames is already a unique list — one entry per game type
    final unique = widget.currentGames.toSet();
    // Add controllers for new game types
    for (final g in unique) {
      if (!_ptCtrl.containsKey(g)) {
        final initial = widget.currentPoints[g] ?? 1.0;
        final ctrl = TextEditingController(
          text: initial % 1 == 0 ? initial.toInt().toString() : initial.toString(),
        );
        ctrl.addListener(() {
          final pts = double.tryParse(ctrl.text.trim()) ?? 1.0;
          final updated = Map<String, double>.from(widget.currentPoints);
          updated[g] = pts;
          widget.onPointsChanged(updated);
        });
        _ptCtrl[g] = ctrl;
      }
    }
    // Remove controllers for game types no longer in the list
    _ptCtrl.removeWhere((g, ctrl) {
      if (!unique.contains(g)) {
        ctrl.dispose();
        return true;
      }
      return false;
    });
  }

  @override
  void dispose() {
    for (final c in _ptCtrl.values) c.dispose();
    super.dispose();
  }

  String _label(String id) =>
      _kCupGameChoices.firstWhere((g) => g.$1 == id,
              orElse: () => (id, id))
          .$2;

  void _addGame(BuildContext context) {
    // Only show game types not already in the list
    final existing = widget.currentGames.toSet();
    final choices  = _kCupGameChoices.where((g) => !existing.contains(g.$1)).toList();
    if (choices.isEmpty) return;
    showModalBottomSheet<String>(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Add a game format',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ...choices.map((g) => ListTile(
            title: Text(g.$2),
            onTap: () => Navigator.of(context).pop(g.$1),
          )),
        ],
      ),
    ).then((picked) {
      if (picked == null) return;
      // Add to games list and default to 1 group
      widget.onChanged([...widget.currentGames, picked]);
      final updatedCounts = Map<String, int>.from(widget.currentGroupCounts);
      updatedCounts.putIfAbsent(picked, () => 1);
      widget.onGroupCountsChanged(updatedCounts);
    });
  }

  void _removeGame(String gameId) {
    final updated = widget.currentGames.where((g) => g != gameId).toList();
    widget.onChanged(updated);
    final updatedPts = Map<String, double>.from(widget.currentPoints)
      ..remove(gameId);
    widget.onPointsChanged(updatedPts);
    final updatedCounts = Map<String, int>.from(widget.currentGroupCounts)
      ..remove(gameId);
    widget.onGroupCountsChanged(updatedCounts);
    _ptCtrl[gameId]?.dispose();
    _ptCtrl.remove(gameId);
  }

  void _setGroupCount(String gameId, int delta) {
    final current  = widget.currentGroupCounts[gameId] ?? 1;
    final newCount = (current + delta).clamp(1, 8);
    final updated  = Map<String, int>.from(widget.currentGroupCounts);
    updated[gameId] = newCount;
    widget.onGroupCountsChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final gameList    = widget.currentGames; // unique game types

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text('R${widget.roundNumber}',
                  style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(widget.courseName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(DateFormat('EEE, MMM d').format(widget.date),
                    style: theme.textTheme.bodySmall),
              ]),
            ),
          ]),

          const SizedBox(height: 12),

          if (gameList.isEmpty)
            Text('No games added yet.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic))
          else ...[
            // Column headers
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Expanded(child: Text('Format',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                SizedBox(width: 90, child: Text('Groups',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                SizedBox(width: 72, child: Text('Pts/win',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                const SizedBox(width: 32), // delete button column
              ]),
            ),
            const Divider(height: 1),
            const SizedBox(height: 4),

            // One row per game type
            ...gameList.map((g) {
              final groupCount = widget.currentGroupCounts[g] ?? 1;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Text(_label(g),
                      style: theme.textTheme.bodyMedium)),

                  // Group count stepper
                  SizedBox(
                    width: 90,
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      InkWell(
                        onTap: groupCount > 1 ? () => _setGroupCount(g, -1) : null,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.remove,
                              size: 16,
                              color: groupCount > 1
                                  ? theme.colorScheme.primary
                                  : theme.disabledColor),
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        child: Text('$groupCount',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                      InkWell(
                        onTap: () => _setGroupCount(g, 1),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.add,
                              size: 16,
                              color: theme.colorScheme.primary),
                        ),
                      ),
                    ]),
                  ),

                  // Points per win field
                  SizedBox(
                    width: 72,
                    child: TextField(
                      controller: _ptCtrl[g],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => FocusScope.of(context).unfocus(),
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(
                        suffixText: 'pt',
                        border    : OutlineInputBorder(),
                        isDense   : true,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                      ),
                    ),
                  ),

                  // Remove button
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => _removeGame(g),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ]),
              );
            }),
          ],

          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: gameList.length < _kCupGameChoices.length
                ? () => _addGame(context)
                : null,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a game'),
          ),
        ]),
      ),
    );
  }
}


// ===========================================================================
// Step 4 — Game Selection
// ===========================================================================

class _Step4Games extends StatefulWidget {
  final Set<String>   activeGames;
  final List<int>     groupSizeList;
  final void Function(String game, bool on) onToggleGame;
  /// When true, the Stroke Play Championship buy-in section is shown first.
  final bool          hasTournamentLowNet;
  /// Total number of selected players — pool multiplier for the championship.
  final int           numPlayers;
  // Stroke Play Championship buy-in
  final int           initialLowNetFee;
  final int           initialLowNetNumPayouts;
  final List<int>     initialLowNetPayouts;
  final void Function(int fee, int numPayouts, List<int> payouts)
      onLowNetConfigChanged;
  /// When true, the Match Play buy-in section is shown at the top of this step.
  final bool          hasTournamentMatchPlay;
  // Match Play buy-in — collected here and applied to all groups on creation.
  final int           initialMatchPlayFee;
  final int           initialMatchPlayNumPayouts;
  final List<int>     initialMatchPlayPayouts;
  final void Function(int fee, int numPayouts, List<int> payouts)
      onMatchPlayConfigChanged;

  const _Step4Games({
    required this.activeGames,
    required this.groupSizeList,
    required this.onToggleGame,
    this.hasTournamentLowNet        = false,
    this.numPlayers                 = 0,
    this.initialLowNetFee           = 0,
    this.initialLowNetNumPayouts    = 3,
    this.initialLowNetPayouts       = const [0, 0, 0, 0],
    required this.onLowNetConfigChanged,
    this.hasTournamentMatchPlay     = false,
    this.initialMatchPlayFee        = 0,
    this.initialMatchPlayNumPayouts = 3,
    this.initialMatchPlayPayouts    = const [0, 0, 0, 0],
    required this.onMatchPlayConfigChanged,
  });

  @override
  State<_Step4Games> createState() => _Step4GamesState();
}

class _Step4GamesState extends State<_Step4Games> {
  // ── Low Net (Stroke Play Championship) controllers ──
  late final TextEditingController _lowNetFeeCtrl;
  int _lowNetNumPayouts = 3;
  late final List<TextEditingController> _lowNetPayoutCtrls;

  // ── Match Play controllers ──
  late final TextEditingController _feeCtrl;
  int _numPayouts = 3;
  late final List<TextEditingController> _payoutCtrls;

  @override
  void initState() {
    super.initState();

    // Low Net
    _lowNetFeeCtrl = TextEditingController(
        text: widget.initialLowNetFee == 0 ? '' : '${widget.initialLowNetFee}');
    _lowNetNumPayouts = widget.initialLowNetNumPayouts;
    _lowNetPayoutCtrls = List.generate(4, (i) {
      final v = i < widget.initialLowNetPayouts.length
          ? widget.initialLowNetPayouts[i]
          : 0;
      return TextEditingController(text: v == 0 ? '' : '$v');
    });
    _lowNetFeeCtrl.addListener(_notifyLowNet);
    for (final c in _lowNetPayoutCtrls) c.addListener(_notifyLowNet);

    // Match Play
    _feeCtrl    = TextEditingController(
        text: widget.initialMatchPlayFee == 0 ? '' : '${widget.initialMatchPlayFee}');
    _numPayouts = widget.initialMatchPlayNumPayouts;
    _payoutCtrls = List.generate(4, (i) {
      final v = i < widget.initialMatchPlayPayouts.length
          ? widget.initialMatchPlayPayouts[i]
          : 0;
      return TextEditingController(text: v == 0 ? '' : '$v');
    });
    _feeCtrl.addListener(_notify);
    for (final c in _payoutCtrls) c.addListener(_notify);
  }

  @override
  void dispose() {
    _lowNetFeeCtrl.dispose();
    for (final c in _lowNetPayoutCtrls) c.dispose();
    _feeCtrl.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  void _notifyLowNet() {
    final fee     = int.tryParse(_lowNetFeeCtrl.text.trim()) ?? 0;
    final payouts = _lowNetPayoutCtrls
        .map((c) => int.tryParse(c.text.trim()) ?? 0)
        .toList();
    widget.onLowNetConfigChanged(fee, _lowNetNumPayouts, payouts);
  }

  void _suggestLowNetPayouts() {
    final fee  = int.tryParse(_lowNetFeeCtrl.text.trim()) ?? 0;
    final pool = fee * widget.numPlayers;
    if (pool <= 0) return;
    final suggested = suggestPayouts(pool, _lowNetNumPayouts);
    for (int i = 0; i < 4; i++) {
      _lowNetPayoutCtrls[i].text = suggested[i] == 0 ? '' : '${suggested[i]}';
    }
    setState(() {});
    _notifyLowNet();
  }

  void _notify() {
    final fee     = int.tryParse(_feeCtrl.text.trim()) ?? 0;
    final payouts = _payoutCtrls
        .map((c) => int.tryParse(c.text.trim()) ?? 0)
        .toList();
    widget.onMatchPlayConfigChanged(fee, _numPayouts, payouts);
  }

  void _suggestPayoutsWizard() {
    final fee    = int.tryParse(_feeCtrl.text.trim()) ?? 0;
    final nFours = widget.groupSizeList.where((s) => s == 4).length;
    final pool   = fee * (nFours > 0 ? 4 : 3);
    if (pool <= 0) return;
    final suggested = suggestPayouts(pool, _numPayouts);
    for (int i = 0; i < 4; i++) {
      _payoutCtrls[i].text = suggested[i] == 0 ? '' : '${suggested[i]}';
    }
    setState(() {});
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final nFours     = widget.groupSizeList.where((s) => s == 4).length;
    final nThrees    = widget.groupSizeList.where((s) => s == 3).length;
    final groupCount = widget.groupSizeList.length;

    final parts = <String>[];
    if (nFours  > 0) parts.add('$nFours foursome${nFours  == 1 ? '' : 's'}');
    if (nThrees > 0) parts.add('$nThrees threesome${nThrees == 1 ? '' : 's'}');
    final groupSummary =
        '$groupCount group${groupCount == 1 ? '' : 's'}: ${parts.join(', ')}';

    final fee           = int.tryParse(_feeCtrl.text.trim()) ?? 0;
    // Pool for balance / auto-suggest: prefer foursome pool, fall back to threesome.
    final poolForSuggest = fee * (nFours > 0 ? 4 : 3);

    final lowNetFee      = int.tryParse(_lowNetFeeCtrl.text.trim()) ?? 0;
    final lowNetPool     = lowNetFee * widget.numPlayers;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Stroke Play Championship Buy-In (shown first) ──────────────────────
        if (widget.hasTournamentLowNet) ...[
          Text('Stroke Play Championship',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Entry fee and payouts applied to the tournament. '
            'Leave blank to configure later.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),

          // Entry fee
          TextFormField(
            controller:   _lowNetFeeCtrl,
            decoration:   const InputDecoration(
              labelText:  'Entry fee per player (\$)',
              border:     OutlineInputBorder(),
              prefixIcon: Icon(Icons.attach_money),
              isDense:    true,
            ),
            keyboardType: TextInputType.number,
          ),
          if (lowNetFee > 0 && widget.numPlayers > 0) ...[
            const SizedBox(height: 6),
            Text(
              'Total pool: \$${lowNetFee * widget.numPlayers} '
              '(${widget.numPlayers} players × \$$lowNetFee)',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),

          PayoutConfigField(
            pool:                lowNetPool,
            numPayouts:          _lowNetNumPayouts,
            payoutCtrls:         _lowNetPayoutCtrls,
            onNumPayoutsChanged: (n) {
              setState(() => _lowNetNumPayouts = n);
              _notifyLowNet();
            },
            onPayoutChanged: _notifyLowNet,
            onSuggest:       _suggestLowNetPayouts,
          ),

          const Divider(height: 28),
        ],

        // ── Match Play Buy-In (shown first when tournament includes match play) ──
        if (widget.hasTournamentMatchPlay) ...[
          Text('Match Play Buy-In',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Entry fee and payouts applied to all groups on creation. '
            'Leave blank to configure each group individually after creation.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),

          // Entry fee
          TextFormField(
            controller:   _feeCtrl,
            decoration:   const InputDecoration(
              labelText:  'Entry fee per player (\$)',
              border:     OutlineInputBorder(),
              prefixIcon: Icon(Icons.attach_money),
              isDense:    true,
            ),
            keyboardType: TextInputType.number,
          ),
          if (fee > 0) ...[
            const SizedBox(height: 6),
            if (nFours > 0)
              Text(
                'Foursomes pool: \$${fee * 4} per group',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            if (nThrees > 0)
              Text(
                'Threesomes pool: \$${fee * 3} per group',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
          const SizedBox(height: 16),

          // Shared payout config widget
          PayoutConfigField(
            pool:                poolForSuggest,
            numPayouts:          _numPayouts,
            payoutCtrls:         _payoutCtrls,
            onNumPayoutsChanged: (n) { setState(() => _numPayouts = n); _notify(); },
            onPayoutChanged:     _notify,
            onSuggest:           _suggestPayoutsWizard,
          ),

          const Divider(height: 28),
        ],

        // ── Side Games ────────────────────────────────────────────────────────
        Text('Side Games', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Optional — pick side games to run alongside the main tournament.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          groupSummary,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),

        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final meta in tournamentRoundGames)
              FilterChip(
                label:      Text(meta.displayName),
                selected:   widget.activeGames.contains(meta.id),
                onSelected: (v) => widget.onToggleGame(meta.id, v),
              ),
          ],
        ),

        const SizedBox(height: 16),
      ]),
    );
  }
}

// ===========================================================================
// Step 5 — Review
// ===========================================================================

class _Step5Review extends StatelessWidget {
  final bool               createNew;
  final String             tournamentName;
  final int                numRounds;
  final List<String>       tournamentActiveGames;
  final CourseInfo?        course;
  final DateTime           date;
  final List<String>       activeGames;
  final List<_RoundDraft>  additionalRounds;
  final List<CourseInfo>   courses;
  /// All players in drag/group order.
  final List<PlayerProfile> orderedPlayers;
  final Map<int, TeeInfo?> playerTees;
  final String?            createError;

  const _Step5Review({
    required this.createNew,
    required this.tournamentName,
    required this.numRounds,
    required this.tournamentActiveGames,
    required this.course,
    required this.date,
    required this.activeGames,
    required this.additionalRounds,
    required this.courses,
    required this.orderedPlayers,
    required this.playerTees,
    this.createError,
  });

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final sizes       = groupSizes(orderedPlayers.length);
    final groupCount  = sizes.length;
    final gameLabels  = {
      for (final g in kGameCatalog) g.id: g.displayName,
      for (final (v, l) in kChampionshipGames) v: l,
    };
    final courseMap   = {for (final c in courses) c.id: c};

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Review', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('Tap "Create Round" to set up all foursomes and games.',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
        const SizedBox(height: 20),

        _ReviewCard(children: [
          _ReviewRow(Icons.emoji_events, 'Tournament',
              '${createNew ? "New — " : ""}$tournamentName'),
          if (createNew && numRounds > 1)
            _ReviewRow(Icons.repeat, 'Rounds', '$numRounds rounds'),
          _ReviewRow(Icons.golf_course,    'Round 1 Course',
              course?.name ?? '—'),
          _ReviewRow(Icons.calendar_today, 'Round 1 Date',
              DateFormat('MMMM d, yyyy').format(date)),
          for (int i = 0; i < additionalRounds.length; i++) ...[
            _ReviewRow(Icons.golf_course,
                'Round ${i + 2} Course',
                courseMap[additionalRounds[i].courseId]?.name ?? '—'),
            _ReviewRow(Icons.calendar_today,
                'Round ${i + 2} Date',
                DateFormat('MMMM d, yyyy').format(additionalRounds[i].date)),
          ],
          _ReviewRow(Icons.people,         'Players',
              '${orderedPlayers.length} players → $groupCount group(s)'),
        ]),

        if (tournamentActiveGames.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Tournament Games',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 4,
            children: tournamentActiveGames.map((g) => Chip(
              label: Text(gameLabels[g] ?? g,
                  style: const TextStyle(fontSize: 12)),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            )).toList(),
          ),
        ],

        if (activeGames.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Active Games',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 4,
            children: activeGames.map((g) => Chip(
              label: Text(gameLabels[g] ?? g,
                  style: const TextStyle(fontSize: 12)),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            )).toList(),
          ),
        ],

        // ── Foursome arrangement ──
        const SizedBox(height: 16),
        Text('Foursomes',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        ...List.generate(groupCount, (g) {
          final groupPlayers = orderedPlayers
              .asMap()
              .entries
              .where((e) => groupOf(e.key, sizes) == g + 1)
              .map((e) => e.value)
              .toList();
          final color = _groupColors[g % _groupColors.length];
          final needsPhantom = groupPlayers.length < 4;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                        color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text('Group ${g + 1}',
                        style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.bold, color: color)),
                    if (needsPhantom) ...[
                      const SizedBox(width: 8),
                      Text('+ 1 phantom',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ]),
                  const SizedBox(height: 6),
                  ...groupPlayers.map((p) {
                    final tee = playerTees[p.id];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        const Icon(Icons.person_outline, size: 15),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(p.name,
                              style: theme.textTheme.bodyMedium),
                        ),
                        if (tee != null)
                          Text(tee.teeName,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color:
                                      theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(width: 8),
                        Text('Hcp ${p.handicapIndex}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color:
                                    theme.colorScheme.onSurfaceVariant)),
                      ]),
                    );
                  }),
                ],
              ),
            ),
          );
        }),

        if (createError != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(createError!,
                    style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ]),
          ),
        ],

        const SizedBox(height: 80),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared review widgets
// ---------------------------------------------------------------------------

class _ReviewCard extends StatelessWidget {
  final List<Widget> children;
  const _ReviewCard({required this.children});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
}

class _ReviewRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  const _ReviewRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: Icon(icon, size: 20, color: Colors.grey),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: Text(value,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Colors.grey)),
      );
}

// ===========================================================================
// Step 6 — Game Setup (shown after round is created)
// ===========================================================================

class _Step6GameSetup extends StatelessWidget {
  final Round       round;
  final int?        tournamentId;
  final String      tournamentName;
  final Set<String> activeGames;
  /// True when this tournament has Cup Play (team_cup) selected.
  final bool        isCupTournament;
  /// True when match play entry fee / payouts were entered in Step 4 and
  /// auto-applied to all groups — no per-group setup needed.
  final bool        matchPlayConfigured;

  const _Step6GameSetup({
    required this.round,
    this.tournamentId,
    this.tournamentName      = '',
    required this.activeGames,
    this.isCupTournament     = false,
    this.matchPlayConfigured = false,
  });

  @override
  Widget build(BuildContext context) {
    final roundId        = round.id;
    final hasIrishRumble = activeGames.contains(GameIds.irishRumble);
    final hasStrokePlay  = activeGames.contains(GameIds.strokePlay);
    final hasPinkBall    = activeGames.contains(GameIds.pinkBall);
    final hasMatchPlay   = activeGames.contains(GameIds.singlesNassau);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Round created!',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Configure your games below before players start entering scores.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),

          // ── Cup Play setup ─────────────────────────────────────────────────
          if (isCupTournament && tournamentId != null) ...[
            _SetupButton(
              icon : Icons.emoji_events_outlined,
              label: 'Set Up Cup Teams & Draft',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RyderCupDraftScreen(
                  tournamentId  : tournamentId!,
                  tournamentName: tournamentName,
                ),
              )),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Create your teams and draft players before the tournament begins.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (hasIrishRumble) ...[
            _SetupButton(
              icon : Icons.flag_circle_outlined,
              label: 'Configure Irish Rumble',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => IrishRumbleSetupScreen(roundId: roundId),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (hasStrokePlay) ...[
            _SetupButton(
              icon : Icons.leaderboard_outlined,
              label: 'Configure Stroke Play',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LowNetSetupScreen(roundId: roundId),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (hasPinkBall) ...[
            _SetupButton(
              icon : Icons.circle_outlined,
              label: 'Configure Pink Ball',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PinkBallSetupScreen(roundId: roundId),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Match Play: auto-configured or needs per-group setup
          if (hasMatchPlay) ...[
            Text('Match Play Brackets',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            if (matchPlayConfigured) ...[
              // Entry fee + payouts were applied to all groups in Step 4.
              Row(children: [
                Icon(Icons.check_circle_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text('All brackets configured',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.primary)),
              ]),
              const SizedBox(height: 4),
              Text(
                'Seedings can still be adjusted from the round screen.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ] else ...[
              Text(
                'Set entry fee and payouts for each group:',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              for (final fs in round.foursomes) ...[
                _SetupButton(
                  icon : Icons.sports_golf,
                  label: 'Set Up ${fs.label}',
                  onTap: () {
                    final allIds = round.foursomes.map((f) => f.id).toList();
                    final peerIds = round.foursomes
                        .where((f) =>
                            f.id != fs.id &&
                            f.realPlayers.length == fs.realPlayers.length)
                        .map((f) => f.id)
                        .toList();
                    Navigator.of(context).pushNamed(
                      '/match-play-setup',
                      arguments: {
                        'foursomeId'     : fs.id,
                        'allMatchPlayIds': allIds,
                        'peerIds'        : peerIds,
                      },
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],        // closes for [...]
            ],          // closes else [...]
          ],            // closes if (hasMatchPlay) [...]

          const SizedBox(height: 8),
          Text(
            'You can also adjust these settings later from the round screen.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SetupButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final VoidCallback onTap;

  const _SetupButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
