import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';

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

  CourseInfo? _selectedCourse;
  // Map of Player ID to Tee ID
  final Map<int, int> _playerTees = {};

  // Game mode.  Sixes is the default; the user can swap it for Points
  // 5-3-1 when the group has exactly 3 real players.  Nassau and Skins
  // are reserved chips in the picker but aren't selectable yet.
  final Set<String> _activeGames = {'sixes'};

  /// Keys in this list ARE the server-side game identifiers — Points
  /// 5-3-1 is 'points_531' (matches core.GameType.POINTS_531), not the
  /// earlier placeholder 'points_5_3_1'.  Label is what the user sees
  /// on the chip.
  static const _allGames = [
    ('sixes',       "Six's"),
    ('points_531',  'Points (5-3-1)'),
    ('nassau',      'Nassau'),
    ('skins',       'Skins'),
  ];

  /// Games that are mutually exclusive as *primary* per-foursome
  /// game.  Picking one auto-deselects all others in its group.
  /// Skins, Nassau, Sixes and Points 5-3-1 are all mutually exclusive
  /// because they each own the hole-by-hole entry screen.
  static const _mutexGroups = [
    {'sixes', 'points_531', 'skins', 'nassau'},
  ];

  /// Apply any mutex constraints after a chip toggle.  If turning ON a
  /// game that's in a mutex group, turn OFF every other member of that
  /// group.  Safe to call even when no constraints are violated — it's
  /// a no-op in that case.
  void _applyGameMutex(String justAdded) {
    for (final group in _mutexGroups) {
      if (group.contains(justAdded)) {
        _activeGames.removeWhere((g) => g != justAdded && group.contains(g));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadData();
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
            _playerTees[authPlayer.id] = 0; // 0 means unassigned tee
          }
        }

        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
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

  /// Render one game FilterChip, handling enabled/disabled state and
  /// mutex cleanup on toggle.
  Widget _buildGameChip(String gameValue, String gameLabel) {
    final selected = _activeGames.contains(gameValue);
    return FilterChip(
      label: Text(gameLabel),
      selected: selected,
      onSelected: (picked) {
        setState(() {
          if (picked) {
            _activeGames.add(gameValue);
            _applyGameMutex(gameValue);
          } else {
            // Refuse to deselect the last remaining game.
            if (_activeGames.length == 1 &&
                _activeGames.contains(gameValue)) {
              return;
            }
            _activeGames.remove(gameValue);
          }
        });
      },
    );
  }

  void _onPlayerToggle(int playerId, bool selected) {
    setState(() {
      if (selected) {
        // Assign the right default tee for this specific player (by sex
        // + priority).  Women get their lowest-priority women's tee,
        // men get their lowest-priority men's tee.
        final player = _players.firstWhere((p) => p.id == playerId);
        _playerTees[playerId] = _defaultTeeIdForPlayer(player);
      } else {
        _playerTees.remove(playerId);
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
    if (_playerTees.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least 2 players.')),
      );
      return;
    }
    // Points 5-3-1 is a hard 3-player game — its tie-splitting math
    // (5/3/1 baseline → 9 points per hole) only sums to zero with
    // exactly three scorers, so block Start until the roster is right.
    if (_activeGames.contains('points_531') && _playerTees.length != 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
            'Points 5-3-1 requires exactly 3 players.')),
      );
      return;
    }
    // Six's is 2v2 best-ball across three 6-hole segments — it requires
    // exactly 4 real players.  Mirrors the 3-player lock on Points
    // 5-3-1 above; prevents the user from landing on the Six's setup
    // screen with an invalid foursome.
    if (_activeGames.contains('sixes') && _playerTees.length != 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
            "Six's requires exactly 4 players.")),
      );
      return;
    }
    // Skins supports 2–4 real players.
    if (_activeGames.contains('skins') &&
        (_playerTees.length < 2 || _playerTees.length > 4)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
            'Skins requires 2–4 players.')),
      );
      return;
    }
    // Nassau supports 2–4 real players (1v1 or 2v2).
    if (_activeGames.contains('nassau') &&
        (_playerTees.length < 2 || _playerTees.length > 4)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
            'Nassau requires 2–4 players (1v1 or 2v2).')),
      );
      return;
    }
    if (_playerTees.values.any((teeId) => teeId == 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please assign a tee for all selected players.')),
      );
      return;
    }

    setState(() { _creating = true; _error = null; });

    try {
      final client = context.read<AuthProvider>().client;
      final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // Create standalone round
      final round = await client.createRound(
        courseId: _selectedCourse!.id,
        date: dateStr,
        activeGames: _activeGames.toList(),
      );

      // Setup foursome with players and their specific tees
      final playersSetup = _playerTees.entries.map((e) => {
        'player_id': e.key,
        'tee_id': e.value,
      }).toList();

      final fullRound = await client.setupRound(
        round.id,
        players: playersSetup,
        randomise: true,
        autoSetupGames: false,
      );

      if (!mounted) return;

      // For a casual round there's exactly one foursome, and we already
      // know which game is active — so skip the /round "group card" hub
      // and drop the user straight on the match setup screen they would
      // have tapped into from /round anyway.  Fewer taps, same outcome.
      // Fallback to /round only if we can't figure out where to go
      // (defensive; shouldn't happen in practice).
      final rp = context.read<RoundProvider>();
      await rp.loadRound(fullRound.id);
      if (!mounted) return;

      final firstFs = fullRound.foursomes.isNotEmpty
          ? fullRound.foursomes.first
          : null;

      if (firstFs != null && _activeGames.contains('sixes')) {
        Navigator.of(context).pushReplacementNamed(
          '/sixes-setup',
          arguments: firstFs.id,
        );
      } else if (firstFs != null && _activeGames.contains('points_531')) {
        Navigator.of(context).pushReplacementNamed(
          '/points-531-setup',
          arguments: firstFs.id,
        );
      } else if (firstFs != null && _activeGames.contains('skins')) {
        Navigator.of(context).pushReplacementNamed(
          '/skins-setup',
          arguments: firstFs.id,
        );
      } else if (firstFs != null && _activeGames.contains('nassau')) {
        Navigator.of(context).pushReplacementNamed(
          '/nassau-setup',
          arguments: firstFs.id,
        );
      } else {
        Navigator.of(context).pushReplacementNamed(
          '/round',
          arguments: fullRound.id,
        );
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _creating = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Start Casual Round')),
      body: _buildBody(),
      floatingActionButton: _loading || _error != null ? null : FloatingActionButton.extended(
        onPressed: _creating ? null : _createRound,
        icon: _creating ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.play_arrow),
        label: Text(_creating ? 'Starting...' : 'Start Round'),
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
          Text('Select Course', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          DropdownButtonFormField<CourseInfo>(
            value: _selectedCourse,
            decoration: const InputDecoration(
              labelText: 'Course',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.golf_course),
            ),
            items: _courses.map((c) => DropdownMenuItem(
              value: c,
              child: Text(c.name),
            )).toList(),
            onChanged: (c) {
              setState(() {
                _selectedCourse = c;
                // Recompute each selected player's default tee when the
                // course changes.  Using the per-player helper keeps
                // Women pointed at a Women's tee and Men at a Men's tee,
                // sorted by sort_priority.  We overwrite only tees that
                // became invalid (wrong course) or were unassigned (0)
                // so manual overrides survive course changes where the
                // tee_id happens to still be valid — rare, but the
                // failure mode is safe.
                for (final pid in _playerTees.keys.toList()) {
                  final cur = _playerTees[pid];
                  final teeStillValid = cur != 0 &&
                      _availableTees.any((t) => t.id == cur);
                  if (!teeStillValid) {
                    final player = _players.firstWhere(
                      (p) => p.id == pid,
                      orElse: () => _players.first,
                    );
                    _playerTees[pid] = _defaultTeeIdForPlayer(player);
                  }
                }
              });
            },
          ),
          const SizedBox(height: 24),

          Text('Games', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (gameValue, gameLabel) in _allGames)
                _buildGameChip(gameValue, gameLabel),
            ],
          ),
          // Inline warnings when the picked game's roster requirement is
          // off.  Sixes is 2v2 best-ball so it needs exactly 4 real
          // players; Points 5-3-1 is a three-player game.  Either
          // mismatch blocks Start Round down below.
          if (_activeGames.contains('points_531') && _playerTees.length != 3)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _playerTees.length < 3
                    ? 'Points 5-3-1 needs exactly 3 players — '
                      'add ${3 - _playerTees.length} more below.'
                    : 'Points 5-3-1 is a 3-player game — '
                      'remove ${_playerTees.length - 3} player(s) below.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_activeGames.contains('sixes') && _playerTees.length != 4)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _playerTees.length < 4
                    ? "Six's needs exactly 4 players — "
                      'add ${4 - _playerTees.length} more below.'
                    : "Six's is a 4-player game — "
                      'remove ${_playerTees.length - 4} player(s) below.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_activeGames.contains('skins') &&
              (_playerTees.length < 2 || _playerTees.length > 4))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _playerTees.length < 2
                    ? 'Skins needs at least 2 players — '
                      'add ${2 - _playerTees.length} more below.'
                    : 'Skins supports at most 4 players — '
                      'remove ${_playerTees.length - 4} player(s) below.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_activeGames.contains('nassau') &&
              (_playerTees.length < 2 || _playerTees.length > 4))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _playerTees.length < 2
                    ? 'Nassau needs at least 2 players — '
                      'add ${2 - _playerTees.length} more below.'
                    : 'Nassau supports at most 4 players (1v1 or 2v2) — '
                      'remove ${_playerTees.length - 4} player(s) below.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 24),

          Text('Select Players & Tees', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),

          if (_selectedCourse == null)
            const Text('Please select a course first to assign tees.', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic))
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _players.length,
              itemBuilder: (context, i) {
                final player = _players[i];
                final isSelected = _playerTees.containsKey(player.id);
                final playerTeeId = _playerTees[player.id];
                // The logged-in player is always locked in as a participant.
                final authPlayer = context.read<AuthProvider>().player;
                final isLockedIn = authPlayer != null && player.id == authPlayer.id;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Checkbox(
                          value: isSelected,
                          onChanged: isLockedIn
                              ? null  // locked — creator cannot remove themselves
                              : (v) => _onPlayerToggle(player.id, v ?? false),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Text(player.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                if (isLockedIn) ...[
                                  const SizedBox(width: 6),
                                  const Chip(
                                    label: Text('You', style: TextStyle(fontSize: 11)),
                                    padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ]),
                              Text('Hcp: ${player.handicapIndex}', style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        if (isSelected)
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
                          )
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 80),
        ],
      ),
    );
  }
}
