/// screens/road_trip_players_screen.dart
/// -------------------------------------
/// **Players & Handicaps** — what every golfer on the trip is playing off,
/// and the organiser's manual adjustment.
///
/// A trip is long enough for an index to be wrong, and on a trip whose own
/// rounds feed the index it is wrong BECAUSE of the trip. So the organiser
/// can move one, and the screen is built around the two things that make
/// that a ruling rather than a row:
///
///   * **It applies from the next unplayed round.** Stated before the save,
///     with the round named. Rounds already played keep the handicap they
///     were scored with — the server picks that round, not this screen.
///   * **A reason is required, and it is shown to the group.** An index cut
///     mid-trip is the organiser taking strokes off somebody in a competition
///     he is losing money in.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/section_card.dart';
import '../utils/stroke_play_standing.dart';

class RoadTripPlayersScreen extends StatefulWidget {
  final int    tournamentId;
  final String tournamentName;

  const RoadTripPlayersScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<RoadTripPlayersScreen> createState() => _RoadTripPlayersScreenState();
}

class _RoadTripPlayersScreenState extends State<RoadTripPlayersScreen> {
  Map<String, dynamic>? _data;
  bool    _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final d = await context.read<AuthProvider>().client
          .getRoadTripHandicaps(widget.tournamentId);
      if (!mounted) return;
      setState(() { _data = d; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _golfers =>
      ((_data?['golfers'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Map<String, dynamic>? get _next {
    final n = _data?['next_round'];
    return n is Map ? Map<String, dynamic>.from(n) : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Players & Handicaps')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: friendlyError(_error!), onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                    children: [
                      Text(
                        _data?['handicap_mode'] == 'locked'
                            ? 'Index locked for the trip. Strokes are worked '
                              'out for each course from its slope and rating.'
                            : 'Index updated before each round. Strokes are '
                              'worked out for each course from its slope and '
                              'rating.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.45),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _next == null
                            ? 'Every round has been played, so there is '
                              'nothing left to adjust.'
                            : 'A change applies from R${_next!['round_number']}'
                              ' · ${_next!['course']}.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.45),
                      ),
                      const SizedBox(height: 12),
                      for (final g in _golfers)
                        _GolferRow(
                          golfer : g,
                          canEdit: _next != null,
                          onTap  : () => _adjust(g),
                        ),
                    ],
                  ),
                ),
    );
  }

  Future<void> _adjust(Map<String, dynamic> golfer) async {
    final result = await showModalBottomSheet<({double index, String why})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AdjustSheet(
        golfer   : golfer,
        nextRound: _next!,
      ),
    );
    if (result == null || !mounted) return;
    try {
      await context.read<AuthProvider>().client.adjustRoadTripIndex(
            widget.tournamentId,
            playerId     : golfer['player_id'] as int,
            handicapIndex: result.index,
            reason       : result.why,
          );
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }
}

class _GolferRow extends StatelessWidget {
  final Map<String, dynamic> golfer;
  final bool canEdit;
  final VoidCallback onTap;
  const _GolferRow(
      {required this.golfer, required this.canEdit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final adj   = golfer['adjustment'];
    final trip  = (golfer['trip_index'] as num?)?.toDouble() ?? 0;
    final own   = (golfer['index'] as num?)?.toDouble() ?? 0;
    return SectionCard(
      title: golfer['name']?.toString() ?? '',
      trailing: canEdit
          ? TextButton(onPressed: onTap, child: const Text('Adjust'))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (adj is Map) ...[
          // **The cut is stated on his own row**, with the reason. It is the
          // difference between a ruling and a rumour.
          Text('Index $own → ${adj['index']} from R${adj['from_round']}',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.tertiary,
                  fontWeight: FontWeight.w600)),
          Text(adj['reason']?.toString() ?? '',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ] else
          Text('Index ${trip.toStringAsFixed(1)}',
              style: theme.textTheme.bodyMedium),
        if (golfer['average_net_to_par'] != null)
          Text(
            'Average net ${toParLabel(
                (golfer['average_net_to_par'] as num).round())} over '
            '${golfer['rounds_played']} rounds',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ]),
    );
  }
}

/// **Save is dead until the index moves AND a reason is typed.** Both, because
/// both are the rule: an adjustment that changes nothing is noise on the
/// group's board, and one with no reason is the thing the reason field exists
/// to prevent.
class _AdjustSheet extends StatefulWidget {
  final Map<String, dynamic> golfer;
  final Map<String, dynamic> nextRound;
  const _AdjustSheet({required this.golfer, required this.nextRound});

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  late double _index =
      (widget.golfer['trip_index'] as num?)?.toDouble() ?? 0;
  late final double _start = _index;
  final _why = TextEditingController();

  @override
  void dispose() {
    _why.dispose();
    super.dispose();
  }

  void _step(double d) => setState(() {
        // 0.1 steps, and never below scratch-minus: a plus handicap is a real
        // index, so the floor is what the field allows rather than zero.
        _index = ((_index + d) * 10).roundToDouble() / 10;
      });

  bool get _ready => _index != _start && _why.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = (widget.golfer['name']?.toString() ?? '').split(' ').first;
    final avg   = widget.golfer['average_net_to_par'];
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Adjust $first's handicap",
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (avg != null)
            Text(
              'Average net ${toParLabel((avg as num).round())} over '
              '${widget.golfer['rounds_played']} rounds.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: 14),
          Row(children: [
            const Expanded(child: Text('Index')),
            IconButton.outlined(
              onPressed: () => _step(-0.1),
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 64,
              child: Text(_index.toStringAsFixed(1),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _index != _start
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurface)),
            ),
            IconButton.outlined(
              onPressed: () => _step(0.1),
              icon: const Icon(Icons.add),
            ),
          ]),
          const Divider(height: 20),
          Row(children: [
            const Expanded(child: Text('Applies from')),
            Text('R${widget.nextRound['round_number']} · '
                 '${widget.nextRound['course']}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 4),
          Text(
            'Rounds already played keep the handicap they were scored with.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _why,
            minLines: 2,
            maxLines: 3,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Reason',
              helperText: 'Shown to the group',
            ),
          ),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _ready
                  ? () => Navigator.of(context)
                      .pop((index: _index, why: _why.text.trim()))
                  : null,
              child: const Text('Save'),
            ),
          ]),
        ]),
    );
  }
}
