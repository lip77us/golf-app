/// screens/round_groups_screen.dart
///
/// Who shares a scorecard, for a round that already exists.
///
/// The create flow was the only place a casual round's field could be set, so
/// a Multi-Group Skins pool could neither be re-grouped nor take a latecomer
/// once it had been drawn. Both are things you find out on the first tee.
///
/// **The two halves have different rules and the screen says so.**
/// Re-grouping rewrites the draw, so the server refuses it once anybody in
/// the round has teed off (`setup_round` deletes and rebuilds the foursomes,
/// and `HoleScore.foursome` is CASCADE). Adding a golfer on a card of his own
/// touches nothing that exists, so it works whenever the round is live.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../utils/skins_cards.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/inline_message.dart';
import '../widgets/scorecard_groups.dart';

class RoundGroupsScreen extends StatefulWidget {
  final int roundId;
  const RoundGroupsScreen({super.key, required this.roundId});

  @override
  State<RoundGroupsScreen> createState() => _RoundGroupsScreenState();
}

class _RoundGroupsScreenState extends State<RoundGroupsScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// player id → group number, seeded from the round and edited here.
  final Map<int, int> _groups = {};
  List<PlayerProfile> _players = const [];
  Map<int, int> _tees = const {};     // player id → tee id, kept as drawn
  Map<int, int> _saved = const {};    // the draw as it stands on the server
  bool _anyScore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rp = context.read<RoundProvider>();
      await rp.loadRound(widget.roundId);
      final round = rp.round;
      if (round == null) throw Exception('Round not found');
      final groups = <int, int>{};
      final tees = <int, int>{};
      final players = <PlayerProfile>[];
      var scored = false;
      for (final fs in round.foursomes) {
        if (fs.hasAnyScore) scored = true;
        for (final m in fs.memberships) {
          if (m.player.isPhantom) continue;
          groups[m.player.id] = fs.groupNumber;
          if (m.tee?.id != null) tees[m.player.id] = m.tee!.id;
          players.add(m.player);
        }
      }
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(groups);
        _saved = Map<int, int>.from(groups);
        _tees = tees;
        _players = players;
        _anyScore = scored;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  bool get _dirty => _groups.toString() != _saved.toString();

  String? get _problem {
    final byId = {for (final p in _players) p.id: p};
    return cardsProblem(
      _groups,
      isOnApp: (id) => byId[id]?.isOnApp ?? false,
      nameOf: (id) => byId[id]?.name ?? 'That golfer',
    );
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.setupRound(
        widget.roundId,
        players: [
          for (final e in _groups.entries)
            if (_tees[e.key] != null)
              {'player_id': e.key, 'tee_id': _tees[e.key]!,
               'group_number': e.value},
        ],
        randomise: false,
      );
      if (!mounted) return;
      await context.read<RoundProvider>().loadRound(widget.roundId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _saving = false; });
    }
  }

  /// Add a golfer who is not in the round — on a card of his own, which is
  /// the only seating that is safe once anybody has teed off.
  Future<void> _addGolfer() async {
    final client = context.read<AuthProvider>().client;
    final roster = await client.getPlayers();
    if (!mounted) return;
    final inRound = _groups.keys.toSet();
    final choices = roster.where((p) => !inRound.contains(p.id)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (choices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Everybody on your roster is already in this round.')));
      return;
    }
    final picked = await showModalBottomSheet<PlayerProfile>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          Text('Add a golfer',
              style: Theme.of(ctx).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('He goes on a card of his own.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in choices)
                  ListTile(
                    title: Text(p.name),
                    subtitle: Text('Index ${p.handicapIndex}'),
                    onTap: () => Navigator.of(ctx).pop(p),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _saving = true);
    try {
      // Straight to the server rather than into the local draw: a new card
      // is safe mid-round, and batching it into Save would make it share the
      // regroup's refusal for no reason.
      await client.addPlayerToRound(widget.roundId, playerId: picked.id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${picked.name} is in, on his own card.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = _problem;
    return Scaffold(
      appBar: const GolfAppBar(title: 'Groups'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _players.isEmpty
              ? ErrorView(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('Who shares a scorecard?',
                        style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      'Golfers in the same group play on one card, so one of '
                      'them keeps the score. The skins pool runs across all '
                      'of them either way.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    if (_anyScore) ...[
                      const InlineMessage(
                        kind: InlineMessageKind.info,
                        text: 'Somebody has teed off, so the groups are set '
                            'for this round — re-drawing them would take the '
                            'scores with it. A golfer can still be added on a '
                            'card of his own.',
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (!_anyScore)
                      ScorecardGroups(
                        players: _players,
                        groups: _groups,
                        onChanged: (next) => setState(() {
                          _groups
                            ..clear()
                            ..addAll(next);
                        }),
                      )
                    else
                      for (final entry in cardsOf(_groups).entries.indexed)
                        _readOnlyCard(entry.$1 + 1, entry.$2.value),
                    if (problem != null && !_anyScore) ...[
                      const SizedBox(height: 4),
                      InlineMessage(
                          kind: InlineMessageKind.error, text: problem),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _addGolfer,
                      icon: const Icon(Icons.person_add_alt, size: 18),
                      label: const Text('Add a golfer'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      InlineMessage(
                          kind: InlineMessageKind.error, text: _error!),
                    ],
                    const SizedBox(height: 24),
                    if (!_anyScore)
                      GolfPrimaryButton(
                        label: _saving ? 'Saving…' : 'Save groups',
                        onPressed: (_saving || !_dirty || problem != null)
                            ? null
                            : _save,
                      ),
                  ],
                ),
    );
  }

  Widget _readOnlyCard(int label, List<int> ids) {
    final theme = Theme.of(context);
    final byId = {for (final p in _players) p.id: p};
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(
          width: 78,
          child: Text('Group $label',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: Text(ids.map((i) => byId[i]?.name ?? '?').join(', '),
              style: theme.textTheme.bodyMedium),
        ),
      ]),
    );
  }
}
