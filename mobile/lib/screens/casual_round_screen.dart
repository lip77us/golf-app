import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/game_chip.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_message.dart';

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
  // Map of Player ID to Group # (only consulted when multi_skins is active;
  // single-foursome casual rounds ignore this entirely).  Defaults to 1.
  final Map<int, int> _playerGroups = {};

  // Active games set — starts empty so the user must explicitly pick.
  // The catalog drives which games are shown and which can combine.
  final Set<String> _activeGames = {};

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

  void _onPlayerToggle(int playerId, bool selected) {
    setState(() {
      if (selected) {
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
      final client = context.read<AuthProvider>().client;
      final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // Create standalone round.  The cap defaults to True on the
      // server; each game's setup screen lets the user opt out alongside
      // the handicap-mode picker, so there's no need to surface it here.
      final round = await client.createRound(
        courseId: _selectedCourse!.id,
        date: dateStr,
        activeGames: _activeGames.toList(),
      );

      // Setup foursome with players and their specific tees.  In
      // multi-group mode we also pass group_number per player so the
      // server respects the user's group assignments (and skips the
      // automatic 4-then-3 partition + phantom padding).
      final playersSetup = _playerTees.entries.map((e) {
        final entry = <String, int>{
          'player_id': e.key,
          'tee_id'   : e.value,
        };
        if (_multiGroup) {
          entry['group_number'] = _playerGroups[e.key] ?? 1;
        }
        return entry;
      }).toList();

      final fullRound = await client.setupRound(
        round.id,
        players: playersSetup,
        // Don't randomise in multi-group mode — the user picked the groups.
        randomise: !_multiGroup,
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

      // For single-game casual rounds, skip the /round hub and drop directly
      // onto the game's setup screen.  For multi-game combos (e.g. Skins +
      // Nassau), go to /round so the user can configure each game in turn.
      String? directRoute;
      Object? directArgs;

      if (_activeGames.length == 1 && firstFs != null) {
        switch (_activeGames.first) {
          case GameIds.sixes:
            directRoute = '/sixes-setup';
            directArgs  = firstFs.id;
          case GameIds.points531:
            directRoute = '/points-531-setup';
            directArgs  = firstFs.id;
          case GameIds.skins:
            directRoute = '/skins-setup';
            directArgs  = firstFs.id;
          case GameIds.tripleCup:
            directRoute = '/triple-cup-setup';
            directArgs  = firstFs.id;
          case GameIds.multiSkins:
            directRoute = '/multi-skins-setup';
            directArgs  = fullRound.id;
          case GameIds.nassau:
            directRoute = '/nassau-setup';
            directArgs  = firstFs.id;
          case GameIds.strokePlay:
            directRoute = '/low-net-setup';
            directArgs  = fullRound.id;
          case GameIds.matchPlay:
            // Match Play auto-dispatches by foursome size:
            //   3 players → Three-Person Match (Points 5-3-1 + 1v1 final)
            //   4 players → single-elimination bracket (semis 1–9,
            //               Final + 3rd-place 10–18)
            final realCount = firstFs.realPlayers.length;
            if (realCount == 3) {
              directRoute = '/three-person-match-setup';
            } else {
              directRoute = '/match-play-setup';
            }
            directArgs = firstFs.id;
        }
      }

      if (directRoute != null) {
        Navigator.of(context).pushReplacementNamed(
          directRoute,
          arguments: directArgs,
        );
      } else {
        // Multi-game combo or Stableford (no per-round setup yet) → hub.
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
      appBar: const GolfAppBar(title: 'Start Casual Round'),
      body: _buildBody(),
      floatingActionButton: _loading || _error != null ? null : FloatingActionButton.extended(
        onPressed: _creating ? null : _createRound,
        icon: _creating ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.tune),
        label: Text(_creating ? 'Configuring...' : 'Configure Round'),
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
            isExpanded: true,
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
              for (final meta in casualGames)
                _buildGameChip(meta),
            ],
          ),
          // Inline player-count warnings driven by the game catalog.
          for (final gameId in _activeGames) ...[
            Builder(builder: (_) {
              final meta = gameMeta(gameId);
              if (meta == null) return const SizedBox.shrink();
              final n = _playerTees.length;
              String? warning;
              if (meta.exactPlayers != null && n != meta.exactPlayers) {
                final diff = meta.exactPlayers! - n;
                warning = diff > 0
                    ? '${meta.displayName} needs exactly ${meta.exactPlayers} players'
                      ' — add $diff more below.'
                    : '${meta.displayName} is a ${meta.exactPlayers}-player game'
                      ' — remove ${-diff} player(s) below.';
              } else if (meta.minPlayers != null && n < meta.minPlayers!) {
                warning = '${meta.displayName} needs at least ${meta.minPlayers}'
                    ' players — add ${meta.minPlayers! - n} more below.';
              } else if (meta.maxPlayers != null && n > meta.maxPlayers!) {
                warning = '${meta.displayName} supports at most ${meta.maxPlayers}'
                    ' players — remove ${n - meta.maxPlayers!} player(s) below.';
              }
              if (warning == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: InlineMessage(
                  text: warning,
                  kind: InlineMessageKind.error,
                ),
              );
            }),
          ],
          const SizedBox(height: 24),

          Text('Select Players & Tees', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),

          if (_selectedCourse == null)
            const InlineMessage(
              text: 'Please select a course first to assign tees.',
              kind: InlineMessageKind.info,
            )
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
            ),
            const SizedBox(height: 80),
        ],
      ),
    );
  }
}
