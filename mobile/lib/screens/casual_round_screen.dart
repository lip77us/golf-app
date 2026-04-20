import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
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

  // Game mode
  final Set<String> _activeGames = {'sixes', 'match_play_18'};

  static const _allGames = [
    ('sixes', "Six's"),
    ('nassau', 'Nassau'),
    ('skins', 'Skins'),
    ('points_5_3_1', 'Points (5-3-1)'),
    ('match_play_18', '18-Hole Match Play'),
  ];

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

  void _onPlayerToggle(int playerId, bool selected) {
    setState(() {
      if (selected) {
        // If they select a player, assign the first available tee for the course (if a course is selected)
        final defaultTee = _availableTees.isNotEmpty ? _availableTees.first.id : 0;
        _playerTees[playerId] = defaultTee;
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
        betUnit: 1.0,
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

      // Navigate to the round screen and jump right in!
      Navigator.of(context).pushReplacementNamed('/round', arguments: fullRound.id);
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
                // Update default tees for already selected players if they don't have a valid tee
                if (_availableTees.isNotEmpty) {
                  final defaultTee = _availableTees.first.id;
                  for (final key in _playerTees.keys.toList()) {
                    // Only update if it was 0 (unassigned) or if the current tee doesn't belong to this course
                    if (_playerTees[key] == 0 || !_availableTees.any((t) => t.id == _playerTees[key])) {
                       _playerTees[key] = defaultTee;
                    }
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
                FilterChip(
                  label: Text(gameLabel),
                  selected: _activeGames.contains(gameValue),
                  onSelected: (gameValue == 'sixes' || gameValue == 'match_play_18')
                      ? (v) {
                          setState(() {
                            if (v) {
                              _activeGames.add(gameValue);
                            } else {
                              if (_activeGames.length > 1) {
                                _activeGames.remove(gameValue);
                              }
                            }
                          });
                        }
                      : null, // Disable the others entirely for now
                ),
            ],
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

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Checkbox(
                          value: isSelected,
                          onChanged: (v) => _onPlayerToggle(player.id, v ?? false),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(player.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              Text('Hcp: ${player.handicapIndex}', style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        if (isSelected)
                          Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: DropdownButton<int>(
                              value: playerTeeId == 0 ? null : playerTeeId,
                              hint: const Text('Tee'),
                              items: _availableTees.map((t) => DropdownMenuItem(
                                value: t.id,
                                child: Text(t.teeName),
                              )).toList(),
                              onChanged: (teeId) {
                                if (teeId != null) {
                                  setState(() => _playerTees[player.id] = teeId);
                                }
                              },
                            ),
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
