import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../utils/create_casual_round.dart';
import '../widgets/error_view.dart';
import '../widgets/game_chip.dart';
import '../utils/add_halved_golfer.dart';
import '../utils/golfer_invite.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/halved_mark.dart';
import '../widgets/inline_message.dart';
import '../widgets/course_search_field.dart';
import 'player_form_screen.dart';

class CasualRoundScreen extends StatefulWidget {
  const CasualRoundScreen({super.key});

  @override
  State<CasualRoundScreen> createState() => _CasualRoundScreenState();
}

class _CasualRoundScreenState extends State<CasualRoundScreen> {
  bool _loading = true;
  Object? _error;
  bool _creating = false;

  List<CourseInfo> _courses = [];
  List<TeeInfo> _tees = [];
  List<PlayerProfile> _players = [];
  /// Wizard step: 0 = course + game, 1 = players + tees.
  int _step = 0;
  /// Search text for the player picker (keeps it usable with a big roster).
  String _playerSearch = '';
  final TextEditingController _playerSearchCtrl = TextEditingController();

  CourseInfo? _selectedCourse;
  // Map of Player ID to Tee ID
  final Map<int, int> _playerTees = {};
  // Map of Player ID to Group # (only consulted when multi_skins is active;
  // single-foursome casual rounds ignore this entirely).  Defaults to 1.
  final Map<int, int> _playerGroups = {};

  // Active games set — starts empty so the user must explicitly pick.
  // The catalog drives which games are shown and which can combine.
  final Set<String> _activeGames = {};

  /// Group-size filter for the game picker: '2' | '3' | '4' | 'groups'.
  /// Defaults to a foursome (the common case — sees the most games); smaller
  /// groups tap their size to get the curated list of games that fit.
  String _sizeFilter = '4';

  /// Games shown for the current group-size filter. Already-selected games
  /// stay visible so changing the filter never hides what you've picked.
  List<GameMeta> get _filteredCasualGames => casualGames.where((m) {
        if (_activeGames.contains(m.id)) return true;
        if (_sizeFilter == 'groups') return m.acrossGroups;
        return !m.acrossGroups && m.supportsSize(int.parse(_sizeFilter));
      }).toList();

  /// True when the user picked Multi-Group Skins — turns on the per-player
  /// Group dropdown and lets the foursome count exceed one.
  bool get _multiGroup => _activeGames.contains(GameIds.multiSkins);

  /// Highest group number currently assigned, plus one (so the dropdown
  /// always offers "create a new group" if there's room).  Capped so the
  /// menu doesn't grow unbounded.
  int get _maxGroupOption {
    final used = _playerGroups.values.toSet();
    final highest = used.isEmpty ? 0 : used.reduce((a, b) => a > b ? a : b);
    // Allow one extra slot beyond the current max so users can split off
    // a new group.  Hard cap at the number of participating players —
    // there's no point offering more groups than there are players.
    return (highest + 1).clamp(1, _playerTees.length.clamp(1, 99));
  }

  /// The group a newly-added player should land in by default — the lowest
  /// existing group that still has room (< 4 players), or a brand-new
  /// group when every current group is full.  Keeps the user from having
  /// to manually reassign every fifth player to group 2.
  int _nextAvailableGroup() {
    final counts = <int, int>{};
    for (final g in _playerGroups.values) {
      counts[g] = (counts[g] ?? 0) + 1;
    }
    if (counts.isEmpty) return 1;
    final sortedGroups = counts.keys.toList()..sort();
    for (final g in sortedGroups) {
      if (counts[g]! < 4) return g;
    }
    return sortedGroups.last + 1;
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _playerSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final authPlayer = context.read<AuthProvider>().player;

      final results = await Future.wait([
        client.getCourses(),
        client.getTees(),
        client.getPlayers(),
      ]);

      if (!mounted) return;

      setState(() {
        _courses = results[0] as List<CourseInfo>;
        _tees = results[1] as List<TeeInfo>;
        _players = (results[2] as List<PlayerProfile>)
            .where((p) => !p.isPhantom)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

        // Automatically select the logged-in user if available.
        if (authPlayer != null) {
          // If the auth player exists in the players list, add them to the selection map.
          // We will assign a default tee later when a course is chosen.
          if (_players.any((p) => p.id == authPlayer.id)) {
            _playerTees[authPlayer.id]   = 0; // 0 means unassigned tee
            _playerGroups[authPlayer.id] = 1;
          }
        }

        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// Called by the inline [CourseSearchField] once a course is chosen (an
  /// existing account course, or a catalog/API one it just cloned in). Refresh
  /// courses+tees (a freshly cloned course brings new tees), select it, and
  /// assign default tees to any already-selected players.
  Future<void> _onCourseSelected(CourseInfo course) async {
    final client = context.read<AuthProvider>().client;
    final results = await Future.wait([client.getCourses(), client.getTees()]);
    if (!mounted) return;
    setState(() {
      _courses = results[0] as List<CourseInfo>;
      _tees    = results[1] as List<TeeInfo>;
      _selectedCourse =
          _courses.firstWhere((c) => c.id == course.id, orElse: () => course);
      for (final pid in _playerTees.keys.toList()) {
        final cur = _playerTees[pid];
        final valid = cur != 0 && _availableTees.any((t) => t.id == cur);
        if (!valid) {
          final player = _players.firstWhere((p) => p.id == pid,
              orElse: () => _players.first);
          _playerTees[pid] = _defaultTeeIdForPlayer(player);
        }
      }
    });
  }

  List<TeeInfo> get _availableTees {
    if (_selectedCourse == null) return [];
    return _tees.where((t) => t.course.id == _selectedCourse!.id).toList();
  }

  /// Tees at the currently-selected course that this player can play:
  /// matches the player's sex OR is unisex (tee.sex == null).  Sorted
  /// by (sort_priority ASC, tee_name ASC) so the "default" tee at this
  /// course for this sex comes out first.  Returns [] if no course is
  /// selected yet.
  List<TeeInfo> _teesForPlayer(PlayerProfile p) {
    final tees = _availableTees
        .where((t) => t.sex == null || t.sex == p.sex)
        .toList()
      ..sort((a, b) {
        final pc = a.sortPriority.compareTo(b.sortPriority);
        if (pc != 0) return pc;
        return a.teeName.compareTo(b.teeName);
      });
    return tees;
  }

  /// Tee id to pre-select for this player: the lowest-priority tee in
  /// [_teesForPlayer].  Returns 0 if no course is selected or no tee
  /// matches (shouldn't happen on a well-seeded course).
  int _defaultTeeIdForPlayer(PlayerProfile p) {
    final tees = _teesForPlayer(p);
    return tees.isEmpty ? 0 : tees.first.id;
  }

  /// Render one game chip, applying catalog combination rules on toggle.
  /// Visual styling lives in [GameSelectableChip] (single source of
  /// truth for the D-10 polished look — green fill, white bold text,
  /// no checkmark icon).
  Widget _buildGameChip(GameMeta meta) {
    final selected = _activeGames.contains(meta.id);
    return GameSelectableChip(
      gameId:   meta.id,
      selected: selected,
      onSelected: (picked) {
        setState(() {
          if (picked) {
            // Compute the new set BEFORE mutating _activeGames.
            final updated = applyGameToggle(_activeGames, meta.id, true);
            _activeGames.clear();
            _activeGames.addAll(updated);
          } else {
            // Refuse to deselect the last remaining game.
            if (_activeGames.length == 1 && selected) return;
            _activeGames.remove(meta.id);
          }
        });
      },
    );
  }

  /// Inline-create a login-less golfer during casual-round setup. Adds them to
  /// the roster and, if a course is already chosen, auto-selects them with their
  /// default tee. Reuses PlayerFormScreen (which pops the saved PlayerProfile).
  Future<void> _addGolfer() async {
    final created = await Navigator.of(context).push<PlayerProfile>(
      MaterialPageRoute(builder: (_) => const PlayerFormScreen()),
    );
    _addCreatedGolfer(created);
    if (created != null && mounted) {
      await maybeOfferRoundSmsInvite(context, created,
          courseName: _selectedCourse?.name);
    }
  }

  /// Add an existing Halved member (not yet in my roster) by phone number.
  Future<void> _addHalvedGolfer() async {
    final created = await addHalvedGolferByPhone(context);
    _addCreatedGolfer(created);
  }

  void _addCreatedGolfer(PlayerProfile? created) {
    if (created == null || !mounted) return;
    setState(() {
      if (!_players.any((p) => p.id == created.id)) {
        _players = [..._players, created]
          ..sort((a, b) => a.name.compareTo(b.name));
      }
    });
    if (_selectedCourse != null) {
      _onPlayerToggle(created.id, true);
    }
  }

  /// Players to show in the picker: filtered by the search box, with selected
  /// golfers (and You) floated to the top, then alphabetical — so the screen
  /// stays usable even with a large roster.
  List<PlayerProfile> _playersForDisplay() {
    final myId = context.read<AuthProvider>().player?.id;
    final q = _playerSearch.trim().toLowerCase();
    final list = _players
        .where((p) => q.isEmpty || p.name.toLowerCase().contains(q))
        .toList();
    list.sort((a, b) {
      final aSel = _playerTees.containsKey(a.id);
      final bSel = _playerTees.containsKey(b.id);
      if (aSel != bSel) return aSel ? -1 : 1;
      if (a.id == myId) return -1;
      if (b.id == myId) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  void _onPlayerToggle(int playerId, bool selected) {
    setState(() {
      if (selected) {
        // Clear the search after a pick so the checked golfers (floated to the
        // top) are visible again, ready for the next selection.
        _playerSearch = '';
        _playerSearchCtrl.clear();
        // Assign the right default tee for this specific player (by sex
        // + priority).  Women get their lowest-priority women's tee,
        // men get their lowest-priority men's tee.
        final player = _players.firstWhere((p) => p.id == playerId);
        _playerTees[playerId] = _defaultTeeIdForPlayer(player);
        // Auto-spillover: land in the lowest group with room (< 4
        // players).  Without this the 5th player joined group 1 and
        // the round-setup API rejected the 5-player group.
        _playerGroups[playerId] = _nextAvailableGroup();
      } else {
        _playerTees.remove(playerId);
        _playerGroups.remove(playerId);
      }
    });
  }

  Future<void> _createRound() async {
    if (_selectedCourse == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a course.')),
      );
      return;
    }
    if (_activeGames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one game.')),
      );
      return;
    }
    if (_playerTees.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least 2 players.')),
      );
      return;
    }
    // Group capacity check — the server caps each group at 4 players.
    // Auto-spillover handles this for new additions, but a user could
    // overstuff a group by manually reassigning, so catch it before the
    // round-setup POST and surface a friendly message.
    if (_multiGroup) {
      final counts = <int, int>{};
      for (final g in _playerGroups.values) {
        counts[g] = (counts[g] ?? 0) + 1;
      }
      final overstuffed = counts.entries
          .where((e) => e.value > 4)
          .map((e) => 'group ${e.key} has ${e.value}')
          .toList();
      if (overstuffed.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Each group can have at most 4 players — ${overstuffed.join(", ")}.',
          ),
        ));
        return;
      }
    }
    // Validate each active game's player-count requirement from the catalog.
    for (final gameId in _activeGames) {
      final meta = gameMeta(gameId);
      if (meta == null) continue;
      final n = _playerTees.length;
      if (meta.exactPlayers != null && n != meta.exactPlayers) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${meta.displayName} requires exactly '
              '${meta.exactPlayers} players.'),
        ));
        return;
      }
      if (meta.minPlayers != null && n < meta.minPlayers!) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${meta.displayName} requires at least '
              '${meta.minPlayers} players.'),
        ));
        return;
      }
      if (meta.maxPlayers != null && n > meta.maxPlayers!) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${meta.displayName} supports at most '
              '${meta.maxPlayers} players.'),
        ));
        return;
      }
    }
    if (_playerTees.values.any((teeId) => teeId == 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please assign a tee for all selected players.')),
      );
      return;
    }

    setState(() { _creating = true; _error = null; });

    try {
      // Create the round + foursome and work out where to route via the shared
      // helper (also used by the onboarding wizard, so the dispatch can't
      // drift).  For a single-game casual round it drops the user straight on
      // the game's setup screen; multi-game combos fall back to the /round hub.
      final launch = await createCasualRound(
        client: context.read<AuthProvider>().client,
        roundProvider: context.read<RoundProvider>(),
        courseId: _selectedCourse!.id,
        playerTees: _playerTees,
        activeGames: _activeGames,
        playerGroups: _multiGroup ? _playerGroups : null,
      );

      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        launch.effectiveRoute,
        arguments: launch.effectiveArgs,
      );
    } catch (e) {
      if (mounted) setState(() { _error = e; _creating = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GolfAppBar(
        title: _step == 0
            ? 'Casual Round · Course & Game'
            : 'Casual Round · Players',
      ),
      body: _buildBody(),
      bottomNavigationBar: (_loading || _error != null) ? null : _buildNav(),
    );
  }

  Widget _buildNav() {
    final canNext = _selectedCourse != null && _activeGames.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            if (_step == 1)
              OutlinedButton(
                onPressed: _creating ? null : () => setState(() => _step = 0),
                child: const Text('Back'),
              ),
            const Spacer(),
            if (_step == 0)
              FilledButton(
                onPressed: canNext ? () => setState(() => _step = 1) : null,
                child: const Text('Next'),
              )
            else
              FilledButton.icon(
                onPressed: _creating ? null : _createRound,
                icon: _creating
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.tune),
                label: Text(_creating ? 'Configuring…' : 'Configure Round'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(
        message: friendlyError(_error!),
        isNetwork: isNetworkError(_error!),
        onRetry: _loadData,
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Step 1: course + game ──
          if (_step == 0) ...[
          Text('Select Course', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          // Inline combined search: type to see matches from your courses + the
          // shared catalog right here, with a full-database/API fallback.
          CourseSearchField(
            selected: _selectedCourse,
            onSelected: _onCourseSelected,
          ),
          const SizedBox(height: 24),

          Text('Games', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          // Group-size filter — surfaces the games that fit your group so a
          // twosome/threesome isn't hunting through foursome-only options.
          Text("Who's playing?",
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '2', label: Text('2')),
              ButtonSegment(value: '3', label: Text('3')),
              ButtonSegment(value: '4', label: Text('4')),
              ButtonSegment(value: 'groups', label: Text('Across groups')),
            ],
            selected: {_sizeFilter},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _sizeFilter = s.first),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final meta in _filteredCasualGames)
                _buildGameChip(meta),
            ],
          ),
          ], // ── end step 1

          // ── Step 2: players + tees ──
          if (_step == 1) ...[
          // How many golfers the chosen game(s) allow — shown up front, and
          // it flips to an error if the current selection is off.
          for (final gameId in _activeGames)
            _gamePlayerCountHint(gameId),
          const SizedBox(height: 8),

          Text('Select Players & Tees',
              style: Theme.of(context).textTheme.titleLarge),
          Wrap(
            children: [
              TextButton.icon(
                onPressed: _addGolfer,
                icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                label: const Text('Add Golfer'),
              ),
              TextButton.icon(
                onPressed: _addHalvedGolfer,
                icon: const Icon(Icons.phone_iphone, size: 18),
                label: const Text('Halved Golfer search'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          if (_selectedCourse == null)
            const InlineMessage(
              text: 'Please select a course first to assign tees.',
              kind: InlineMessageKind.info,
            )
          else ...[
            TextField(
              controller: _playerSearchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search golfers…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _playerSearch = v),
            ),
            const SizedBox(height: 8),
            Builder(builder: (context) {
              final shown = _playersForDisplay();
              if (shown.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No golfers match your search.'),
                );
              }
              return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: shown.length,
              itemBuilder: (context, i) {
                final player = shown[i];
                final isSelected = _playerTees.containsKey(player.id);
                final playerTeeId = _playerTees[player.id];
                // The logged-in player is always locked in as a participant.
                final authPlayer = context.read<AuthProvider>().player;
                final isLockedIn = authPlayer != null && player.id == authPlayer.id;

                final scheme = Theme.of(context).colorScheme;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        // Per D-06: the logged-in user's checkbox is
                        // *locked*, not disabled.  Use the active brand-
                        // green fill (not the default disabled gray) so
                        // the row reads "you're in" — and tag the You
                        // chip with a lock icon to show why it can't be
                        // toggled off.
                        Checkbox(
                          value:    isSelected,
                          onChanged: isLockedIn
                              ? null
                              : (v) => _onPlayerToggle(player.id, v ?? false),
                          fillColor: isLockedIn
                              ? WidgetStateProperty.all(scheme.primary)
                              : null,
                          checkColor: isLockedIn ? Colors.white : null,
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Flexible(
                                  child: Text(
                                    player.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (player.isOnApp) ...[
                                  const SizedBox(width: 6),
                                  const HalvedMark(size: 18),
                                ] else if (!isLockedIn) ...[
                                  const SizedBox(width: 6),
                                  // Invite a golfer who isn't on the app yet.
                                  Builder(
                                    builder: (btnCtx) => IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      tooltip: 'Invite ${player.name}',
                                      icon: const Icon(
                                          Icons.person_add_alt_1_outlined,
                                          size: 18),
                                      onPressed: () =>
                                          inviteGolfer(btnCtx, player),
                                    ),
                                  ),
                                ],
                                if (isLockedIn) ...[
                                  const SizedBox(width: 6),
                                  Chip(
                                    avatar: Icon(Icons.lock_outline,
                                        size: 12,
                                        color: scheme.onSecondaryContainer),
                                    label: const Text('You',
                                        style: TextStyle(fontSize: 11)),
                                    padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: scheme.secondaryContainer,
                                  ),
                                ],
                              ]),
                              Text('Hcp: ${player.handicapIndex}', style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        if (isSelected) ...[
                          if (_multiGroup)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: DropdownButton<int>(
                                value: _playerGroups[player.id] ?? 1,
                                hint: const Text('Group'),
                                items: [
                                  for (int g = 1; g <= _maxGroupOption; g++)
                                    DropdownMenuItem(
                                      value: g,
                                      child: Text('G$g'),
                                    ),
                                ],
                                onChanged: (g) {
                                  if (g != null) {
                                    setState(() => _playerGroups[player.id] = g);
                                  }
                                },
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Builder(builder: (_) {
                              // Dropdown only shows tees this player can
                              // legitimately play: matching sex + any
                              // unisex tees at the course, sorted by
                              // priority so the default is first.
                              final playerTees = _teesForPlayer(player);
                              // If the stored value is 0 or not in the
                              // filtered list, show the hint instead of
                              // forcing Flutter to render a missing value.
                              final effectiveValue =
                                  playerTees.any((t) => t.id == playerTeeId)
                                      ? playerTeeId
                                      : null;
                              return DropdownButton<int>(
                                value: effectiveValue,
                                hint: const Text('Tee'),
                                items: playerTees.map((t) => DropdownMenuItem(
                                  value: t.id,
                                  child: Text(t.teeName),
                                )).toList(),
                                onChanged: (teeId) {
                                  if (teeId != null) {
                                    setState(() => _playerTees[player.id] = teeId);
                                  }
                                },
                              );
                            }),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
            }),
          ],
            const SizedBox(height: 80),
          ], // ── end step 2
        ],
      ),
    );
  }

  /// Players-step guidance: how many golfers the chosen game allows, turning
  /// into an error when the current count is off.
  /// "2 or 4" / "2, 3 or 4" for a set of supported sizes.
  String _sizesLabel(Set<int> s) {
    final l = s.toList()..sort();
    if (l.length == 1) return '${l.first}';
    return '${l.sublist(0, l.length - 1).join(', ')} or ${l.last}';
  }

  Widget _gamePlayerCountHint(String gameId) {
    final meta = gameMeta(gameId);
    if (meta == null) return const SizedBox.shrink();
    final n = _playerTees.length;
    final String range;
    if (meta.sizes != null) {
      range = '${_sizesLabel(meta.sizes!)} players';
    } else if (meta.exactPlayers != null) {
      range = '${meta.exactPlayers} players';
    } else if (meta.minPlayers != null && meta.maxPlayers != null) {
      range = '${meta.minPlayers}–${meta.maxPlayers} players';
    } else if (meta.minPlayers != null) {
      range = '${meta.minPlayers}+ players';
    } else if (meta.maxPlayers != null) {
      range = 'up to ${meta.maxPlayers} players';
    } else {
      range = 'any number of players';
    }
    var text = '${meta.displayName}: $range';
    var kind = InlineMessageKind.info;
    if (meta.sizes != null && !meta.sizes!.contains(n)) {
      text += ' — needs ${_sizesLabel(meta.sizes!)}.';
      kind = InlineMessageKind.error;
    } else if (meta.exactPlayers != null && n != meta.exactPlayers) {
      final diff = meta.exactPlayers! - n;
      text += diff > 0 ? ' — add $diff more.' : ' — remove ${-diff}.';
      kind = InlineMessageKind.error;
    } else if (meta.minPlayers != null && n < meta.minPlayers!) {
      text += ' — add ${meta.minPlayers! - n} more.';
      kind = InlineMessageKind.error;
    } else if (meta.maxPlayers != null && n > meta.maxPlayers!) {
      text += ' — remove ${n - meta.maxPlayers!}.';
      kind = InlineMessageKind.error;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InlineMessage(text: text, kind: kind),
    );
  }
}
