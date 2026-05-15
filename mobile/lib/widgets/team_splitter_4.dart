import 'package:flutter/material.dart';

import '../api/models.dart';

/// Reorderable 4-player team picker with position-based team affinity.
///
/// Rows 0 and 1 are Team A, rows 2 and 3 are Team B.  The user drags rows
/// to assemble the desired teams (and, where it matters, the order within
/// a team).  One gesture serves three games:
///   • Nassau          — order within team is cosmetic
///   • Sixes match-start — order within team controls hole rotation
///   • Sixes extra match — pure 2v2, order is cosmetic
///
/// The current order is exposed via [onChanged].  Callers extract
/// `teamA = ordered.sublist(0, 2)` and `teamB = ordered.sublist(2, 4)`.
class TeamSplitter4 extends StatefulWidget {
  final List<Membership> players;
  final ValueChanged<List<Membership>> onChanged;

  /// Team labels shown as a chip inside each player row.  The app uses
  /// Red/Blue as the standard team identity across casual games; Cup
  /// callers can override with the tournament team names.
  final String teamALabel;
  final String teamBLabel;

  /// Team accent colors used for the row tint and the team chip.
  final Color teamAColor;
  final Color teamBColor;

  /// When false, hides the drag handles and disables reordering.  Useful
  /// for read-only displays of an already-set foursome.
  final bool reorderable;

  const TeamSplitter4({
    super.key,
    required this.players,
    required this.onChanged,
    this.teamALabel = 'Red',
    this.teamBLabel = 'Blue',
    this.teamAColor = const Color(0xFFB71C1C),
    this.teamBColor = const Color(0xFF0D47A1),
    this.reorderable = true,
  });

  @override
  State<TeamSplitter4> createState() => _TeamSplitter4State();
}

class _TeamSplitter4State extends State<TeamSplitter4> {
  late List<Membership> _ordered;

  @override
  void initState() {
    super.initState();
    assert(widget.players.length == 4,
        'TeamSplitter4 requires exactly 4 players.');
    _ordered = List.of(widget.players);
  }

  @override
  void didUpdateWidget(covariant TeamSplitter4 old) {
    super.didUpdateWidget(old);
    // Reset only when the player composition actually changes (e.g. a round
    // reload swapped a player out) — otherwise keep the user's arrangement.
    final oldIds = old.players.map((m) => m.player.id).toSet();
    final newIds = widget.players.map((m) => m.player.id).toSet();
    if (oldIds.length != newIds.length || !oldIds.containsAll(newIds)) {
      _ordered = List.of(widget.players);
    }
  }

  void _onReorder(int oldIdx, int newIdx) {
    setState(() {
      if (newIdx > oldIdx) newIdx -= 1;
      final m = _ordered.removeAt(oldIdx);
      _ordered.insert(newIdx, m);
    });
    widget.onChanged(_ordered);
  }

  Color _teamColorFor(int index) =>
      index < 2 ? widget.teamAColor : widget.teamBColor;

  String _teamLabelFor(int index) =>
      index < 2 ? widget.teamALabel : widget.teamBLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: 4,
        onReorder: widget.reorderable ? _onReorder : (_, __) {},
        proxyDecorator: (child, _, __) => Material(
          elevation: 6,
          color: Colors.transparent,
          child: child,
        ),
        itemBuilder: (ctx, i) => _PlayerRow(
          key: ValueKey('p-${_ordered[i].player.id}'),
          index: i,
          member: _ordered[i],
          teamColor: _teamColorFor(i),
          teamLabel: _teamLabelFor(i),
          reorderable: widget.reorderable,
        ),
      ),
      if (widget.reorderable) ...[
        const SizedBox(height: 8),
        Text(
          'Drag rows to change teams or reorder within a team.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    ]);
  }
}

class _PlayerRow extends StatelessWidget {
  final int        index;
  final Membership member;
  final Color      teamColor;
  final String     teamLabel;
  final bool       reorderable;

  const _PlayerRow({
    super.key,
    required this.index,
    required this.member,
    required this.teamColor,
    required this.teamLabel,
    required this.reorderable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: teamColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: teamColor.withOpacity(0.4)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: teamColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(teamLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              )),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(member.player.name,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text('Hcp ${member.playingHandicap}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        if (reorderable)
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.drag_handle,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ]),
    );
  }
}
