import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'irish_rumble_setup_screen.dart'; // also exports LowNetSetupScreen

// ---------------------------------------------------------------------------
// Game catalogue — label + value for every supported game type
// ---------------------------------------------------------------------------

const _allGames = [
  ('skins',        'Skins'),
  ('nassau',       'Nassau 9-9-18'),
  ('sixes',        "Six's"),
  ('stableford',   'Stableford'),
  ('pink_ball',    'Pink Ball'),
  ('match_play',   'Match Play'),
  ('low_net_round','Low Net'),
  ('irish_rumble', 'Irish Rumble'),
  ('scramble',     'Scramble'),
];

// Group badge colours — cycles for > 4 foursomes
const _groupColors = [
  Color(0xFF1565C0), // blue
  Color(0xFF2E7D32), // green
  Color(0xFFB71C1C), // red
  Color(0xFFE65100), // orange
  Color(0xFF6A1B9A), // purple
];

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
  static const _totalSteps = 5;

  // ---- Step 0: Tournament ----
  bool              _createNewTournament = true;
  Tournament?       _existingTournament;
  final _nameCtrl   = TextEditingController();

  // ---- Step 1: Round details (course only — tees per player in step 3) ----
  List<CourseInfo>  _courses        = [];
  int?              _selectedCourseId;
  DateTime          _date           = DateTime.now();
  final Set<String> _activeGames = {}; // no defaults — user picks
  String            _handicapMode   = 'net';
  int               _netPercent     = 100;

  // ---- Step 2: Players ----
  List<PlayerProfile> _allPlayers = [];
  final Set<int>      _selectedIds = {};
  String              _search = '';

  // ---- Step 3: Drag-and-drop group assignment + per-player tee ----
  List<int>           _orderedPlayerIds = [];
  Map<int, TeeInfo?>  _playerTees       = {};

  // ---- Step 4: Review / create ----
  bool    _creating    = false;
  String? _createError;

  // ---- Step 5: Game setup (shown after round is created) ----
  int? _createdRoundId;

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
        _selectedCourseId ??= courses.isNotEmpty ? courses.first.id : null;
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
    switch (_step) {
      case 0:
        if (_createNewTournament) return _nameCtrl.text.trim().isNotEmpty;
        return _existingTournament != null;
      case 1: return _selectedCourseId != null && _activeGames.isNotEmpty;
      case 2: return _selectedIds.length >= 2;
      case 3:
        return _orderedPlayerIds.isNotEmpty &&
            _orderedPlayerIds.every((id) => _playerTees[id] != null);
      case 4: return true;
      default: return false;
    }
  }

  void _next() {
    if (_step == 0 && !(_step0Key.currentState?.validate() ?? true)) return;
    if (_step == 1 && !(_step1Key.currentState?.validate() ?? true)) return;
    if (_step == 2) _initGroups();
    if (_step < _totalSteps - 1) setState(() => _step++);
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
      final client  = context.read<AuthProvider>().client;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final games   = _activeGames.toList();

      // 1. Resolve or create tournament
      int? tournamentId;
      if (_createNewTournament) {
        final t = await client.createTournament(
          name       : _nameCtrl.text.trim(),
          startDate  : dateStr,
          activeGames: games,
        );
        tournamentId = t.id;
      } else {
        tournamentId = _existingTournament?.id;
      }

      // 2. Create round
      final existing = _existingTournament?.rounds.length ?? 0;
      final round = await client.createRound(
        tournamentId: tournamentId,
        courseId    : _selectedCourseId!,
        date        : dateStr,
        activeGames : games,
        roundNumber : _createNewTournament ? 1 : existing + 1,
        handicapMode: _handicapMode,
        netPercent  : _netPercent,
      );

      // 3. Set up foursomes: ordered list drives group assignment; randomise=false
      //    tells the server to group players exactly as submitted (first 4 → group 1,
      //    next 4 → group 2, etc.).
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
      // If any game needs configuration, show step 5; otherwise pop straight back.
      final needsConfig = _activeGames.contains('irish_rumble') ||
          _activeGames.contains('low_net_round');
      if (needsConfig) {
        setState(() {
          _createdRoundId = fullRound.id;
          _step = 5;
          _creating = false;
        });
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() { _createError = friendlyError(e); _creating = false; });
      }
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
          title: Text(_step == 5
              ? 'Game Setup'
              : 'New Round  ($_step of ${_totalSteps - 1})'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              // Cap at 1.0 on step 5 so bar stays full
              value: (_step >= 5 ? _totalSteps : _step + 1) / _totalSteps,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        body: _dataLoading
            ? const Center(child: CircularProgressIndicator())
            : _dataError != null
                ? ErrorView(message: _dataError!, onRetry: _loadReferenceData)
                : _stepBody(),
        bottomNavigationBar: _dataLoading || _dataError != null
            ? null
            : _BottomBar(
                step      : _step,
                totalSteps: _totalSteps,
                canAdvance: _canAdvance(),
                creating  : _creating,
                onBack    : _back,
                onNext    : _next,
                onCreate  : _createRound,
                onDone    : () => Navigator.of(context).pop(true),
              ),
      ),
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _Step0Tournament(
          createNew         : _createNewTournament,
          tournaments       : _tournaments,
          existingTournament: _existingTournament,
          nameCtrl          : _nameCtrl,
          formKey           : _step0Key,
          onToggleNew       : (v) => setState(() {
            _createNewTournament = v;
            _existingTournament  = null;
          }),
          onPickTournament  : (t) => setState(() => _existingTournament = t),
        );
      case 1:
        return _Step1Details(
          courses         : _courses,
          selectedCourseId: _selectedCourseId,
          date            : _date,
          activeGames     : _activeGames,
          handicapMode    : _handicapMode,
          netPercent      : _netPercent,
          formKey         : _step1Key,
          onPickCourse    : (id) => setState(() {
            _selectedCourseId = id;
            // Clear per-player tees if course changes (tees list changes)
            _playerTees.clear();
          }),
          onPickDate      : (d) => setState(() => _date = d),
          onToggleGame    : (g, on) => setState(() {
            on ? _activeGames.add(g) : _activeGames.remove(g);
          }),
          onChangeHandicap: (mode, pct) => setState(() {
            _handicapMode = mode;
            _netPercent   = pct;
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
        return _Step4Review(
          createNew      : _createNewTournament,
          tournamentName : _createNewTournament
              ? _nameCtrl.text.trim()
              : (_existingTournament?.name ?? '—'),
          course         : _selectedCourse,
          date           : _date,
          activeGames    : _activeGames.toList(),
          orderedPlayers : _orderedPlayers,
          playerTees     : _playerTees,
          createError    : _createError,
        );
      case 5:
        return _Step5GameSetup(
          roundId    : _createdRoundId!,
          activeGames: _activeGames,
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
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onCreate;
  final VoidCallback onDone;

  const _BottomBar({
    required this.step,
    required this.totalSteps,
    required this.canAdvance,
    required this.creating,
    required this.onBack,
    required this.onNext,
    required this.onCreate,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    // Step 5 is post-create game setup — show Done only
    if (step == 5) {
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
                  : const Icon(Icons.flag),
              label: const Text('Create Round'),
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
  final ValueChanged<bool>        onToggleNew;
  final ValueChanged<Tournament?> onPickTournament;

  const _Step0Tournament({
    required this.createNew,
    required this.tournaments,
    required this.existingTournament,
    required this.nameCtrl,
    required this.formKey,
    required this.onToggleNew,
    required this.onPickTournament,
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

          if (createNew)
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
            )
          else ...[
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
  final Set<String>       activeGames;
  final String            handicapMode;
  final int               netPercent;
  final GlobalKey<FormState> formKey;
  final ValueChanged<int?>      onPickCourse;
  final ValueChanged<DateTime>  onPickDate;
  final void Function(String game, bool on) onToggleGame;
  final void Function(String mode, int pct) onChangeHandicap;

  const _Step1Details({
    required this.courses,
    required this.selectedCourseId,
    required this.date,
    required this.activeGames,
    required this.handicapMode,
    required this.netPercent,
    required this.formKey,
    required this.onPickCourse,
    required this.onPickDate,
    required this.onToggleGame,
    required this.onChangeHandicap,
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

          // Course picker
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

          // Date
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
          const SizedBox(height: 20),

          // Active games
          Text('Active Games',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Select at least one game to continue.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (gameValue, gameLabel) in _allGames)
                FilterChip(
                  label: Text(gameLabel),
                  selected: activeGames.contains(gameValue),
                  onSelected: (v) => onToggleGame(gameValue, v),
                ),
            ],
          ),
          const SizedBox(height: 24),

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
            final segW = constraints.maxWidth / 3;
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

          // Net percent field — only shown when mode = net
          if (handicapMode == 'net') ...[
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
            '${(selectedIds.length / 4).ceil()} group(s)  •  '
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
    final groupCount = (orderedPlayers.length / 4).ceil();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Groups & Tees',
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Drag  ≡  to reorder. Every 4 players form one group. '
            'Pick each player\'s tee on the right.',
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
                  final groupNum = idx ~/ 4 + 1;
                  final color    =
                      _groupColors[(groupNum - 1) % _groupColors.length];
                  final tee      = playerTees[player.id];

                  // Only show tees that match this player's sex, plus unisex.
                  final playerTeeOptions = courseTees
                      .where((t) => t.sex == player.sex || t.sex == null)
                      .toList();

                  // First player in a group gets a stronger top border
                  final isGroupStart = idx % 4 == 0 && idx > 0;

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
// Step 4 — Review
// ===========================================================================

class _Step4Review extends StatelessWidget {
  final bool               createNew;
  final String             tournamentName;
  final CourseInfo?        course;
  final DateTime           date;
  final List<String>       activeGames;
  /// All players in drag/group order.
  final List<PlayerProfile> orderedPlayers;
  final Map<int, TeeInfo?> playerTees;
  final String?            createError;

  const _Step4Review({
    required this.createNew,
    required this.tournamentName,
    required this.course,
    required this.date,
    required this.activeGames,
    required this.orderedPlayers,
    required this.playerTees,
    this.createError,
  });

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final groupCount  = (orderedPlayers.length / 4).ceil();
    final gameLabels  = {for (final (v, l) in _allGames) v: l};

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
          _ReviewRow(Icons.golf_course,    'Course',
              course?.name ?? '—'),
          _ReviewRow(Icons.calendar_today, 'Date',
              DateFormat('MMMM d, yyyy').format(date)),
          _ReviewRow(Icons.people,         'Players',
              '${orderedPlayers.length} players → $groupCount group(s)'),
        ]),

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
              .where((e) => e.key ~/ 4 == g)
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
// Step 5 — Game Setup (shown after round is created)
// ===========================================================================

class _Step5GameSetup extends StatelessWidget {
  final int         roundId;
  final Set<String> activeGames;

  const _Step5GameSetup({required this.roundId, required this.activeGames});

  @override
  Widget build(BuildContext context) {
    final hasIrishRumble = activeGames.contains('irish_rumble');
    final hasLowNet      = activeGames.contains('low_net_round');

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

          if (hasLowNet) ...[
            _SetupButton(
              icon : Icons.leaderboard_outlined,
              label: 'Configure Low Net',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LowNetSetupScreen(roundId: roundId),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

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
