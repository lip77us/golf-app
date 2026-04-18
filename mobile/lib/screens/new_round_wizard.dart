import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

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
  static const _totalSteps = 4;

  // ---- Step 0: Tournament ----
  bool              _createNewTournament = true;
  Tournament?       _existingTournament;
  final _nameCtrl   = TextEditingController();

  // ---- Step 1: Round details ----
  List<TeeInfo>     _tees = [];
  TeeInfo?          _selectedTee;
  DateTime          _date = DateTime.now();
  final _betCtrl    = TextEditingController(text: '5.00');
  final Set<String> _activeGames = {
    'skins', 'nassau', 'sixes', 'stableford', 'pink_ball',
  };

  // ---- Step 2: Players ----
  List<PlayerProfile> _allPlayers = [];
  final Set<int>      _selectedIds = {};
  String              _search = '';

  // ---- Step 3: Review / create ----
  bool    _creating = false;
  String? _createError;

  // ---- reference data ----
  List<Tournament> _tournaments = [];
  bool _dataLoading = true;
  String? _dataError;

  // ---- form keys ----
  final _step0Key = GlobalKey<FormState>();
  final _step1Key = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _loadReferenceData();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _betCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadReferenceData() async {
    setState(() { _dataLoading = true; _dataError = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final results = await Future.wait([
        client.getTournaments(),
        client.getTees(),
        client.getPlayers(),
      ]);
      if (!mounted) return;
      setState(() {
        _tournaments = results[0] as List<Tournament>;
        _tees        = results[1] as List<TeeInfo>;
        _allPlayers  = (results[2] as List<PlayerProfile>)
            .where((p) => !p.isPhantom)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        _dataLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _dataError = friendlyError(e); _dataLoading = false; });
    }
  }

  // ---- navigation ----

  bool _canAdvance() {
    switch (_step) {
      case 0:
        if (_createNewTournament) return _nameCtrl.text.trim().isNotEmpty;
        return _existingTournament != null;
      case 1: return _selectedTee != null;
      case 2: return _selectedIds.length >= 2;
      case 3: return true;
      default: return false;
    }
  }

  void _next() {
    if (_step == 0 && !(_step0Key.currentState?.validate() ?? true)) return;
    if (_step == 1 && !(_step1Key.currentState?.validate() ?? true)) return;
    if (_step < _totalSteps - 1) setState(() => _step++);
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
    else Navigator.of(context).pop();
  }

  // ---- create ----

  Future<void> _createRound() async {
    setState(() { _creating = true; _createError = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final games   = _activeGames.toList();

      // 1. Resolve or create tournament
      int? tournamentId;
      if (_createNewTournament) {
        final t = await client.createTournament(
          name        : _nameCtrl.text.trim(),
          startDate   : dateStr,
          activeGames : games,
        );
        tournamentId = t.id;
      } else {
        tournamentId = _existingTournament?.id;
      }

      // 2. Create round
      final existing = _existingTournament?.rounds.length ?? 0;
      final round = await client.createRound(
        tournamentId : tournamentId,
        courseId     : _selectedTee!.course.id,
        date         : dateStr,
        betUnit      : double.tryParse(_betCtrl.text) ?? 1.0,
        activeGames  : games,
        roundNumber  : _createNewTournament ? 1 : existing + 1,
      );

      // 3. Draw foursomes + auto-setup games
      final fullRound = await client.setupRound(
        round.id,
        players        : _selectedIds.map((id) => {'player_id': id, 'tee_id': _selectedTee!.id}).toList(),
        randomise      : true,
        autoSetupGames : true,
      );

      if (!mounted) return;
      // Navigate to the new round, replacing the wizard
      Navigator.of(context).pushReplacementNamed('/round', arguments: fullRound.id);
    } catch (e) {
      if (mounted) setState(() { _createError = friendlyError(e); _creating = false; });
    }
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          title: Text('New Round  ($_step of ${_totalSteps - 1})'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              value: (_step + 1) / _totalSteps,
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
                step        : _step,
                totalSteps  : _totalSteps,
                canAdvance  : _canAdvance(),
                creating    : _creating,
                onBack      : _back,
                onNext      : _next,
                onCreate    : _createRound,
              ),
      ),
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0: return _Step0Tournament(
          createNew          : _createNewTournament,
          tournaments        : _tournaments,
          existingTournament : _existingTournament,
          nameCtrl           : _nameCtrl,
          formKey            : _step0Key,
          onToggleNew        : (v) => setState(() {
            _createNewTournament = v;
            _existingTournament  = null;
          }),
          onPickTournament   : (t) => setState(() => _existingTournament = t),
        );
      case 1: return _Step1Details(
          tees        : _tees,
          selectedTee : _selectedTee,
          date        : _date,
          betCtrl     : _betCtrl,
          activeGames : _activeGames,
          formKey     : _step1Key,
          onPickTee   : (t) => setState(() => _selectedTee = t),
          onPickDate  : (d) => setState(() => _date = d),
          onToggleGame: (g, on) => setState(() {
            on ? _activeGames.add(g) : _activeGames.remove(g);
          }),
        );
      case 2: return _Step2Players(
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
      case 3: return _Step3Review(
          createNew          : _createNewTournament,
          tournamentName     : _createNewTournament
              ? _nameCtrl.text.trim()
              : (_existingTournament?.name ?? '—'),
          tee                : _selectedTee!,
          date               : _date,
          betUnit            : double.tryParse(_betCtrl.text) ?? 1.0,
          activeGames        : _activeGames.toList(),
          selectedPlayers    : _allPlayers.where((p) => _selectedIds.contains(p.id)).toList(),
          createError        : _createError,
        );
      default: return const SizedBox.shrink();
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

  const _BottomBar({
    required this.step,
    required this.totalSteps,
    required this.canAdvance,
    required this.creating,
    required this.onBack,
    required this.onNext,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
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
  final bool createNew;
  final List<Tournament> tournaments;
  final Tournament? existingTournament;
  final TextEditingController nameCtrl;
  final GlobalKey<FormState> formKey;
  final ValueChanged<bool> onToggleNew;
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
                  value: t,
                  child: Text(t.name),
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
// Step 1 — Round Details
// ===========================================================================

class _Step1Details extends StatelessWidget {
  final List<TeeInfo> tees;
  final TeeInfo? selectedTee;
  final DateTime date;
  final TextEditingController betCtrl;
  final Set<String> activeGames;
  final GlobalKey<FormState> formKey;
  final ValueChanged<TeeInfo?> onPickTee;
  final ValueChanged<DateTime> onPickDate;
  final void Function(String game, bool on) onToggleGame;

  const _Step1Details({
    required this.tees,
    required this.selectedTee,
    required this.date,
    required this.betCtrl,
    required this.activeGames,
    required this.formKey,
    required this.onPickTee,
    required this.onPickDate,
    required this.onToggleGame,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Round Details', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),

          // Course / Tee
          DropdownButtonFormField<TeeInfo>(
            value: selectedTee,
            decoration: const InputDecoration(
              labelText: 'Course & Tee',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.golf_course),
            ),
            items: tees.map((t) => DropdownMenuItem(
              value: t,
              child: Text(t.display),
            )).toList(),
            onChanged: onPickTee,
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
          const SizedBox(height: 16),

          // Bet unit
          TextFormField(
            controller: betCtrl,
            decoration: const InputDecoration(
              labelText: 'Bet unit (\$)',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.attach_money),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Enter a bet unit';
              if (double.tryParse(v) == null) return 'Must be a number';
              return null;
            },
          ),
          const SizedBox(height: 24),

          // Games
          Text('Active Games',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
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
  final Set<int> selectedIds;
  final String search;
  final ValueChanged<int> onToggle;
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
        : players.where((p) =>
            p.name.toLowerCase().contains(search.toLowerCase())).toList();

    return Column(children: [
      // Header
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Select Players',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('${selectedIds.length} selected  •  '
              '${(selectedIds.length / 4).ceil()} foursome(s)',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Colors.grey)),
        ]),
      ),

      // Search + select all/none
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

      // Player list
      Expanded(
        child: filtered.isEmpty
            ? const Center(child: Text('No players found.'))
            : ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final p   = filtered[i];
                  final sel = selectedIds.contains(p.id);
                  return CheckboxListTile(
                    value   : sel,
                    onChanged: (_) => onToggle(p.id),
                    title   : Text(p.name),
                    subtitle: Text('Handicap ${p.handicapIndex}'),
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

      // Min-player hint
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
// Step 3 — Review
// ===========================================================================

class _Step3Review extends StatelessWidget {
  final bool createNew;
  final String tournamentName;
  final TeeInfo tee;
  final DateTime date;
  final double betUnit;
  final List<String> activeGames;
  final List<PlayerProfile> selectedPlayers;
  final String? createError;

  const _Step3Review({
    required this.createNew,
    required this.tournamentName,
    required this.tee,
    required this.date,
    required this.betUnit,
    required this.activeGames,
    required this.selectedPlayers,
    this.createError,
  });

  @override
  Widget build(BuildContext context) {
    final groupCount = (selectedPlayers.length / 4).ceil();
    final gameLabels = {for (final (v, l) in _allGames) v: l};

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Review', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('Tap "Create Round" to draw foursomes and set up all games.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: Colors.grey)),
        const SizedBox(height: 20),

        _ReviewCard(children: [
          _ReviewRow(Icons.emoji_events,  'Tournament',
              '${createNew ? "New — " : ""}$tournamentName'),
          _ReviewRow(Icons.golf_course,   'Course',   tee.display),
          _ReviewRow(Icons.calendar_today,'Date',
              DateFormat('MMMM d, yyyy').format(date)),
          _ReviewRow(Icons.attach_money,  'Bet unit', '\$${betUnit.toStringAsFixed(2)}'),
          _ReviewRow(Icons.people,        'Players',
              '${selectedPlayers.length} players → $groupCount foursome(s)'),
        ]),

        const SizedBox(height: 16),

        if (activeGames.isNotEmpty) ...[
          Text('Active Games',
              style: Theme.of(context).textTheme.titleSmall
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
          const SizedBox(height: 16),
        ],

        Text('Players',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        _ReviewCard(
          children: selectedPlayers
              .map((p) => _ReviewRow(
                    Icons.person_outline,
                    p.name,
                    'Hcp ${p.handicapIndex}',
                  ))
              .toList(),
        ),

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
                        color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ]),
          ),
        ],

        const SizedBox(height: 80), // room for bottom bar
      ]),
    );
  }
}

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
  final String label;
  final String value;
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
